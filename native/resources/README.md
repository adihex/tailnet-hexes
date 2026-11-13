# App icons

The owner selected **21 — Night Moth** from `icon-concepts/`.
`icon.svg` is the editable, full-bleed master: cream geometric wings,
pink hexagonal wing eyes, and a dark aubergine background.
It replaces the earlier H/P icon copied from the supplied Chrome app.

- `Hexes.icns`: the selected inset Mac tile with ten standard/Retina
  representations, from 16 px through 1024 px.
- `icon.png`: the 1024 × 1024 full-bleed Android launcher image.

Regenerate both exports on a Mac with `resvg` and `iconutil` installed:

```sh
cd native
python3 tools/generate-icons.py
```

The exporter round-trips every ICNS representation through Apple's decoder.
Generated validation and the Mac preview are in ignored `zig-out/icons/`.
The exports are checked in; normal builds do not require the artwork tools.

The Mac bundle names `Hexes.icns` in `Info.plist`; direct binary launches
embed the same icon. Android's pinned NanoUI builder compiles `icon.png` as
its launcher mipmap. That builder currently accepts a PNG, not Android
adaptive foreground/background XML. The mark is kept inside the central
safe area and the Android image has no pre-baked rounded corners.

Both server profiles live in one native app and use this one app icon.
Their themes, settings, and credentials remain independent.

## New icon proposals

`icon-concepts/` contains 24 original vector proposals, numbered preview sheets,
an HTML gallery, and detailed prompts for external image-generation services.
The original studies remain unchanged; the selected production master and
platform exports live here, outside that proposal collection.
