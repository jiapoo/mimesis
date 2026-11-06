# Mimesis roadmap

Compare two sports videos (tennis, soccer, swimming…) side by side or overlaid, on macOS, iPadOS and iOS.
Kinovea's analysis tools plus Dartfish's SimulCam, made natively for Apple devices.

Each step starts as ⬜. When it's done, it becomes ✅ with the date: `- ✅ Step (2026-11-06)`.

---

## Phase 0 — Setup and the riskiest test first

- ✅ Git: `git init`, first commit, push to `github.com/jiapoo/mimesis` (2026-11-06)
- ✅ Project laid out like Imago: XcodeGen `project.yml`, `Mac/` and `iOS/` targets, a `Packages/MimesisKit`
      package for shared code, and `AreteMedia` pinned at a version (currently 1.8.0) (2026-11-06)
- ✅ Empty app builds and runs on Mac, iPad and iPhone (simulators; not yet on a real device) (2026-11-06)
- ✅ **Masking test:** run Apple's person mask (`VNGeneratePersonInstanceMaskRequest`) and its lift-subject
      mask (`VNGenerateForegroundInstanceMaskRequest`) over tennis clips.
      Record whether the racket survives, mid-swing too, and how long a clip takes to process.
      The answer decides how Phase 4 is built. (2026-11-06; findings below)
- ⬜ Repeat the masking test on a TV clip of Alcaraz: several people in frame (opponent, umpire, ball kids),
      a far camera, and the score and logos drawn over the picture

### Masking test findings (2026-11-06)

Run with the app's masking test screen, or from the command line:
`cd Packages/MimesisKit && swift run -c release mask-probe <video> --start 3 --seconds 2 --out <folder>`
(writes `sheet.png`: frame | person mask | lift subject).

Tested on two phone-filmed clips (1080×1920): a slice serve at 60 fps and a backhand slice at 30 fps, on an M-series Mac.

| | Person mask | Lift subject |
|---|---|---|
| Racket | Faint or missing, often only a ghost | Kept, at the top of the serve too; sometimes partly lost in a fast blur |
| Shadow | Sometimes cut out with the player | Left out |
| Edges | Soft and blurry | Sharp |
| Speed (Mac) | 22–65 ms a frame | 15–16 ms a frame |
| Missed frames | 2 of 179 | 3 of 179 |

**Decision: build Phase 4 on lift subject** (`VNGenerateForegroundInstanceMaskRequest`).
Both methods also keep text and stickers drawn over the video (titles, a red ✗), so clips with overlays
will need the "tap to choose" step, or cropping the overlay out.

## Phase 1 — The comparison core (the Kinovea part)

