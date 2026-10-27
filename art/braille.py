# Braille helpers: decode text art to a dot grid, draw, encode back, and render to PNG for checking.
from PIL import Image, ImageDraw
BITS = {(0,0):0x01,(0,1):0x02,(0,2):0x04,(1,0):0x08,(1,1):0x10,(1,2):0x20,(0,3):0x40,(1,3):0x80}
def decode(lines):
    h, w = len(lines) * 4, max(len(l) for l in lines) * 2
    g = [[0] * w for _ in range(h)]
    for r, l in enumerate(lines):
        for c, ch in enumerate(l):
            v = ord(ch) - 0x2800
            if 0 <= v < 256:
                for (dx, dy), b in BITS.items():
                    if v & b: g[r*4+dy][c*2+dx] = 1
    return g
def encode(g):
    out = []
    for r in range(0, len(g), 4):
        row = ''
        for c in range(0, len(g[0]), 2):
            v = sum(b for (dx, dy), b in BITS.items() if r+dy < len(g) and c+dx < len(g[0]) and g[r+dy][c+dx])
            row += chr(0x2800 + v)
        out.append(row)
    return out
def png(g, path, scale=8, grid=True):
    h, w = len(g), len(g[0])
    im = Image.new('RGB', (w*scale, h*scale), 'white'); d = ImageDraw.Draw(im)
    if grid:
        for c in range(0, w, 2): d.line([(c*scale, 0), (c*scale, h*scale)], fill=(235,235,235) if c % 20 else (180,180,255))
        for r in range(0, h, 4): d.line([(0, r*scale), (w*scale, r*scale)], fill=(235,235,235) if r % 20 else (180,180,255))
    for y in range(h):
        for x in range(w):
            if g[y][x]: d.ellipse([x*scale+1, y*scale+1, x*scale+scale-1, y*scale+scale-1], fill=(215,135,95))
    im.save(path)
