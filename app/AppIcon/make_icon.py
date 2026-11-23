#!/usr/bin/env python3
"""PrepareMe's app icon (owner's pick, 2026-10-15: "F", a folded map standing as the walls of a house under a book laid
face down as its roof, on the pages' dark ink; in color, "G5": an amber roof over a pale blue and green map). Since the
Apple guidelines plan's phase 6 (owner, 2026-10-22, by click, from Icon Composer's own pictures of every look) it is one
Icon Composer file, app/Kiwix/PrepareMeApp/PrepareMeAppIcon.icon, for the iPhone, iPad and Mac: a layer per color over
the ink gradient, so the system adds Liquid Glass and makes the clear and tinted looks itself. The colored look is the
normal one as well as the dark one (owner, 2026-10-22). The layers are pictures, drawn here and turned into PNGs by
macOS's `sips`: as drawings, Xcode's pictures for iOS 17 and 18 and macOS 14 and 15 lost the outlines (the roof came
out a solid triangle). Only the PrepareMe target names it (project.yml); Kiwix (PrepareMe) and Kiwix keep Kiwix's
AppIcon. It also writes PrepareMeMark, the same drawing for the opening screen, and PrepareMe Dev's icon (Unlisted plan,
phase 3): the same drawing on a purple ground with a yellow "DEV" band, so the development copy is told apart at a
glance, kept in app/Kiwix/PrepareMeDev, outside the family app's folder (kiwix-mac/build.sh's Dev modes put it in). Standard library only. Run by hand after changing a drawing or a color here, then commit what it writes. To
see each look: Xcode's Icon Composer, or its `ictool` (`--export-image --platform iOS --rendition Dark`, and so on)."""

import json
import pathlib
import shutil
import subprocess
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
OUT = HERE.parent / "Kiwix" / "PrepareMeApp" / "PrepareMeAppIcon.icon"

MAP = "M290,470 L438,498 L586,470 L734,498 L734,792 L586,764 L438,792 L290,764 Z"

# Back to front: each layer's shapes (drawn in black; the layer's color fills them) and its color, from BASE's tokens
# (packer/front_style.py): "G5", the roof in --accent's amber, the map's panels pale blue and green.
LAYERS = [
    ("panels", '<polygon points="290,470 438,498 438,792 290,764"/><polygon points="586,470 734,498 734,792 586,764"/>',
     "#bfdbfe"),
    ("middle", '<polygon points="438,498 586,470 586,764 438,792"/>', "#86efac"),
    ("route", f'<path d="{MAP}" fill="none" stroke="#000" stroke-width="26" stroke-linejoin="round"/>'
              '<path d="M330,730 C372,694 394,640 452,650 C510,660 540,716 598,690 C634,674 652,640 662,612" '
              'fill="none" stroke="#000" stroke-width="34" stroke-linecap="round"/><circle cx="668" cy="586" r="34"/>',
     "#151b22"),
    ("pages", '<polyline points="214,572 512,267 810,572" fill="none" stroke="#000" stroke-width="44" '
              'transform="translate(0,34)"/>', "#b45309"),
    ("roof", '<polyline points="196,560 512,236 828,560" fill="none" stroke="#000" stroke-width="84" '
             'stroke-linejoin="miter" stroke-miterlimit="4"/>', "#f59e0b"),
]
GROUND = ("#232b35", "#121820")  # the ink gradient, top to bottom
# PrepareMe Dev's: a purple ground and, in front, a yellow band with DEV drawn in strokes (no font to depend on)
DEV_OUT = HERE.parent / "Kiwix" / "PrepareMeDev" / "PrepareMeDevAppIcon.icon"
DEV_GROUND = ("#7c3aed", "#3b0764")
DEV_LAYERS = [
    ("band", '<rect x="0" y="800" width="1024" height="150"/>', "#facc15"),
    ("letters", '<g fill="none" stroke="#000" stroke-width="24" stroke-linejoin="round" stroke-linecap="round">'
                '<path d="M340,830 L340,920 L384,920 Q434,920 434,875 Q434,830 384,830 Z"/>'
                '<polyline points="560,830 484,830 484,920 560,920"/><line x1="484" y1="875" x2="544" y2="875"/>'
                '<polyline points="604,830 646,920 688,830"/></g>', "#151b22"),
]
# The same drawing as one picture for the app's own opening screen (PrepareMeSplash.swift; owner, 2026-11-12): a vector
# image in PrepareMe.xcassets, the layers in their colors on the ink gradient in the icon's rounded square
MARK = HERE.parent / "Kiwix" / "PrepareMeApp" / "PrepareMe.xcassets" / "PrepareMeMark.imageset"


def srgb(hex_color):
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return f"srgb:{r:.5f},{g:.5f},{b:.5f},1.00000"


def looks(value):
    """Icon Composer's per-look values: the same in the normal look and in dark, so dark keeps the colors (with one plain
    value, the dark look turned the ground black)."""
    return [{"value": value}, {"appearance": "dark", "value": value}]


def gradient(top, bottom):
    return {"linear-gradient": [srgb(top), srgb(bottom)],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}


def main():
    write_icon(OUT, LAYERS, GROUND)
    write_icon(DEV_OUT, LAYERS + DEV_LAYERS, DEV_GROUND)
    write_mark()


def write_icon(out, drawn, ground):
    shutil.rmtree(out, ignore_errors=True)
    (out / "Assets").mkdir(parents=True)
    layers = []
    for name, shapes, color in reversed(drawn):  # Icon Composer lists the front layer first
        with tempfile.TemporaryDirectory() as tmp:
            drawing = pathlib.Path(tmp) / f"{name}.svg"
            drawing.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" '
                               f'viewBox="0 0 1024 1024"><g transform="translate(0,20)">{shapes}</g></svg>')
            subprocess.run(["/usr/bin/sips", "-s", "format", "png", "-z", "1024", "1024", str(drawing), "--out",
                            str(out / "Assets" / f"{name}.png")], check=True, capture_output=True)
        layers.append({"name": name, "image-name": f"{name}.png", "glass": False,
                       "fill-specializations": looks({"solid": srgb(color)})})
    icon = {
        "fill-specializations": looks(gradient(*ground)),
        "groups": [{"layers": layers, "shadow": {"kind": "neutral", "opacity": 0.5},
                    "translucency": {"enabled": True, "value": 0.4}}],
        "supported-platforms": {"squares": "shared"},
    }
    (out / "icon.json").write_text(json.dumps(icon, indent=2) + "\n")


def write_mark():
    shapes = "".join(f'<g fill="{color}">{body.replace("#000", color)}</g>' for _, body, color in LAYERS)
    MARK.mkdir(parents=True, exist_ok=True)
    (MARK / "mark.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><defs>'
        f'<linearGradient id="ink" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="{GROUND[0]}"/>'
        f'<stop offset="1" stop-color="{GROUND[1]}"/></linearGradient></defs>'
        '<rect width="1024" height="1024" rx="229" fill="url(#ink)"/>'
        f'<g transform="translate(0,20)">{shapes}</g></svg>\n')
    (MARK / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "mark.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True}}, indent=2) + "\n")


if __name__ == "__main__":
    main()
