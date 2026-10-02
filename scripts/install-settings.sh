#!/bin/zsh
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import os, pathlib, plistlib, shutil, subprocess, sys, tempfile
root = pathlib.Path(sys.argv[1])
home = pathlib.Path.home()
label = "com.jaehyeokchoi.MyKeyMapping.PhraseSettings"
app = home / "Library/Application Support/MyKeyMapping/PhraseSettings.app"
plist = home / "Library/LaunchAgents" / (label + ".plist")
logs = home / "Library/Logs/MyKeyMapping"
service = f"gui/{os.getuid()}/{label}"
if app.exists():
    with (app / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleIdentifier") != label:
            raise SystemExit(f"Refusing to replace a different app: {app}")
with tempfile.TemporaryDirectory(prefix="phrase-settings-") as temporary:
    build = pathlib.Path(temporary)
    bundle = build / "PhraseSettings.app"
    executable = bundle / "Contents/MacOS/PhraseSettings"
    executable.parent.mkdir(parents=True)
    shutil.copyfile(root / "Sources/PhraseSettings.swift", build / "main.swift")
    subprocess.run(["swiftc", "-O", "-framework", "AppKit", "-framework", "ApplicationServices",
                    str(root / "Sources/ModifierHold.swift"), str(build / "main.swift"), "-o", str(executable)], check=True)
    shutil.copyfile(root / "Sources/PhraseSettingsInfo.plist", bundle / "Contents/Info.plist")
    subprocess.run(["codesign", "--force", "--sign", "-", "--identifier", label, str(bundle)], check=True)
    active = subprocess.run(["launchctl", "print", service], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if active.returncode == 0:
        subprocess.run(["launchctl", "bootout", service], check=True)
    app.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(bundle, app, dirs_exist_ok=True)
plist.parent.mkdir(parents=True, exist_ok=True)
logs.mkdir(parents=True, exist_ok=True)
data = {"Label": label, "ProgramArguments": [str(app / "Contents/MacOS/PhraseSettings")], "RunAtLoad": True,
        "LimitLoadToSessionType": "Aqua", "StandardOutPath": str(logs / "settings.out.log"),
        "StandardErrorPath": str(logs / "settings.err.log")}
with plist.open("wb") as stream:
    plistlib.dump(data, stream)
subprocess.run(["launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist)], check=True)
PY
print "Installed phrase settings; hold Control+Option+Command for 3 seconds."
