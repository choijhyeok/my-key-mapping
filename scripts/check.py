#!/usr/bin/env python3
"""Offline source, hold-gesture, and publication checks. Never emits keyboard events."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args: str) -> None:
    subprocess.run(args, cwd=ROOT, check=True)


with tempfile.TemporaryDirectory(prefix="my-key-mapping-check-") as directory:
    temporary = Path(directory)
    main = temporary / "main.swift"
    for name in ["PhraseTyper", "PhraseSettings", "DistributionApp", "VialSetup"]:
        shutil.copyfile(ROOT / "Sources" / (name + ".swift"), main)
        sources = [str(ROOT / "Sources/ModifierHold.swift")] if name == "PhraseSettings" else []
        run("swiftc", "-typecheck", *sources, str(main))
    shutil.copyfile(ROOT / "tests/ModifierHoldTests.swift", main)
    executable = temporary / "hold-tests"
    run("swiftc", str(ROOT / "Sources/ModifierHold.swift"), str(main), "-o", str(executable))
    run(str(executable))
    for path in (ROOT / "Sources").glob("*.plist"):
        with path.open("rb") as stream:
            plistlib.load(stream)
    for path in (ROOT / "scripts").glob("*.sh"):
        run("zsh", "-n", str(path))
tracked = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
assert not any(path.startswith("backups/") or path.startswith("analysis/request-frequency.") for path in tracked)
run("git", "diff", "--check")
print("PASS: source type checks, modifier hold tests, plists, scripts, private-file exclusions")
