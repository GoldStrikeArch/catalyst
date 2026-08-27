"""Pixel-art "alchemy" icon for Catalyst: a bubbling Erlenmeyer flask on an indigo squircle.

32x32 hand-drawn grid, scaled x32 with nearest-neighbour to 1024x1024 so every icns size
(512..32) is an exact integer downscale and stays crisp.

Regenerate (from the umbrella root; needs Pillow):

    python3 rel/icon/gen_icon.py apps/catalyst_desktop/priv/icon.png \
        apps/catalyst_web/priv/static/favicon.ico
    rm rel/macosx/icons.icns   # desktop_deployment rebuilds it from icon.png on the next
                               # `mix release catalyst_desktop` (or run sips/iconutil by hand)
"""
import sys
from PIL import Image

GRID = 32
SCALE = 32

PALETTE = {
    "O": (11, 9, 24, 255),        # outline
    "g": (185, 212, 255, 255),    # glass highlight
    "n": (61, 63, 128, 255),      # glass tint (empty part of flask)
    "p": (46, 230, 166, 255),     # potion
    "P": (20, 176, 124, 255),     # potion, darker
    "l": (184, 255, 228, 255),    # potion light / bubbles
    "w": (255, 255, 255, 255),    # white sparkle
    "y": (255, 200, 87, 255),     # gold sparkle
    "Y": (255, 243, 196, 255),    # gold sparkle core
    "d": (110, 106, 168, 255),    # dim star
}
BG_FAR = (26, 23, 48, 255)
BG_MID = (36, 31, 71, 255)
BG_NEAR = (47, 40, 96, 255)

ART = [
    "................................",  # 0
    "................................",  # 1
    "................................",  # 2
    ".......d.........l.......d......",  # 3
    "...........OOOOOOOOOO...........",  # 4
    "...........OgnnnnnnnO...........",  # 5
    "....d.......OgnnnnnO............",  # 6
    "............OgnnnnnO...y........",  # 7
    "............OgnnlnnO..yYy.......",  # 8
    "............OgnnnnnO...y........",  # 9
    "......y.....OgnnnnnO............",  # 10
    "............OgnnnnlO............",  # 11
    "...........OgnnnnnnnO......d....",  # 12
    "..........OgnnnnnnnnnO..........",  # 13
    ".........OgnnnnlnnnnnnO.........",  # 14
    "........OgnnnnnnnnnnnnnO........",  # 15
    ".......OgnnnnnnnnnnnnnnnO.......",  # 16
    "......OglPlPPPPPPPPPPPPPPO......",  # 17
    ".....OgpppppppppppppppppppO.....",  # 18
    "....OgpppplppppppppppppppppO....",  # 19
    "...OgpppppppppppppppplpppppO....",  # 20 (sides go vertical from here)
    "...OgpppppppppppppppppppppppO...",  # 21
    "...OgppppppppppppPlpppppppppO...",  # 22
    "...OgpppppppppppPPPpppppppppO...",  # 23
    "...OgpppppppplppppppppppppppO...",  # 24
    "...OgPPPPPPPPPPPPPPPPPPPPPPPO...",  # 25
    "...OOPPPPPPPPPPPPPPPPPPPPPPOO...",  # 26
    "....OOOOOOOOOOOOOOOOOOOOOOOO....",  # 27
    "................................",  # 28
    "................................",  # 29
    "................................",  # 30
    "................................",  # 31
]


def inside_squircle(x, y, lo=2, hi=29, r=8):
    """Pixel-stepped rounded square covering cells lo..hi with corner radius r."""
    if not (lo <= x <= hi and lo <= y <= hi):
        return False
    cx = min(max(x, lo + r), hi - r)
    cy = min(max(y, lo + r), hi - r)
    return (x - cx) ** 2 + (y - cy) ** 2 <= r * r + r * 0.6


def background(x, y):
    d2 = (x - 15.5) ** 2 + (y - 19) ** 2
    if d2 < 8**2:
        return BG_NEAR
    if d2 < 13**2:
        return BG_MID
    return BG_FAR


def main(out_png, out_fav):
    for row in ART:
        assert len(row) == GRID, f"row length {len(row)}: {row!r}"
    img = Image.new("RGBA", (GRID, GRID), (0, 0, 0, 0))
    px = img.load()
    for y, row in enumerate(ART):
        for x, ch in enumerate(row):
            if ch in PALETTE:
                px[x, y] = PALETTE[ch]
            elif inside_squircle(x, y):
                px[x, y] = background(x, y)
    img.resize((GRID * SCALE, GRID * SCALE), Image.NEAREST).save(out_png)
    img.resize((64, 64), Image.NEAREST).save(out_fav)
    print("wrote", out_png, "and", out_fav)


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2])
