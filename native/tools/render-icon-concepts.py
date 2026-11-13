#!/usr/bin/env python3
"""Render the 24 original SVG studies without touching installed app assets."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import xml.etree.ElementTree as ET

from PIL import Image, ImageDraw, ImageFont


ROOT = Path(__file__).resolve().parents[1] / "resources" / "icon-concepts"
OUTPUT = ROOT / "previews"
NS = "{http://www.w3.org/2000/svg}"
PAPER = "#F2EFE7"
INK = "#253E40"
MUTED = "#69716B"


def font(size):
    candidates = [
        os.environ.get("HEXES_PREVIEW_FONT"),
        "/System/Library/Fonts/Avenir Next.ttc",
        "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
        "C:/Windows/Fonts/segoeui.ttf",
    ]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            return ImageFont.truetype(candidate, size)
    raise SystemExit("Set HEXES_PREVIEW_FONT to a TrueType/OpenType label font.")


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_source(path, number):
    if not path.name.startswith(f"{number:02d}-"):
        raise ValueError(f"Missing or out-of-order concept {number}: {path.name}")
    tree = ET.parse(path)
    root = tree.getroot()
    if root.tag != NS + "svg" or root.get("viewBox") != "0 0 1024 1024":
        raise ValueError(f"Invalid icon canvas: {path.name}")
    title = root.findtext(NS + "title")
    description = root.findtext(NS + "desc")
    if not title or not description:
        raise ValueError(f"Missing accessible icon description: {path.name}")
    for element in root.iter():
        if element.tag.rsplit("}", 1)[-1] in ("script", "foreignObject", "image"):
            raise ValueError(f"Non-vector or executable content: {path.name}")
        for key, value in element.attrib.items():
            if key.rsplit("}", 1)[-1] == "href" and not value.startswith("#"):
                raise ValueError(f"External reference: {path.name}")
            if "url(" in value and not value.startswith("url(#"):
                raise ValueError(f"External paint reference: {path.name}")
    if len(path.read_text().splitlines()) > 600:
        raise ValueError(f"Source exceeds the project line limit: {path.name}")
    return title, description


def contact_sheet(concepts, start, filename):
    sheet = Image.new("RGB", (1440, 1380), PAPER)
    draw = ImageDraw.Draw(sheet)
    draw.text((64, 38), "HEXES / ICON STUDIES", font=font(21), fill=MUTED)
    draw.text(
        (64, 78),
        "Pick your kind of strange.",
        font=font(44),
        fill=INK,
    )
    draw.text(
        (1114, 106),
        f"{start + 1}–{start + len(concepts)} / 24",
        font=font(23),
        fill=INK,
    )
    draw.line((64, 148, 1376, 148), fill="#CDCFC3", width=2)
    for offset, concept in enumerate(concepts):
        column, row = offset % 4, offset // 4
        x, y = 64 + column * 334, 173 + row * 375
        with Image.open(OUTPUT / concept["png"]) as original:
            icon = original.convert("RGBA").resize((308, 308), Image.Resampling.LANCZOS)
        sheet.paste(icon, (x - 2, y), icon)
        draw.rounded_rectangle((x + 17, y + 314, x + 54, y + 350), radius=9, fill=INK)
        number = str(start + offset + 1)
        draw.text(
            (x + 35, y + 331),
            number,
            font=font(21),
            fill=PAPER,
            anchor="mm",
        )
        draw.text((x + 66, y + 316), concept["name"], font=font(23), fill=INK)
    draw.text(
        (64, 1320),
        "Original vector concepts · Not installed · Choose by number",
        font=font(21),
        fill=MUTED,
    )
    sheet.save(OUTPUT / filename)


def small_sizes(concepts):
    sheet = Image.new("RGB", (1440, 1050), PAPER)
    draw = ImageDraw.Draw(sheet)
    draw.text((48, 30), "HEXES / SMALL-SIZE CHECK", font=font(30), fill=INK)
    draw.text((48, 80), "Each row shows 64 px, 32 px, and 16 px exports.", font=font(20), fill=MUTED)
    for offset, concept in enumerate(concepts):
        column, row = offset % 4, offset // 4
        x, y = 48 + column * 350, 138 + row * 144
        with Image.open(OUTPUT / concept["png"]) as original:
            image = original.convert("RGBA")
            for size, shift in ((64, 0), (32, 88), (16, 146)):
                icon = image.resize((size, size), Image.Resampling.LANCZOS)
                sheet.paste(icon, (x + shift, y + (64 - size) // 2), icon)
        draw.text((x, y + 75), f'{offset + 1}. {concept["name"]}', font=font(18), fill=INK)
    sheet.save(OUTPUT / "small-sizes.png")


def main():
    renderer = shutil.which("resvg")
    if not renderer:
        raise SystemExit("Install resvg or put it on PATH.")
    sources = sorted(ROOT.glob("[0-9][0-9]-*.svg"))
    if len(sources) != 24:
        raise SystemExit(f"Expected exactly 24 icon sources, found {len(sources)}.")
    OUTPUT.mkdir(exist_ok=True)
    concepts = []
    for number, source in enumerate(sources, 1):
        name, description = validate_source(source, number)
        destination = OUTPUT / (source.stem + ".png")
        subprocess.run(
            [renderer, "--skip-system-fonts", "--width", "1024", "--height", "1024", str(source), str(destination)],
            check=True,
        )
        with Image.open(destination) as image:
            if image.size != (1024, 1024) or image.mode != "RGBA":
                raise ValueError(f"Wrong PNG dimensions or color mode: {destination.name}")
            if image.getchannel("A").getbbox() is None:
                raise ValueError(f"Empty icon: {destination.name}")
        concepts.append(
            {
                "number": number,
                "name": name,
                "description": description,
                "svg": source.name,
                "png": destination.name,
                "png_sha256": sha256(destination),
            }
        )
    if len({concept["png_sha256"] for concept in concepts}) != 24:
        raise ValueError("Two concepts have identical raster output.")
    contact_sheet(concepts[:12], 0, "contact-sheet-1.png")
    contact_sheet(concepts[12:], 12, "contact-sheet-2.png")
    small_sizes(concepts)
    report = {
        "count": len(concepts),
        "dimensions": [1024, 1024],
        "checks": ["valid XML", "described vectors", "local-only references", "24 distinct PNGs", "RGBA 1024 × 1024"],
        "renderer": subprocess.check_output([renderer, "--version"], text=True).strip(),
        "concepts": concepts,
    }
    (OUTPUT / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Rendered and validated {len(concepts)} distinct icon concepts.")
    print(f"Contact sheets, small-size study, and report: {OUTPUT}")


if __name__ == "__main__":
    main()
