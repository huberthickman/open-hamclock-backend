#!/usr/bin/env python3
"""
muf_map.py — World map of median MUF from DE to every point on Earth.

For each grid point, runs dvoacap at 5 probe frequencies and finds the
frequency where muf_day crosses 0.5 — that is the "median MUF" (MUF
exceeded on half the days of the month). Matches HamClock user guide:
"median Maximum Usable Frequency between DE and other points."

Fallback: for long/multi-hop paths where dvoacap returns all zeros,
estimates MUF from a simplified foF2 model at the path midpoint.

Grid → scipy bicubic interpolation → full-resolution PNG.
Color scale: jet 3–35 MHz (same as the freq legend bar).
"""
import argparse, hashlib, io, math, os, sys, time
from multiprocessing import Pool, cpu_count
from pathlib import Path
import numpy as np

# Probe frequencies to bracket the median MUF
PROBE_FREQS = [3.5, 7.0, 14.0, 21.0, 28.0]
MUF_MIN =  3.0
MUF_MAX = 35.0


# ---------------------------------------------------------------------------
# Jet colormap: blue(3MHz) → cyan → green → yellow → orange → red(35MHz)
# ---------------------------------------------------------------------------
def _jet(t):
    t = max(0.0, min(1.0, t))
    if   t < 0.125: return (0,   int(128 + t/0.125*127),         255)
    elif t < 0.375: return (0,   255,                             int(255-(t-0.125)/0.25*255))
    elif t < 0.625: return (int((t-0.375)/0.25*255), 255,        int(255-(t-0.375)/0.25*255))
    elif t < 0.875: return (255, int(255-(t-0.625)/0.25*255),    0)
    else:           return (int(255-(t-0.875)/0.125*128), 0,     0)

def mhz_to_rgba(mhz):
    t = max(0.0, min(1.0, (mhz - MUF_MIN) / (MUF_MAX - MUF_MIN)))
    r, g, b = _jet(t)
    return (r, g, b, 255)


# ---------------------------------------------------------------------------
# foF2 fallback model — used when dvoacap fails for long paths
# ---------------------------------------------------------------------------
def _solar_dec(month):
    return 23.45 * math.sin(math.radians(360/365 * ((month-1)*30.4+15 - 81)))

def _cos_zenith(lat, lng, utc, month):
    decl = math.radians(_solar_dec(month))
    ha   = math.radians(lng - (-15.0*(utc-12.0)))
    la   = math.radians(lat)
    return math.sin(la)*math.sin(decl) + math.cos(la)*math.cos(decl)*math.cos(ha)

def _foF2(lat, lng, utc, month, ssn):
    cz      = _cos_zenith(lat, lng, utc, month)
    abs_lat = abs(lat)
    ssn_f   = 1.0 + ssn / 100.0
    lat_f   = max(0.20, math.cos(math.radians(min(85, abs_lat) * 0.90)))
    if cz > 0:
        fof2 = 7.0 * ssn_f * max(0.15, cz**0.25) * lat_f
    else:
        lf = max(0.15, 1.0 - abs_lat / 85.0)
        if cz > -0.07:
            lf *= 1.0 + 0.4*(cz+0.07)/0.07
        fof2 = 1.6 * ssn_f * lf
    return max(1.5, min(12.0, fof2))

def _great_circle_km(la1, lo1, la2, lo2):
    R = 6371.0
    la1,lo1,la2,lo2 = map(math.radians, [la1,lo1,la2,lo2])
    a = (math.sin((la2-la1)/2)**2 +
         math.cos(la1)*math.cos(la2)*math.sin((lo2-lo1)/2)**2)
    return 2*R*math.asin(math.sqrt(max(0.0, min(1.0, a))))

