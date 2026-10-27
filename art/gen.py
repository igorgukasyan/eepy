# Builds eepy's kitty in braille: the owner's sleeping cat, dotted z's that float up, a thought cloud with a trail.
#   python3 -I art/gen.py        writes kitty.txt next to eepy: "lines-per-frame text-row first-col last-col",
#                                then each animation frame. eepy writes the thought into the text row.
#   python3 -I art/gen.py png    writes scene PNGs to the temp dir, to look at before regenerating
# cat.txt is cat.png (the owner's drawing) flattened onto white, cut to the lines (grey < 160), cropped with a 6 px
# margin, lines thickened with a 3 px max filter, then: chafa -f symbols --symbols braille -c none --work 9 --size 44x
import sys, os, tempfile
HERE = os.path.dirname(os.path.abspath(__file__)); sys.path.insert(0, HERE)
from braille import decode, encode, png
from PIL import Image, ImageDraw, ImageChops, ImageFilter

S = 4                                   # supersampling for the cloud: S x S pixels per dot
W, H, OY = 128, 72, 32                  # canvas in dots (64 cols, 18 rows); cat drawn OY dots down (a multiple of 4)
CX, CY, CW, CH = 62, 4, 64, 26          # cloud box in dots

def glyph(rows): return [(x, y) for y, r in enumerate(rows) for x, ch in enumerate(r) if ch == '#']
DOT  = glyph(['##', '##'])
RING = glyph(['.##.', '#..#', '#..#', '.##.'])
BIG  = glyph(['..###..', '.#...#.', '#.....#', '#.....#', '#.....#', '.#...#.', '..###..'])
TRAIL = [(46, 32, DOT), (49, 26, RING), (54, 18, BIG)]   # from the ear tip up to the cloud
Z = [glyph(['####', '..#.', '.#..', '####']),
     glyph(['#####', '...#.', '..#..', '.#...', '#####']),
     glyph(['######', '....#.', '...#..', '..#...', '.#....', '######'])]
ZSTEPS = [(30, 29, 0), (25, 23, 0), (20, 16, 1), (15, 10, 1), (9, 4, 2), (3, 0, 2)]   # x, y, size: rising and growing

def put(g, x0, y0, pts):
    for x, y in pts:
        if 0 <= y0 + y < H and 0 <= x0 + x < W: g[y0 + y][x0 + x] = 1

def cloud(g):
    m = Image.new('L', (W * S, H * S)); dm = ImageDraw.Draw(m)
    def puff(x, y, r): dm.ellipse([(CX + x - r) * S, (CY + y - r) * S, (CX + x + r) * S, (CY + y + r) * S], fill=255)
    for x, y, r in [(13, 11, 9), (27, 8, 10.5), (42, 8, 10), (54, 11, 8.5),     # top puffs
                    (8, 16, 7), (57, 16, 6.5),                                  # ends
                    (18, 19, 6.5), (32, 20, 6.5), (46, 19, 6.5)]:               # bottom puffs
        puff(x, y, r)
    dm.rectangle([(CX + 9) * S, (CY + 10) * S, (CX + 56) * S, (CY + 19) * S], fill=255)
    m = m.filter(ImageFilter.GaussianBlur(S * 1.5)).point(lambda v: 255 if v > 128 else 0)   # round off the cusps
    edge = ImageChops.subtract(m, m.filter(ImageFilter.MinFilter(5))).resize((W, H), Image.BOX)
    for y in range(H):
        for x in range(W):
            if edge.getpixel((x, y)) > 60: g[y][x] = 1

def scene(frame=None):
    g = [[0] * W for _ in range(H)]
    cloud(g)
    for x, y, pts in TRAIL: put(g, x, y, pts)
    if frame is not None:                # three z's, two steps apart, moving up the path
        for k in (0, 2, 4):
            x, y, s = ZSTEPS[(frame + k) % 6]; put(g, x, y, Z[s])
    cat = decode(open(HERE + '/cat.txt', encoding='utf-8').read().splitlines())
    for y in range(len(cat)):
        for x in range(len(cat[0])):
            if cat[y][x] and not (x < 24 and y < 16): g[OY + y][x] = 1   # drop the drawn zzz
    return g

def text_span():                         # the cloud's middle cell row and the clear cells inside it
    rows = encode(scene()); r = (CY + CH // 2) // 4
    ink = [c for c in range(CX // 2, (CX + CW) // 2 + 1) if c < len(rows[r]) and rows[r][c] != '⠀']
    return r, ink[0] + 2, ink[-1] - 2

if __name__ == '__main__':
    if sys.argv[1:] == ['png']:
        for f in range(2): png(scene(f), f'{tempfile.gettempdir()}/kitty-scene{f}.png', scale=10); print(f'{tempfile.gettempdir()}/kitty-scene{f}.png')
    else:
        r, a, b = text_span()
        with open(HERE + '/../kitty.txt', 'w', encoding='utf-8') as out:
            out.write(f'{H // 4} {r} {a} {b}\n')
            for f in range(6): out.write('\n'.join(encode(scene(f))) + '\n')
