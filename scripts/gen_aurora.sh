#!/bin/bash

# By SleepyNinja

# Define JSON URL and Output Path
URL="https://services.swpc.noaa.gov/json/ovation_aurora_latest.json"
OUT="/opt/hamclock-backend/htdocs/ham/HamClock/aurora/aurora.txt"

# 1. Fetch the JSON data and find the MAX coordinate
MAX_VALUE=$(curl -s "$URL" | jq '.coordinates | map(.[2]) | max')

# 2. Get the current UNIX epoch time
EPOCH_TIME=$(date +%s)

# 3. Append the new data to the file
echo "$EPOCH_TIME $MAX_VALUE" >> "$OUT"

# 4. Trim the file to keep only the last 48 lines
# This keeps the file size constant by slicing off the oldest entry
TRIMMED_DATA=$(tail -n 48 "$OUT")
echo "$TRIMMED_DATA" > "$OUT"
