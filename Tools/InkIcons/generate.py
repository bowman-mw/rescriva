#!/usr/bin/env python3
"""Rescriva's pen-drawn icons.

Each icon is drawn on a 24 x 24 grid as pen strokes: one weight throughout,
square-cut ends and mitred corners, and a small flare where the pen leaves
the paper (a "nib") at the end of every open stroke longer than a few units.

Run from the repository root:

    python3 Tools/InkIcons/generate.py            # writes scanner/Design/InkIconPaths.swift
    python3 Tools/InkIcons/generate.py --preview out.svg   # also writes a preview sheet

Edit the icons here, not in the generated Swift.
"""
import math
import re
import sys

# Stroke width in grid units used by the preview (the app sets it from the
# rendered size; see InkGlyph in scanner/Design/InkIcons.swift).
PREVIEW_STROKE = 1.7
# Open strokes shorter than this (grid units) get square ends but no nib.
MIN_NIB_LENGTH = 3.5


# MARK: - Path helpers

def arc(cx, cy, r, start, end):
    """An arc as cubic segments (SVG path text, no initial move), angles in
    degrees, y down, sweeping from `start` to `end` (end > start: clockwise)."""
    out = []
    total = end - start
    steps = max(1, int(math.ceil(abs(total) / 90)))
    step = total / steps
    for i in range(steps):
        a0 = math.radians(start + step * i)
        a1 = math.radians(start + step * (i + 1))
        k = 4 / 3 * math.tan((a1 - a0) / 4)
        p0 = (cx + r * math.cos(a0), cy + r * math.sin(a0))
        p3 = (cx + r * math.cos(a1), cy + r * math.sin(a1))
        c1 = (p0[0] - k * r * math.sin(a0), p0[1] + k * r * math.cos(a0))
        c2 = (p3[0] + k * r * math.sin(a1), p3[1] - k * r * math.cos(a1))
        out.append("C%s %s %s %s %s %s" % tuple(fmt(v) for v in (*c1, *c2, *p3)))
    return " ".join(out)


def polar(cx, cy, r, degrees):
    a = math.radians(degrees)
    return (cx + r * math.cos(a), cy + r * math.sin(a))


def fmt(value):
    value = round(value, 3)
    text = ("%.3f" % value).rstrip("0").rstrip(".")
    return "0" if text in ("-0", "") else text


def star(cx, cy, outer, inner, points=5):
    coords = []
    for i in range(points * 2):
        r = outer if i % 2 == 0 else inner
        coords.append(polar(cx, cy, r, -90 + i * 180 / points))
    return "M" + " L".join("%s %s" % (fmt(x), fmt(y)) for x, y in coords) + " Z"


def gear(cx, cy, base, tip, teeth=8):
    coords = []
    for k in range(teeth):
        a = k * 360 / teeth
        coords += [polar(cx, cy, base, a - 13), polar(cx, cy, tip, a - 9), polar(cx, cy, tip, a + 9), polar(cx, cy, base, a + 13)]
    return "M" + " L".join("%s %s" % (fmt(x), fmt(y)) for x, y in coords) + " Z"


def arrowhead(tip, toward, length=4.2, spread=42):
    """A V-shaped arrowhead at `tip`, pointing along `toward` (a direction)."""
    dx, dy = toward
    n = math.hypot(dx, dy)
    dx, dy = dx / n, dy / n
    wings = []
    for sign in (1, -1):
        a = math.radians(spread * sign)
        bx = -dx * math.cos(a) + dy * math.sin(a)
        by = -dx * math.sin(a) * -1 - dy * math.cos(a)
        # Rotate the backward vector (-dx, -dy) by ±spread.
        rx = -dx * math.cos(a) - (-dy) * math.sin(a)
        ry = -dx * math.sin(a) + (-dy) * math.cos(a)
        wings.append((tip[0] + rx * length, tip[1] + ry * length))
    return "M%s %s L%s %s L%s %s" % (fmt(wings[0][0]), fmt(wings[0][1]), fmt(tip[0]), fmt(tip[1]), fmt(wings[1][0]), fmt(wings[1][1]))


