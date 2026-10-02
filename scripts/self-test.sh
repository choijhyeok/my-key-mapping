#!/bin/zsh
set -euo pipefail

APP="$HOME/Library/Application Support/MyKeyMapping/PhraseTyper.app"
EXECUTABLE="$APP/Contents/MacOS/PhraseTyper"
CONFIG="$HOME/Library/Application Support/MyKeyMapping/phrases.json"
SUPPORT="$HOME/Library/Application Support/MyKeyMapping"
LOG="$HOME/Library/Logs/MyKeyMapping/phrase-typer.log"
MARKER="$SUPPORT/self-test.ok"
LABEL="com.jaehyeokchoi.MyKeyMapping.PhraseTyper"
UID_NUM="$(id -u)"

if [[ "${1:-}" != "--record-user-verified" || "$#" -ne 1 ]]; then
  print -u2 "After you confirm Ctrl+Option+Command+2 types exactly ‘알려줘’ in the intended test field, run: scripts/self-test.sh --record-user-verified"
  exit 64
fi
if [[ ! -x "$EXECUTABLE" || ! -f "$CONFIG" || ! -f "$LOG" ]]; then
  print -u2 "Run scripts/prepare.sh and scripts/enable.sh first."
  exit 1
fi

SERVICE="$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null)" || {
  print -u2 "PhraseTyper LaunchAgent is not running; no verification marker was written."
  exit 1
}
PID="$(print -r -- "$SERVICE" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')"
PROGRAM="$(print -r -- "$SERVICE" | sed -n 's/^[[:space:]]*program = //p' | head -n 1)"
if [[ -z "$PID" || "$PROGRAM" != "$EXECUTABLE" ]]; then
  print -u2 "The running LaunchAgent does not match the installed PhraseTyper app."
  exit 1
fi
READY_LINE="$(grep -F "ready: registered 10 of 10 hotkeys; AX trusted; pid=$PID" "$LOG" | tail -n 1 || true)"
RUNNING_COMMAND="$(ps -p "$PID" -o args= | sed 's/^[[:space:]]*//' || true)"
if [[ -z "$READY_LINE" || "$RUNNING_COMMAND" != "$EXECUTABLE" ]]; then
  print -u2 "The current app process has no matching fresh 10/10 Accessibility-ready record."
  exit 1
fi

BINARY_HASH="$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')"
CONFIG_HASH="$(shasum -a 256 "$CONFIG" | awk '{print $1}')"
TEMP_MARKER="$SUPPORT/.self-test.ok.$$"
trap 'rm -f "$TEMP_MARKER"' EXIT
{
  print 'user_reported=1'
  print 'method=manual_ctrl_option_cmd_2'
  print "verified_at_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  print "pid=$PID"
  print "binary_sha256=$BINARY_HASH"
  print "config_sha256=$CONFIG_HASH"
} > "$TEMP_MARKER"
mv "$TEMP_MARKER" "$MARKER"
trap - EXIT
print "Recorded user-confirmed Fn+2 host-chord test for ready PhraseTyper process $PID."
