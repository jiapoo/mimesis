# Mimesis roadmap

Compare two sports videos (tennis, soccer, swimming…) side by side or overlaid, on macOS, iPadOS and iOS.
Kinovea's analysis tools plus Dartfish's SimulCam, made natively for Apple devices.

When a step is done, tick its box and add the date: `- [x] Step (2026-11-06)`.

---

## Phase 0 — Setup and the riskiest test first

- [ ] Git: `git init`, first commit, push to `github.com/jiapoo/mimesis`
- [ ] Project laid out like Imago: XcodeGen `project.yml`, `Mac/` and `iOS/` targets, a `Packages/MimesisKit`
      package for shared code, and `AreteMedia` pinned at a version (currently 1.8.0)
- [ ] Empty app builds and runs on Mac, iPad and iPhone
- [ ] **Masking test:** run Apple's person mask (`VNGeneratePersonInstanceMaskRequest`) and its lift-subject
      mask (`VNGenerateForegroundInstanceMaskRequest`) over a few Alcaraz forehands and serves.
      Record whether the racket survives, mid-swing too, and how long a clip takes to process.
      The answer decides how Phase 4 is built.

## Phase 1 — The comparison core (the Kinovea part)

- [ ] Open two clips into a left pane and a right pane (file picker, drag and drop, Photos on iOS)
- [ ] Show only one pane full-width, or both
- [ ] **Independent** playback: each pane has its own play, scrub and frame-step
- [ ] **Linked** playback: one play button, one scrubber; a frame step moves both
- [ ] Trim each clip
- [ ] A sync point in each clip (e.g. the moment of contact); linking lines up the two sync points
- [ ] A speed for each clip (e.g. 0.8× and 1.0×) that still plays in step when linked
- [ ] Mirror each clip on its own (from AreteMedia)
- [ ] Zoom and pan each clip on its own
- [ ] Keys on Mac (AreteMedia's `MovistKeys`) and touch on iOS: swipe to frame-step, pinch to zoom
- [ ] Save a comparison (the two clips, trims, sync points, speeds, mirrors) and reopen it later

## Phase 2 — Drawing and measuring

- [ ] Lines, arrows and circles on a frame
- [ ] Angle tool (shoulder, elbow, knee, racket face)
- [ ] Drawings stay on their frame, or for a span of frames
- [ ] Apple Pencil on iPad

## Phase 3 — Multi-point time matching (what sets Mimesis apart)

- [ ] Several marks in each clip (start of backswing, racket drop, contact, finish)
- [ ] Each section between marks is sped up or slowed separately, so every phase lines up
      (`AVMutableComposition` with `scaleTimeRange`)
- [ ] Show each section's speed, and let it be adjusted by hand

## Phase 4 — Overlay your idol on your clip (SimulCam)

The goal: Alcaraz, cut out of a TV clip, laid over your own clip so you can see where your body differs
from his, frame by frame. The court, camera angle and distance can all differ between the two clips.
The five steps below build it.

### 4.1 Cut Alcaraz out of his video

- [ ] Cut out every person in each frame with `VNGeneratePersonInstanceMaskRequest`, or with
      `VNGenerateForegroundInstanceMaskRequest` if Phase 0 showed it keeps the racket better
- [ ] Tap Alcaraz to choose him when the opponent, umpire or ball kids are also in frame;
      follow him from frame to frame
- [ ] Process the clip once, with a progress bar, and save the cutout (video with a transparent background),
      so playback and frame-stepping stay smooth
- [ ] Soften the cutout's edge so it doesn't flicker
- [ ] Fallback if the racket gets cut off: a soft-edged box around him instead of an exact cutout

### 4.2 Mirror him

- [ ] Mirror the cutout side to side (reuses AreteMedia's mirroring), so a right-hander matches a left-hander
- [ ] Mirror only how it's shown, never the saved cutout

### 4.3 Lay him semi-transparent over your clip

- [ ] Draw the cutout on top of your clip, with an opacity slider (0–100%)
- [ ] Optional: tint him one colour (e.g. red) so his body is easy to tell from yours
- [ ] Switch between overlay and side by side with one key or tap
- [ ] Plain overlay without a cutout too (the whole clip semi-transparent), useful when both clips
      were filmed at the same place

### 4.4 Drag and resize him until his feet and hips sit on yours

- [ ] Drag to move, pinch or scroll to resize; rotate slightly if the cameras were tilted
- [ ] Auto-align: find hips, knees and ankles in both clips with `VNDetectHumanBodyPoseRequest`,
      then move and resize him so his hips and feet land on yours; you nudge from there
- [ ] Keep the position and size for the whole clip, saved with the comparison
- [ ] Automatic background alignment for clips filmed at the same place (`VNHomographicImageRegistrationRequest`)

### 4.5 Keep it in time using the sync points

- [ ] The overlay plays linked: the two sync points (e.g. contact) line up, using each clip's trim and speed
- [ ] Frame-stepping moves both clips together in the overlay
- [ ] Use the Phase 3 section speeds, so every phase of the stroke lines up, not only contact
- [ ] Export the overlay as a video to share

## Phase 5 — At the court (iPad and iPhone)

- [ ] Delayed playback: the camera records and shows you N seconds later
- [ ] Record a clip from that and drop it straight into a comparison
- [ ] Remind to film at 240 fps (slow-mo) or at least 60 fps

## Phase 6 — StroMotion

- [ ] One image of a whole motion: the athlete in several positions in one frame (reuses the Phase 4 cutout)
- [ ] Choose how many positions and which span
- [ ] Export it as an image to share

## Phase 7 — Library and tagging

- [ ] A library of clips with names and notes
- [ ] Tag moments ("forehand", "double fault", "good contact")
- [ ] Search by tag across all clips and play the results back to back
- [ ] Sync the library across devices (iCloud)

## Phase 8 — Release

- [ ] Export a comparison as a video (side by side or overlaid, drawings included)
- [ ] Check "Mimesis" in the App Store and the USPTO software classes (9 and 42); choose the store name
      (e.g. "Mimesis: Motion Compare") while the icon says "Mimesis"
- [ ] Icon, screenshots, privacy details
- [ ] Price: free or very cheap
- [ ] TestFlight, then App Store (Mac, iPad, iPhone)
