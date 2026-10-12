# Rescriva's design language: paper and ink

Rescriva began with the same look as Fernlet: greens and earth tones, soft organic shapes, a
companion speaking in thought bubbles. It keeps that calm feel but now looks like itself. The
screens are a sheet of paper, the type is ink, and one marker picks out whatever needs a look.
In the dark, the paper becomes a chalkboard.

Everything here lives in `scanner/Design/`:

| File | What's in it |
| --- | --- |
| `RescrivaTheme.swift` | Palette, type, radii, shadows, motion tokens, paper grain |
| `RescrivaMotifs.swift` | Folded sheet, ink stroke, ruled and dot-grid paper, empty states, margin note, the motion signatures |
| `RescrivaComponents.swift` | Buttons, chips, the switch, ink-stroke tabs, toast, banner, thumbnails, wordmark |
| `RescrivaIllustrations.swift` | Hand-drawn sketches beside their clean versions |
| `InkIcons.swift`, `InkIconPaths.swift` | The pen-drawn icon set (`InkIconPaths.swift` is generated) |

## Palette

Each colour has a paper (light) and a chalkboard (dark) appearance, defined once in
`RescrivaPalette` and exposed as `Color` tokens.

| Token | Paper | Chalkboard | Use |
| --- | --- | --- | --- |
| `stock` | `#F5F2EA` | `#222625` | Screen background: warm paper stock, or charcoal slate |
| `vellum` | `#FDFBF6` | `#2C302F` | Cards, sheets, pills |
| `carbon` | `#1D2233` | `#ECE9E1` | Primary text: carbon ink, or chalk |
| `graphite` | `#676C7A` | `#A3A79F` | Secondary text |
| `ink` | `#2B3B8C` | `#A9BAF2` | Brand colour and primary actions: indigo ink, or blue chalk |
| `bluePencil` | `#5A7BD0` | `#87A1EA` | Progress, secondary accent |
| `wash` | `#E3E7F4` | `#343A4C` | Muted fills, the chosen row |
| `highlighter` | `#F6C823` | `#F2D660` | **The one marker**: flags, highlights, pins, the camera's page outline |
| `markerInk` | `#B88A00` | `#F2D660` | The highlighter as a thin line or an icon (pinned, favourites, an uncertain arrow) |
| `vermilion` | `#CF4326` | `#F0866B` | Delete only, never errors or flags |
| `shade` | `#1D2233` | `#000000` | Shadows and scrims |
| `rim` | carbon at 18% | chalk at 45% | The hairline round a colour swatch |

These colours look the same in either appearance:

- `paper`: scanned pages and thumbnails.
- `printInk`: type laid on paper or on the highlighter.
- `ballpoint`: handwriting renderings.
- `darkroom`: the camera's surround.
- `chalk`: type and controls on the camera.

Rules:

- **Flags are highlighted, never red.** An uncertain word gets a highlighter swipe, as if
  someone had marked it on the page.
- **Pages are paper in both appearances.** The rebuilt document, thumbnails, the drawing canvas
  and sample pages pin `.environment(\.colorScheme, .light)`, so their ink keeps its paper
  colours in the dark.
- **Anything saved into a document uses paper colours.** That covers PDF annotations, the
  comparison marks and exported notes. They take `RescrivaPalette.x.onPaper`, never a dynamic
  colour, so dark mode can't leak into a file.
- **The camera and page editor are always dark** and are drawn with `chalk`, `printInk` and the
  highlighter.
- The app follows the system appearance. The camera darkens its window
  (`overrideUserInterfaceStyle`, set from `ContentView`), and the page editor pins
  `.environment(\.colorScheme, .dark)`.
- **The highlighter is a fill.** Where it has to be a hairline or an icon on paper, use
  `markerInk`; where type sits on it, use `printInk`.

## Type

