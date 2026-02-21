#!/usr/bin/env python3
"""
Generate HamClock-compatible Kp stream: 72 lines total
- 56 historic values (7 days * 8 bins/day), ending at a chosen 3-hour boundary with optional lag
- 16 forecast values from the 3-day geomag forecast Kp table, with an adjustable bin offset
  (so you can start forecast at 03-06UT instead of 00-03UT and still keep 16 bins by
   borrowing the first bin of day3).

Output: one float per line, oldest -> newest.
Never emits NaN or negative values; fills missing with persistence.

Recent bins (where DGD has -1 sentinel values) are patched from the
real-time planetary Kp JSON endpoint to match CSI behaviour.
"""

import re
import math
from datetime import datetime, timezone, timedelta

import pandas as pd
import requests


DGD_URL  = "https://services.swpc.noaa.gov/text/daily-geomagnetic-indices.txt"
GMF_URL  = "https://services.swpc.noaa.gov/text/3-day-geomag-forecast.txt"
RT_URL   = "https://services.swpc.noaa.gov/json/planetary_k_index_1m.json"

KP_VPD  = 8
KP_NHD  = 7
KP_NPD  = 2
KP_NV   = (KP_NHD + KP_NPD) * KP_VPD  # 72
HIST_NV = KP_NHD * KP_VPD              # 56
FCST_NV = KP_NPD * KP_VPD              # 16

FCST_OFFSET_BINS = 1   # forecast starts at 03-06UT bin of day1


