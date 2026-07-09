#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

state_file="${CLAUDE_USAGE_STATE:-$project_dir/state/status.json}"
raw_file="${CLAUDE_USAGE_RAW:-$project_dir/state/usage.txt}"
log_file="${CLAUDE_USAGE_CAPTURE_LOG:-$project_dir/logs/capture.log}"
mkdir -p "$(dirname "$state_file")"
mkdir -p "$(dirname "$log_file")"

captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
tmp="$(mktemp)"
state_tmp="$(mktemp "${state_file}.tmp.XXXXXX")"
trap 'rm -f "$tmp" "$state_tmp"' EXIT

claude_bin="${CLAUDE_BIN:-$(command -v claude || true)}"
if [[ -z "$claude_bin" ]]; then
  printf '%s claude_not_found PATH=%s\n' "$captured_at" "$PATH" >> "$log_file"
  exit 127
fi

"$claude_bin" /usage > "$tmp"
cp "$tmp" "$raw_file"

python3 - "$captured_at" "$tmp" "$state_tmp" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone
from zoneinfo import ZoneInfo

captured_at, raw_path, state_tmp_path = sys.argv[1:4]
text = open(raw_path, encoding="utf-8").read()
now = datetime.now()

def parse_reset(raw):
    if not raw:
        return None
    m = re.search(r"([A-Z][a-z]{2})\s+(\d{1,2})\s+at\s+(\d{1,2}(?::\d{2})?\s*[ap]m)\s+\(([^)]+)\)", raw)
    if not m:
        return None
    mon, day, time_part, zone = m.groups()
    clean_time = time_part.replace(" ", "")
    fmt = "%Y %b %d %I:%M%p" if ":" in clean_time else "%Y %b %d %I%p"
    dt = datetime.strptime(f"{now.year} {mon} {day} {clean_time}", fmt)
    try:
        dt = dt.replace(tzinfo=ZoneInfo(zone))
    except Exception:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

def pct(pattern):
    m = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
    return float(m.group(1)) if m else None

def reset(pattern):
    m = re.search(pattern, text, re.IGNORECASE | re.MULTILINE)
    return parse_reset(m.group(1)) if m else None

five_pct = pct(r"Current session:\s*([0-9]+(?:\.[0-9]+)?)%\s+used")
five_reset = reset(r"Current session:.*?resets\s+(.+)$")
week_pct = pct(r"Current week \(all models\):\s*([0-9]+(?:\.[0-9]+)?)%\s+used")
week_reset = reset(r"Current week \(all models\):.*?resets\s+(.+)$")
fable_pct = pct(r"Current week \(Fable\):\s*([0-9]+(?:\.[0-9]+)?)%\s+used")

rate_limits = {}
if five_pct is not None:
    rate_limits["five_hour"] = {"used_percentage": five_pct}
    if five_reset:
        rate_limits["five_hour"]["resets_at"] = five_reset
if week_pct is not None:
    rate_limits["seven_day"] = {"used_percentage": week_pct}
    if week_reset:
        rate_limits["seven_day"]["resets_at"] = week_reset
if fable_pct is not None:
    rate_limits["fable"] = {"used_percentage": fable_pct}

if not rate_limits:
    raise SystemExit("Could not parse claude /usage output")

payload = {
    "captured_at": captured_at,
    "source": "claude_usage_command",
    "rate_limits": rate_limits,
}

with open(state_tmp_path, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)
    f.write("\n")
PY

mv "$state_tmp" "$state_file"
printf '%s claude_usage_command\n' "$captured_at" >> "$log_file"
