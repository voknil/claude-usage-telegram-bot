#!/usr/bin/env bash
set -euo pipefail

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"

credentials_file="${CLAUDE_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
state_file="${CLAUDE_USAGE_STATE:-$project_dir/state/status.json}"
raw_file="${CLAUDE_USAGE_API_RAW:-$project_dir/state/api-usage.json}"
log_file="${CLAUDE_USAGE_CAPTURE_LOG:-$project_dir/logs/capture.log}"
mkdir -p "$(dirname "$state_file")"
mkdir -p "$(dirname "$log_file")"

captured_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

if [[ ! -f "$credentials_file" ]]; then
  printf '%s api_credentials_missing\n' "$captured_at" >> "$log_file"
  exit 1
fi

token="$(jq -r '.claudeAiOauth.accessToken // empty' "$credentials_file" 2>/dev/null || true)"
if [[ -z "$token" ]]; then
  printf '%s api_access_token_missing\n' "$captured_at" >> "$log_file"
  exit 1
fi

tmp="$(mktemp)"
state_tmp="$(mktemp "${state_file}.tmp.XXXXXX")"
trap 'rm -f "$tmp" "$state_tmp"' EXIT

http_status="$(
  curl -sS --max-time 8 -w '%{http_code}' -o "$tmp" \
    'https://api.anthropic.com/api/oauth/usage' \
    -H "Authorization: Bearer $token" \
    -H 'anthropic-beta: oauth-2025-04-20' \
    -H 'Content-Type: application/json' 2>/dev/null || printf '000'
)"

cp "$tmp" "$raw_file" 2>/dev/null || true

if [[ "$http_status" != "200" ]]; then
  error_type="$(jq -r '.error.type // .type // "unknown"' "$tmp" 2>/dev/null || printf 'unknown')"
  printf '%s api_usage_failed http=%s error=%s\n' "$captured_at" "$http_status" "$error_type" >> "$log_file"
  exit 1
fi

jq -e '.five_hour.utilization? // .five_hour.used_percentage?' "$tmp" >/dev/null

jq --arg captured_at "$captured_at" '
  def pct($x): if $x == null then null else $x end;
  def reset($x): if $x == null then null else $x end;
  def limit($obj):
    if $obj == null then null else
      {
        used_percentage: pct($obj.utilization // $obj.used_percentage),
        resets_at: reset($obj.resets_at // $obj.reset_at)
      }
    end;
  {
    captured_at: $captured_at,
    source: "anthropic_oauth_usage_api",
    rate_limits: (
      {
        five_hour: limit(.five_hour),
        seven_day: limit(.seven_day),
        seven_day_sonnet: limit(.seven_day_sonnet),
        seven_day_opus: limit(.seven_day_opus),
        extra_usage: .extra_usage
      }
      | with_entries(select(.value != null))
    )
  }
' "$tmp" > "$state_tmp"

mv "$state_tmp" "$state_file"
printf '%s anthropic_oauth_usage_api\n' "$captured_at" >> "$log_file"
