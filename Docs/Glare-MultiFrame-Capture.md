# Glare: a second look (multi-frame capture)

Design note, 2026-10-10. Status (2026-10-12): fusion core tested on synthetic photos; live check, capture sequence, processing, hint and setting wired into the camera (steps 3–6 below), not yet tried end to end on an iPhone. The live check does flag the lamp hotspot on three real stills of a laminated sheet (`Par Count`, 10–15% of cells, slide suggested toward the nearer edge).

**Recommendation.** Keep today's one-photo capture as the fast path. When the live preview shows glare on the page, take the normal still, then ask the user to slide the phone a few centimetres. Take one or two more full-resolution stills once the live view shows the glary part clean, and fuse them with `GlareFusion` (`scanner/Capture/GlareFusion.swift`). Don't use Live Photo, exposure brackets or video frames as the source.

On a synthetic glossy page with a clipped highlight over the body text, fusing three stills gives:

- **Pixel error under the glare:** 34.7 → 8.1 RMSE (sRGB levels, against a glare-free photo).
- **Lines under the glare read by Vision OCR:** 5 of 12 → 12 of 12.
- **Time on this Mac:** about 0.25 s for the whole fuse.

Real-device numbers are still missing (see "Still to test on a device").

![Reference shot](glare-fusion/shot-reference.jpg) ![Second shot, phone eased 8 cm left](glare-fusion/shot-eased-left.jpg)

![Crops under the glare: one photo, one photo + whiteboard glare heuristic, median, minimum, GlareFusion, glare-free](glare-fusion/crops-glossy-3.jpg)

## How glare behaves

On paper, glare is the lamp's mirror image. It **adds** light, it doesn't multiply it, and it often clips.

The highlight sits where the line from the lens to the lamp's reflection below the page crosses the page. That has two consequences for the design:

- **Turning the phone about its lens does not move the glare on the page. Moving the phone does.** If the lens is `h_c` above the page and the lamp `h_l`, the highlight travels `h_l / (h_c + h_l)` of the phone's sideways move, in the same direction.
  - Ceiling lamp 1.6 m up, phone at 36 cm: 82%.
  - Desk lamp 50 cm up: 58%.
  - A glare blob 3–6 cm across clears after a **5–10 cm slide**. So the hint says *ease left*, not *tilt*.
- **Slide toward the page edge nearest the glare.** The highlight then lands on the margin or off the page, and the new shot is clean where the first one wasn't.

Ink stays put while the highlight moves. So once the photos are aligned in page space, each part of the page can be taken from a photo that sees it without glare.

## 1. Where the frames come from

| Source | Resolution and quality | Glare | Verdict |
| --- | --- | --- | --- |
| **Live Photo movie** (`livePhotoCaptureEnabled`, `livePhotoMovieFileURL`) | A preview-class HEVC/H.264 video track (`AVCaptureResolvedPhotoSettings.livePhotoMovieDimensions`, about 2 MP on recent iPhones; log it on device). It has temporal compression and motion blur from the move. | About 1.5 s before and after the shutter, so the user would have to move *before* tapping. `livePhotoAutoTrimmingEnabled` (on by default) trims "excessive movement", which is exactly the move we need. | **No.** Too few pixels for small text, awkward timing, and it needs a lengthy pipeline reconfiguration. It also forces preview-sized video-data buffers. The movie is a file we'd write and have to delete; it would only reach the photo library if we saved it, which we wouldn't. |
| **Exposure bracket** (`AVCapturePhotoBracketSettings`) | Full resolution. Brackets skip still stabilization, fusion and zero shutter lag (SDK header), and `maxBracketedCapturePhotoCount` can be 0 for a format. | Every bracket is taken from the same spot within about 100 ms, so the glare doesn't move. A darker bracket only helps sheen that isn't clipped, which Smart HDR already tone-maps. | **No.** It can't see under a clipped highlight. |
| **Video-data frames** while the user moves | With `.photo` the video output gets **preview-sized** buffers by default ("assumed … a preview proxy", SDK header). Full-size frames need `automaticallyConfiguresOutputBufferDimensions = false` and about 1.4 GB/s of BGRA at 12 MP. Video exposure blurs a moving phone, frames have rolling shutter, and there's no still-pipeline denoise. | Viewpoints change continuously. | **For guidance only.** The preview frames we already analyse at about 10 fps carry the page quad and a cheap glare map (below). |
| **Two or three stills** at distinct positions (`capturePhoto` as today) | Same 12 MP processed HEIF as the current single shot. iOS 17's zero shutter lag is on by default where supported. `isResponsiveCaptureEnabled` and `isFastCapturePrioritizationEnabled` let a capture overlap the previous one's processing. | Each still is taken once the phone has settled at a new position. | **Yes.** It gives the best pixels for OCR, and everything stays in memory on device. |