def swap_axes(d):
    """The same path mirrored across the diagonal (x <-> y)."""
    tokens = re.findall(r"[MLHVCQZ]|-?\d*\.?\d+", d)
    out, cmd, args = [], None, []
    swap_cmd = {"H": "V", "V": "H"}
    i = 0
    result = []
    for t in tokens:
        if t.isalpha():
            result.append(swap_cmd.get(t, t))
        else:
            result.append(t)
    # Swap coordinate pairs for M L C Q; H/V already swapped.
    text = []
    cmd = None
    pair = []
    for t in result:
        if t.isalpha():
            cmd = t
            text.append(t)
            pair = []
        elif cmd in ("H", "V"):
            text.append(t)
        else:
            pair.append(t)
            if len(pair) == 2:
                text.append(pair[1] + " " + pair[0])
                pair = []
    return " ".join(text)


# MARK: - The icons
#
# Each entry: name -> (sf_symbols, elements). Elements:
#   ("p", d, nibs)   a stroked path; nibs: "both", "start", "end" or "none"
#                    (applies to open subpaths only)
#   ("circle", cx, cy, r)
#   ("dot", cx, cy, side)   a solid, slightly rounded square of ink

CORNERS = [("p", "M3 8.5 V3 H8.5", "both"), ("p", "M15.5 3 H21 V8.5", "both"),
           ("p", "M21 15.5 V21 H15.5", "both"), ("p", "M8.5 21 H3 V15.5", "both")]

SLIDERS_V = [
    ("p", "M6 3 V12.5", "start"), ("p", "M6 17 V21", "end"), ("p", "M4.25 12.5 H7.75 V17 H4.25 Z", "none"),
    ("p", "M12 3 V5.5", "start"), ("p", "M12 10 V21", "end"), ("p", "M10.25 5.5 H13.75 V10 H10.25 Z", "none"),
    ("p", "M18 3 V10.5", "start"), ("p", "M18 15 V21", "end"), ("p", "M16.25 10.5 H19.75 V15 H16.25 Z", "none"),
]

REBUILD_END = polar(12, 12.5, 7.75, 290)
REBUILD_TANGENT = (-math.sin(math.radians(290)), math.cos(math.radians(290)))

