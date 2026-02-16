#!/bin/bash
# This script reads .env and prints it in Lighttpd config format

echo "setenv.set-environment = ("

# support file doesn't exist
if [ -r /opt/hamclock-backend/.env ]; then
    while IFS='=' read -r key value; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
        echo "  \"$key\" => \"$value\","
    done < /opt/hamclock-backend/.env
fi

echo ")"