## 2. Registration

`GlareFusion.align` places every frame on the reference's page grid (the first still's quad sets the page size and aspect, as `correctPerspective` does). It does this in two steps:

1. **Quad homography:** the frame's detected quad onto the page rectangle. This is a 4-point solve in `Homography`, warped in one resample with `CIPerspectiveTransform`.
2. **Refinement:** `VNHomographicImageRegistrationRequest` at 1024 px, run on luminance divided by the paper level and clamped at 1. Clamping flattens glare (and the paper around it) to white, so only ink drives the match.
   - The refinement is accepted only if it moves no page corner by more than 3% and lowers the mean difference to the reference over the pixels both cover.
   - Checked empirically, Vision's `warpTransform` maps the *floating* image onto the reference, in pixels with a bottom-left origin.

Measured in the harness (`Tools/GlareFusionHarness`): the second shot is moved sideways and re-aimed at the page, and the error is the true misplacement on a 2400 px-wide page:

| Tilt | Vision's quads only | Quads + refinement | True quads (with the 1% inset) |
| --- | --- | --- | --- |
| 3.4° | 11.6 px mean / 16.3 max | 0.50 / 1.30 | 0.22 / 0.36 |
| 5.5° | 6.8 / 12.8 | 0.51 / 0.96 | 0.42 / 0.64 |
| 8.2° | 8.9 / 16.2 | 0.26 / 0.62 | 0.61 / 0.92 |
| 11.1° | 7.9 / 13.9 | 0.15 / 0.39 | 0.80 / 1.20 |
| 14.1° | 11.1 / 14.8 | 0.44 / 1.06 | 0.98 / 1.47 |
| 17.0° | 8.5 / 21.5 | 0.24 / 0.53 | 1.15 / 1.73 |

**Detected quads alone are not good enough.** Fusing on them alone ghosts badly: RMSE 32 against 16 for a single photo. With refinement, ±10–15° of hand tilt is a non-issue for a flat page.

What the test can't show: real pages aren't flat. A 1 mm bulge seen 12° off-axis shifts about 2–3 px at this scale, and a homography can't fix that. The blend takes whole regions from one frame and feathers the seams over about 50 px, so curl shows only as slight doubling inside the seams. If device tests show it, add tile-wise refinement (`VNTranslationalImageRegistrationRequest` per tile, or `VNGenerateOpticalFlowRequest`).

## 3. Fusion

### How it works

