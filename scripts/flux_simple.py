#!/usr/bin/env python3
"""
solarflux_99_swpc.py

Reconstruct ClearSky-like solarflux-99 generation without ClearSky availability.

Inputs:
- SWPC daily-solar-indices.txt: last ~30 days daily solar indices, including 10.7 cm flux
- SWPC wwv.txt: daily solar flux value in prose, used to patch the newest day if newer than DSD

Algorithm:
- Build/maintain a rolling cache of daily values (YYYYMMDD -> int flux)
- Select last 33 daily values (pad-left with oldest if fewer)
- Expand each day to 3 samples (repeat 3x) => 99 values
- Write 99 integers, one per line, to:
  /opt/hamclock-backend/htdocs/ham/HamClock/solar-flux/solarflux-99.txt

Cache:
  /opt/hamclock-backend/data/solarflux-swpc-cache.txt
"""

from __future__ import annotations

import os
import re
import sys
import tempfile
from datetime import datetime
from typing import Dict, List, Optional, Tuple

import requests

URL_DSD = "https://services.swpc.noaa.gov/text/daily-solar-indices.txt"
URL_WWV = "https://services.swpc.noaa.gov/text/wwv.txt"

CACHE_PATH = "/opt/hamclock-backend/data/solarflux-swpc-cache.txt"
OUT_PATH = "/opt/hamclock-backend/htdocs/ham/HamClock/solar-flux/solarflux-99.txt"

DAYS = 33
REPEAT = 3
TOTAL = DAYS * REPEAT

UA = "open-hamclock-backend/solarflux-99"


def fetch_text(url: str) -> str:
    r = requests.get(url, headers={"User-Agent": UA}, timeout=30)
    r.raise_for_status()
    return r.text


def atomic_write(path: str, content: str) -> None:
    d = os.path.dirname(path)
    os.makedirs(d, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix="._solarflux.", dir=d, text=True)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as f:
            f.write(content)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def load_cache(path: str) -> Dict[str, int]:
    out: Dict[str, int] = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                parts = line.split()
                if len(parts) != 2:
                    continue
                ymd, v = parts
                if not re.fullmatch(r"\d{8}", ymd):
                    continue
                try:
                    out[ymd] = int(v)
                except ValueError:
                    continue
    except FileNotFoundError:
        pass
    return out


def save_cache(path: str, cache: Dict[str, int], keep_days: int = 180) -> None:
    keys = sorted(cache.keys())
    if len(keys) > keep_days:
        for k in keys[:-keep_days]:
            cache.pop(k, None)
    content = "".join(f"{k} {cache[k]}\n" for k in sorted(cache.keys()))
    atomic_write(path, content)


def parse_dsd(text: str) -> Dict[str, int]:
    """
    Parse SWPC daily-solar-indices.txt lines that look like:
      YYYY MM DD  <10.7cm> ...

    We take the 4th token (10.7 cm flux).
    """
    daily: Dict[str, int] = {}
    for line in text.splitlines():
        if not line or line.startswith(("#", ":")):
            continue
        if not re.match(r"^\s*\d{4}\s+\d{1,2}\s+\d{1,2}\s+", line):
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        y, m, d = int(parts[0]), int(parts[1]), int(parts[2])
        flux_str = parts[3]
        ymd = f"{y:04d}{m:02d}{d:02d}"
        try:
            v = int(float(flux_str))  # truncate
        except ValueError:
            continue
        daily[ymd] = v
    return daily


def parse_wwv(text: str) -> Optional[Tuple[str, int]]:
    """
    Extract:
      Solar-terrestrial indices for <D> <Month> follow.
      Solar flux <N> and ...

    Year is taken from :Issued: line.
    """
    issued_year = None
    for line in text.splitlines():
        if line.startswith(":Issued:"):
            m = re.search(r":Issued:\s+(\d{4})\s+", line)
            if m:
                issued_year = int(m.group(1))
            break
    if issued_year is None:
        return None

    idx_date = None
    for line in text.splitlines():
        m = re.search(r"Solar-terrestrial indices for\s+(\d{1,2})\s+([A-Za-z]+)\s+follow\.", line)
        if m:
            day = int(m.group(1))
            mon = m.group(2)
            # Month might be full or abbreviated; try both.
            for fmt in ("%Y %B %d", "%Y %b %d"):
                try:
                    dt = datetime.strptime(f"{issued_year} {mon} {day}", fmt)
                    idx_date = dt.strftime("%Y%m%d")
                    break
                except ValueError:
                    continue
            break
    if idx_date is None:
        return None

    for line in text.splitlines():
        m = re.search(r"\bSolar flux\s+(\d+)\b", line)
        if m:
            return idx_date, int(m.group(1))

    return None


def build_99(cache: Dict[str, int]) -> List[int]:
    keys = sorted(cache.keys())
    if not keys:
        raise ValueError("no cached daily values")

    vals = [cache[k] for k in keys]

    # last 33 days, pad-left if needed
    if len(vals) >= DAYS:
        vals = vals[-DAYS:]
    else:
        pad = vals[0]
        vals = [pad] * (DAYS - len(vals)) + vals

    out: List[int] = []
    for v in vals:
        out.extend([int(v)] * REPEAT)

    if len(out) != TOTAL:
        raise ValueError(f"internal: produced {len(out)} values, expected {TOTAL}")
    return out


def main() -> int:
    cache = load_cache(CACHE_PATH)

    try:
        dsd_txt = fetch_text(URL_DSD)
        dsd = parse_dsd(dsd_txt)
        if not dsd:
            raise ValueError("parsed 0 daily values from DSD")
        cache.update(dsd)
    except Exception as e:
        print(f"ERROR: failed to ingest daily-solar-indices.txt: {e}", file=sys.stderr)
        return 2

    # WWV patch if newer than newest DSD day
    try:
        wwv_txt = fetch_text(URL_WWV)
        wwv = parse_wwv(wwv_txt)
        if wwv:
            wwv_date, wwv_flux = wwv
            newest_dsd = max(dsd.keys())
            if wwv_date >= newest_dsd:
                cache[wwv_date] = wwv_flux
    except Exception:
        # Non-fatal: DSD is primary
        pass

    # persist cache
    try:
        save_cache(CACHE_PATH, cache, keep_days=180)
    except Exception as e:
        print(f"ERROR: failed to write cache: {e}", file=sys.stderr)
        return 3

    # build and write 99
    try:
        out = build_99(cache)
        content = "\n".join(map(str, out)) + "\n"
        atomic_write(OUT_PATH, content)
    except Exception as e:
        print(f"ERROR: failed to build/write 99: {e}", file=sys.stderr)
        return 4

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

