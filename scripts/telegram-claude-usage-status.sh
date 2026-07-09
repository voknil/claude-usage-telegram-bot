#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

env_file="${CLAUDE_STATUS_BOT_ENV:-$project_dir/.env}"
usage_file="${CLAUDE_USAGE_STATE:-$project_dir/state/status.json}"
state_file="${CLAUDE_STATUS_MESSAGE_STATE:-$project_dir/state/telegram-message.json}"
api_capture_script="$script_dir/claude-usage-api-capture.sh"
cli_capture_script="$script_dir/claude-usage-cli-capture.sh"
status_log="${CLAUDE_STATUS_LOG:-$project_dir/logs/status.log}"

if [[ ! -f "$env_file" ]]; then
  echo "Missing $env_file" >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$env_file"

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "TELEGRAM_BOT_TOKEN is empty" >&2
  exit 2
fi

api="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
mkdir -p "$(dirname "$state_file")"
mkdir -p "$(dirname "$status_log")"

telegram() {
  local method="$1"
  shift
  curl -fsS -X POST "$api/$method" "$@"
}

telegram_raw() {
  local method="$1"
  shift
  curl -sS -X POST "$api/$method" "$@"
}

state_chat_id="$(jq -r '.chat_id // empty' "$state_file" 2>/dev/null || true)"
state_message_id="$(jq -r '.message_id // empty' "$state_file" 2>/dev/null || true)"
chat_id="${CLAUDE_STATUS_CHAT_ID:-$state_chat_id}"
message_id="${CLAUDE_STATUS_MESSAGE_ID:-$state_message_id}"

if [[ -z "$chat_id" ]]; then
  updates="$(curl -fsS "$api/getUpdates")"
  chat_id="$(
    python3 - "$updates" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
matches = []
for upd in data.get("result", []):
    msg = upd.get("message") or {}
    chat = msg.get("chat") or {}
    text = (msg.get("text") or "").strip()
    if chat.get("type") == "private" and text.startswith("/start"):
        matches.append(chat.get("id"))
if matches:
    print(matches[-1])
PY
  )"
fi

if [[ -z "$chat_id" ]]; then
  echo "No private /start update found for the status bot yet." >&2
  exit 3
fi

usage_age_seconds=999999
if [[ -f "$usage_file" ]]; then
  usage_mtime="$(stat -f '%m' "$usage_file" 2>/dev/null || echo 0)"
  usage_age_seconds="$(( $(date +%s) - usage_mtime ))"
fi

if [[ "${CLAUDE_USAGE_SKIP_API_CAPTURE:-}" != "1" && -x "$api_capture_script" && ( "${CLAUDE_USAGE_FORCE_API_CAPTURE:-${CLAUDE_USAGE_FORCE_CLI_CAPTURE:-}}" == "1" || "$usage_age_seconds" -gt 240 ) ]]; then
  "$api_capture_script" >/dev/null 2>>"$status_log" || printf '%s api_capture_failed\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$status_log"
fi

usage_age_seconds=999999
if [[ -f "$usage_file" ]]; then
  usage_mtime="$(stat -f '%m' "$usage_file" 2>/dev/null || echo 0)"
  usage_age_seconds="$(( $(date +%s) - usage_mtime ))"
fi

if [[ "${CLAUDE_USAGE_SKIP_CLI_CAPTURE:-}" != "1" && -x "$cli_capture_script" && ( "${CLAUDE_USAGE_FORCE_CLI_CAPTURE:-}" == "1" || "$usage_age_seconds" -gt 240 ) ]]; then
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$cli_capture_script" >/dev/null 2>>"$status_log" || printf '%s cli_capture_failed\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$status_log"
  else
    "$cli_capture_script" >/dev/null 2>>"$status_log" || printf '%s cli_capture_failed\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$status_log"
  fi
fi

text="$(
  python3 - "$usage_file" <<'PY'
import json, sys
from datetime import datetime, timezone

path = sys.argv[1]
now = datetime.now(timezone.utc)

def parse_dt(value):
    if not value:
        return None
    if isinstance(value, (int, float)):
        # Accept seconds or milliseconds.
        if value > 10_000_000_000:
            value /= 1000
        return datetime.fromtimestamp(value, timezone.utc)
    if isinstance(value, str):
        try:
            return datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    return None

