# Converts colors from highlight.js to SCSS variables
# for use as default colour schemes.
#
# See: https://github.com/highlightjs/highlight.js/tree/main/src/styles/base16
#
COLOR_SCHEME_TEMPLATE = '''base03:  '{base03}'
base02:  '{base02}'
base01:  '{base01}'
base00:  '{base00}'
base0:   '{base0}'
base1:   '{base1}'
base2:   '{base2}'
base3:   '{base3}'
yellow:  '{yellow}'
orange:  '{orange}'
red:     '{red}'
magenta: '{magenta}'
violet:  '{violet}'
blue:    '{blue}'
cyan:    '{cyan}'
green:   '{green}'
'''

def parse_colors(given):
    colors = {}
    for line in given.split('\n'):
        if not line.startswith('base'):
            continue
        name, hex = line.split()[0:2]
        colors[name] = hex
    return colors

def render_scheme(colors):
    return COLOR_SCHEME_TEMPLATE.format(
        base03=colors['base07'],
        base02=colors['base06'],
        base01=colors['base05'],
        base00=colors['base04'],
        base0=colors['base03'],
        base1=colors['base02'],
        base2=colors['base01'],
        base3=colors['base00'],
        yellow=colors['base0A'],
        orange=colors['base09'],
        red=colors['base08'],
        magenta=colors['base0F'],
        violet=colors['base0E'],
        blue=colors['base0D'],
        cyan=colors['base0C'],
        green=colors['base0B'],
    )

import sys

if __name__ == '__main__':
    print(render_scheme(parse_colors(sys.stdin.read())))