- ✅ Design: dark studio canvas, the icon's crimson as the one accent, clip A and clip B as rounded cards
      with controls floating over the video, and one transport panel at the bottom using Arete's two
      timelines (progress bar + frame ruler, AreteMedia's `FrameRulerTimeline`) (2026-11-06)
- ⬜ Open two clips as A and B: file picker (built), drag and drop (built), Photos (built);
      only tested by opening clips at launch so far
- ✅ Show only one clip, or both (A | B, A, B); side by side in landscape, one above the other in portrait (2026-11-06)
- ✅ **Independent** playback: the transport plays, scrubs and frame-steps the selected clip (2026-11-06)
- ✅ **Linked** playback: one play button and one ruler; a frame step or a drag moves both (2026-11-06)
- ✅ Trim each clip: In / Out at the playhead, shown on the ruler (2026-11-06)
- ✅ A sync point in each clip (e.g. the moment of contact); linking lines up the two sync points (2026-11-06)
- ✅ A speed for each clip (e.g. 0.5× and 1.0×) that still plays in step when linked (2026-11-06)
- ✅ Mirror each clip on its own (from AreteMedia) (2026-11-06)
- ✅ Zoom each clip on its own: pinch, then drag to pan; double-tap or the fit button to reset (2026-11-06)
- ✅ Swipe sideways on a video to move frame by frame (both clips while linked) (2026-11-06)
- ⬜ Keys on Mac: Movist's keys for the selected clip, Space / , . / ← → for both when linked, [ ] S L Tab,
      ⌘S save, ⇧⌘O saved comparisons (built, not yet tested)
- ✅ Save a comparison by name (both clips, trims, sync points, speeds, mirroring) and reopen it from
      Saved comparisons; the last comparison comes back by itself at the next launch (2026-11-06)

## Phase 2 — Drawing and measuring

- ✅ Drawing mode (the pencil on each clip): lines, arrows and circles in four colours; drag a point to move it;
      undo and clear. Drawings follow zoom, pan and mirroring (2026-11-06; line tested, arrow and circle built)
- ✅ Angle tool (shoulder, elbow, knee, racket face): drag from the vertex along one arm, then move either arm;
      shows the angle in degrees (2026-11-06)
- ✅ Drawings stay on their frame, or on every frame ("This frame" / "Every frame") (2026-11-06; "This frame" tested)
- ✅ Drawings are saved with the comparison (2026-11-06)
- ⬜ Marks on the timeline where a clip has drawings, to jump to them
- ⬜ Apple Pencil on iPad (drawing uses ordinary touch, so it should work; needs a real iPad to check)

## Phase 3 — Multi-point time matching (what sets Mimesis apart)

- ⬜ Several marks in each clip (start of backswing, racket drop, contact, finish)
- ⬜ Each section between marks is sped up or slowed separately, so every phase lines up
      (`AVMutableComposition` with `scaleTimeRange`)
- ⬜ Show each section's speed, and let it be adjusted by hand

## Phase 4 — Overlay your idol on your clip (SimulCam)

The goal: Alcaraz, cut out of a TV clip, laid over your own clip so you can see where your body differs
from his, frame by frame. The court, camera angle and distance can all differ between the two clips.
The five steps below build it.

### 4.1 Cut Alcaraz out of his video

- ⬜ Cut out the player in each frame with `VNGenerateForegroundInstanceMaskRequest` (lift subject),
      which kept the racket far better in Phase 0
- ⬜ Tap Alcaraz to choose him when the opponent, umpire or ball kids are also in frame;
      follow him from frame to frame
- ⬜ Process the clip once, with a progress bar, and save the cutout (video with a transparent background),
      so playback and frame-stepping stay smooth
- ⬜ Soften the cutout's edge so it doesn't flicker
- ⬜ Fallback if the racket gets cut off: a soft-edged box around him instead of an exact cutout

### 4.2 Mirror him

- ⬜ Mirror the cutout side to side (reuses AreteMedia's mirroring), so a right-hander matches a left-hander
- ⬜ Mirror only how it's shown, never the saved cutout

### 4.3 Lay him semi-transparent over your clip

- ⬜ Draw the cutout on top of your clip, with an opacity slider (0–100%)
- ⬜ Optional: tint him one colour (e.g. red) so his body is easy to tell from yours
- ⬜ Switch between overlay and side by side with one key or tap
- ⬜ Plain overlay without a cutout too (the whole clip semi-transparent), useful when both clips
      were filmed at the same place

### 4.4 Drag and resize him until his feet and hips sit on yours

- ⬜ Drag to move, pinch or scroll to resize; rotate slightly if the cameras were tilted
- ⬜ Auto-align: find hips, knees and ankles in both clips with `VNDetectHumanBodyPoseRequest`,
      then move and resize him so his hips and feet land on yours; you nudge from there
- ⬜ Keep the position and size for the whole clip, saved with the comparison
- ⬜ Automatic background alignment for clips filmed at the same place (`VNHomographicImageRegistrationRequest`)

### 4.5 Keep it in time using the sync points

- ⬜ The overlay plays linked: the two sync points (e.g. contact) line up, using each clip's trim and speed
- ⬜ Frame-stepping moves both clips together in the overlay
- ⬜ Use the Phase 3 section speeds, so every phase of the stroke lines up, not only contact
- ⬜ Export the overlay as a video to share

## Phase 5 — At the court (iPad and iPhone)

- ⬜ Delayed playback: the camera records and shows you N seconds later
- ⬜ Record a clip from that and drop it straight into a comparison
- ⬜ Remind to film at 240 fps (slow-mo) or at least 60 fps

## Phase 6 — StroMotion

- ⬜ One image of a whole motion: the athlete in several positions in one frame (reuses the Phase 4 cutout)
- ⬜ Choose how many positions and which span
- ⬜ Export it as an image to share

## Phase 7 — Library and tagging

- ⬜ A library of clips with names and notes
- ⬜ Tag moments ("forehand", "double fault", "good contact")
- ⬜ Search by tag across all clips and play the results back to back
- ⬜ Sync the library across devices (iCloud)

## Phase 8 — Release

- ⬜ Export a comparison as a video (side by side or overlaid, drawings included)
- ⬜ Check "Mimesis" in the App Store and the USPTO software classes (9 and 42); choose the store name
      (e.g. "Mimesis: Motion Compare") while the icon says "Mimesis"
- ⬜ Icon, screenshots, privacy details
- ⬜ Price: free or very cheap
- ⬜ TestFlight, then App Store (Mac, iPad, iPhone)
