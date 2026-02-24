#!/opt/hamclock-backend/venv/bin/python3
# kindex_simple.py
#
# Build HamClock geomag/kindex.txt (72 lines) from SWPC:
#   - daily-geomagnetic-indices.txt  -> most recent 56 valid observed Planetary Kp bins
#   - 3-day-geomag-forecast.txt      -> 16 forecast Kp bins starting at current UTC 3-hour slot
#
# CSI-matching behavior:
#   forecast slice starts at current UTC bin index (hour // 3) within day1 of the 3-day forecast,
#   then takes 16 bins (48 hours).
#
# Output path is atomically written:
#   /opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt

from __future__ import annotations

import os
import re
import sys
import tempfile
from datetime import datetime, timezone

import pandas as pd
import requests

DAILY_URL = "https://services.swpc.noaa.gov/text/daily-geomagnetic-indices.txt"
FCST_URL = "https://services.swpc.noaa.gov/text/3-day-geomag-forecast.txt"
OUTFILE = "/opt/hamclock-backend/htdocs/ham/HamClock/geomag/kindex.txt"

TIMEOUT = 20
HEADERS = {"User-Agent": "OHB kindex_simple.py"}


def fetch_text(url: str) -> str:
    r = requests.get(url, headers=HEADERS, timeout=TIMEOUT)
    r.raise_for_status()
    r.encoding = "utf-8"
    return r.text


def parse_daily_kp_observed(text: str) -> pd.Series:
    """
    Parse SWPC daily-geomagnetic-indices.txt and return chronological valid Planetary Kp bins.

    Assumption (matches SWPC product): the LAST 8 numeric fields on each data row are
    Planetary Kp values for 00-03, 03-06, ..., 21-24 UTC.
    """
    vals = []
    date_row_re = re.compile(r"^\s*(\d{4})\s+(\d{2})\s+(\d{2})\b")

    for line in text.splitlines():
        if not date_row_re.match(line):
            continue

        nums = re.findall(r"-?\d+(?:\.\d+)?", line)
        if len(nums) < 11:
            continue

        try:
            kp8 = [float(x) for x in nums[-8:]]
        except ValueError:
            continue

        vals.extend(kp8)

    if not vals:
        raise RuntimeError("No Kp rows parsed from daily-geomagnetic-indices.txt")

    s = pd.Series(vals, dtype="float64")
    s = s[s >= 0].reset_index(drop=True)  # drop -1 placeholders

    if len(s) < 56:
        raise RuntimeError(f"Need at least 56 valid observed Kp bins, got {len(s)}")

    return s


def parse_forecast_kp(text: str) -> pd.Series:
    """
    Parse ONLY the NOAA Kp forecast table from 3-day-geomag-forecast.txt.

    Returns 24 values in chronological order:
      day1 bins 0..7, day2 bins 0..7, day3 bins 0..7
    """
    lines = text.splitlines()
    in_kp_block = False
    kp_rows = []

    row_re = re.compile(
        r"^\s*(\d{2})-(\d{2})UT\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*$"
    )

    for line in lines:
        if "NOAA Kp index forecast" in line:
            in_kp_block = True
            continue

        if not in_kp_block:
            continue

        if "NOAA Ap index forecast" in line:
            break

        m = row_re.match(line)
        if not m:
            continue

        start_hour = int(m.group(1))
        vals = [float(m.group(3)), float(m.group(4)), float(m.group(5))]
        kp_rows.append((start_hour, vals))

    if len(kp_rows) != 8:
        raise RuntimeError(f"Expected exactly 8 Kp forecast UT rows, got {len(kp_rows)}")

    kp_rows.sort(key=lambda x: x[0])

    day1 = [vals[0] for _, vals in kp_rows]
    day2 = [vals[1] for _, vals in kp_rows]
    day3 = [vals[2] for _, vals in kp_rows]

    fc = pd.Series(day1 + day2 + day3, dtype="float64").reset_index(drop=True)

    if len(fc) != 24:
        raise RuntimeError(f"Expected 24 forecast Kp bins, got {len(fc)}")

    return fc


def atomic_write_lines(path: str, values: pd.Series) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    payload = "".join(f"{v:.2f}\n" for v in values.tolist())

    fd, tmp = tempfile.mkstemp(prefix=".kindex.", suffix=".tmp", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as f:
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main() -> int:
    try:
        daily_text = fetch_text(DAILY_URL)
        fcst_text = fetch_text(FCST_URL)

        obs = parse_daily_kp_observed(daily_text).tail(56).reset_index(drop=True)

        fc_all = parse_forecast_kp(fcst_text)  # 24 bins: day1 + day2 + day3

        # CSI-like splice: start at current UTC 3-hour bin within day1, take 16 bins (48h)
        now_utc = datetime.now(timezone.utc)
        start_bin = now_utc.hour // 3  # 0..7
        fc = fc_all.iloc[start_bin:start_bin + 16].reset_index(drop=True)

        if len(fc) != 16:
            raise RuntimeError(
                f"Expected 16 forecast bins from start_bin={start_bin}, got {len(fc)}"
            )

        out = pd.concat([obs, fc], ignore_index=True)

        if len(out) != 72:
            raise RuntimeError(f"Expected 72 output values, got {len(out)}")

        atomic_write_lines(OUTFILE, out)
        return 0

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