ICONS = {
    "scan": (["doc.viewfinder", "viewfinder"], CORNERS + [
        ("p", "M8.75 7 H13 L15.25 9.25 V17 H8.75 Z", "none"),
        ("p", "M13 7 V9.25 H15.25", "none"),
        ("p", "M10.75 12.75 H13.25", "none"),
    ]),
    "scanPlus": (["plus.viewfinder"], CORNERS + [
        ("p", "M12 7.75 V16.25", "both"), ("p", "M7.75 12 H16.25", "both"),
    ]),
    "whiteboard": (["rectangle.and.pencil.and.ellipsis"], [
        ("p", "M2.5 3.5 H21.5 V16.5 H2.5 Z", "none"),
        ("p", "M7.5 16.5 L6 21", "end"), ("p", "M16.5 16.5 L18 21", "end"),
        ("p", "M5.5 7 H10 V12.5 H5.5 Z", "none"),
        ("p", "M10 9.75 H14", "none"),
        ("p", "M14 7 H18.5 V12.5 H14 Z", "none"),
    ]),
    "photo": (["photo"], [
        ("p", "M3 4.5 H21 V19.5 H3 Z", "none"),
        ("p", "M3 16.5 L8.5 11 L13 15.5 L15.5 13 L21 18.5", "none"),
        ("circle", 16, 8.75, 1.75),
    ]),
    "document": (["doc", "doc.text"], [
        ("p", "M5.5 2.5 H14 L18.5 7 V21.5 H5.5 Z", "none"),
        ("p", "M14 2.5 V7 H18.5", "none"),
        ("p", "M8.5 11.5 H15.5", "both"), ("p", "M8.5 15 H15.5", "both"), ("p", "M8.5 18.5 H12.5", "none"),
    ]),
    "documentAdd": (["doc.badge.plus"], [
        ("p", "M11.5 21.5 H5.5 V2.5 H14 L18.5 7 V11", "both"),
        ("p", "M14 2.5 V7 H18.5", "none"),
        ("p", "M17.75 14 V21.5", "both"), ("p", "M14 17.75 H21.5", "both"),
    ]),
    "sliders": (["slider.vertical.3"], SLIDERS_V),
    "slidersHorizontal": (["slider.horizontal.3"], [(k, swap_axes(d), n) for k, d, n in SLIDERS_V]),
    "search": (["magnifyingglass"], [
        ("circle", 10.25, 10.25, 6.75),
        ("p", "M15.25 15.25 L21 21", "end"),
    ]),
    "chevronLeft": (["chevron.left"], [("p", "M15 4.5 L7.5 12 L15 19.5", "both")]),
    "chevronRight": (["chevron.right"], [("p", "M9 4.5 L16.5 12 L9 19.5", "both")]),
    "chevronUp": (["chevron.up"], [("p", "M4.5 15.5 L12 8 L19.5 15.5", "both")]),
    "chevronDown": (["chevron.down"], [("p", "M4.5 8.5 L12 16 L19.5 8.5", "both")]),
    "close": (["xmark"], [("p", "M5.5 5.5 L18.5 18.5", "both"), ("p", "M18.5 5.5 L5.5 18.5", "both")]),
    "plus": (["plus"], [("p", "M12 4 V20", "both"), ("p", "M4 12 H20", "both")]),
    "check": (["checkmark"], [("p", "M4 12.5 L9.5 18 L20 6.5", "both")]),
    "folder": (["folder"], [
        ("p", "M2.5 4.5 H9 L11 7 H21.5 V19.5 H2.5 Z", "none"),
        ("p", "M2.5 10.25 H21.5", "none"),
    ]),
    "folderAdd": (["folder.badge.plus"], [
        ("p", "M11.5 19.5 H2.5 V4.5 H9 L11 7 H21.5 V11.5", "both"),
        ("p", "M2.5 10.25 H11.5", "none"),
        ("p", "M17.75 14 V21.5", "both"), ("p", "M14 17.75 H21.5", "both"),
    ]),
    "stack": (["tray.full", "square.stack"], [
        ("p", "M3 9 H15 V21.5 H3 Z", "none"),
        ("p", "M6.5 5.75 H18.25 V18", "both"),
        ("p", "M10 2.5 H21.5 V14.5", "both"),
    ]),
    "pin": (["pin", "pin.fill"], [
        ("p", "M8 3.5 H16", "both"),
        ("p", "M9.75 3.5 V9.25 L6.5 13 H17.5 L14.25 9.25 V3.5", "none"),
        ("p", "M12 13 V21.5", "end"),
    ]),
    "star": (["star", "star.fill"], [("p", star(12, 12.75, 9.5, 4.1), "none")]),
    "trash": (["trash"], [
        ("p", "M3.5 6.5 H20.5", "both"),
        ("p", "M9.25 6.5 V3.25 H14.75 V6.5", "none"),
        ("p", "M5.75 6.5 L7 21 H17 L18.25 6.5", "none"),
        ("p", "M10.25 10 V17.5", "both"), ("p", "M13.75 10 V17.5", "both"),
    ]),
    "share": (["square.and.arrow.up"], [
        ("p", "M12 3 V14.5", "end"),
        ("p", "M8 7 L12 3 L16 7", "both"),
        ("p", "M8.5 9.75 H4.5 V21.5 H19.5 V9.75 H15.5", "both"),
    ]),
    "hash": (["number"], [
        ("p", "M10 3.5 L8.25 20.5", "both"), ("p", "M15.75 3.5 L14 20.5", "both"),
        ("p", "M4.5 9 H20", "both"), ("p", "M4 15 H19.5", "both"),
    ]),
    "info": (["info.circle"], [
        ("circle", 12, 12, 9.25),
        ("p", "M12 10.75 V17.25", "both"),
        ("dot", 12, 7.25, 2.1),
    ]),
    "warning": (["exclamationmark.triangle"], [
        ("p", "M12 3 L21.75 20 H2.25 Z", "none"),
        ("p", "M12 9 V14", "both"),
        ("dot", 12, 16.75, 2.0),
    ]),
    "rebuild": (["arrow.clockwise"], [
        ("p", "M%s %s %s" % (fmt(polar(12, 12.5, 7.75, 0)[0]), fmt(polar(12, 12.5, 7.75, 0)[1]), arc(12, 12.5, 7.75, 0, 290)), "start"),
        ("p", arrowhead(REBUILD_END, REBUILD_TANGENT), "both"),
    ]),
    "undo": (["arrow.uturn.backward"], [
        ("p", "M9 4.5 L4.5 9 L9 13.5", "both"),
        ("p", "M4.5 9 H14.5 C17.8 9 20 11.4 20 14.5 C20 17.6 17.8 20 14.5 20 H11", "end"),
    ]),
    "redo": (["arrow.uturn.forward"], [
        ("p", "M15 4.5 L19.5 9 L15 13.5", "both"),
        ("p", "M19.5 9 H9.5 C6.2 9 4 11.4 4 14.5 C4 17.6 6.2 20 9.5 20 H13", "end"),
    ]),
    "more": (["ellipsis"], [("dot", 5.5, 12, 2.6), ("dot", 12, 12, 2.6), ("dot", 18.5, 12, 2.6)]),
    "lock": (["lock"], [
        ("p", "M4.5 10.5 H19.5 V21 H4.5 Z", "none"),
        ("p", "M8 10.5 V7.5 C8 5 9.8 3 12 3 C14.2 3 16 5 16 7.5 V10.5", "none"),
        ("p", "M12 14 V17.5", "none"),
    ]),
    "bolt": (["bolt.fill", "bolt"], [("p", "M13.5 2.5 L5 13.5 H11.5 L10.5 21.5 L19 10.5 H12.5 Z", "none")]),
    "book": (["book.closed", "book"], [
        ("p", "M6.75 2.75 H19 V17.5 H7 C5.9 17.5 5 18.4 5 19.5 V4.5 C5 3.5 5.75 2.75 6.75 2.75 Z", "none"),
        ("p", "M5 19.5 C5 20.6 5.9 21.5 7 21.5 H19 V17.5", "none"),
        ("p", "M9 7 H15", "none"),
    ]),
    "briefcase": (["briefcase"], [
        ("p", "M2.5 7.5 H21.5 V20 H2.5 Z", "none"),
        ("p", "M8.5 7.5 V4.25 H15.5 V7.5", "none"),
        ("p", "M2.5 12.75 H21.5", "none"),
    ]),
    "flask": (["flask"], [
        ("p", "M8.25 3 H15.75", "both"),
        ("p", "M10 3 V9 L4.5 19 C4.1 19.9 4.6 21 5.6 21 H18.4 C19.4 21 19.9 19.9 19.5 19 L14 9 V3", "none"),
        ("p", "M7 15.5 H17", "none"),
    ]),
    "house": (["house"], [
        ("p", "M2.5 11.5 L12 3.5 L21.5 11.5", "both"),
        ("p", "M5 9.5 V21 H19 V9.5", "none"),
        ("p", "M10 21 V15 H14 V21", "none"),
    ]),
    "lightbulb": (["lightbulb"], [
        ("p", "M9 16 C9 13.75 5.5 12.6 5.5 8.75 C5.5 5.2 8.4 2.5 12 2.5 C15.6 2.5 18.5 5.2 18.5 8.75 C18.5 12.6 15 13.75 15 16 Z", "none"),
        ("p", "M9 18.75 H15", "both"), ("p", "M10.25 21.25 H13.75", "none"),
    ]),
    "pencil": (["pencil"], [
        ("p", "M4 20 L5 15 L15.75 4.25 C16.6 3.4 17.9 3.4 18.75 4.25 L19.75 5.25 C20.6 6.1 20.6 7.4 19.75 8.25 L9 19 Z", "none"),
        ("p", "M14 6 L18 10", "none"),
        ("p", "M5 15 L9 19", "none"),
    ]),
    "calendar": (["calendar"], [
        ("p", "M3 5.25 H21 V21 H3 Z", "none"),
        ("p", "M3 9.75 H21", "none"),
        ("p", "M8 2.5 V7.5", "both"), ("p", "M16 2.5 V7.5", "both"),
        ("dot", 8, 13.75, 1.8), ("dot", 12, 13.75, 1.8), ("dot", 16, 13.75, 1.8), ("dot", 8, 17.5, 1.8), ("dot", 12, 17.5, 1.8),
    ]),
    "heart": (["heart"], [
        ("p", "M12 20.25 C6 15.75 2.75 12.25 2.75 8.5 C2.75 5.6 5 3.6 7.75 3.6 C9.6 3.6 11.2 4.7 12 6.4 C12.8 4.7 14.4 3.6 16.25 3.6 C19 3.6 21.25 5.6 21.25 8.5 C21.25 12.25 18 15.75 12 20.25 Z", "none"),
    ]),
    "gear": (["gearshape"], [("p", gear(12, 12, 6.6, 9.25), "none"), ("circle", 12, 12, 2.75)]),
    "copy": (["doc.on.doc"], [
        ("p", "M8.5 7 H20 V21.5 H8.5 Z", "none"),
        ("p", "M4 16.5 V2.5 H15.5 V7", "start"),
    ]),
    "note": (["text.bubble"], [
        ("p", "M3 3.5 H21 V16 H10.5 L5.75 20.75 V16 H3 Z", "none"),
        ("p", "M7 8 H17", "both"), ("p", "M7 11.75 H13.5", "both"),
    ]),
}


