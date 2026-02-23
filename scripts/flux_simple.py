#!/usr/bin/env python3
"""
Generate HamClock-style solarflux-99.txt in a CSI-like format (simplified).

Output:
- 99 lines total
- 33 daily values, each repeated 3 times

Phases:
1) daily-solar-indices.txt (DSD):
   - parse last 30 daily rows
   - take Radio Flux 10.7cm column
   - skip the oldest row, keep 29 rows
   - repeat each value 3x

2) wwv.txt:
   - parse "Solar flux NNN"
   - repeat that value 3x

3) Synthetic 3-day bridge (CSI-like tail):
   - from WWV observed flux, generate [obs+2, obs+5, obs+8]
   - repeat each value 3x

This intentionally ignores forecast parsing to match the CSI-style tail shape
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path
from typing import List, Tuple
from urllib.request import Request, urlopen


DSD_URL = "https://services.swpc.noaa.gov/text/daily-solar-indices.txt"
WWV_URL = "https://services.swpc.noaa.gov/text/wwv.txt"

UA = "open-hamclock-backend/1.0 (+solarflux-99 generator)"


def fetch_text(url: str, timeout: int = 20) -> str:
    req = Request(url, headers={"User-Agent": UA})
    with urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
    return raw.decode("utf-8", errors="replace")


def parse_dsd_fluxes(text: str) -> List[int]:
    """
    Parse daily-solar-indices.txt rows.

    Example row:
    2026 01 24  174    147      880      1    -999      *   5  0  0  0  0  0  0

    We only need the Radio Flux 10.7cm value (4th numeric field in the row).
    Returns the most recent 30 flux values.
    """
    fluxes: List[int] = []

    for line in text.splitlines():
        line = line.rstrip()
        if not line or line.startswith(":") or line.startswith("#"):
            continue

        # Match row start: YYYY MM DD flux ...
        m = re.match(r"^\s*(\d{4})\s+(\d{2})\s+(\d{2})\s+(\d+)\b", line)
        if not m:
            continue

        # groups: year, month, day, flux
        flux = int(m.group(4))
        fluxes.append(flux)

    if len(fluxes) < 30:
        raise ValueError(f"Expected at least 30 DSD rows, found {len(fluxes)}")

    # SWPC rows are chronological; keep the newest 30 parsed flux values.
    # Phase 1 later skips the oldest of these 30, leaving 29 daily values.
    return fluxes[-30:]


def parse_wwv_flux(text: str) -> int:
    """
    Parse only the WWV line:
      'Solar flux 110 and estimated planetary A-index 36.'
    Return 110.
    """
    m = re.search(r"\bSolar flux\s+(\d{1,3})\b", text, re.I)
    if not m:
        raise ValueError("Could not parse WWV 'Solar flux NNN' line")
    return int(m.group(1))


def build_phase3_bridge(obs_flux: int) -> List[int]:
    """
    CSI-like 3-day tail heuristic:
      +2, +3, +3 increments from the observed WWV value.

    Example:
      110 -> [112, 115, 118]
    """
    v1 = obs_flux + 2
    v2 = v1 + 3
    v3 = v2 + 3
    return [v1, v2, v3]


def expand_tripled(values: List[int]) -> List[int]:
    out: List[int] = []
    for v in values:
        out.extend([v, v, v])
    return out


def generate_solarflux_99(dsd_text: str, wwv_text: str, debug: bool = False) -> List[int]:
    # Phase 1: DSD rows (30 total, skip oldest => 29)
    dsd_fluxes_30 = parse_dsd_fluxes(dsd_text)
    phase1_daily = dsd_fluxes_30[1:]  # 29 values

    # Phase 2: WWV observed flux (1 day)
    wwv_flux = parse_wwv_flux(wwv_text)

    # Phase 3: CSI-like synthetic bridge (3 days)
    phase3_daily = build_phase3_bridge(wwv_flux)

    daily33 = phase1_daily + [wwv_flux] + phase3_daily

    if len(daily33) != 33:
        raise RuntimeError(f"Expected 33 daily values, got {len(daily33)}")

    out99 = expand_tripled(daily33)

    if len(out99) != 99:
        raise RuntimeError(f"Expected 99 values, got {len(out99)}")

    if debug:
        print(f"DEBUG: phase1_daily (29): {phase1_daily}", file=sys.stderr)
        print(f"DEBUG: wwv_flux: {wwv_flux}", file=sys.stderr)
        print(f"DEBUG: phase3_daily (3): {phase3_daily}", file=sys.stderr)
        print(f"DEBUG: daily33: {daily33}", file=sys.stderr)

    return out99


def write_lines(path: Path, values: List[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as f:
        for v in values:
            f.write(f"{v}\n")


def main() -> int:
    ap = argparse.ArgumentParser(description="Generate solarflux-99.txt (CSI-like, simplified)")
    ap.add_argument(
        "--out",
        default="/opt/hamclock-backend/htdocs/ham/HamClock/solar-flux/solarflux-99.txt",
        help="Output file path",
    )
    ap.add_argument("--debug", action="store_true", help="Verbose diagnostics to stderr")

    # Optional local overrides for offline testing
    ap.add_argument("--dsd-file", help="Use local daily-solar-indices.txt instead of fetching SWPC")
    ap.add_argument("--wwv-file", help="Use local wwv.txt instead of fetching SWPC")

    args = ap.parse_args()

    try:
        if args.dsd_file:
            dsd_text = Path(args.dsd_file).read_text(encoding="utf-8", errors="replace")
        else:
            dsd_text = fetch_text(DSD_URL)

        if args.wwv_file:
            wwv_text = Path(args.wwv_file).read_text(encoding="utf-8", errors="replace")
        else:
            wwv_text = fetch_text(WWV_URL)

        values = generate_solarflux_99(dsd_text, wwv_text, debug=args.debug)
        write_lines(Path(args.out), values)

        if args.debug:
            print(f"DEBUG: wrote {len(values)} lines to {args.out}", file=sys.stderr)

        return 0

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
