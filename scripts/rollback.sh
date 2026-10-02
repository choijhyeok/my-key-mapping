#!/bin/zsh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$ROOT"
APP="$HOME/Library/Application Support/MyKeyMapping/PhraseTyper.app"
SUPPORT="$HOME/Library/Application Support/MyKeyMapping"
LABEL="com.jaehyeokchoi.MyKeyMapping.PhraseTyper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_NUM="$(id -u)"

# The Swift tool checks every mapped key against its original/configured value before writing.
swift "$ROOT/Sources/VialSetup.swift" rollback

if launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then launchctl bootout "gui/$UID_NUM" "$PLIST"; fi
if [[ -f "$PLIST" ]]; then rm "$PLIST"; fi
SETTINGS_LABEL="com.jaehyeokchoi.MyKeyMapping.PhraseSettings"
SETTINGS_PLIST="$HOME/Library/LaunchAgents/$SETTINGS_LABEL.plist"
SETTINGS_APP="$SUPPORT/PhraseSettings.app"
if launchctl print "gui/$UID_NUM/$SETTINGS_LABEL" >/dev/null 2>&1; then launchctl bootout "gui/$UID_NUM/$SETTINGS_LABEL"; fi
if [[ -f "$SETTINGS_PLIST" ]]; then rm "$SETTINGS_PLIST"; fi
if [[ -f "$SETTINGS_APP/Contents/Info.plist" ]] && /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$SETTINGS_APP/Contents/Info.plist" | /usr/bin/grep -qx "$SETTINGS_LABEL"; then
  rm -rf "$SETTINGS_APP"
fi
if [[ -f "$APP/Contents/Info.plist" ]] && /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" | /usr/bin/grep -qx 'com.jaehyeokchoi.MyKeyMapping.PhraseTyper'; then
  rm -rf "$APP"
fi
if [[ -f "$SUPPORT/phrases.json" ]] && /usr/bin/cmp -s "$SUPPORT/phrases.json" "$ROOT/config/phrases.json"; then
  rm "$SUPPORT/phrases.json"
fi
rmdir "$SUPPORT" 2>/dev/null || true
print "Keyboard mappings restored where still owned by this setup; helper stopped."