# MARK: - Parsing

def parse(d):
    """Subpaths as lists of segments: ("M", p) ("L", p) ("C", c1, c2, p) ("Q", c, p) ("Z",)."""
    tokens = re.findall(r"[MLHVCQZ]|-?\d*\.?\d+", d)
    subpaths, current, pos, start = [], None, (0.0, 0.0), (0.0, 0.0)
    i = 0

    def num():
        nonlocal i
        value = float(tokens[i]); i += 1
        return value

    while i < len(tokens):
        cmd = tokens[i]; i += 1
        if cmd == "M":
            pos = (num(), num()); start = pos
            current = [("M", pos)]; subpaths.append(current)
        elif cmd == "L":
            pos = (num(), num()); current.append(("L", pos))
        elif cmd == "H":
            pos = (num(), pos[1]); current.append(("L", pos))
        elif cmd == "V":
            pos = (pos[0], num()); current.append(("L", pos))
        elif cmd == "C":
            c1 = (num(), num()); c2 = (num(), num()); pos = (num(), num()); current.append(("C", c1, c2, pos))
        elif cmd == "Q":
            c = (num(), num()); pos = (num(), num()); current.append(("Q", c, pos))
        elif cmd == "Z":
            current.append(("Z",)); pos = start
        # Implicit repeats of the same command.
        while i < len(tokens) and not tokens[i].isalpha():
            if cmd in ("M", "L"):
                pos = (num(), num()); current.append(("L", pos))
            elif cmd == "H":
                pos = (num(), pos[1]); current.append(("L", pos))
            elif cmd == "V":
                pos = (pos[0], num()); current.append(("L", pos))
            elif cmd == "C":
                c1 = (num(), num()); c2 = (num(), num()); pos = (num(), num()); current.append(("C", c1, c2, pos))
            else:
                raise ValueError("unexpected numbers after %s in %s" % (cmd, d))
    return subpaths


