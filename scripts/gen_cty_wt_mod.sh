#!/bin/bash

THIS=$(basename $0)

OUTFILE=/opt/hamclock-backend/htdocs/ham/HamClock/cty/cty_wt_mod-ll-dxcc.txt
URL="https://www.country-files.com/cty/cty_wt_mod.dat"

SOURCE_VERSION=$(curl -s $URL | head -n 3 | sed -n 's/^.*RELEASE\s\+\([0-9.]\+\).*$/\1/p')
EXTRACTED_TIME=$(date "+%a %b %d %H:%M:%S %YZ")
if [ -e $OUTFILE ]; then
    PREV_SOURCE_VERSION=$(head -n 3 $OUTFILE | sed -n 's/^.*RELEASE\s\+\([0-9.]\+\).*$/\1/p')
else
    PREV_SOURCE_VERSION='No previous version'
fi

if [ "$SOURCE_VERSION" == "$PREV_SOURCE_VERSION" ]; then
    echo "$THIS: no new version. ours: '$PREV_SOURCE_VERSION', theirs: '$SOURCE_VERSION'"
    exit 0
fi

cat <<EOF > $OUTFILE
# extracted from cty_wt_mod.dat on $EXTRACTED_TIME
# from cty_wt_mod.dat RELEASE $SOURCE_VERSION
# prefix     lat+N   lng+W  DXCC
EOF

curl -s https://www.country-files.com/cty/cty_wt_mod.dat | awk '
{ 
    # This line removes all Windows Carriage Returns (\r) immediately
    gsub(/\r/, ""); 
}

# 1. Capture the ADIF number
/# ADIF/ { adif = $3 }

# 2. Capture Default Lat/Lon
/:/ && !/#/ { 
    split($0, a, ":"); 
    def_lat = a[5]; 
    def_lon = a[6] * -1;
    processing_prefixes = 1;
    next;
}

# 3. Process prefix lines
/^[[:space:]]+/ && processing_prefixes {
    gsub(/^[ \t]+|[ \t\r\n]+$/, "", $0);
    has_semicolon = index($0, ";");
    gsub(/;/, "", $0);
    
    n = split($0, prefixes, ",");
    for (i=1; i<=n; i++) {
        p = prefixes[i];
        if (p != "") {
            use_lat = def_lat;
            use_lon = def_lon;
            
            # --- mawk compatible override logic ---
            start = index(p, "<");
            end = index(p, ">");
            if (start > 0 && end > start) {
                # Extract string between < and >
                content = substr(p, start + 1, end - start - 1);
                split(content, coords, "/");
                use_lat = coords[1];
                use_lon = coords[2] * -1;
                
                # Strip the <...> part from prefix
                p = substr(p, 1, start - 1) substr(p, end + 1);
            }

            # --- Cleaning logic (mawk handles these gsubs fine) ---
            gsub(/\[[^]]*\]/, "", p);
            gsub(/\([^)]*\)/, "", p);
            gsub(/~[^~]*~/, "", p);
            gsub(/^=/, "", p);
            gsub(/[[:space:]]/, "", p);

            if (p != "") {
                data[p] = sprintf("%8.2f %8.2f %s", use_lat, use_lon, adif);
            }
        }
    }
    if (has_semicolon) processing_prefixes = 0;
}

END {
    for (p in data) {
        printf "%-15s %s\n", p, data[p];
    }
}' | sort -k1,1 >> $OUTFILE

echo "$THIS: updated to version: $SOURCE_VERSION"
