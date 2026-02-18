#!/usr/bin/env bash
# kc2g_muf_heatmap.sh
set -euo pipefail

MUFD_URL="https://prop.kc2g.com/renders/current/mufd-normal-now.geojson"
STAS_URL="https://prop.kc2g.com/api/stations.json"
OUT="kc2g_muf_heatmap"
R="-180/180/-90/90"
J="Q0/6.6i"
DPI=100

CPT="muf_hamclock.cpt"
if [[ ! -f "$CPT" ]]; then
  echo "ERROR: $CPT not found in $(pwd)" >&2; exit 1
fi

# ── 1. Fetch ───────────────────────────────────────────────────────────────────
curl -fsSL "$MUFD_URL" -o mufd.geojson
curl -fsSL "$STAS_URL" -o stations.json

# ── 2. Build smooth grid, stretch using station-derived range ──────────────────
python3 - << 'PYEOF'
import json, sys
import numpy as np
from scipy.interpolate import griddata
from scipy.ndimage import gaussian_filter

gj     = json.load(open("mufd.geojson"))
stas   = json.load(open("stations.json"))

# ── Contour points ─────────────────────────────────────────────────────────────
pts = []
for feat in gj["features"]:
    value = float(feat["properties"]["level-value"])
    geom  = feat["geometry"]
    coords = geom["coordinates"]
    lines = [coords] if geom["type"] == "LineString" else coords
    for line in lines:
        for lon, lat in line:
            pts.append((float(lon), float(lat), value))
pts = np.array(pts)
levels = sorted(set(pts[:, 2]))
print(f"  Contour levels: {levels}", file=sys.stderr)

# ── Station range — tells us real current MUF extremes ─────────────────────────
sta_mufd = []
for row in stas:
    mufd = row.get("mufd") or row.get("muf")
    conf = float(row.get("confidence", 1.0) or 1.0)
    if mufd is None or conf < 0.1: continue
    sta_mufd.append(float(mufd))

sta_mufd = np.array(sta_mufd)
# Use 5th/95th percentile to avoid outlier stations skewing the range
sta_lo = max(5.0,  np.percentile(sta_mufd,  5))
sta_hi = min(35.0, np.percentile(sta_mufd, 95))
print(f"  Station MUF 5th–95th pct: {sta_lo:.1f} – {sta_hi:.1f} MHz", file=sys.stderr)

# ── Interpolate contour shape ──────────────────────────────────────────────────
lons = np.linspace(-180, 180, 361)
lats = np.linspace(-90,   90, 181)
glon, glat = np.meshgrid(lons, lats)

print("  Interpolating...", file=sys.stderr)
grid = griddata(pts[:, :2], pts[:, 2], (glon, glat), method="linear")
nan_mask = np.isnan(grid)
if nan_mask.any():
    grid_nn = griddata(pts[:, :2], pts[:, 2], (glon, glat), method="nearest")
    grid[nan_mask] = grid_nn[nan_mask]
grid = gaussian_filter(grid, sigma=1.5)
print(f"  Interpolated: {grid.min():.1f} – {grid.max():.1f} MHz", file=sys.stderr)

# ── Stretch: map contour range → station range ─────────────────────────────────
# Instead of forcing 5–35, we use the real current lo/hi from stations.
# This means the darkest nightside maps to sta_lo (e.g. 7 MHz) and the
# brightest dayside maps to sta_hi (e.g. 28 MHz) — matching reality.
c_min = grid.min()
c_max = grid.max()
grid_s = sta_lo + (grid - c_min) / (c_max - c_min) * (sta_hi - sta_lo)
grid_s = np.clip(grid_s, 5, 35)
print(f"  Stretched:    {grid_s.min():.1f} – {grid_s.max():.1f} MHz", file=sys.stderr)

with open("mufd_grid.xyz", "w") as f:
    for j in range(grid_s.shape[0]):
        for i in range(grid_s.shape[1]):
            f.write(f"{lons[i]:.2f}\t{lats[j]:.2f}\t{grid_s[j,i]:.3f}\n")
print("  Done.", file=sys.stderr)
PYEOF

gmt xyz2grd mufd_grid.xyz -R${R} -I1 -Gmufd.grd
echo "  Grid: $(gmt grdinfo mufd.grd -C | awk '{print $6, "-", $7, "MHz"}')"

# ── 3. Stations ────────────────────────────────────────────────────────────────
python3 - << 'PYEOF'
import json, sys
with open("stations.json") as fh:
    data = json.load(fh)
circles, labels = [], []
for row in data:
    st   = row.get("station", {})
    lon  = st.get("longitude")
    lat  = st.get("latitude")
    mufd = row.get("mufd") or row.get("muf")
    conf = float(row.get("confidence", 1.0) or 1.0)
    if lon is None or lat is None or mufd is None: continue
    if float(conf) < 0.05: continue
    mufd = float(mufd)
    circles.append(f"{float(lon):.3f}\t{float(lat):.3f}\t{mufd:.2f}")
    labels.append( f"{float(lon):.3f}\t{float(lat):.3f}\t{mufd:.0f}")
with open("stations_circles.txt", "w") as f:
    f.write("\n".join(circles) + "\n")
with open("stations_labels.txt", "w") as f:
    f.write("\n".join(labels) + "\n")
print(f"  {len(circles)} stations", file=sys.stderr)
PYEOF

# ── 4. Render ──────────────────────────────────────────────────────────────────
gmt begin "$OUT" png E${DPI}
  gmt set MAP_FRAME_TYPE=plain
  gmt coast -R${R} -J${J} -Gblack -Sblack -B0 -Dc
  gmt grdimage mufd.grd -R${R} -J${J} -C${CPT} -Q
  gmt coast   -R${R} -J${J} -W0.6p,black -N1/0.4p,black -Dc
  gmt grdcontour mufd.grd -R${R} -J${J} -C2 -W0.5p,white@60 -S4
  gmt plot stations_circles.txt -R${R} -J${J} -Sc0.15i -G0/200/0 -W0.5p,black
  gmt text stations_labels.txt  -R${R} -J${J} -F+f6p,Helvetica-Bold,black+jCM
gmt end show
echo "Done → ${OUT}.png"

