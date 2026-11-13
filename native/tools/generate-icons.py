#!/usr/bin/env python3
"""Export the selected Night Moth master for macOS and Android."""

import copy
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import xml.etree.ElementTree as ET


ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "resources"
SOURCE = RESOURCES / "icon.svg"
OUTPUT = ROOT / "zig-out" / "icons"
SVG = "{http://www.w3.org/2000/svg}"
SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}


def png_size(path):
    header = path.read_bytes()[:24]
    if header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        raise ValueError(f"Not a PNG: {path}")
    return struct.unpack(">II", header[16:24])


def render(renderer, svg, destination, size):
    subprocess.run(
        [
            renderer, "--skip-system-fonts", "--resources-dir", str(RESOURCES),
            "--width", str(size), "--height", str(size), "-", str(destination),
        ],
        input=ET.tostring(svg),
        check=True,
    )
    if png_size(destination) != (size, size):
        raise ValueError(f"Incorrect export dimensions: {destination}")


def main():
    renderer = shutil.which("resvg")
    iconutil = shutil.which("iconutil")
    if not renderer or not iconutil:
        raise SystemExit("Requires resvg and macOS iconutil on PATH.")
    source = ET.parse(SOURCE).getroot()
    if source.tag != SVG + "svg" or source.get("viewBox") != "0 0 1024 1024":
        raise ValueError("The icon master must have a 1024 × 1024 SVG canvas.")
    background = source.find(f"{SVG}rect[@id='background']")
    if background is None or background.get("fill") != "#2E2C43":
        raise ValueError("The selected master must retain Night Moth's aubergine background.")

    # Android's current NanoUI builder consumes a full-bleed launcher PNG.
    # macOS gets the selected inset tile, including transparent outer corners.
    mac = copy.deepcopy(source)
    mac.find(f"{SVG}rect[@id='background']").attrib.update(
        {"x": "64", "y": "64", "width": "896", "height": "896", "rx": "208"}
    )
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="night-moth-", dir=OUTPUT) as directory:
        temporary = Path(directory)
        iconset = temporary / "Hexes.iconset"
        iconset.mkdir()
        for name, size in SIZES.items():
            render(renderer, mac, iconset / name, size)
        android = temporary / "icon.png"
        render(renderer, source, android, 1024)
        icns = temporary / "Hexes.icns"
        subprocess.run([iconutil, "-c", "icns", str(iconset), "-o", str(icns)], check=True)

        # Round-trip through Apple's decoder; a single 512 px image is not
        # enough for a crisp Dock, Finder, and Retina presentation.
        decoded = temporary / "decoded.iconset"
        subprocess.run([iconutil, "-c", "iconset", str(icns), "-o", str(decoded)], check=True)
        for name, size in SIZES.items():
            if png_size(decoded / name) != (size, size):
                raise ValueError(f"Missing or incorrect ICNS representation: {name}")
        render(renderer, mac, OUTPUT / "night-moth-macos.png", 1024)

        # Replace the checked-in exports only after both platforms validate.
        shutil.copyfile(icns, RESOURCES / "Hexes.icns")
        shutil.copyfile(android, RESOURCES / "icon.png")

    report = {
        "selected_concept": 21,
        "name": "Night Moth",
        "source": "resources/icon.svg",
        "source_sha256": hashlib.sha256(SOURCE.read_bytes()).hexdigest(),
        "mac_representations": SIZES,
        "android_size": [1024, 1024],
        "checks": ["SVG master parsed", "10 ICNS representations round-tripped", "1024 px Android PNG"],
    }
    (OUTPUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print("Night Moth exported: 10 macOS ICNS representations and a full-bleed Android PNG.")


if __name__ == "__main__":
    main()
