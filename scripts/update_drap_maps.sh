#!/usr/bin/env bash
set -euo pipefail

OUTDIR="/opt/hamclock-backend/htdocs/ham/HamClock/maps"
TMPROOT="/opt/hamclock-backend/tmp"
URL="https://services.swpc.noaa.gov/images/d-rap/global.png"

mkdir -p "$OUTDIR" "$TMPROOT"

# Load sizes from lib_sizes.sh
# shellcheck source=/dev/null
source "/opt/hamclock-backend/scripts/lib_sizes.sh"
ohb_load_sizes   # populates SIZES=(...) in your OHB conventions

# Temp dir under /opt/hamclock-backend/tmp (www-data writable)
TMPDIR="$(mktemp -d -p "$TMPROOT" drap.XXXXXX)"
trap 'rm -rf "$TMPDIR"' EXIT

IN="$TMPDIR/drap.png"
curl -fsSL -A "open-hamclock-backend/1.0" --retry 2 --retry-delay 2 -o "$IN" "$URL"

# Source crop rectangle (in source pixels)
SRC_CROP_W=660
SRC_CROP_H=330
SRC_XOFF=9
SRC_YOFF=0

# Crop once, reuse for all sizes (avoids repeated decode)
CROPPED="/tmp/drap_cropped.png"
convert "$IN" -crop "${SRC_CROP_W}x${SRC_CROP_H}+${SRC_XOFF}+${SRC_YOFF}" +repage "$CROPPED"

zlib_compress() {
  local in="$1"
  local out="$2"
  python3 - <<'PY' "$in" "$out"
import zlib, sys
data = open(sys.argv[1], "rb").read()
open(sys.argv[2], "wb").write(zlib.compress(data, 9))
PY
}

for sz in "${SIZES[@]}"; do
  W="${sz%x*}"
  H="${sz#*x}"
  
  # Build BMP in tmp, then install, then zlib compress in place.
  day_bmp_tmp="$TMPDIR/map-D-${W}x${H}-DRAP-S.bmp"
  night_bmp_tmp="$TMPDIR/map-N-${W}x${H}-DRAP-S.bmp"

  convert "$CROPPED" -resize "${sz}!" "BMP3:$day_bmp_tmp"

  cp -f "$day_bmp_tmp" "$night_bmp_tmp"

  install -m 0644 "$day_bmp_tmp"   "$OUTDIR/map-D-${W}x${H}-DRAP-S.bmp"
  install -m 0644 "$night_bmp_tmp" "$OUTDIR/map-N-${W}x${H}-DRAP-S.bmp"

  zlib_compress "$OUTDIR/map-D-${W}x${H}-DRAP-S.bmp" "$OUTDIR/map-D-${W}x${H}-DRAP-S.bmp.z"
  zlib_compress "$OUTDIR/map-N-${W}x${H}-DRAP-S.bmp" "$OUTDIR/map-N-${W}x${H}-DRAP-S.bmp.z"
done

echo "OK: DRAP maps updated into $OUTDIR"