def unit(dx, dy):
    n = math.hypot(dx, dy)
    return (0.0, 0.0) if n == 0 else (dx / n, dy / n)


def length(sub):
    total, pos = 0.0, sub[0][1]
    for seg in sub[1:]:
        if seg[0] == "Z":
            continue
        end = seg[-1]
        total += math.hypot(end[0] - pos[0], end[1] - pos[1])
        pos = end
    return total


def terminals(sub, nibs):
    """(point, outward direction) for the ends of an open subpath."""
    if any(seg[0] == "Z" for seg in sub) or nibs == "none" or len(sub) < 2 or length(sub) < MIN_NIB_LENGTH:
        return []
    out = []
    first = sub[1]
    p0 = sub[0][1]
    toward = first[1] if first[0] in ("C", "Q") else first[-1]
    if toward == p0 and first[0] == "C":
        toward = first[2]
    if nibs in ("both", "start"):
        out.append((p0, unit(p0[0] - toward[0], p0[1] - toward[1])))
    last = sub[-1]
    end = last[-1]
    before = sub[-2][-1]
    if last[0] == "C":
        before = last[2] if last[2] != end else last[1]
    elif last[0] == "Q":
        before = last[1]
    if nibs in ("both", "end"):
        out.append((end, unit(end[0] - before[0], end[1] - before[1])))
    return out


def nib_polygon(point, direction, width):
    """The flare at a stroke's end, in grid units: a little wider than the
    stroke where the pen lifts, and a touch asymmetric, like a nib's angle."""
    (x, y), (dx, dy) = point, direction
    nx, ny = -dy, dx
    inner, outer = -0.45 * width, 0.5 * width
    left_in, left_out, right_out, right_in = 0.5 * width, 0.64 * width, 0.58 * width, 0.5 * width
    return [
        (x + dx * inner + nx * left_in, y + dy * inner + ny * left_in),
        (x + dx * outer + nx * left_out, y + dy * outer + ny * left_out),
        (x + dx * outer - nx * right_out, y + dy * outer - ny * right_out),
        (x + dx * inner - nx * right_in, y + dy * inner - ny * right_in),
    ]


