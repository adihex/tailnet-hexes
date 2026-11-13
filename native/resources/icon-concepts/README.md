# Twenty-four Hexes icon studies

Original, hand-authored vector concepts for the shared native Mac/Android
client. These are proposals, not replacements for the installed icon.
No external image service was used.

The owner selected **21 — Night Moth**. Its production master is
`../icon.svg`; platform exports are generated outside this proposal archive.

- `01-*.svg` through `24-*.svg`: editable 1024 × 1024 vector originals.
- `gallery.src.html`: numbered visual gallery; each icon links to its SVG.
- `prompts.md`: a reusable image-generation brief and 24 individual directions.
- `previews/`: generated PNGs, two numbered contact sheets, and a size study.

The rounded tiles show a Mac-style presentation, not final adaptive Android
assets. After a concept is selected, prepare an unmasked master, a complete
Mac `.icns` size set, and Android foreground/background assets. Check the
selected mark at 16, 32, 48, and 128 pixels before installing it.

## Reproduce the previews

Requires Python 3 with Pillow and `resvg` on `PATH`. No app build is needed:

```sh
cd native
python3 tools/render-icon-concepts.py
```

The renderer checks the exact set of 24 sources, XML validity, accessible
titles/descriptions, local-only references, distinct raster output, and
1024 × 1024 PNG exports. It writes `previews/report.json` with the results.

The gallery uses the local Visual Explainer renderer when available. Compact
the generated HTML afterward to keep it within the project's line limit;
the readable, editable version remains `gallery.src.html`.

```sh
node ~/.agents/skills/visual-explainer/kit/render.mjs \
  resources/icon-concepts/gallery.src.html
uv run --with minify-html python -c \
  'from pathlib import Path; import minify_html; p = Path("resources/icon-concepts/gallery.html"); p.write_text(minify_html.minify(p.read_text(), minify_css=True, minify_js=False))'
```

Neither command installs an icon or changes the running applications.
