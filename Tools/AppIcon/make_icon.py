#!/usr/bin/env python3
"""Rescriva's app icon: a sheet of paper whose top-right corner is folded over
to show the ink-blue desk beneath, with a stylized R written on it in a
single stroke of indigo ink.

Run from the repository root (needs Pillow):

    python3 Tools/AppIcon/make_icon.py
    python3 Tools/AppIcon/make_icon.py --preview DIR   # also renders every variant into DIR

Writes the 1024 pt app icons (light, dark and tinted) into
scanner/Assets.xcassets/AppIcon.appiconset and the Safari extension's icons.
Other variants (`VARIANTS`) keep the fold and put something else on the
page: typeset lines, lines with a scan bar, or the page on an indigo tile.
"""
import math
import random

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4  # supersampling for smooth edges
S = SIZE * SCALE

THEMES = {
    # paper, paper shading, ink, muted type, desk under the fold, the fold's flap
    "light": dict(paper=(247, 244, 236), shade=(226, 220, 205), ink=(43, 59, 140), muted=(103, 108, 122),
                  desk=(43, 59, 140), flap=(233, 228, 214), grain=10),
    "dark": dict(paper=(35, 39, 38), shade=(26, 29, 28), ink=(236, 233, 225), muted=(163, 167, 159),
                 desk=(169, 186, 242), flap=(48, 53, 51), grain=7),
    "tinted": dict(paper=(0, 0, 0), shade=(0, 0, 0), ink=(255, 255, 255), muted=(150, 150, 150),
                   desk=(150, 150, 150), flap=(40, 40, 40), grain=0),
}

FOLD = 250  # how far the folded corner reaches along each edge, at 1024


def cubic(p0, p1, p2, p3, t):
    u = 1 - t
    return (u**3 * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t**3 * p3[0],
            u**3 * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t**3 * p3[1])


# The R's centreline as one continuous run of cubic curves (1024 space): up the
# stem from a small lead-in, round the bowl, back into the stem, and out along
# the leg with a flick.
R_STROKE = [
    ((352, 806), (360, 760), (372, 520), (384, 252)),      # the stem, written upward
    ((384, 252), (520, 214), (712, 236), (708, 376)),      # over the top of the bowl
    ((708, 376), (704, 498), (548, 532), (414, 520)),      # down and back into the stem
    ((414, 520), (520, 560), (604, 700), (676, 788)),      # the leg
    ((676, 788), (700, 818), (742, 826), (772, 806)),      # the flick
]


# Centres the letter on the page, nudged left and down, clear of the folded corner.
R_CENTRE = (512 - 22, 534)


def centreline(samples_per_curve=240, centre=R_CENTRE, scale=1.0):
    """The R's centreline, scaled about its own middle and centred on `centre`."""
    points = []
    for curve in R_STROKE:
        for i in range(samples_per_curve):
            points.append(cubic(*curve, i / samples_per_curve))
    points.append(R_STROKE[-1][3])
    xs, ys = [x for x, _ in points], [y for _, y in points]
    mx, my = (min(xs) + max(xs)) / 2, (min(ys) + max(ys)) / 2
    return [(centre[0] + (x - mx) * scale, centre[1] + (y - my) * scale) for x, y in points]


def nib_stroke(draw, points, colour, nib=76, thin=19, angle=-38):
    """Draws `points` with a broad-edged pen held at `angle` degrees: wide on
    strokes across the nib, hairline along it, like a calligrapher's R."""
    a = math.radians(angle)
    nx, ny = math.cos(a), math.sin(a)
    total = len(points)
    for i in range(total - 1):
        (x0, y0), (x1, y1) = points[i], points[i + 1]
        t = i / total
        # A little more ink as the pen lands and a lift at the very end.
        pressure = 0.86 + 0.14 * math.sin(math.pi * min(1, t * 1.6)) - 0.18 * max(0, (t - 0.93) / 0.07)
        half = (nib * pressure) / 2
        # The hairline floor keeps the stroke from vanishing along the nib.
        dx, dy = x1 - x0, y1 - y0
        length = math.hypot(dx, dy) or 1
        px, py = -dy / length, dx / length
        quad = [
            (x0 + nx * half + px * thin / 2, y0 + ny * half + py * thin / 2),
            (x1 + nx * half + px * thin / 2, y1 + ny * half + py * thin / 2),
            (x1 - nx * half - px * thin / 2, y1 - ny * half - py * thin / 2),
            (x0 - nx * half - px * thin / 2, y0 - ny * half - py * thin / 2),
        ]
        draw.polygon([(x * SCALE, y * SCALE) for x, y in quad], fill=colour)


def box(x, y, w, h):
    return [x * SCALE, y * SCALE, (x + w) * SCALE, (y + h) * SCALE]


def typeset_lines(draw, t, written_to=None):
    """A heading and four lines of type. Lines above `written_to` (a y) are in
    ink; the rest wait in a faint grey, as if not yet read."""
    rows = [(212, 300, 330, 56, "ink")] + [(212, y, w, 26, "muted") for y, w in ((452, 600), (540, 540), (628, 600), (716, 360))]
    for x, y, w, h, role in rows:
        colour = t[role]
        alpha = 255 if role == "ink" else 170
        if written_to is not None and y > written_to:
            colour, alpha = t["muted"], 70
        draw.rounded_rectangle(box(x, y, w, h), radius=(10 if role == "ink" else 7) * SCALE, fill=colour + (alpha,))


