#!/usr/bin/env python3
"""Build a universal macOS app and installer without changing the installed apps."""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def run(*args: str) -> None:
    subprocess.run(args, check=True)


def build_app(name: str, source: str, info: str, output: Path, temporary: Path,
              version: str, build: str, architectures: list[str], sdk: str,
              extra_sources: list[str] | None = None) -> None:
    contents = output / "Contents"
    executable = contents / "MacOS" / name
    executable.parent.mkdir(parents=True)
    with (ROOT / "Sources" / info).open("rb") as stream:
        definition = plistlib.load(stream)
    definition.update(CFBundleShortVersionString=version, CFBundleVersion=build, LSMinimumSystemVersion="13.0")
    with (contents / "Info.plist").open("wb") as stream:
        plistlib.dump(definition, stream)
    work = temporary / name
    work.mkdir()
    main = work / "main.swift"
    shutil.copyfile(ROOT / "Sources" / source, main)
    binaries = []
    for architecture in architectures:
        binary = work / architecture
        command = ["swiftc", "-O", "-target", architecture + "-apple-macosx13.0", "-sdk", sdk,
                   "-framework", "AppKit", "-framework", "ApplicationServices", "-framework", "Carbon"]
        command += [str(ROOT / "Sources" / path) for path in extra_sources or []]
        command += [str(main), "-o", str(binary)]
        run(*command)
        binaries.append(str(binary))
    run("lipo", "-create", *binaries, "-output", str(executable))
    executable.chmod(0o755)
    run("codesign", "--force", "--sign", "-", "--identifier", definition["CFBundleIdentifier"], str(output))


def main() -> None:
    version = os.environ.get("MYKEYMAPPING_VERSION", (ROOT / "VERSION").read_text().strip())
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("Version must be MAJOR.MINOR.PATCH")
    build = os.environ.get("MYKEYMAPPING_BUILD", "1")
    if not build.isdigit():
        raise SystemExit("Build must be a number")
    architectures = ["arm64", "x86_64"]
    sdk = subprocess.check_output(["xcrun", "--show-sdk-path"], text=True).strip()
    dist = ROOT / "dist"
    if dist.is_symlink():
        raise SystemExit("Refusing to build into a symbolic link")
    dist.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="my-key-mapping-release-") as directory:
        temporary = Path(directory)
        payload = temporary / "root"
        application = payload / "MyKeyMapping.app"
        build_app("MyKeyMapping", "DistributionApp.swift", "DistributionInfo.plist", application,
                  temporary, version, build, architectures, sdk)
        helpers = application / "Contents/Helpers"
        build_app("PhraseTyper", "PhraseTyper.swift", "Info.plist", helpers / "PhraseTyper.app",
                  temporary, version, build, architectures, sdk)
        build_app("PhraseSettings", "PhraseSettings.swift", "PhraseSettingsInfo.plist", helpers / "PhraseSettings.app",
                  temporary, version, build, architectures, sdk, ["ModifierHold.swift"])
        resources = application / "Contents/Resources"
        resources.mkdir()
        shutil.copyfile(ROOT / "config/phrases.json", resources / "phrases.json")
        run("codesign", "--force", "--sign", "-", "--identifier", "com.jaehyeokchoi.MyKeyMapping", str(application))
        run("codesign", "--verify", "--deep", "--strict", str(application))
        run(str(application / "Contents/MacOS/MyKeyMapping"), "--validate-bundle")
        components = temporary / "components.plist"
        run("pkgbuild", "--analyze", "--root", str(payload), str(components))
        with components.open("rb") as stream:
            definitions = plistlib.load(stream)
        for definition in definitions:
            definition["BundleIsRelocatable"] = False
            definition["BundleHasStrictIdentifier"] = True
        with components.open("wb") as stream:
            plistlib.dump(definitions, stream)
        package = dist / "MyKeyMapping.pkg"
        if package.exists():
            package.unlink()
        run("pkgbuild", "--root", str(payload), "--component-plist", str(components),
            "--install-location", "/Applications", "--identifier", "com.jaehyeokchoi.MyKeyMapping.installer",
            "--version", version, str(package))
        archive = dist / "MyKeyMapping.zip"
        if archive.exists():
            archive.unlink()
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(application), str(archive))
        inspectable = dist / "MyKeyMapping.app"
        if inspectable.exists():
            with (inspectable / "Contents/Info.plist").open("rb") as stream:
                if plistlib.load(stream).get("CFBundleIdentifier") != "com.jaehyeokchoi.MyKeyMapping":
                    raise SystemExit("Refusing to replace a different app in dist")
            shutil.rmtree(inspectable)
        shutil.copytree(application, inspectable)
    checksums = "".join(f"{hashlib.sha256((dist / name).read_bytes()).hexdigest()}  {name}\n"
                        for name in ["MyKeyMapping.pkg", "MyKeyMapping.zip"])
    (dist / "SHA256SUMS.txt").write_text(checksums)
    print(f"Built MyKeyMapping {version}: {dist / 'MyKeyMapping.pkg'}")


if __name__ == "__main__":
    main()