def floor_to_3h(dt_utc: datetime) -> datetime:
    dt_utc = dt_utc.astimezone(timezone.utc)
    hour   = (dt_utc.hour // 3) * 3
    return dt_utc.replace(hour=hour, minute=0, second=0, microsecond=0)


def sanitize_series(vals, fallback=0.0):
    """Replace non-finite or negative values with last good (persistence)."""
    out  = []
    last = None
    for v in vals:
        try:
            f = float(v)
        except Exception:
            f = float("nan")

        if math.isnan(f) or math.isinf(f) or f < 0:
            f = last if last is not None else float(fallback)
        else:
            last = f

        out.append(f)
    return out


def load_realtime_kp_bins() -> dict:
    """
    Fetch real-time 1-minute planetary Kp and return a dict mapping
    3-hour bin start (UTC datetime, truncated to 3h) -> mean Kp (float).
    Only bins with >= 30 minutes of data are included.
    """
    data = requests.get(RT_URL, timeout=20).json()

    # Group 1-minute samples into 3-hour bins
    bins = {}
    for row in data:
        # time_tag format: "2026-02-21 14:00:00.000"
        try:
            tt = datetime.strptime(row["time_tag"][:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
        except Exception:
            continue
        kp = row.get("estimated_kp")
        if kp is None:
            continue
        try:
            kp = float(kp)
        except Exception:
            continue
        bin_start = floor_to_3h(tt)
        bins.setdefault(bin_start, []).append(kp)

    result = {}
    for bin_start, samples in bins.items():
        if len(samples) >= 30:           # at least 30 minutes of data
            result[bin_start] = sum(samples) / len(samples)
    return result


def load_dgd_planetary_timeseries() -> pd.DataFrame:
    """
    Return DataFrame with columns:
      time_tag (UTC datetime)  kp (float)
    Built from DGD daily rows expanded into 8 x 3-hour bins per day.
    Bins with -1 (missing) are left as NaN so the caller can patch them.

    Uses regex instead of read_csv to avoid column misalignment when integer
    Kp fields fuse together without spaces (e.g. "1-1-1-1").
    The planetary float Kp values are always the last 8 tokens on each line.
    """
    txt = requests.get(DGD_URL, timeout=20).text

    # Match date then capture the 8 trailing planetary float Kp columns
    row_re = re.compile(
        r"^(\d{4})\s+(\d{1,2})\s+(\d{1,2})\s+.+?\s+"
        r"([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+"
        r"([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s+([-\d.]+)\s*$"
    )

    bins = []
    for ln in txt.splitlines():
        if len(ln) < 5 or not ln[:4].isdigit() or ln[4] != ' ':
            continue
        m = row_re.match(ln)
        if not m:
            continue
        year, month, day = int(m.group(1)), int(m.group(2)), int(m.group(3))
        day0 = datetime(year, month, day, tzinfo=timezone.utc)
        for i in range(8):
            t  = day0 + timedelta(hours=i * 3)
            kp = float(m.group(4 + i))
            bins.append((t, float("nan") if kp < 0 else kp))

    if not bins:
        raise RuntimeError("No DGD data rows found")

    ts = pd.DataFrame(bins, columns=["time_tag", "kp"]).sort_values("time_tag").reset_index(drop=True)
    return ts


def load_forecast_16_bins(offset_bins: int = FCST_OFFSET_BINS) -> list:
    txt   = requests.get(GMF_URL, timeout=20).text
    lines = txt.splitlines()

    start_idx = None
    for i, ln in enumerate(lines):
        if ln.startswith("NOAA Kp index forecast"):
            start_idx = i
            break
    if start_idx is None:
        raise RuntimeError("No 'NOAA Kp index forecast' header found")

    row_re = re.compile(r"^\s*\d{2}-\d{2}UT\s+([0-9.]+)\s+([0-9.]+)\s+([0-9.]+)\s*$")

    rows = []
    for ln in lines[start_idx + 1:]:
        m = row_re.match(ln)
        if not m:
            continue
        rows.append((float(m.group(1)), float(m.group(2)), float(m.group(3))))
        if len(rows) == 8:
            break

    if len(rows) != 8:
        raise RuntimeError(f"Expected 8 Kp rows, got {len(rows)}")

    seq24 = [r[0] for r in rows] + [r[1] for r in rows] + [r[2] for r in rows]
    if offset_bins < 0 or offset_bins + FCST_NV > len(seq24):
        raise RuntimeError(f"Bad offset_bins={offset_bins}")

    return sanitize_series(seq24[offset_bins:offset_bins + FCST_NV], fallback=0.0)


def build_kp72(fcst_offset_bins: int = FCST_OFFSET_BINS) -> list:
    """
    Return exactly 72 values (56 historic + 16 forecast), oldest -> newest.

    hist_end is set to the NEXT 3-hour boundary (strict less-than filter),
    which includes the current in-progress bin exactly once — matching CSI.
    """
    dgd_ts  = load_dgd_planetary_timeseries()
    rt_bins = load_realtime_kp_bins()
    fcst16  = load_forecast_16_bins(offset_bins=fcst_offset_bins)

    # 56 bins ending at midnight today — matches CSI's fixed daily anchor
    now_utc    = datetime.now(timezone.utc)
    hist_end   = now_utc.replace(hour=0, minute=0, second=0, microsecond=0)
    hist_start = hist_end - timedelta(hours=3 * 56)          # 56 bins, strict >

    hist = dgd_ts[(dgd_ts["time_tag"] > hist_start) & (dgd_ts["time_tag"] < hist_end)].copy()
    if hist.empty:
        raise RuntimeError("No historic bins found")

    # Patch DGD NaN bins with real-time averages where available (within window only)
    def patch_kp(row):
        if math.isnan(row["kp"]) and row["time_tag"] in rt_bins:
            return rt_bins[row["time_tag"]]
        return row["kp"]

    hist["kp"] = hist.apply(patch_kp, axis=1)

    # Sanitize — persistence-fill anything still NaN
    hist["kp"] = sanitize_series(hist["kp"].tolist(), fallback=0.0)

    hist56 = hist["kp"].tolist()
    if len(hist56) < HIST_NV:
        pad    = [hist56[0]] * (HIST_NV - len(hist56))
        hist56 = pad + hist56
    else:
        hist56 = hist56[-HIST_NV:]

    out = sanitize_series(hist56 + fcst16, fallback=hist56[-1] if hist56 else 0.0)

    if len(out) != KP_NV:
        raise RuntimeError(f"Internal error: expected {KP_NV} values, got {len(out)}")
    return out


def main():
    kp = build_kp72(fcst_offset_bins=FCST_OFFSET_BINS)
    print("\n".join(f"{v:.2f}" for v in kp))


if __name__ == "__main__":
    main()