def scan_bar(image, t, y):
    """A scan bar across the page at `y`, with its glow trailing above."""
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    draw = ImageDraw.Draw(glow)
    for i in range(140):
        alpha = int(70 * (i / 140) ** 2)
        draw.rectangle(box(150, y - 140 + i, 724, 1), fill=t["ink"] + (alpha,))
    image.alpha_composite(glow)
    ImageDraw.Draw(image).rounded_rectangle(box(150, y - 4, 724, 8), radius=4 * SCALE, fill=t["ink"] + (255,))


def paper(t):
    image = Image.new("RGBA", (S, S), t["paper"] + (255,))
    if t["grain"]:
        rng = random.Random(0x9A9E5)
        small = Image.new("L", (SIZE // 2, SIZE // 2))
        small.putdata([128 + rng.randint(-t["grain"], t["grain"]) for _ in range((SIZE // 2) ** 2)])
        grain = small.resize((S, S), Image.BILINEAR)
        image = Image.merge("RGBA", [grain.point(lambda v, c=c: max(0, min(255, c + v - 128))) for c in t["paper"]] + [Image.new("L", (S, S), 255)])
    # A soft vignette of shading toward the bottom, like light falling across a sheet.
    mask = Image.linear_gradient("L").resize((S, S)).point(lambda v: int(v * 0.35))
    image.paste(Image.new("RGBA", (S, S), t["shade"] + (255,)), (0, 0), mask)
    return image


def fold_corner(image, t, theme, right=SIZE, top=0, fold=FOLD, desk=True):
    """Folds over the sheet's corner at (`right`, `top`): the desk shows where
    the corner was (unless the desk is already there), and the flap lies on
    the page with a little shadow under it."""
    r, tp, f = right * SCALE, top * SCALE, fold * SCALE
    draw = ImageDraw.Draw(image)
    if desk:
        draw.polygon([(r - f, tp), (r, tp), (r, tp + f)], fill=t["desk"] + (255,))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon([(r - f, tp), (r, tp + f), (r - f - f * 0.056, tp + f + f * 0.088)],
                                   fill=(0, 0, 0, 90 if theme != "tinted" else 0))
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(f * 0.056)))
    draw = ImageDraw.Draw(image)
    draw.polygon([(r - f, tp), (r, tp + f), (r - f, tp + f)], fill=t["flap"] + (255,))
    draw.line([(r - f, tp), (r, tp + f)], fill=t["shade"] + (255,), width=3 * SCALE)


def render(theme, variant="r"):
    """One icon. Variants: "r" (the R in one stroke of ink), "lines" (typeset
    lines), "scan" (lines with a scan bar halfway down), "indigo" (the R on a
    page lying on an indigo tile)."""
    t = THEMES[theme]
    if variant == "indigo":
        image = Image.new("RGBA", (S, S), t["desk"] + (255,))
        sheet = paper(t)
        # The page: portrait, inset on the tile, its corner cut where it folds.
        x0, y0, x1, y1, f = 208, 150, 816, 874, 150
        mask = Image.new("L", (S, S), 0)
        ImageDraw.Draw(mask).rounded_rectangle(box(x0, y0, x1 - x0, y1 - y0), radius=26 * SCALE, fill=255)
        ImageDraw.Draw(mask).polygon([((x1 - f) * SCALE, y0 * SCALE), (x1 * SCALE, y0 * SCALE), (x1 * SCALE, (y0 + f) * SCALE)], fill=0)
        page_shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        page_shadow.paste(Image.new("RGBA", (S, S), (0, 0, 0, 80)), (0, 14 * SCALE), mask)
        image.alpha_composite(page_shadow.filter(ImageFilter.GaussianBlur(18 * SCALE)))
        image.paste(sheet, (0, 0), mask)
        nib_stroke(ImageDraw.Draw(image), centreline(centre=(500, 530), scale=0.66), t["ink"] + (255,), nib=56, thin=14)
        fold_corner(image, t, theme, right=x1, top=y0, fold=f, desk=False)
    else:
        image = paper(t)
        draw = ImageDraw.Draw(image)
        if variant == "r":
            nib_stroke(draw, centreline(), t["ink"] + (255,))
        elif variant == "lines":
            typeset_lines(draw, t)
        elif variant == "scan":
            typeset_lines(draw, t, written_to=560)
            scan_bar(image, t, 600)
        fold_corner(image, t, theme)
    return image.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")


VARIANTS = ["r", "lines", "scan", "indigo"]
# The variant the app ships.
ICON = "r"


if __name__ == "__main__":
    import sys
    folder = "scanner/Assets.xcassets/AppIcon.appiconset/"
    light = render("light", ICON)
    light.save(folder + "AppIcon.png")
    render("dark", ICON).save(folder + "AppIcon-Dark.png")
    render("tinted", ICON).convert("L").convert("RGB").save(folder + "AppIcon-Tinted.png")
    for side in (48, 64, 96, 128, 256, 512):
        light.resize((side, side), Image.LANCZOS).save("SafariExtension/Resources/images/icon-%d.png" % side)
    if "--preview" in sys.argv:
        out = sys.argv[sys.argv.index("--preview") + 1]
        for variant in VARIANTS:
            for theme in ("light", "dark"):
                render(theme, variant).save("%s/icon-%s-%s.png" % (out, variant, theme))