1. **Exposure match.** Each frame gets a per-channel gain: the median of reference ÷ frame over well-exposed pixels. Auto-exposure and white balance shift between shots; the harness simulates −6% to +5%.
2. **Glare score**, at 384 px. Regress each frame's luminance locally on the per-pixel minimum of the stack: `frame ≈ a · minimum + b`.
   - Glare is additive, so it lands in the offset `b`.
   - A shadow (the phone's own) is multiplicative and goes into the slope `a`, clamped to 1–1.8.
   - Score = `b ÷ paper + nearby clipped share`.
3. **Weights.** `prior · coverage · exp(−score / 0.04)`, smoothed and normalized.
   - The prior prefers the reference ×2.
   - It also scales each frame by `sharpness^4`. Sharpness is edge steepness Σ|∇|²/Σ|∇| relative to the reference, so a shot blurred by movement only fills in where it must.
   - Where all frames are clean, the result is mostly the reference with some denoising (about 39% less noise with three frames).
   - Where the reference has glare, it comes from the others. Where every frame has glare, it comes from the least glary one, and the region is reported in `residualMap`.
4. **Blend.** Weighted sum at full size, in linear light. Each aligned page is rendered once to 8-bit first, so the blend never reads several 12 MP photos at once. Then `PageCleanup.clean` runs unchanged.

### Results (synthetic, cleaned in document mode, against a glare-free photo of the same view)

| Method | Page RMSE | Glare-zone RMSE | Glare lines read |
| --- | --- | --- | --- |
| One photo (today) | 16.3 | 34.7 | 5/12 |
| One photo + whiteboard glare heuristic | 13.9 | 29.8 | 5/12 |
| Stack mean | 14.2 | 26.5 | 12/12 |
| Stack median | 6.3 | 13.1 | 12/12 |
| Stack minimum | **4.27** | **7.11** | 12/12 |
| GlareFusion, quads only (no refinement) | 32.1 | 60.4 | 1/12 |
| **GlareFusion** | 4.29 | 8.13 | 12/12 |
| GlareFusion, two shots only | 5.50 | 10.8 | 12/12 |
| *Phone shadow in shot 2:* minimum / GlareFusion | 4.46 / 4.73 | 7.62 / 8.50 | 12/12 both |
| *Shot 2 motion-blurred (σ 2.2 px):* minimum / median / GlareFusion | 7.91 / 15.0 / **7.21** | 15.3 / 29.5 / **14.1** | 12/12 all |

The existing single-image heuristic can't recover clipped glare, because the information isn't in the photo. Any multi-view method beats it.

**Mean and median are out.** Mean only dilutes the glare. Median fails as soon as two frames share a highlight, and it needs at least three frames.

**Plain per-pixel minimum is a strong baseline** once frames are aligned and exposure-matched. On sharp, clean synthetic frames it slightly beats GlareFusion.

**GlareFusion is still the recommendation**, because it degrades better:

- Minimum is biased dark by noise and darkens or thickens strokes wherever alignment is off.
- GlareFusion's priors keep a blurred or misaligned frame out of regions that don't need it. It wins on the motion-blur case, which is the realistic failure in a "move, then shoot" flow.
- It works with two frames.
- It reports where glare remains, which drives the UX.

Keep minimum as a one-line A/B option for device testing.

**Super-resolution:** not worth it. 2400 px across a letter page is about 280 dpi, already above what Vision needs. Each still is already a multi-frame ISP fusion, and real paper won't register to the sub-pixel accuracy SR needs.

**Known weakness:** a phone shadow over *blank* paper. With no ink nearby, the slope can't be measured, so an additive excess and a multiplicative deficit look the same. The shadowed frame then wins there, and a faint smudge survives cleanup (crop below). The fix for three or more frames: when the other frames agree within about 3% and one frame is darker, treat that one as shadowed.

![Faint residue of the phone's shadow in blank paper](glare-fusion/phone-shadow-residue.jpg)

## 4. UX

**Fast path stays fast.** `GlareMap.estimate` runs on the preview frame we already analyse:

- It warps the page to 96 px.
- A pixel counts as glare if it is near-clipped or at least 1.3× the page's 75th-percentile luminance.
- The cell grid is 6 × 8.

The decision is ready before the shutter fires. On a matte page it found no glare in any shot, so nothing changes: one still, today's timing.

**When there is glare** (debounced: glary in 3 of the last 5 analysed frames):

1. Take the reference still as now: auto-capture on steady, or the shutter.
2. `GlareCoverage(first:)` records the glary cells. `suggestedMove` picks the page edge nearest them, and `PageDirection.onScreen(for: quad)` turns that into a screen direction.
3. The hint pill changes, in the companion's italic voice: *"A little shine on the page — ease the phone left"*. Variants are *right*, *up* and *toward you*.
   - The hint is announced once to VoiceOver, with one soft haptic.
   - Over the glary cells, a soft fern-tinted veil fades as each cell is seen clean in the live frames. Nothing flashes, and the hint never changes while the user is mid-move.
4. When the live map shows every pending cell clean and the page has been steady for 0.3 s, take the next still. Use a short stability window and the same auto-capture state machine.
5. Stop when coverage is complete (usually one extra shot), or after 3 stills, 2.5 s after the first, a shutter tap ("done") or the page being lost for 1 s.
6. Fuse on the processing queue. If coverage didn't complete, fuse what there is and say nothing. On any `FusionError`, keep the reference through today's single-photo path.
7. If the hint was shown, finish with *"That's it — shine's gone."*, then the usual "Got page N".

**Setting:** *Reduce glare with a second look*, `RescrivaPreference` key `multiFrameGlare` (Bool, default on). The Settings row belongs to the session that owns `SettingsView`.

**Budget:** the extra shot takes about 1 s of user movement plus 0.3 s steady. Fusion is about 0.25 s on this Mac and should be well under 1 s on an A15. That's inside the 2 s aim once the user has moved.

## 5. Cost

Measured on this Mac (Apple M5, `-O`), from HEIC stills through decode, fuse, render and cleanup:

| | One photo (today) | Fused: 1 frame | 2 frames | 3 frames |
| --- | --- | --- | --- | --- |
| Time | 0.05 s | 0.10 s | 0.18 s | 0.25–0.33 s |
| Peak memory footprint (includes Core Image's GPU buffers) | 0.47 GB | 0.63 GB | 0.89 GB | 0.98 GB |

- **Timing breakdown:** registration is about 30–40 ms per extra frame. The analysis maths runs on Accelerate (vDSP/vForce), so the unoptimized build fuses three frames in 0.75 s rather than the 5.7 s the first plain-Swift loops took.
- **Memory, the number to watch:**
  - Registration accounts for about 0.3 GB of the three-frame figure (0.69 GB with refinement off).
  - Autorelease pools and `clearCaches()` didn't lower the peak. It is Core Image's working set for decoding 12 MP stills.
  - Mitigations: default to one extra shot (two frames); register from the 8-bit page images rather than the photos; measure the jetsam headroom on a 4 GB A15 phone.
- **Thermal:** one or two extra stills and well under a second of compute per glary page is negligible next to the running camera. The live check is a 96 px render per analysed frame.

## Implementation plan

1. **Done:** `GlareFusion.swift` (fusion core, `GlareMap`, `GlareCoverage`, `PageDirection`, `Homography`) and the macOS harness `Tools/GlareFusionHarness/run.sh`. It has 45 checks and writes the PNGs behind this note.
2. **Device baseline, Debug only:** log the preview-buffer size, `isZeroShutterLagSupported` and `isResponsiveCaptureSupported`, and still processing times. Collect a fixture set in the app container (never the photo library): glossy magazine, laminated card, receipt, whiteboard by a window, book spread. Time `fuse` and record peak memory on an A15 and an A18.
3. **Done: live check** in `CapturePipeline.captureOutput`: after detection, the frame is reduced once to 480 px and `GlareMap.estimate` runs on it; `GlareDebouncer` (3 of the last 5 analysed frames) sets `DetectionUpdate.showsGlare`, published as `CaptureCamera.showsGlare`.
4. **Done: capture sequence** in `CaptureCamera.capturePage()`:
   - If the live view was glary at the shutter, coverage starts from the still's own map (or the live map when Smart HDR toned the still's highlight below the check). `secondLook` holds the on-screen direction while the call waits.
   - `SecondLookTrigger` runs on the video queue: it fires once the page has moved at least 4% from the last still and settled 0.3 s where every pending cell is clean (0.9 s if only some are), and reports a page lost for 1 s.
   - Stops after 2 extra stills, full coverage, a shutter tap (`finishSecondLook()`), a lost page, or **6 s** (2.5 s left no time to read the hint and move). Ending a look re-disarms auto-capture on the page in view, so the slide doesn't trigger a duplicate shot.
   - Not done: `isResponsiveCaptureEnabled`.
5. **Done: processing:** `captureStill` decodes, detects (or maps the preview quad) and measures glare; `processPage` fuses (render once, then `PageCleanup.clean`) or takes the single-photo path on a `FusionError`. The camera sets `keepsUnrefinedFrames = false`, so a follow-up that registration can't match (another page, a bad shot) is dropped rather than placed by its quad alone, which ghosts. The first still stays the original and sets the crop, so re-making the page later (new crop or mode) starts from it alone and the glare comes back; rotating keeps the fused page.
6. **Done, without the veil: UI** in `CaptureView`: "Some shine on the page — I'll take a second look" before the shot, then "A little shine on the page — ease the phone left / right / away from you / toward you" ("up" read as lifting the phone), one soft haptic and a VoiceOver announcement, a flash per extra still, the shutter as "keep it as is", and "That's it — shine's gone." Settings › Reduce glare (`multiFrameGlare`, default on). The fading veil over the glary cells is still to do.
7. **Tests:** `GlareCaptureTests` covers the debouncer and the trigger; the harness checks the camera's options keep every registered shot and drop a mismatched page. Still to do: the real-photo fixtures from step 2.
8. **Tune on device** against the fixtures:
   - `clipLevel` and `sheenRatio`: Smart HDR may tone-map glare below the clip level.
   - `glareScale`, the slide distance and the timeout.
   - An A/B of GlareFusion against plain minimum.
9. **Follow-ups:**
   - The shadow-consensus rule.
   - Tile-wise registration for curled pages and book spreads.
   - The same fusion for whiteboards (window glare) and for several imported photos of one page.

## Still to test on a device

Everything that touches the camera:

- The preview-buffer size under `.photo` and how fast `GlareMap.estimate` runs on it.
- Shot-to-shot timing with zero shutter lag and responsive capture.
- Whether Smart HDR clips real speculars, which sets the thresholds.
- Real glare shapes (streaks, partial sheen) and real paper curl.
- Lens distortion; the wide camera's correction is assumed.
- Peak memory against the jetsam limit on 4 GB phones.
- Whether people slide rather than tilt when asked.

The Simulator has no camera, and the harness's photos are synthetic: a flat page, a round highlight and no ISP.