def _fallback_muf(tx_lat, tx_lng, rx_lat, rx_lng, utc, month, ssn):
    """
    Estimate median MUF using worst-case hop foF2 × M-factor.
    For long paths, MUF is limited by the lowest foF2 hop along the path.
    Sample foF2 at TX, midpoint, and RX — use the minimum.
    """
    dist    = _great_circle_km(tx_lat, tx_lng, rx_lat, rx_lng)
    mid_lat = (tx_lat + rx_lat) / 2.0
    mid_lng = (tx_lng + rx_lng) / 2.0

    fof2_tx  = _foF2(tx_lat,  tx_lng,  utc, month, ssn)
    fof2_mid = _foF2(mid_lat, mid_lng, utc, month, ssn)
    fof2_rx  = _foF2(rx_lat,  rx_lng,  utc, month, ssn)
    # MUF is limited by the weakest hop
    fof2 = min(fof2_tx, fof2_mid, fof2_rx)

    # M-factor by distance
    if dist < 100:
        m = 1.1
    elif dist < 4000:
        m = 2.5 + 1.0 * min(1.0, dist/3000.0)
    elif dist < 8000:
        m = 3.5 - 0.5*(dist-4000)/4000.0
    else:
        m = max(1.8, 3.0 - 0.8*(dist-8000)/4000.0)
    return max(MUF_MIN, min(MUF_MAX, fof2 * m))


# ---------------------------------------------------------------------------
# dvoacap worker — one engine per process
# ---------------------------------------------------------------------------
def _worker_init(tx_lat, tx_lng, utc, ssn, month):
    global _engine, _tx_lat, _tx_lng, _utc, _ssn, _month
    import numpy as _np
    from dvoacap.path_geometry import GeoPoint
    from dvoacap.prediction_engine import PredictionEngine
    _engine = PredictionEngine()
    _engine.params.ssn                  = float(ssn)
    _engine.params.month                = int(month)
    _engine.params.tx_location          = GeoPoint.from_degrees(tx_lat, tx_lng)
    _engine.params.tx_power             = 100.0
    _engine.params.min_angle            = _np.deg2rad(3.0)
    _engine.params.long_path            = False
    _engine.params.required_snr         = 3.0
    _engine.params.required_reliability = 0.1
    _tx_lat, _tx_lng, _utc, _ssn, _month = tx_lat, tx_lng, utc, ssn, month


def _worker_predict(args):
    """
    Returns (rx_lat, rx_lng, muf_mhz) where muf_mhz is the median MUF
    — the interpolated frequency where muf_day crosses 0.5.
    Falls back to foF2 model if dvoacap returns all zeros.
    """
    rx_lat, rx_lng = args
    try:
        from dvoacap.path_geometry import GeoPoint
        rx = GeoPoint.from_degrees(rx_lat, rx_lng)
        _engine.predict(
            rx_location=rx,
            utc_time=float(_utc) / 24.0,
            frequencies=PROBE_FREQS
        )
        probs = [float(getattr(p.signal, 'muf_day', 0.0))
                 for p in _engine.predictions]

        # Find median MUF: interpolate where muf_day crosses 0.5
        # muf_day is P(MUF > freq), so it should decrease with frequency
        effective_muf = None
        for i in range(len(PROBE_FREQS)):
            if probs[i] >= 0.5:
                effective_muf = PROBE_FREQS[i]
                # Interpolate between this and next probe
                if i + 1 < len(PROBE_FREQS) and probs[i+1] < 0.5:
                    dp = probs[i] - probs[i+1]
                    if dp > 0:
                        t = (probs[i] - 0.5) / dp
                        effective_muf = PROBE_FREQS[i] + t*(PROBE_FREQS[i+1]-PROBE_FREQS[i])
                        break

        # If dvoacap returned all zeros — use fallback
        if effective_muf is None or max(probs) < 0.01:
            effective_muf = _fallback_muf(
                _tx_lat, _tx_lng, rx_lat, rx_lng, _utc, _month, _ssn)

        return (rx_lat, rx_lng, max(MUF_MIN, min(MUF_MAX, effective_muf)))

    except Exception as e:
        muf = _fallback_muf(_tx_lat, _tx_lng, rx_lat, rx_lng, _utc, _month, _ssn)
        return (rx_lat, rx_lng, muf)


