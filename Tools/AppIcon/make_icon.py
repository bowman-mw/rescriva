#!/usr/bin/env python3
"""Rescriva's app icon: a stylized R written in a single stroke of indigo ink,
a swipe of highlighter behind it, on a sheet of paper whose top-right corner
is folded over to show the ink-blue desk beneath.

Run from the repository root (needs Pillow):

    python3 Tools/AppIcon/make_icon.py

Writes the 1024 pt app icons (light, dark and tinted) into
scanner/Assets.xcassets/AppIcon.appiconset and the Safari extension's icons.
"""
import math
import random

from PIL import Image, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 4  # supersampling for smooth edges
S = SIZE * SCALE

THEMES = {
    # paper, paper shading, ink, highlighter (rgba), desk under the fold, flap
    "light": dict(paper=(247, 244, 236), shade=(226, 220, 205), ink=(43, 59, 140), marker=(246, 200, 35, 205),
                  desk=(43, 59, 140), flap=(233, 228, 214), grain=10),
    "dark": dict(paper=(35, 39, 38), shade=(26, 29, 28), ink=(236, 233, 225), marker=(242, 214, 96, 200),
                 desk=(169, 186, 242), flap=(48, 53, 51), grain=7),
    "tinted": dict(paper=(0, 0, 0), shade=(0, 0, 0), ink=(255, 255, 255), marker=(255, 255, 255, 70),
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


# Nudges the letter left of centre and down a touch, away from the folded corner.
OFFSET = (-38, 14)


def centreline(samples_per_curve=240):
    points = []
    for curve in R_STROKE:
        for i in range(samples_per_curve):
            points.append(cubic(*curve, i / samples_per_curve))
    points.append(R_STROKE[-1][3])
    return [(x + OFFSET[0], y + OFFSET[1]) for x, y in points]


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


def highlighter(size, colour):
    """A swipe of highlighter: a chisel tip's band with angled ends, slightly tilted."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    band = [(206 + OFFSET[0], 606 + OFFSET[1]), (836 + OFFSET[0], 568 + OFFSET[1]),
            (814 + OFFSET[0], 704 + OFFSET[1]), (230 + OFFSET[0], 736 + OFFSET[1])]
    draw.polygon([(x * SCALE, y * SCALE) for x, y in band], fill=colour)
    return layer


def render(theme):
    t = THEMES[theme]
    image = Image.new("RGBA", (S, S), t["paper"] + (255,))
    # Paper grain.
    if t["grain"]:
        rng = random.Random(0x9A9E5)
        small = Image.new("L", (SIZE // 2, SIZE // 2))
        small.putdata([128 + rng.randint(-t["grain"], t["grain"]) for _ in range((SIZE // 2) ** 2)])
        grain = small.resize((S, S), Image.BILINEAR)
        paper = Image.new("RGBA", (S, S), t["paper"] + (255,))
        tint = Image.merge("RGBA", [grain.point(lambda v, c=c: max(0, min(255, c + v - 128))) for c in t["paper"]] + [Image.new("L", (S, S), 255)])
        image = Image.blend(paper, tint, 1.0)
    # A soft vignette of shading toward the bottom, like light falling across a sheet.
    shade = Image.new("RGBA", (S, S), t["shade"] + (0,))
    mask = Image.linear_gradient("L").resize((S, S)).point(lambda v: int(v * 0.35))
    image.paste(Image.new("RGBA", (S, S), t["shade"] + (255,)), (0, 0), mask)

    image.alpha_composite(highlighter(S, t["marker"]))
    draw = ImageDraw.Draw(image)
    nib_stroke(draw, centreline(), t["ink"] + (255,))

    # The folded corner: the desk shows where the corner was, and the flap lies on the page.
    f = FOLD * SCALE
    draw.polygon([(S - f, 0), (S, 0), (S, f)], fill=t["desk"] + (255,))
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).polygon([(S - f, 0), (S, f), (S - f - 14 * SCALE, f + 22 * SCALE)], fill=(0, 0, 0, 90 if theme != "tinted" else 0))
    image.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14 * SCALE)))
    draw = ImageDraw.Draw(image)
    draw.polygon([(S - f, 0), (S, f), (S - f, f)], fill=t["flap"] + (255,))
    draw.line([(S - f, 0), (S, f)], fill=t["shade"] + (255,), width=3 * SCALE)

    return image.resize((SIZE, SIZE), Image.LANCZOS).convert("RGB")


if __name__ == "__main__":
    folder = "scanner/Assets.xcassets/AppIcon.appiconset/"
    light = render("light")
    light.save(folder + "AppIcon.png")
    render("dark").save(folder + "AppIcon-Dark.png")
    render("tinted").convert("L").convert("RGB").save(folder + "AppIcon-Tinted.png")
    for side in (48, 64, 96, 128, 256, 512):
        light.resize((side, side), Image.LANCZOS).save("SafariExtension/Resources/images/icon-%d.png" % side)
