#!/usr/bin/env bash
set -euo pipefail

TLEDIR="/opt/hamclock-backend/tle"
ARCHIVE="$TLEDIR/archive"
TLEFILE="$TLEDIR/tles.txt"
TMPFILE="$TLEDIR/tles.new"

ESATS="/opt/hamclock-backend/scripts/build_esats.pl"

mkdir -p "$TLEDIR" "$ARCHIVE"

URLS=(
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=active&FORMAT=tle"
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=amateur&FORMAT=tle"
  "https://celestrak.org/NORAD/elements/gp.php?GROUP=stations&FORMAT=tle"
)

ts() { date -u +"%Y%m%dT%H%M%SZ"; }

echo "[$(date -u)] Fetching TLEs..."

: > "$TMPFILE"

for u in "${URLS[@]}"; do
    curl -fsSL "$u" >> "$TMPFILE"
    echo >> "$TMPFILE"
done

# Sanity check
if ! grep -q '^1 ' "$TMPFILE"; then
    echo "ERROR: no TLE records"
    exit 1
fi

# First install
if [ ! -f "$TLEFILE" ]; then
    mv "$TMPFILE" "$TLEFILE"
    cp "$TLEFILE" "$ARCHIVE/tles-$(ts).txt"
    echo "Initial TLE install"
    exec "$ESATS"
fi

OLDHASH=$(sha256sum "$TLEFILE" | awk '{print $1}')
NEWHASH=$(sha256sum "$TMPFILE" | awk '{print $1}')

if [[ "$OLDHASH" == "$NEWHASH" ]]; then
    rm "$TMPFILE"
    echo "No TLE change"
    exit 0
fi

STAMP="$(ts)"

# Archive old + new
cp "$TLEFILE" "$ARCHIVE/tles-${STAMP}-old.txt"
cp "$TMPFILE" "$ARCHIVE/tles-${STAMP}-new.txt"

# Atomic replace
mv "$TMPFILE" "$TLEFILE"

echo "TLE updated ($STAMP) — rebuilding ESATS"

# Keep last 60 snapshots (~15 days at 6h cadence)
ls -1t "$ARCHIVE"/tles-* 2>/dev/null | tail -n +61 | xargs -r rm --
exec "$ESATS"