# ---------------------------------------------------------------------------
# Build grid
# ---------------------------------------------------------------------------
def build_grid(grid_deg):
    lats = np.arange(-90 + grid_deg/2,  90, grid_deg)
    lngs = np.arange(-180 + grid_deg/2, 180, grid_deg)
    return [(float(la), float(lo)) for la in lats for lo in lngs], lats, lngs


# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
def render_map(muf_grid, grid_lats, grid_lngs,
               tx_lat, tx_lng, utc, month,
               width=660, height=330):
    from PIL import Image, ImageDraw
    from scipy.interpolate import RegularGridInterpolator

    # Bicubic interpolation to full resolution
    interp = RegularGridInterpolator(
        (grid_lats, grid_lngs), muf_grid,
        method='linear', bounds_error=False, fill_value=MUF_MIN
    )
    map_lats = np.linspace(90, -90, height)
    map_lngs = np.linspace(-180, 180, width)
    ll, gg   = np.meshgrid(map_lats, map_lngs, indexing='ij')
    full     = interp(np.stack([ll.ravel(), gg.ravel()], axis=-1)).reshape(height, width)

    # Pre-compute TX pixel
    tx_px = (tx_lng + 180) / 360 * width
    tx_py = (90 - tx_lat)  / 180 * height

    # Pixel colors
    rgba = np.zeros((height, width, 4), dtype=np.uint8)
    for row in range(height):
        lat = 90.0 - row * 180.0 / height
        for col in range(width):
            lng = -180.0 + col * 360.0 / width
            mhz = float(full[row, col])
            # Skip zone: F2 reflection needs minimum path ~300-500km
            # Blend toward MUF_MIN within 500km of TX
            dist = _great_circle_km(tx_lat, tx_lng, lat, lng)
            if dist < 500:
                t    = dist / 500.0
                mhz  = MUF_MIN + (mhz - MUF_MIN) * (t ** 1.5)
            rgba[row, col] = mhz_to_rgba(mhz)

    img  = Image.fromarray(rgba, 'RGBA')
    draw = ImageDraw.Draw(img)

    # TX dot
    tx_x = int((tx_lng + 180) / 360 * width)
    tx_y = int((90 - tx_lat)  / 180 * height)
    draw.ellipse([(tx_x-5, tx_y-5),(tx_x+5, tx_y+5)],
                 outline=(255,255,255,255), width=2)
    draw.ellipse([(tx_x-2, tx_y-2),(tx_x+2, tx_y+2)],
                 fill=(255,255,255,255))

    img = _overlay_borders(img, width, height)
    return img


def _overlay_borders(img, width, height):
    import glob as _glob
    from PIL import Image
    base_dir = '/opt/hamclock-backend/htdocs/ham/HamClock/maps'
    all_bmps = sorted(_glob.glob(f'{base_dir}/map-*-Countries.bmp'),
                      key=lambda p: os.path.getsize(p))
    candidates = ([f'{base_dir}/map-N-{width}x{height}-Countries.bmp',
                   f'{base_dir}/map-D-{width}x{height}-Countries.bmp']
                  + all_bmps)
    for path in candidates:
        if os.path.exists(path):
            try:
                base = Image.open(path).convert('RGB').resize((width, height))
                arr  = np.array(base)
                brightness = (arr[:,:,0].astype(int) +
                              arr[:,:,1].astype(int) +
                              arr[:,:,2].astype(int))
                border     = brightness > 80
                # Remove outermost edge pixels — the BMP has a frame border
                border[ :3, :]  = False
                border[-3:, :]  = False
                border[:,  :3]  = False
                border[:, -3:]  = False
                ov         = np.zeros((height, width, 4), dtype=np.uint8)
                ov[border] = [0, 0, 0, 200]
                return Image.alpha_composite(img, Image.fromarray(ov, 'RGBA'))
            except Exception as e:
                print(f"Border load failed: {e}", file=sys.stderr)
    return img


