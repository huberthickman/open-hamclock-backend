#!/bin/bash

# By SleepyNinja

# 1. Generate Year and Month for the URL
# %y = last 2 digits of year (e.g., 26)
# %m = 2 digit month (e.g., 02)
YY=$(date +%y)
MM=$(date +%m)

URL="https://wdc.kugi.kyoto-u.ac.jp/dst_realtime/presentmonth/dst${YY}${MM}.for.request"
TMP_FILE="/opt/hamclock-backend/htdocs/ham/HamClock/dst/dst_data.txt"
OUTPUT="/opt/hamclock-backend/htdocs/ham/HamClock/dst/dst.txt"
ERROR_FILE="/opt/hamclock-backend/htdocs/ham/HamClock/dst/error.log"

# 1. Download the file
if ! curl -s --fail "$URL" -o "$TMP_FILE"; then
    EPOCH_TIME=$(date +%s)
    echo "$EPOCH_TIME Error: Download failed (possibly 404 Not Found). Exiting." >> "$ERROR_FILE"
    exit 1
fi

# 2. Parse, find the last valid entry, and save to dst.txt
awk '
/^DST/ {
    yy = substr($0, 4, 2);
    mm = substr($0, 6, 2);
    dd = substr($0, 9, 2);

    base_str = substr($0, 17, 4);
    gsub(/ /, "", base_str);
    base = base_str + 0;

    for (i = 0; i < 24; i++) {
        val_str = substr($0, 21 + (i * 4), 4);
        clean_val = val_str;
        gsub(/ /, "", clean_val);

        # Ignore empty strings and the 9999 filler
        if (clean_val != "" && clean_val !~ /99/) {
            actual_value = (base * 100) + clean_val;
            printf "20%s-%s-%sT%02d:00:00 %d\n", yy, mm, dd, i, actual_value;
        }
    }
}' "$TMP_FILE" | tail -n 1 >> "$OUTPUT"
rm -f "$TMP_FILE"

# 3. Trim the file to keep only the last 24 lines
TRIMMED_DATA=$(tail -n 24 "$OUTPUT")
echo "$TRIMMED_DATA" > "$OUTPUT"