# MARK: - Swift

def swift_point(p):
    return "CGPoint(x: %s, y: %s)" % (fmt(p[0]), fmt(p[1]))


def swift_strokes(elements):
    lines = []
    for element in elements:
        if element[0] == "p":
            for sub in parse(element[1]):
                for seg in sub:
                    if seg[0] == "M":
                        lines.append("path.move(to: %s)" % swift_point(seg[1]))
                    elif seg[0] == "L":
                        lines.append("path.addLine(to: %s)" % swift_point(seg[1]))
                    elif seg[0] == "C":
                        lines.append("path.addCurve(to: %s, control1: %s, control2: %s)" % (swift_point(seg[3]), swift_point(seg[1]), swift_point(seg[2])))
                    elif seg[0] == "Q":
                        lines.append("path.addQuadCurve(to: %s, control: %s)" % (swift_point(seg[2]), swift_point(seg[1])))
                    elif seg[0] == "Z":
                        lines.append("path.closeSubpath()")
        elif element[0] == "circle":
            _, cx, cy, r = element
            lines.append("path.addEllipse(in: CGRect(x: %s, y: %s, width: %s, height: %s))" % (fmt(cx - r), fmt(cy - r), fmt(2 * r), fmt(2 * r)))
    return lines


def swift_marks(elements):
    lines = []
    for element in elements:
        if element[0] == "dot":
            _, cx, cy, side = element
            lines.append("path.addRoundedRect(in: CGRect(x: %s, y: %s, width: %s, height: %s), cornerSize: CGSize(width: %s, height: %s))"
                         % (fmt(cx - side / 2), fmt(cy - side / 2), fmt(side), fmt(side), fmt(side * 0.22), fmt(side * 0.22)))
    return lines


def swift_terminals(elements):
    found = []
    for element in elements:
        if element[0] == "p":
            for sub in parse(element[1]):
                found += terminals(sub, element[2])
    return ["InkTerminal(x: %s, y: %s, dx: %s, dy: %s)" % (fmt(p[0]), fmt(p[1]), fmt(d[0]), fmt(d[1])) for p, d in found]


def swift_source():
    names = list(ICONS)
    out = []
    out.append("//")
    out.append("//  InkIconPaths.swift")
    out.append("//  Rescriva (fork of Open Scanner)")
    out.append("//")
    out.append("//  Generated by Tools/InkIcons/generate.py: edit the icons there, not here.")
    out.append("//")
    out.append("")
    out.append("import SwiftUI")
    out.append("")
    out.append("/// Rescriva's pen-drawn icons, on a 24 × 24 grid. See `InkGlyph`.")
    out.append("enum InkIcon: String, CaseIterable {")
    out.append("\tcase " + ", ".join(names))
    out.append("")
    out.append("\t/// The icon standing in for an SF Symbol, if Rescriva draws one.")
    out.append("\tinit?(symbol: String) {")
    out.append("\t\tswitch symbol {")
    for name in names:
        symbols = ", ".join('"%s"' % s for s in ICONS[name][0])
        out.append("\t\tcase %s: self = .%s" % (symbols, name))
    out.append("\t\tdefault: return nil")
    out.append("\t\t}")
    out.append("\t}")
    out.append("")
    out.append("\t/// The pen strokes, open and closed.")
    out.append("\tvar strokes: Path {")
    out.append("\t\tvar path = Path()")
    out.append("\t\tswitch self {")
    for name in names:
        lines = swift_strokes(ICONS[name][1])
        out.append("\t\tcase .%s:" % name)
        if lines:
            out += ["\t\t\t" + line for line in lines]
        else:
            out.append("\t\t\tbreak")
    out.append("\t\t}")
    out.append("\t\treturn path")
    out.append("\t}")
    out.append("")
    out.append("\t/// Solid marks of ink (dots).")
    out.append("\tvar marks: Path {")
    out.append("\t\tvar path = Path()")
    out.append("\t\tswitch self {")
    with_marks = [n for n in names if swift_marks(ICONS[n][1])]
    for name in with_marks:
        out.append("\t\tcase .%s:" % name)
        out += ["\t\t\t" + line for line in swift_marks(ICONS[name][1])]
    out.append("\t\tdefault:")
    out.append("\t\t\tbreak")
    out.append("\t\t}")
    out.append("\t\treturn path")
    out.append("\t}")
    out.append("")
    out.append("\t/// Where open strokes end, and which way they leave: each end gets a nib.")
    out.append("\tvar terminals: [InkTerminal] {")
    out.append("\t\tswitch self {")
    with_terminals = [n for n in names if swift_terminals(ICONS[n][1])]
    for name in with_terminals:
        items = swift_terminals(ICONS[name][1])
        out.append("\t\tcase .%s:" % name)
        out.append("\t\t\treturn [")
        out += ["\t\t\t\t%s," % item for item in items]
        out.append("\t\t\t]")
    out.append("\t\tdefault:")
    out.append("\t\t\treturn []")
    out.append("\t\t}")
    out.append("\t}")
    out.append("}")
    out.append("")
    return "\n".join(out)


