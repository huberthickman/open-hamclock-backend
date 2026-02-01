#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

SRC_URL="https://services.swpc.noaa.gov/text/ace-magnetometer.txt"
TMP_FILE="$(mktemp)"
OUT="/opt/hamclock-backend/htdocs/ham/HamClock/Bz/Bz.txt"
TMP="${OUT}.tmp"

/usr/bin/curl -fsSL "$SRC_URL" -o "$TMP_FILE"

# Write header to TEMP file
echo "# UNIX        Bx     By     Bz     Bt" > "$TMP"

awk '
# Match only real data rows
$1 ~ /^[0-9]{4}$/ && NF >= 11 {

    year = $1
    mon  = $2
    day  = $3
    hhmm = $4

    hour = int(hhmm / 100)
    min  = hhmm % 100

    # Build UTC timestamp
    ts = sprintf("%04d-%02d-%02d %02d:%02d:00",
                 year, mon, day, hour, min)

    cmd = "date -u -d \"" ts "\" +%s"
    if ((cmd | getline epoch) <= 0) {
        close(cmd)
        next
    }
    close(cmd)

    bx = $8
    by = $9
    bz = $10
    bt = $11

    # Skip missing/bad data rows
    if (bx == -999.9 || by == -999.9 || bz == -999.9 || bt == -999.9)
        next

    printf "%-10s %6.1f %6.1f %6.1f %6.1f\n",
           epoch, bx, by, bz, bt
}
' "$TMP_FILE" >> "$TMP"

# Atomic replace
mv "$TMP" "$OUT"

# Cleanup
rm -f "$TMP_FILE"

rm -f "$TMP_FILE"
