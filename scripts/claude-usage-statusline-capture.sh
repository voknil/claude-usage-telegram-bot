#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

state_file="${CLAUDE_USAGE_STATE:-$project_dir/state/status.json}"
log_file="${CLAUDE_USAGE_CAPTURE_LOG:-$project_dir/logs/capture.log}"
mkdir -p "$(dirname "$state_file")"
mkdir -p "$(dirname "$log_file")"

tmp="$(mktemp)"
state_tmp="$(mktemp "${state_file}.tmp.XXXXXX")"
trap 'rm -f "$tmp" "$state_tmp"' EXIT
cat > "$tmp"

captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if jq -e '.rate_limits? // empty' "$tmp" >/dev/null 2>&1; then
  jq --arg captured_at "$captured_at" '
    {
      captured_at: $captured_at,
      source: "official_rate_limits",
      rate_limits: .rate_limits,
      model: (.model.display_name? // .model.name? // .model? // null),
      workspace: (.workspace.current_dir? // .cwd? // null)
    }
  ' "$tmp" > "$state_tmp"
  printf '%s official_rate_limits keys=%s\n' "$captured_at" "$(jq -r '.rate_limits | keys | join(",")' "$tmp" 2>/dev/null || printf '?')" >> "$log_file"
  mv "$state_tmp" "$state_file"
else
  printf '%s no_rate_limits raw_keys=%s\n' "$captured_at" "$(jq -r 'keys? | join(",")' "$tmp" 2>/dev/null || printf '?')" >> "$log_file"
fi

# Keep Claude Code's own status line quiet and stable; Telegram is the display.
printf 'Claude usage captured'
