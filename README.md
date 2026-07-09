# Claude Usage Telegram Bot

A tiny Telegram status bot for Claude Code subscription usage.

It keeps one Telegram message updated instead of sending a stream of new messages. The first two lines are optimized for Telegram chat previews:

```text
5h: 13% used · rst 18:20
Week: 53% used · rst Fri 08:00
```

The message also includes progress bars, updated time, source, and an inline refresh button.

## Features

- One persistent Telegram message, edited in place.
- `↻ Обновить сейчас ✅` refresh button.
- Button switches to `⏳ Обновляю...` while refresh is running.
- Auto-refresh via launchd, default template is once per minute.
- Reads Claude Code usage from `claude /usage`.
- Optional official `rate_limits` capture via Claude Code `statusLine`.
- Optional Anthropic OAuth usage API fallback if your local credentials work.
- No credentials are committed; `.env`, `state/`, and `logs/` are gitignored.

## Requirements

- macOS for the provided launchd templates.
- `bash`, `curl`, `jq`, `python3`.
- Claude Code CLI available as `claude`.
- A Telegram bot token from BotFather.

## Setup

Clone the repo and create your env file:

```bash
cp .env.example .env
nano .env
```

Set:

```bash
TELEGRAM_BOT_TOKEN='your-bot-token'
```

Open the bot in Telegram and send `/start`.

Run once:

```bash
./scripts/telegram-claude-usage-status.sh
```

This creates the first status message and stores its `chat_id` and `message_id` in `state/telegram-message.json`.

Start callback polling for the refresh button:

```bash
./scripts/telegram-claude-usage-callbacks.sh
```

## launchd

Copy the templates and replace `REPO_DIR` with the absolute path to this repo:

```bash
cp launchd/com.example.claude-usage-status.plist ~/Library/LaunchAgents/
cp launchd/com.example.claude-usage-callbacks.plist ~/Library/LaunchAgents/
```

Then edit both copied files:

```bash
plutil -replace ProgramArguments.0 -string "$PWD/scripts/telegram-claude-usage-status.sh" ~/Library/LaunchAgents/com.example.claude-usage-status.plist
plutil -replace WorkingDirectory -string "$PWD" ~/Library/LaunchAgents/com.example.claude-usage-status.plist
plutil -replace StandardOutPath -string "$PWD/logs/status.log" ~/Library/LaunchAgents/com.example.claude-usage-status.plist
plutil -replace StandardErrorPath -string "$PWD/logs/status.err.log" ~/Library/LaunchAgents/com.example.claude-usage-status.plist

plutil -replace ProgramArguments.0 -string "$PWD/scripts/telegram-claude-usage-callbacks.sh" ~/Library/LaunchAgents/com.example.claude-usage-callbacks.plist
plutil -replace WorkingDirectory -string "$PWD" ~/Library/LaunchAgents/com.example.claude-usage-callbacks.plist
plutil -replace StandardOutPath -string "$PWD/logs/callbacks.log" ~/Library/LaunchAgents/com.example.claude-usage-callbacks.plist
plutil -replace StandardErrorPath -string "$PWD/logs/callbacks.err.log" ~/Library/LaunchAgents/com.example.claude-usage-callbacks.plist
```

Load:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.claude-usage-status.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.claude-usage-callbacks.plist
```

The status job runs every 60 seconds.

## Optional Claude Code statusLine

If Claude Code provides `rate_limits` in the statusLine payload, you can capture it:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/absolute/path/to/claude-usage-telegram-bot/scripts/claude-usage-statusline-capture.sh"
  }
}
```

When `rate_limits` are present, they are stored in `state/status.json` with source `official_rate_limits`.

## Files

- `scripts/claude-usage-cli-capture.sh` - runs `claude /usage` and writes normalized JSON.
- `scripts/claude-usage-api-capture.sh` - optional OAuth API capture.
- `scripts/claude-usage-statusline-capture.sh` - optional statusLine capture.
- `scripts/telegram-claude-usage-status.sh` - creates/edits the Telegram status message.
- `scripts/telegram-claude-usage-callbacks.sh` - handles the inline refresh button.

## Security

Do not commit `.env`, `state/`, `logs/`, or Claude credentials. The repo ignores them by default.
