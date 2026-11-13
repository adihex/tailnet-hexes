#!/usr/bin/env python3
"""Fetch the pinned Android build prerequisites into the ignored local cache.

Official archives and SHA-1 checksums from Google's repository2-3.xml.
The SDK/NDK licenses remain in the extracted distributions. No sdkmanager
licenses are silently accepted and no system SDK configuration is changed.
"""
import hashlib
from pathlib import Path
import shutil
import subprocess
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parent.parent / ".android-sdk"
PACKAGES = (
    ("android-ndk-r29-darwin.zip", "03d29fbb57e3c05a7d53597dd011d856c1456a4f",
     "ndk/29.0.14206865", "source.properties"),
    ("build-tools_r36_macosx.zip", "199ae0047ee61e842f8ee0c6d3918e44fb9a1f83",
     "build-tools/36.0.0", "aapt2"),
    ("platform-36_r02.zip", "2c1a80dd4d9f7d0e6dd336ec603d9b5c55a6f576",
     "platforms/android-36", "android.jar"),
)


def checksum(path):
    h = hashlib.sha1()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def install(filename, digest, destination, marker):
    target = ROOT / destination
    if (target / marker).is_file():
        print(f"Already available: {destination}", flush=True)
        return
    downloads = ROOT / "downloads"
    downloads.mkdir(parents=True, exist_ok=True)
    archive = downloads / filename
    if not archive.exists() or checksum(archive) != digest:
        partial = archive.with_suffix(".zip.part")
        print(f"Downloading {filename}", flush=True)
        with urllib.request.urlopen(
            "https://dl.google.com/android/repository/" + filename, timeout=60
        ) as response, partial.open("wb") as output:
            shutil.copyfileobj(response, output, 1024 * 1024)
        if checksum(partial) != digest:
            raise RuntimeError(f"Checksum mismatch: {filename}")
        partial.replace(archive)
    stage = ROOT / ("stage-" + target.name)
    stage.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(archive) as z:
        names = {Path(name).parts[0] for name in z.namelist()}
        if len(names) != 1:
            raise RuntimeError(f"Unexpected archive layout: {filename}")
        for name in z.namelist():
            if not (stage / name).resolve().is_relative_to(stage.resolve()):
                raise RuntimeError(f"Unsafe archive path: {filename}")
    # unzip preserves the NDK's executable bits and symlinks.
    subprocess.run(["unzip", "-q", "-o", str(archive), "-d", str(stage)], check=True)
    target.parent.mkdir(parents=True, exist_ok=True)
    (stage / names.pop()).rename(target)
    if not (target / marker).is_file():
        raise RuntimeError(f"Missing prerequisite after extraction: {destination}")
    stage.rmdir()
    print(f"Ready: {destination}", flush=True)


if __name__ == "__main__":
    for package in PACKAGES:
        install(*package)
    print(f"Build with ANDROID_HOME='{ROOT}' zig build -Dtarget=aarch64-linux-android")