# MARK: - Preview

def svg_path(elements):
    parts = []
    for element in elements:
        if element[0] == "p":
            parts.append(element[1])
        elif element[0] == "circle":
            _, cx, cy, r = element
            parts.append("M%s %s %s Z" % (fmt(cx + r), fmt(cy), arc(cx, cy, r, 0, 360)))
    return " ".join(parts)


def svg_icon(name, x, y, size, color, fill=False):
    elements = ICONS[name][1]
    box = size * 1.2
    scale = box / 24
    width = max(1.25, size * 0.078) / scale
    g = ['<g transform="translate(%s %s) scale(%s)">' % (fmt(x), fmt(y), fmt(scale))]
    d = svg_path(elements)
    if fill:
        g.append('<path d="%s" fill="%s"/>' % (d, color))
    g.append('<path d="%s" fill="none" stroke="%s" stroke-width="%s" stroke-linecap="square" stroke-linejoin="miter" stroke-miterlimit="4"/>' % (d, color, fmt(width)))
    for element in elements:
        if element[0] == "dot":
            _, cx, cy, side = element
            g.append('<rect x="%s" y="%s" width="%s" height="%s" rx="%s" fill="%s"/>' % (fmt(cx - side / 2), fmt(cy - side / 2), fmt(side), fmt(side), fmt(side * 0.22), color))
        if element[0] == "p":
            for sub in parse(element[1]):
                for point, direction in terminals(sub, element[2]):
                    poly = nib_polygon(point, direction, width)
                    g.append('<polygon points="%s" fill="%s"/>' % (" ".join("%s,%s" % (fmt(a), fmt(b)) for a, b in poly), color))
    g.append("</g>")
    return "".join(g)


def preview(path):
    names = list(ICONS)
    columns = 4
    cell_w, cell_h = 230, 74
    rows = math.ceil(len(names) / columns)
    width, height = columns * cell_w, rows * cell_h
    themes = [("#F5F2EA", "#1D2233", "#2B3B8C", "#676C7A"), ("#222625", "#ECE9E1", "#A9BAF2", "#A3A79F")]
    svg = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d">' % (width, height * 2)]
    for t, (bg, fg, accent, quiet) in enumerate(themes):
        oy = t * height
        svg.append('<rect x="0" y="%d" width="%d" height="%d" fill="%s"/>' % (oy, width, height, bg))
        for i, name in enumerate(names):
            cx, cy = (i % columns) * cell_w, oy + (i // columns) * cell_h
            svg.append(svg_icon(name, cx + 10, cy + 14, 17, fg))
            svg.append(svg_icon(name, cx + 42, cy + 8, 24, accent))
            svg.append(svg_icon(name, cx + 82, cy + 4, 32, fg, fill=name in ("star",) and t == 1))
            svg.append('<text x="%d" y="%d" font-family="Helvetica" font-size="12" fill="%s">%s</text>' % (cx + 128, cy + 30, quiet, name))
    svg.append("</svg>")
    with open(path, "w") as f:
        f.write("\n".join(svg))


if __name__ == "__main__":
    with open("scanner/Design/InkIconPaths.swift", "w") as f:
        f.write(swift_source())
    if "--preview" in sys.argv:
        preview(sys.argv[sys.argv.index("--preview") + 1])
