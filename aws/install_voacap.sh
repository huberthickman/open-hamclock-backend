#!/usr/bin/env bash
set -euo pipefail

BASE="/opt/hamclock-backend"
VENV="$BASE/venv"

echo "==> Downloading dvoacap-python..."
if [ ! -d "$BASE/dvoacap-python" ]; then
  sudo curl -fsSL \
    https://github.com/skyelaird/dvoacap-python/archive/refs/heads/main.tar.gz \
    | sudo tar -xz -C "$BASE"
  sudo mv "$BASE/dvoacap-python-main" "$BASE/dvoacap-python"
else
  echo "    already present, skipping"
fi

echo "==> Patching Python version constraint..."
sudo sed -i 's/requires-python = ">=3\.11"/requires-python = ">=3.10"/' \
  "$BASE/dvoacap-python/pyproject.toml"

echo "==> Installing dvoacap into venv..."
sudo "$VENV/bin/pip" install --quiet "$BASE/dvoacap-python"

echo "==> Creating voacap cache dir..."
sudo mkdir -p "$BASE/cache/voacap-cache"


echo "==> Fixing ownership..."
sudo chown -R www-data:www-data "$BASE/dvoacap-python"
sudo chown -R www-data:www-data "$BASE/cache/voacap-cache"
sudo chown www-data:www-data "$BASE/scripts/voacap_bandconditions.py"
sudo chown www-data:www-data "$BASE/htdocs/ham/HamClock/fetchBandConditions.pl"

echo "==> Verifying install..."
sudo -u www-data "$VENV/bin/python3" -c "import dvoacap; print('dvoacap OK')"

# HamClock-style smoke test using current script arguments only
# (stderr debug is useful during install; stdout remains the HamClock-format table)
sudo -u www-data "$VENV/bin/python3" "$BASE/scripts/voacap_bandconditions.py" \
  --year 2026 --month 2 --utc 17 \
  --txlat 28.000 --txlng -81.000 \
  --rxlat 42.564 --rxlng -114.461 \
  --path 1 --pow 100 --mode 19 --toa 3.0 --ssn 0 \
  --noise-at-3mhz 153 \
  --required-snr 10 \
  --required-reliability 0 \
  --debug --debug-hour 23 --quiet-set-debug \
  >/tmp/voacap_bandconditions_smoketest.out

# Basic shape checks: 26 lines total (header + descriptor + 24 hour rows)
line_count="$(wc -l < /tmp/voacap_bandconditions_smoketest.out || true)"
if [ "$line_count" -ne 26 ]; then
  echo "ERROR: voacap_bandconditions.py produced unexpected line count: $line_count (expected 26)"
  echo "--- output ---"
  cat /tmp/voacap_bandconditions_smoketest.out || true
  exit 1
fi

# Ensure descriptor line exists and contains expected tokens
if ! sed -n '2p' /tmp/voacap_bandconditions_smoketest.out | grep -q 'W,.*TOA>.*,'; then
  echo "ERROR: voacap_bandconditions.py descriptor line malformed"
  echo "--- output ---"
  cat /tmp/voacap_bandconditions_smoketest.out || true
  exit 1
fi

echo "voacap_bandconditions.py OK"
rm -f /tmp/voacap_bandconditions_smoketest.out

echo "Done."