def find_percent(obj):
    if not isinstance(obj, dict):
        return None
    keys = (
        "percent_used", "used_percent", "usage_percent", "percent",
        "percentage", "usedPercentage", "usagePercentage", "used_pct",
        "usage_pct", "used_percentage", "usage_percentage"
    )
    for key in keys:
        val = obj.get(key)
        if isinstance(val, (int, float)):
            pct = float(val)
            return pct * 100 if 0 <= pct <= 1 else pct
        if isinstance(val, str):
            s = val.strip().rstrip("%")
            try:
                pct = float(s)
            except ValueError:
                continue
            return pct * 100 if 0 <= pct <= 1 else pct
    used = obj.get("used")
    limit = obj.get("limit") or obj.get("total")
    if isinstance(used, (int, float)) and isinstance(limit, (int, float)) and limit:
        return used / limit * 100
    return None

def find_reset(obj):
    if not isinstance(obj, dict):
        return None
    for key in ("reset_at", "resets_at", "resetAt", "resetsAt", "reset_time", "resetTime"):
        dt = parse_dt(obj.get(key))
        if dt:
            return dt
    return None

def fmt_pct(p):
    if p is None:
        return "unknown"
    left = max(0, 100 - p)
    return f"{p:.0f}% used / {left:.0f}% left"

def fmt_used(p):
    if p is None:
        return "unknown"
    return f"{p:.0f}% used"

def fmt_left_short(p):
    if p is None:
        return "?"
    return f"{max(0, 100 - p):.0f}%"

