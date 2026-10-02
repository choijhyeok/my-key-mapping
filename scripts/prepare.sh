#!/bin/zsh
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
SUPPORT="$HOME/Library/Application Support/MyKeyMapping"
APP="$SUPPORT/PhraseTyper.app"
if [[ -e "$APP" ]]; then
  APP_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist" 2>/dev/null || true)"
  if [[ "$APP_ID" != "com.jaehyeokchoi.MyKeyMapping.PhraseTyper" ]]; then
    print -u2 "Refusing to replace an app with a different identity: $APP"
    exit 1
  fi
fi
mkdir -p "$SUPPORT" "$HOME/Library/Logs/MyKeyMapping"
if [[ ! -e "$SUPPORT/phrases.json" ]]; then cp "$ROOT/config/phrases.json" "$SUPPORT/phrases.json"; fi
BUILD="$(mktemp -d "${TMPDIR:-/tmp}/phrase-typer.XXXXXX")"
trap 'rm -rf "$BUILD"' EXIT
mkdir -p "$BUILD/PhraseTyper.app/Contents/MacOS"
swiftc -framework AppKit -framework ApplicationServices -framework Carbon \
  -o "$BUILD/PhraseTyper.app/Contents/MacOS/PhraseTyper" "$ROOT/Sources/PhraseTyper.swift"
cp "$ROOT/Sources/Info.plist" "$BUILD/PhraseTyper.app/Contents/Info.plist"
codesign --force --deep --sign - --identifier com.jaehyeokchoi.MyKeyMapping.PhraseTyper "$BUILD/PhraseTyper.app"
if [[ -d "$APP" ]]; then
  cp "$BUILD/PhraseTyper.app/Contents/MacOS/PhraseTyper" "$APP/Contents/MacOS/PhraseTyper"
  cp "$BUILD/PhraseTyper.app/Contents/Info.plist" "$APP/Contents/Info.plist"
  codesign --force --deep --sign - --identifier com.jaehyeokchoi.MyKeyMapping.PhraseTyper "$APP"
else
  ditto "$BUILD/PhraseTyper.app" "$APP"
fi
print "Prepared $APP"
print "With a trusted LaunchAgent running, manually verify Control+Option+Command+2, then run zsh scripts/self-test.sh --record-user-verified and zsh scripts/enable.sh."
