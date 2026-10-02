#!/bin/zsh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
APP="$HOME/Library/Application Support/MyKeyMapping/PhraseTyper.app"
EXECUTABLE="$APP/Contents/MacOS/PhraseTyper"
CONFIG="$HOME/Library/Application Support/MyKeyMapping/phrases.json"
MARKER="$HOME/Library/Application Support/MyKeyMapping/self-test.ok"
LOG="$HOME/Library/Logs/MyKeyMapping/phrase-typer.log"
LABEL="com.jaehyeokchoi.MyKeyMapping.PhraseTyper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if [[ ! -x "$EXECUTABLE" ]]; then print -u2 "Run scripts/prepare.sh first"; exit 1; fi
if [[ ! -f "$MARKER" || ! -f "$CONFIG" ]]; then
  print -u2 "Run the manual host-chord check, then scripts/self-test.sh --record-user-verified."
  exit 1
fi
marker_value() { awk -F= -v key="$1" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$MARKER"; }
if [[ "$(marker_value user_reported)" != "1" || "$(marker_value method)" != "manual_ctrl_option_cmd_2" ]]; then
  print -u2 "The marker does not record the required user-confirmed Ctrl+Option+Command+2 test."
  exit 1
fi
if [[ "$(marker_value binary_sha256)" != "$(shasum -a 256 "$EXECUTABLE" | awk '{print $1}')" ||
      "$(marker_value config_sha256)" != "$(shasum -a 256 "$CONFIG" | awk '{print $1}')" ]]; then
  print -u2 "The app or phrase configuration changed after manual verification; rerun scripts/self-test.sh."
  exit 1
fi
PREVIOUS_PID="$(marker_value pid)"
PREVIOUS_SERVICE="$(launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null)" || {
  print -u2 "The manually tested PhraseTyper LaunchAgent is no longer running. Rerun the manual test."
  exit 1
}
PREVIOUS_CURRENT_PID="$(print -r -- "$PREVIOUS_SERVICE" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')"
PREVIOUS_PROGRAM="$(print -r -- "$PREVIOUS_SERVICE" | sed -n 's/^[[:space:]]*program = //p' | head -n 1)"
PREVIOUS_READY="$(grep -F "ready: registered 10 of 10 hotkeys; AX trusted; pid=$PREVIOUS_PID" "$LOG" 2>/dev/null | tail -n 1 || true)"
PREVIOUS_COMMAND="$(ps -p "$PREVIOUS_PID" -o args= 2>/dev/null | sed 's/^[[:space:]]*//' || true)"
if [[ -z "$PREVIOUS_PID" || "$PREVIOUS_PID" != "$PREVIOUS_CURRENT_PID" ||
      "$PREVIOUS_PROGRAM" != "$EXECUTABLE" || -z "$PREVIOUS_READY" ||
      "$PREVIOUS_COMMAND" != "$EXECUTABLE" ]]; then
  print -u2 "The user-verified helper process is stale or does not match the current ready LaunchAgent. Rerun the manual test."
  exit 1
fi
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs/MyKeyMapping"
python3 - "$PLIST" "$EXECUTABLE" "$HOME/Library/Logs/MyKeyMapping/launchd.out.log" "$HOME/Library/Logs/MyKeyMapping/launchd.err.log" "$LABEL" <<'PY'
import plistlib,sys
path,executable,out_log,err_log,label=sys.argv[1:]
data={"Label":label,"ProgramArguments":[executable],"RunAtLoad":True,"KeepAlive":False,
      "LimitLoadToSessionType":"Aqua","StandardOutPath":out_log,"StandardErrorPath":err_log}
with open(path,"wb") as stream: plistlib.dump(data,stream,sort_keys=False)
PY
UID_NUM="$(id -u)"
touch "$LOG"
OFFSET="$(wc -c < "$LOG" | tr -d ' ')"
if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then launchctl bootout "gui/$UID_NUM" "$PLIST"; fi
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl kickstart "gui/$UID_NUM/$LABEL"
for _ in {1..80}; do
  RECENT="$(tail -c +$((OFFSET + 1)) "$LOG" 2>/dev/null || true)"
  if [[ "$RECENT" == *"AX_PERMISSION_REQUIRED"* ]]; then
    launchctl bootout "gui/$UID_NUM" "$PLIST" || true
    print -u2 "LaunchAgent does not have Accessibility approval; no keyboard mappings were applied."
    exit 2
  fi
  if [[ "$RECENT" == *"ready: registered 10 of 10 hotkeys; AX trusted; pid="* ]]; then
    READY_PID="$(print -r -- "$RECENT" | grep -F "ready: registered 10 of 10 hotkeys; AX trusted; pid=" | tail -n 1 | sed 's/.*pid=//')"
    CURRENT_SERVICE="$(launchctl print "gui/$UID_NUM/$LABEL" 2>/dev/null || true)"
    CURRENT_PID="$(print -r -- "$CURRENT_SERVICE" | awk '$1 == "pid" && $2 == "=" { print $3; exit }')"
    if [[ -n "$READY_PID" && "$READY_PID" == "$CURRENT_PID" ]]; then
      print "Enabled $LABEL; fresh process $CURRENT_PID registered all ten hotkeys with Accessibility access."
      exit 0
    fi
  fi
  sleep 0.1
done
launchctl bootout "gui/$UID_NUM" "$PLIST" || true
print -u2 "Timed out waiting for fresh LaunchAgent readiness; no keyboard mappings were applied."
exit 3
print "Enabled $LABEL"
