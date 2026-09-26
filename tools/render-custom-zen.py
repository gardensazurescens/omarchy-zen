#!/usr/bin/env python3
"""Render the Zen browser CSS from an Omarchy theme's colors.toml.

This mirrors Omarchy's pywal mapping (color0=background, color7=foreground,
color8=muted, ...) and its theme-mode precedence (mode key, theme_type key,
background luminance auto-detection, dark). The plugin falls back to this
renderer when `omarchy theme refresh` leaves a stale palette behind, and the
screenshot pipeline uses it to produce preview images without switching the
desktop theme.

Usage: render-custom-zen.py COLORS_TOML OUTPUT [CUSTOM_ZEN_TPL]
"""
from pathlib import Path
import os
import re
import sys

# Quoted values may be followed by an inline `# comment` (themes do this, e.g.
# falling-leaves decorates every colorN). Match the quoted value without
# anchoring on end-of-line so the comment is ignored; bare values cover keys
# like `mode = dark`.
TOML_VAR = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=\s*"([^"]*)"')
TOML_BARE = re.compile(r'^\s*([A-Za-z0-9_]+)\s*=\s*([A-Za-z0-9_]+)\s*$')
TPL_VAR = re.compile(r'\{\{\s*([A-Za-z0-9_]+)\s*\}\}')
HEX_RE = re.compile(r'^#?[0-9a-fA-F]{6}$')
FALLBACK = '#11111b'


def parse(toml_path):
    values = {}
    for line in Path(toml_path).read_text(encoding='utf-8').splitlines():
        m = TOML_VAR.match(line) or TOML_BARE.match(line)
        if m:
            values[m.group(1)] = m.group(2)
    return {k: v for k, v in values.items()
            if HEX_RE.match(v) or k in ('mode', 'theme_type')}


