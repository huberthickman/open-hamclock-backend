#!/bin/bash

# By SleepyNinja

# Define the URL and output file
URL="https://services.swpc.noaa.gov/products/noaa-scales.json"
OUTPUT_FILE="/opt/hamclock-backend/htdocs/ham/HamClock/NOAASpaceWX/noaaswx.txt"

# Fetch the JSON data
data=$(curl -s "$URL")

# Function to extract scales for a specific key (R, S, or G) for indices 0, 1, 2, 3
extract_scale() {
    local key=$1
    # .// "0" handles null values by replacing them with 0
    echo "$data" | jq -r "([.\"0\".$key.Scale, .\"1\".$key.Scale, .\"2\".$key.Scale, .\"3\".$key.Scale] | map(. // \"0\>
}

# Generate the output and write to the text file
{
    extract_scale "R"
    extract_scale "S"
    extract_scale "G"
} > "$OUTPUT_FILE"