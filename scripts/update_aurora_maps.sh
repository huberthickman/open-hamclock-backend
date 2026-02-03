#!/usr/bin/env bash
set -euo pipefail

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
W=660
H=330

JSON_URL="https://services.swpc.noaa.gov/json/ovation_aurora_latest.json"

DAY_BASE_CANDIDATES=(
  "$OUTDIR/map-D-660x330-Countries.bmp.z"
  "$OUTDIR/map-D-660x330-Countries.bmp"
  "$OUTDIR/map-D-2640x1320-Countries.bmp.z"
)

NIGHT_BASE_CANDIDATES=(
  "$OUTDIR/map-N-660x330-Countries.bmp.z"
  "$OUTDIR/map-N-660x330-Countries.bmp"
)

# Aurora shaping
AURORA_MIN="${AURORA_MIN:-2}"
AURORA_GAMMA="${AURORA_GAMMA:-0.9}"
AURORA_SCALE="${AURORA_SCALE:-1.5}"
BLUR_PASSES="${BLUR_PASSES:-2}"
GLOW_ALPHA="${GLOW_ALPHA:-1.0}"

# Night basemap processing
NIGHT_WHITE_THRESH="${NIGHT_WHITE_THRESH:-5}"
NIGHT_BOLD_PASSES="${NIGHT_BOLD_PASSES:-2}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: missing command: $1" >&2; exit 1; }; }
need curl
need python3

mkdir -p "$OUTDIR"

json_file="$TMPDIR/ovation_aurora_latest.json"
curl -fsS --retry 3 --retry-delay 2 "$JSON_URL" -o "$json_file"

pick_first_existing() {
  for f in "$@"; do
    if [[ -f "$f" ]]; then echo "$f"; return 0; fi
  done
  return 1
}

DAY_BASE="$(pick_first_existing "${DAY_BASE_CANDIDATES[@]}")" || {
  echo "ERROR: No DAY basemap found. Expected one of:" >&2
  printf '  %s\n' "${DAY_BASE_CANDIDATES[@]}" >&2
  exit 1
}

NIGHT_BASE="$(pick_first_existing "${NIGHT_BASE_CANDIDATES[@]}")" || {
  echo "ERROR: No NIGHT basemap found. Expected one of:" >&2
  printf '  %s\n' "${NIGHT_BASE_CANDIDATES[@]}" >&2
  exit 1
}

echo "DAY_BASE=$DAY_BASE"
echo "NIGHT_BASE=$NIGHT_BASE"

python3 - <<'PY' \
  "$json_file" "$DAY_BASE" "$NIGHT_BASE" "$OUTDIR" "$W" "$H" \
  "$AURORA_MIN" "$AURORA_GAMMA" "$AURORA_SCALE" "$BLUR_PASSES" "$GLOW_ALPHA" \
  "$NIGHT_WHITE_THRESH" "$NIGHT_BOLD_PASSES"
import json, os, struct, sys, zlib
import numpy as np

(json_path, day_base_path, night_base_path, outdir, W, H,
 vmin, gamma, scale, blur_passes, glow_alpha,
 night_thresh, night_bold_passes) = sys.argv[1:]

W=int(W); H=int(H)
vmin=float(vmin); gamma=float(gamma); scale=float(scale)
blur_passes=int(blur_passes); glow_alpha=float(glow_alpha)
night_thresh=float(night_thresh); night_bold_passes=int(night_bold_passes)

def zread(path: str) -> bytes:
    data = open(path, "rb").read()
    if path.endswith(".z"):
        return zlib.decompress(data)
    return data