def luminance(hex_color):
    r, g, b = (int(hex_color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast(a, b):
    la, lb = sorted((luminance(a), luminance(b)), reverse=True)
    return (la + 0.05) / (lb + 0.05)


def readable(accent, base, mode, target=4.5):
    """Minimum mix of accent toward black (dark mode needs lighter-on-dark,
    so it mixes toward white) so its contrast against `base` reaches WCAG AA.
    Guarantees accent-colored text stays legible even for low-contrast pywal
    palettes."""
    light = mode == 'light'
    anchor = '#000000' if light else '#ffffff'
    if contrast(accent, base) >= target and (
            not light or luminance(accent) < luminance(base)) and (
            light or luminance(accent) > luminance(base)):
        return accent
    lo, hi = 0.0, 100.0
    for _ in range(20):
        mid = (lo + hi) / 2
        c = mix(accent, anchor, mid)
        # Mixing toward the anchor is monotonic in contrast against `base`,
        # so binary search finds the minimum mix that reaches the target.
        # The guard below walks in the direction that increases contrast: in
        # light mode the anchor is black (darkens), in dark mode white.
        if light:
            ok = contrast(c, base) >= target and luminance(c) < luminance(base)
        else:
            ok = contrast(c, base) >= target and luminance(c) > luminance(base)
        if ok:
            lo = mid
        else:
            hi = mid
    return mix(accent, anchor, lo)


def mix(hex_a, hex_b, pct):
    """Scale hex_a toward hex_b by pct percent (0-100). Both must be #rrggbb."""
    a = [int(hex_a[i:i + 2], 16) for i in (1, 3, 5)]
    b = [int(hex_b[i:i + 2], 16) for i in (1, 3, 5)]
    return '#' + ''.join('%02x' % round(a[i] * pct / 100 + b[i] * (1 - pct / 100))
                         for i in range(3))


def theme_mode(values, toml_path=None):
    for key in ('mode', 'theme_type'):
        if values.get(key):
            return values[key]
    if toml_path and (Path(toml_path).parent / 'light.mode').is_file():
        return 'light'
    bg = values.get('background') or values.get('color0')
    if bg and HEX_RE.match(bg):
        # Omarchy's luminance rule: sum of RGB channels above 382 is light.
        r, g, b = (int(bg[i:i + 2], 16) for i in (1, 3, 5))
        return 'light' if r + g + b > 382 else 'dark'
    return 'dark'


def resolve(values):
    """Mirror Omarchy's alias cascade (omarchy-theme-color) for the keys this
    renderer consumes: semantic names, legacy short names, and the ANSI
    colorN names. Keeping this in sync means the fallback render matches the
    palette Omarchy bakes into the generated configs."""
    v = dict(values)

    def alias(target, *sources):
        if not v.get(target):
            for source in sources:
                if v.get(source):
                    v[target] = v[source]
                    return

    for canonical, short in (('background', 'bg'), ('foreground', 'fg'),
                             ('dark_background', 'dark_bg'),
                             ('dark_foreground', 'dark_fg'),
                             ('bright_foreground', 'bright_fg')):
        alias(canonical, short)

    # Semantic <-> ANSI fallbacks. Canonical names win when both exist.
    alias('background', 'color0')
    alias('foreground', 'color7')
    if v.get('background'):
        v['color0'] = v['background']
    if v.get('foreground'):
        v['color7'] = v['foreground']

    for ansi, name in (('color1', 'red'), ('color2', 'green'), ('color3', 'yellow'),
                       ('color4', 'blue'), ('color5', 'magenta'), ('color6', 'cyan')):
        alias(ansi, name)
        alias(name, ansi)

    alias('magenta', 'purple')
    alias('muted', 'color8', 'dark_foreground', 'foreground')
    alias('selection_background', 'selection', 'color8', 'color0', 'background')
    alias('selection_foreground', 'bright_foreground', 'color15', 'foreground')
    return v


def palette(values):
    v = resolve(values)
    bg = v.get('color0') or v.get('background') or FALLBACK
    fg = v.get('color7') or v.get('foreground') or '#cdd6f4'

    base = {'color%d' % i: (v.get('color%d' % i) or bg) for i in range(16)}
    base['color0'] = bg
    base['color7'] = fg
    base['color8'] = v.get('color8') or v.get('muted') or fg

    base['foreground_rgb'] = '%d,%d,%d' % (
        int(fg[1:3], 16), int(fg[3:5], 16), int(fg[5:7], 16))
    base['selection_background'] = (
        v.get('selection_background') or v.get('selection') or bg)
    base['selection_foreground'] = v.get('selection_foreground') or fg
    accent = v.get('accent') or fg
    # Panel = background tinted toward the theme's blue (color4), matching the
    # tpl. Tinting toward foreground/accent washed palettes whose accent is a
    # near-white (e.g. kanagawa #dcd7ba) back to neutral gray; color4 carries a
    # hue for every real ANSI palette and stays neutral for gray themes.
    panel = mix(bg, v.get('color4') or v.get('blue') or accent, 82)
    if values.get('mode') == 'light':
        # Light theme: hovered/selected text must be legible on the light
        # panel, so darken the accent; pressed darkens less. A blind
        # color-mix to white produced near-white on white (unreadable tab).
        base['accent_hover'] = readable(accent, panel, 'light')
        base['accent_active'] = readable(mix(accent, '#888888', 50), panel, 'light')
    else:
        base['accent_hover'] = readable(accent, panel, 'dark')
        base['accent_active'] = readable(mix(accent, '#000000', 85), panel, 'dark')
    base['panel'] = panel
    return base


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    values = parse(sys.argv[1])
    values['mode'] = theme_mode(values, sys.argv[1])
    values.update(palette(values))
    if len(sys.argv) > 3:
        tpl_path = Path(sys.argv[3])
    else:
        defaults = [
            Path(os.environ.get('HOME', '')) / '.config' / 'omarchy' / 'themed' / 'custom-zen.css.tpl',
            Path(__file__).resolve().parent.parent / 'assets' / 'omarchy' / 'custom-zen.css.tpl',
        ]
        tpl_path = next((p for p in defaults if p.is_file()), defaults[-1])
    css = TPL_VAR.sub(lambda m: values.get(m.group(1), FALLBACK),
                      tpl_path.read_text(encoding='utf-8'))
    Path(sys.argv[2]).write_text(css, encoding='utf-8')
    print('rendered %s' % sys.argv[2])
    return 0


if __name__ == '__main__':
    sys.exit(main())