Headings, the wordmark and the document's own voice are set in **New York**, the serif built
into iOS (so there's nothing to license or bundle). The interface keeps its sans (DM Sans where
it's bundled, otherwise SF Pro). Section labels are set like a document's running head: small
uppercase graphite, tracked out. Hints and empty states are set in New York italic, like a note
in the margin.

## Motifs

- **Folded corner**: cards (`paperCard()`) and page thumbnails (`foldedPage()`) have their
  top-right corner folded over. The flap casts a small shadow and the fold leaves a crease.
  Lists lie flat (`paperCard(fold: 0)`): the Library's folder cards have no fold.
- **Paper grain**: `GrainBackground` tiles mottling and short fibres over the stock. It
  multiplies on paper and lifts like chalk dust on the chalkboard.
- **Ruled and dot-grid paper**: empty states (`EmptyState`) sit on dot-grid or notebook-ruled
  sheets.
- **Ink-stroke tabs**: `RescrivaSegmentedPicker` sets its options like tabs on a ruled line.
  The chosen tab gets a hand-inked stroke (`InkStroke`), which slides across when the choice
  changes.
- **Margin note**: the companion's tips are italic notes on a folded slip, marked down the edge
  with the highlighter (`MarginNote`). This replaces Fernlet's thought bubbles.
- **Card-stock tabs**: buttons and pills use a squarer radius (`RescrivaRadius.control`) in
  place of capsules and circles.

## Icons

Icons look pen-drawn:

- every icon at a given size has the same stroke weight
- ends are cut square, with a slight lopsided flare where the pen lifts
- corners are mitred

`Glyph("doc.viewfinder")` draws Rescriva's ink icon when there is one and falls back to the SF
Symbol otherwise. To VoiceOver an ink icon is still its SF Symbol, so accessibility is
unchanged.

To add or change an icon, edit `Tools/InkIcons/generate.py`, then run it from the repository
root:

```sh
python3 Tools/InkIcons/generate.py --preview /tmp/icons.svg
```

## Illustrations

Illustrations show what Rescriva does: something drawn by hand next to the clean version
Rescriva makes of it. `SketchToCleanIllustration` has two subjects:

- a whiteboard flowchart becoming clean boxes (the empty Library)
- handwritten notes becoming typeset lines (empty folders)

The sketch is seeded, so it's the same every time.

## Motion

Motion is ease-out or spring, never linear. Rescriva has three signatures, and each one falls
back to a fade or a still image with Reduce Motion on:

1. **A scan bar sweeping the page.** Each page taken is held up in the viewfinder, cleaned up
   and squared, while a highlighter scan bar passes down it (`ScanLinePass`); then it drops
   onto the stack. The shutter itself is a soft flash. A scan bar also sweeps each page's
   thumbnail while its text is being read, and the page on the processing screen while a
   rebuild runs (`ScanLineLoop`).
2. **Ink drawing itself onto the screen.** As the rebuild recognises text, the page's lines
   write themselves in from left to right (`inked(_:)`). The empty-state sketches draw
   themselves in too.
3. **A page settling into place.** After an export, the toast shows a page dropping onto its
   stack and settling (`SettlingPage`). Screens and cards settle in from just above
   (`.settle`) rather than floating up. The processing page settles flat when the rebuild is
   done.

## App icon

The icon is a sheet of paper with its top-right corner folded over to show the ink-blue desk
beneath, and a stylized R written on it in a single broad-nib stroke of indigo ink. It has dark
(chalkboard) and tinted variants for iOS 18. To regenerate the icons (app and Safari extension),
run this from the repository root:

```sh
python3 Tools/AppIcon/make_icon.py
```

The script also draws other variants that keep the fold (`--preview DIR` renders them all):
typeset lines, lines with a scan bar, or the R on a page lying on an indigo tile. To ship one,
set `ICON` in the script and run it again.

## Tags

The Library's home has no tag list. Tags show as chips under the search field while searching,
to narrow the results (`TagFilterBar`). Rescriva adds some tags by itself when it first reads a
scan's pages (`AutoTags`): #receipt, #invoice, #contract, #recipe and #whiteboard. They carry a
small sparkle. Every other tag, like #todo, is added by hand.