def read_bmp_v4_rgb565_topdown(blob: bytes):
    if blob[0:2] != b"BM":
        raise ValueError("Not a BMP")
    bfOffBits = struct.unpack_from("<I", blob, 10)[0]
    dib = struct.unpack_from("<I", blob, 14)[0]
    w = struct.unpack_from("<i", blob, 18)[0]
    h = struct.unpack_from("<i", blob, 22)[0]
    planes = struct.unpack_from("<H", blob, 26)[0]
    bpp = struct.unpack_from("<H", blob, 28)[0]
    comp = struct.unpack_from("<I", blob, 30)[0]
    if bfOffBits != 122 or dib != 108 or planes != 1 or bpp != 16 or comp != 3:
        raise ValueError(f"Unexpected BMP header off={bfOffBits} dib={dib} planes={planes} bpp={bpp} comp={comp}")
    if h >= 0:
        raise ValueError("Expected top-down BMP (negative height)")
    H0 = -h
    pix = blob[bfOffBits:bfOffBits + (w*H0*2)]
    arr = np.frombuffer(pix, dtype="<u2").reshape((H0, w))
    return w, H0, arr

def rgb565_to_rgb888(arr565: np.ndarray) -> np.ndarray:
    a = arr565.astype(np.uint16)
    r = ((a >> 11) & 0x1F).astype(np.uint16)
    g = ((a >> 5)  & 0x3F).astype(np.uint16)
    b = (a & 0x1F).astype(np.uint16)
    r8 = ((r * 255 + 15) // 31).astype(np.uint8)
    g8 = ((g * 255 + 31) // 63).astype(np.uint8)
    b8 = ((b * 255 + 15) // 31).astype(np.uint8)
    return np.stack([r8, g8, b8], axis=2)

def rgb888_to_rgb565(rgb: np.ndarray) -> np.ndarray:
    r = (rgb[:,:,0].astype(np.uint16) >> 3) & 0x1F
    g = (rgb[:,:,1].astype(np.uint16) >> 2) & 0x3F
    b = (rgb[:,:,2].astype(np.uint16) >> 3) & 0x1F
    return (r << 11) | (g << 5) | b

def write_bmp_v4_rgb565_topdown(path: str, arr565: np.ndarray):
    H0, W0 = arr565.shape
    bfOffBits = 122
    pix = arr565.astype("<u2").tobytes()
    bfSize = bfOffBits + len(pix)

    filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, bfOffBits)

    biSize = 108
    biWidth = W0
    biHeight = -H0
    biPlanes = 1
    biBitCount = 16
    biCompression = 3
    biSizeImage = len(pix)

    rmask, gmask, bmask, amask = 0xF800, 0x07E0, 0x001F, 0x0000
    cstype = 0x73524742  # 'sRGB'
    endpoints = b"\x00"*36
    gamma0 = b"\x00"*12

    v4hdr = struct.pack(
        "<IiiHHIIIIII",
        biSize, biWidth, biHeight, biPlanes, biBitCount, biCompression,
        biSizeImage, 0, 0, 0, 0
    ) + struct.pack("<IIII", rmask, gmask, bmask, amask) + struct.pack("<I", cstype) + endpoints + gamma0

    with open(path, "wb") as f:
        f.write(filehdr); f.write(v4hdr); f.write(pix)

def zwrite(path: str, blob: bytes):
    with open(path, "wb") as f:
        f.write(zlib.compress(blob, 9))

def resize_nn_rgb(rgb: np.ndarray, Wt: int, Ht: int) -> np.ndarray:
    Hs, Ws, _ = rgb.shape
    yi = (np.linspace(0, Hs-1, Ht)).astype(np.int32)
    xi = (np.linspace(0, Ws-1, Wt)).astype(np.int32)
    return rgb[yi][:, xi]

def blur5(img: np.ndarray, passes: int) -> np.ndarray:
    if passes <= 0:
        return img.astype(np.float32)
    k = np.array([1,4,6,4,1], dtype=np.float32) / 16.0
    out = img.astype(np.float32)
    for _ in range(passes):
        pad = np.pad(out, ((0,0),(2,2)), mode="edge")
        tmp = (k[0]*pad[:,0:-4] + k[1]*pad[:,1:-3] + k[2]*pad[:,2:-2] + k[3]*pad[:,3:-1] + k[4]*pad[:,4:])
        pad2 = np.pad(tmp, ((2,2),(0,0)), mode="edge")
        out = (k[0]*pad2[0:-4,:] + k[1]*pad2[1:-3,:] + k[2]*pad2[2:-2,:] + k[3]*pad2[3:-1,:] + k[4]*pad2[4:,:])
    return out

def dilate(mask: np.ndarray, passes: int) -> np.ndarray:
    if passes <= 0:
        return mask
    m = mask.astype(np.uint8)
    for _ in range(passes):
        p = np.pad(m, ((1,1),(1,1)), mode="edge")
        m = np.maximum.reduce([
            p[0:-2,0:-2], p[0:-2,1:-1], p[0:-2,2:],
            p[1:-1,0:-2], p[1:-1,1:-1], p[1:-1,2:],
            p[2:,0:-2],   p[2:,1:-1],   p[2:,2:]
        ])
    return m.astype(bool)

def load_basemap(path: str) -> np.ndarray:
    blob = zread(path)
    bw, bh, base565 = read_bmp_v4_rgb565_topdown(blob)
    rgb = rgb565_to_rgb888(base565)
    if (bw, bh) != (W, H):
        rgb = resize_nn_rgb(rgb, W, H)
    return rgb

day_base = load_basemap(day_base_path)
night_in = load_basemap(night_base_path)

# --- NIGHT outlines: use max channel threshold (not luma) ---
mx = night_in.max(axis=2).astype(np.float32)

#print("DEBUG night mx.max:", float(mx.max()), "night_thresh:", night_thresh)
#print("DEBUG counts:", int((mx>1).sum()), int((mx>10).sum()), int((mx>50).sum()))

outline = (mx > night_thresh)
if outline.sum() == 0:
    # fallback: threshold too high; try 1
    outline = (mx > 1.0)

outline = dilate(outline, night_bold_passes)

#print("outline pixels:", int(outline.sum()), "of", W*H)

night_base = np.zeros((H, W, 3), dtype=np.uint8)
night_base[outline] = 255  # pure white on black

# --- Render OVATION -> intensity ---
aur = json.load(open(json_path, "r", encoding="utf-8"))
coords = np.array(aur["coordinates"], dtype=np.float32)
vals = coords[:,2]
grid = np.reshape(vals, (181, 360), order="F")

y_idx = (np.linspace(0, 180, H)).astype(np.int32)
x_idx = (np.linspace(0, 359, W)).astype(np.int32)
img = grid[y_idx][:, x_idx]

img = np.flipud(img)
img = np.roll(img, img.shape[1] // 2, axis=1)
img = np.clip(img, 0.0, 100.0)
img[img < vmin] = 0.0
norm = (img / 100.0) ** gamma
g0 = (norm * 255.0 * scale).clip(0, 255)
g_blur = blur5(g0, blur_passes)
g = (g_blur * glow_alpha).clip(0, 255).astype(np.uint8)

# Day: basemap + green glow (no darkening)
day = day_base.astype(np.uint16)
day[:,:,1] = np.minimum(255, day[:,:,1] + g).astype(np.uint16)
day_rgb = day.astype(np.uint8)

# Night: white-only outlines + green glow, then re-force outlines to pure white
night = night_base.astype(np.uint16)
night[:,:,1] = np.minimum(255, night[:,:,1] + g).astype(np.uint16)
night_rgb = night.astype(np.uint8)
night_rgb[outline] = 255

def emit(tag: str, rgb: np.ndarray):
    bmp = os.path.join(outdir, f"map-{tag}-{W}x{H}-Aurora.bmp")
    bmpz = bmp + ".z"
    arr565 = rgb888_to_rgb565(rgb)
    write_bmp_v4_rgb565_topdown(bmp, arr565)
    zwrite(bmpz, open(bmp, "rb").read())

emit("D", day_rgb)
emit("N", night_rgb)

print("OK: aurora maps updated")
PY

chmod 0644 \
  "$OUTDIR/map-D-${W}x${H}-Aurora.bmp" \
  "$OUTDIR/map-N-${W}x${H}-Aurora.bmp" \
  "$OUTDIR/map-D-${W}x${H}-Aurora.bmp.z" \
  "$OUTDIR/map-N-${W}x${H}-Aurora.bmp.z"