def fmt_reset(dt):
    if not dt:
        return "unknown"
    delta = dt - now
    mins = max(0, int(delta.total_seconds() // 60))
    h, m = divmod(mins, 60)
    local = dt.astimezone().strftime("%H:%M")
    if h:
        return f"{local} (in {h}h {m}m)"
    return f"{local} (in {m}m)"

def fmt_reset_short(dt):
    if not dt:
        return "?"
    local_dt = dt.astimezone()
    local_now = now.astimezone(local_dt.tzinfo)
    if local_dt.date() == local_now.date():
        return local_dt.strftime("%H:%M")
    return local_dt.strftime("%a %H:%M")

def top_line(label, item):
    if not item:
        return f"{label}: ? used · rst ?"
    percent = item.get("percent")
    used = "?" if percent is None else f"{percent:.0f}%"
    return f"{label}: {used} used · rst {fmt_reset_short(item.get('reset'))}"

def progress_bar(p, width=18):
    if p is None:
        return "[" + "?" * width + "]"
    p = max(0, min(100, p))
    filled = round(width * p / 100)
    return "[" + "#" * filled + "-" * (width - filled) + "]"

def human_label(key):
    raw = str(key or "").replace("-", "_")
    labels = {
        "five_hour": "Current session",
        "fivehour": "Current session",
        "session": "Current session",
        "current_session": "Current session",
        "seven_day": "All models",
        "sevenday": "All models",
        "weekly": "All models",
        "week": "All models",
        "all_models": "All models",
        "allmodels": "All models",
        "fable": "Fable",
        "opus": "Opus",
        "sonnet": "Sonnet",
        "haiku": "Haiku",
    }
    lowered = raw.lower()
    if lowered in labels:
        return labels[lowered]
    return raw.replace("_", " ").strip().title() or "Limit"

def extract_limit(obj, label):
    pct = find_percent(obj)
    reset = find_reset(obj)
    if pct is None and reset is None:
        return None
    return {
        "label": label,
        "percent": pct,
        "reset": reset,
    }

def child_dicts(obj):
    if not isinstance(obj, dict):
        return []
    out = []
    for key, val in obj.items():
        if isinstance(val, dict):
            out.append((key, val))
    return out

def collect_nested_limits(obj, parent_label=None, depth=0):
    if not isinstance(obj, dict) or depth > 4:
        return []
    found = []
    for key, val in child_dicts(obj):
        label = human_label(key)
        item = extract_limit(val, label)
        children = collect_nested_limits(val, label, depth + 1)
        if item:
            found.append(item)
        found.extend(children)
    return found

def dedupe_limits(items):
    seen = set()
    out = []
    for item in items:
        pct = item.get("percent")
        reset = item.get("reset")
        sig = (
            item.get("label"),
            None if pct is None else round(pct, 3),
            reset.isoformat() if reset else None,
        )
        if sig in seen:
            continue
        seen.add(sig)
        out.append(item)
    return out

def append_limit(lines, item):
    lines.append(item["label"])
    lines.append(f"{progress_bar(item.get('percent'))} {fmt_used(item.get('percent'))}")
    reset = item.get("reset")
    if reset:
        lines.append(f"Resets: {fmt_reset(reset)}")

try:
    data = json.load(open(path))
except FileNotFoundError:
    print("5h: ? used · rst ?\nWeek: ? used · rst ?\n\n⏳ Status: waiting for Claude Code data\n✅ Updated: never\nSource: none")
    raise SystemExit

captured = parse_dt(data.get("captured_at"))
age = None
if captured:
    age = int((now - captured).total_seconds() // 60)

source = data.get("source") or "unknown"
rl = data.get("rate_limits") or {}

five = rl.get("five_hour") or rl.get("fiveHour") or rl.get("session") or rl.get("current_session") or {}
week = rl.get("seven_day") or rl.get("sevenDay") or rl.get("weekly") or rl.get("week") or {}

five_item = extract_limit(five, "Current session")
week_item = extract_limit(week, "All models")
all_items = dedupe_limits(collect_nested_limits(rl))

weekly_items = []
for item in all_items:
    if item["label"] == "Current session":
        continue
    if week_item and item["label"] == "All models":
        continue
    weekly_items.append(item)

trusted_sources = {"official_rate_limits", "claude_usage_command", "anthropic_oauth_usage_api"}
if source in trusted_sources:
    lines = [
        top_line("5h", five_item),
        top_line("Week", week_item),
    ]

    if five_item:
        lines.append("")
        append_limit(lines, five_item)
    else:
        lines.append("")
        lines.append("Current session: unknown")

    lines.append("")
    lines.append("Weekly limits")
    if week_item:
        append_limit(lines, week_item)
    if weekly_items:
        for item in weekly_items:
            lines.append("")
            append_limit(lines, item)
    elif not week_item:
        lines.append("unknown")
else:
    lines = ["5h: ? used · rst ?", "Week: ? used · rst ?"]
    lines.append("")
    lines.append("⏳ Status: waiting for official rate_limits")

if captured:
    local = captured.astimezone().strftime("%H:%M")
    stale = " stale" if age is not None and age > 20 else ""
    lines.append(f"✅ Updated: {local} ({age}m ago){stale}")
else:
    lines.append("✅ Updated: unknown")
lines.append(f"Source: {source}")

print("\n".join(lines))
PY
	)"

reply_markup='{"inline_keyboard":[[{"text":"↻ Обновить сейчас ✅","callback_data":"refresh_claude_usage"}]]}'

if [[ -z "$message_id" ]]; then
  response="$(telegram sendMessage --data-urlencode "chat_id=$chat_id" --data-urlencode "text=$text" --data-urlencode "reply_markup=$reply_markup" --data-urlencode "disable_notification=true")"
  message_id="$(jq -r '.result.message_id' <<<"$response")"
  jq -n --argjson chat_id "$chat_id" --argjson message_id "$message_id" \
    '{chat_id: $chat_id, message_id: $message_id}' > "$state_file"
  echo "Created status message $message_id in chat $chat_id"
  exit 0
fi

edit_response="$(telegram_raw editMessageText --data-urlencode "chat_id=$chat_id" --data-urlencode "message_id=$message_id" --data-urlencode "text=$text" --data-urlencode "reply_markup=$reply_markup")"
edit_ok="$(jq -r '.ok // false' <<<"$edit_response" 2>/dev/null || echo false)"
edit_description="$(jq -r '.description // empty' <<<"$edit_response" 2>/dev/null || true)"

if [[ "$edit_ok" == "true" ]]; then
  echo "Updated status message $message_id in chat $chat_id"
elif [[ "$edit_description" == *"message is not modified"* ]]; then
  echo "Status message $message_id unchanged in chat $chat_id"
elif [[ "$edit_description" == *"message to edit not found"* ]]; then
  response="$(telegram sendMessage --data-urlencode "chat_id=$chat_id" --data-urlencode "text=$text" --data-urlencode "reply_markup=$reply_markup" --data-urlencode "disable_notification=true")"
  message_id="$(jq -r '.result.message_id' <<<"$response")"
  jq -n --argjson chat_id "$chat_id" --argjson message_id "$message_id" \
    '{chat_id: $chat_id, message_id: $message_id}' > "$state_file"
  echo "Recreated missing status message $message_id in chat $chat_id"
else
  echo "Failed to edit status message $message_id in chat $chat_id: $edit_description" >&2
  exit 4
fi
