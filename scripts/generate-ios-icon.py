#!/usr/bin/env python3
"""Build the iOS app icon from the existing Android adaptive artwork (Pillow).

Run with --check to verify the committed PNG matches its source and layout.
No corner mask is applied: iOS supplies the platform's rounded icon shape.
"""
import argparse
from pathlib import Path
import xml.etree.ElementTree as ET

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / 'android/app/src/main/res'
OUTPUT = ROOT / 'ios/SSHepherd/SSHepherd/Assets.xcassets/AppIcon.appiconset/AppIcon.png'


def icon():
    colors = ET.parse(RESOURCES / 'values/ic_launcher_background.xml').getroot()
    background = next(item.text for item in colors if item.attrib.get('name') == 'ic_launcher_background')
    inset = ET.parse(RESOURCES / 'drawable/ic_launcher_foreground.xml').getroot()
    namespace = '{http://schemas.android.com/apk/res/android}'
    margins = [float(inset.attrib[namespace + 'inset' + side].removesuffix('%')) / 100
               for side in ('Left', 'Top', 'Right', 'Bottom')]
    left, top, right, bottom = margins
    if not (left == top == right == bottom and 0 <= left < .5):
        raise ValueError('Expected equal Android adaptive foreground insets')
    artwork = Image.open(RESOURCES / 'drawable/ic_launcher_foreground_art.png').convert('RGBA')
    if artwork.width != artwork.height:
        raise ValueError('Expected square source artwork')
    size = 1024
    art_size = round(size * (1 - left - right))
    artwork = artwork.resize((art_size, art_size), Image.Resampling.LANCZOS)
    canvas = Image.new('RGBA', (size, size), background)
    canvas.alpha_composite(artwork, ((size - art_size) // 2, (size - art_size) // 2))
    return canvas.convert('RGB')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    expected = icon()
    if args.check:
        with Image.open(OUTPUT) as actual:
            if actual.mode != 'RGB' or actual.size != (1024, 1024) or actual.tobytes() != expected.tobytes():
                raise SystemExit('iOS app icon is missing opacity, size, or source fidelity')
        print('PASS: opaque 1024x1024 iOS icon matches Android artwork, color and insets')
    else:
        OUTPUT.parent.mkdir(parents=True, exist_ok=True)
        expected.save(OUTPUT, optimize=True)
        print(OUTPUT.relative_to(ROOT))