# ---------------------------------------------------------------------------
# Cache / main
# ---------------------------------------------------------------------------
def _cache_path(cache_dir, tx_lat, tx_lng, utc, ssn, month, mhz, grid, w, h):
    key = f"{tx_lat:.2f},{tx_lng:.2f},{utc},{ssn},{month},{mhz:.3f},{grid},{w},{h}"
    return Path(cache_dir) / f"muf-{hashlib.md5(key.encode()).hexdigest()[:12]}.png"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--txlat',     type=float, required=True)
    ap.add_argument('--txlng',     type=float, required=True)
    ap.add_argument('--utc',       type=int,   required=True)
    ap.add_argument('--month',     type=int,   required=True)
    ap.add_argument('--ssn',       type=float, required=True)
    ap.add_argument('--mhz',       type=float, default=14.0)
    ap.add_argument('--width',     type=int,   default=660)
    ap.add_argument('--height',    type=int,   default=330)
    ap.add_argument('--grid',      type=int,   default=10,
                    help='Grid spacing in degrees (default 10 = 648 points)')
    ap.add_argument('--workers',   type=int,   default=0)
    ap.add_argument('--cache-dir', type=str,   default='/tmp')
    ap.add_argument('--cache-ttl', type=int,   default=1800)
    ap.add_argument('--output',    type=str,   default='-')
    ap.add_argument('--timing',    action='store_true')
    args = ap.parse_args()

    workers = args.workers or max(1, cpu_count() - 1)

    cp = _cache_path(args.cache_dir, args.txlat, args.txlng,
                     args.utc, args.ssn, args.month, args.mhz,
                     args.grid, args.width, args.height)
    if args.cache_ttl > 0 and cp.exists():
        age = time.time() - cp.stat().st_mtime
        if age < args.cache_ttl:
            if args.timing:
                print(f"Cache hit ({age:.0f}s old)", file=sys.stderr)
            data = cp.read_bytes()
            (sys.stdout.buffer if args.output=='-'
             else open(args.output,'wb')).write(data)
            return

    t0 = time.time()
    points, grid_lats, grid_lngs = build_grid(args.grid)
    if args.timing:
        print(f"Grid: {len(points)} pts, {workers} workers", file=sys.stderr)

    with Pool(processes=workers,
              initializer=_worker_init,
              initargs=(args.txlat, args.txlng,
                        args.utc, args.ssn, args.month)) as pool:
        results = pool.map(_worker_predict, points)

    t1 = time.time()
    if args.timing:
        print(f"Predictions: {t1-t0:.2f}s", file=sys.stderr)

    # Assemble grid
    muf_grid = np.full((len(grid_lats), len(grid_lngs)), MUF_MIN)
    lat_idx  = {round(float(v), 4): i for i, v in enumerate(grid_lats)}
    lng_idx  = {round(float(v), 4): i for i, v in enumerate(grid_lngs)}
    n_dvocap = 0
    n_fallbk = 0
    for rx_lat, rx_lng, mhz in results:
        li = lat_idx.get(round(rx_lat, 4))
        lj = lng_idx.get(round(rx_lng, 4))
        if li is not None and lj is not None:
            muf_grid[li, lj] = mhz
            if mhz > MUF_MIN + 0.1:
                n_dvocap += 1
            else:
                n_fallbk += 1

    if args.timing:
        print(f"dvoacap: {n_dvocap} pts, fallback: {n_fallbk} pts", file=sys.stderr)

    img = render_map(muf_grid, grid_lats, grid_lngs,
                     args.txlat, args.txlng,
                     args.utc, args.month,
                     args.width, args.height)

    t2 = time.time()
    if args.timing:
        print(f"Render: {t2-t1:.2f}s  Total: {t2-t0:.2f}s", file=sys.stderr)

    buf = io.BytesIO()
    img.save(buf, format='PNG', optimize=True)
    png_bytes = buf.getvalue()
    try:
        cp.parent.mkdir(parents=True, exist_ok=True)
        cp.write_bytes(png_bytes)
    except Exception:
        pass
    if args.output == '-':
        sys.stdout.buffer.write(png_bytes)
    else:
        Path(args.output).write_bytes(png_bytes)


if __name__ == '__main__':
    main()
