#!/usr/bin/env python3

import sys
from datetime import datetime, timezone

def main():

    if len(sys.argv) > 1:
        f = open(sys.argv[1])
    else:
        f = sys.stdin

    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        try:
            t, bx, by, bz, bt = line.split()
            t = int(t)

            ts = datetime.fromtimestamp(t, tz=timezone.utc)
            ts_str = ts.strftime("%Y-%m-%d %H:%M:%S UTC")

            print(f"{ts_str}  Bx={float(bx):6.2f}  By={float(by):6.2f}  Bz={float(bz):6.2f}  Bt={float(bt):6.2f}")

        except Exception as e:
            print(f"BAD LINE: {line}", file=sys.stderr)

    if f is not sys.stdin:
        f.close()

if __name__ == "__main__":
    main()

