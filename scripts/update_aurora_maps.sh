#!/bin/bash
set -e

export GMT_USERDIR=/opt/hamclock-backend/tmp
cd $GMT_USERDIR

source "/opt/hamclock-backend/scripts/lib_sizes.sh"
ohb_load_sizes   # populates SIZES=(...) per OHB conventions

JSON=ovation.json
XYZ=ovation.xyz

echo "Fetching OVATION..."
curl -fs https://services.swpc.noaa.gov/json/ovation_aurora_latest.json -o "$JSON"

# JSON -> XYZ in 0..360 longitude space for seamless polar gridding
# The aurora wraps around the poles so 0/360 avoids a seam in the grid.
# Rendering is done in -180/180 so HamClock city coordinates are correct.
python3 <<'EOF'
import json
d=json.load(open("ovation.json"))
with open("ovation.xyz","w") as f:
    for lon,lat,val in d["coordinates"]:
        if val <= 2:
            continue
        # keep lon in -180/180
        if lon > 180.0:
            lon -= 360.0
        f.write(f"{lon:.6f} {lat:.6f} {val:.6f}\n")
        # duplicate at both edges to avoid seam
        if lon == -180.0 or lon == 180.0:
            f.write(f"-180.000000 {lat:.6f} {val:.6f}\n")
            f.write(f"180.000000 {lat:.6f} {val:.6f}\n")
EOF

echo "Gridding aurora once..."

# nearneighbor with search radius of 3 degrees gives smooth edges
# without spreading data far from actual aurora locations.
# No grdfilter needed — avoids equatorial bleed entirely.
gmt nearneighbor "$XYZ" -R-180/180/-90/90 -I0.25 -S3 -Lx -Gaurora_raw.nc
gmt grdfilter aurora_raw.nc -Fg2 -D0 -Gaurora.nc
gmt grdclip aurora.nc -Sb1/NaN -Gaurora_clipped.nc

# Dynamically scale CPT to actual data max so bright neon always hits the peak
# Use at least 20 as floor so CPT thresholds don't collapse on quiet days
VMAX=$(gmt grdinfo aurora.nc -C | awk '{v=int($7); print (v>20)?v:20}')
echo "Aurora vmax: $VMAX"

V15=$(echo "$VMAX * 15 / 100" | bc)
V40=$(echo "$VMAX * 40 / 100" | bc)
V65=$(echo "$VMAX * 65 / 100" | bc)

cat > aurora.cpt <<EOF
0      0/0/0    1      0/0/0
1      0/20/0   $V15   0/80/0
$V15   0/80/0   $V40   0/160/0
$V40   0/160/0  $V65   0/220/0
$V65   0/220/0  $VMAX  1/251/0
EOF

# Write BMPv4 (BITMAPV4HEADER), 16bpp RGB565, top-down — matches ClearSkyInstitute format
make_bmp_v4_rgb565_topdown() {
  local inraw="$1" outbmp="$2" W="$3" H="$4"
  python3 - <<'PY' "$inraw" "$outbmp" "$W" "$H"
import struct, sys
inraw, outbmp, W, H = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

raw = open(inraw, "rb").read()
exp = W*H*3
if len(raw) != exp:
    raise SystemExit(f"RAW size {len(raw)} != expected {exp}")

pix = bytearray(W*H*2)
j = 0
for i in range(0, len(raw), 3):
    r = raw[i]; g = raw[i+1]; b = raw[i+2]
    v = ((r >> 3) << 11) | ((g >> 2) << 5) | (b >> 3)
    pix[j:j+2] = struct.pack("<H", v)
    j += 2

bfOffBits = 14 + 108
bfSize = bfOffBits + len(pix)
filehdr = struct.pack("<2sIHHI", b"BM", bfSize, 0, 0, bfOffBits)

biSize = 108
rmask, gmask, bmask, amask = 0xF800, 0x07E0, 0x001F, 0x0000
cstype = 0x73524742  # sRGB
endpoints = b"\x00"*36
gamma = b"\x00"*12

v4hdr = struct.pack("<IiiHHIIIIII",
    biSize, W, -H, 1, 16, 3, len(pix), 0, 0, 0, 0
) + struct.pack("<IIII", rmask, gmask, bmask, amask) \
  + struct.pack("<I", cstype) + endpoints + gamma

with open(outbmp, "wb") as f:
    f.write(filehdr)
    f.write(v4hdr)
    f.write(pix)
PY
}

zlib_compress() {
  local in="$1" out="$2"
  python3 -c "
import zlib, sys
data = open(sys.argv[1], 'rb').read()
open(sys.argv[2], 'wb').write(zlib.compress(data, 9))
" "$in" "$out"
}

echo "Rendering maps..."

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
mkdir -p "$OUTDIR"

for DN in D N; do

for SZ in "${SIZES[@]}"; do
  BASE="$GMT_USERDIR/aurora_${DN}_${SZ}"
  PNG="${BASE}.png"
  PNG_FIXED="${BASE}_fixed.png"
  BMP="$OUTDIR/map-${DN}-${SZ}-Aurora.bmp"

  W=${SZ%x*}
  H=${SZ#*x}
  W2=$((W * 2))

  echo "  -> ${DN} ${SZ}"

  gmt begin "$BASE" png
    gmt set MAP_FRAME_TYPE plain MAP_FRAME_AXES "" MAP_FRAME_PEN 0p MAP_GRID_PEN_PRIMARY 0p MAP_GRID_PEN_SECONDARY 0p MAP_GRID_CROSS_SIZE_PRIMARY 0p MAP_GRID_CROSS_SIZE_SECONDARY 0p
    gmt coast -R-180/180/-90/90 -JQ0/${W2}p -G0/0/0 -S0/0/0 -A10000 --MAP_FRAME_AXES=
    if [[ "$DN" == "D" ]]; then
      gmt coast -R-180/180/-90/90 -JQ0/${W2}p -G72/72/72 -S72/72/72 -A10000 --MAP_FRAME_AXES=
    fi
    gmt grdimage aurora_clipped.nc -Caurora.cpt -Q -n+b --MAP_FRAME_AXES=
    gmt coast -R-180/180/-90/90 -JQ0/${W2}p -W0.75p,white -N1/0.5p,white -A10000 --MAP_FRAME_AXES=
  gmt end || { echo "gmt failed for $SZ"; continue; }

  convert "$PNG" -filter Lanczos -resize "${SZ}!" "$PNG_FIXED" || { echo "resize failed for $SZ"; continue; }

  RAW="$GMT_USERDIR/aurora_${DN}_${SZ}.raw"
  convert "$PNG_FIXED" RGB:"$RAW" || { echo "raw extract failed for $SZ"; continue; }
  make_bmp_v4_rgb565_topdown "$RAW" "$BMP" "$W" "$H" || { echo "bmp write failed for $SZ"; continue; }
  rm -f "$RAW" "$PNG" "$PNG_FIXED"

  zlib_compress "$BMP" "${BMP}.z"

  echo "  -> Done: $BMP"

done

done

rm -f aurora_native.nc aurora_raw.nc aurora.nc aurora_clipped.nc aurora.cpt ovation.xyz

echo "Done."
