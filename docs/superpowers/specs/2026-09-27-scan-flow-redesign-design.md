# iOS scan flow redesign

Date: 2026-09-27. Scope: `ios/` only. No portal or database changes.

## What was asked

- Scanning is the worst part of the app: hovering over one sheet saves it several times.
- Two modes: **Single** (scan one) and **Batch** (fly through a stack, tap Done, then review each result one by one: approve or rescan).
- Tapping a test shows its stats.
- No Students tab on mobile, but a student can still be assigned after scanning.
- Rethink how scanning works.

Decisions made while designing:

- Scores upload the moment a sheet is captured (as today). Review edits, rescans and discards sync immediately. Unsure scans still show in the portal's "Needs review" tab.
- Approach A: rebuild the capture logic as a small, pure, tested state machine and new screens on top. Keep `BoxFinder`, `Reader`, `Grader`, `NameReader`, `NameMatch` and the upload queue.
- The "frozen picture to mark the paper" goes away; the result card shows the marked sheet instead. No live red/green marks on the camera.

## Why it double-scans today

`AppStore.handle(.sheet)` decides "same sheet?" from (a) the full consensus answer string and (b) a 16×2 signature of the handwritten name. While hovering, a borderline bubble flips between "?" and a letter (changes the key), the name signature drifts with angle and light, and it is missing entirely when the name area is partly out of frame (`difference` returns 1). Any of these reads as a new sheet. Losing the sheet for ~30 frames (tilt, glare) also sets `sheetLeft`, so the same sheet is accepted again. Frames keep being processed while a sheet is "frozen", so nothing else stops it.

## Capture engine

### CaptureGate (pure, no UIKit/AVFoundation)

Fed one frame at a time on the scanner queue:

```swift
struct GateFrame { let time: TimeInterval; let sheet: SheetRead? }   // nil = no readable sheet (includes unknown test)
struct SheetRead { let corners: [CGPoint]; let identity: String; let period: Int?; let answers: String }
// identity = "\(quizId)|\(studentNumber ?? 0)"; answers use A–E, "-" blank, "*" two marks, "?" unclear
enum GateOutput { case idle, locking(Double), fire(period: Int?, answers: String), blank, waiting }
```

States: `armed`, `cooldown(captured)`, `paused`.

- **Steady run:** consecutive frames with the same identity whose corners each moved less than `steadyStep` since the previous frame and less than `steadyDrift` since the run started. Anything else restarts the run with the current frame.
- **armed:** output `locking(elapsed / lockDuration)` during a steady run. When the run lasts `lockDuration` and has at least `minReads` frames, take the consensus of its last `window` reads (per question: the value at least `agreement` of reads share, else "?"; period the same way, else nil).
  - No filled answer in the consensus → `blank`, stay armed.
  - Otherwise → `fire(consensus)`, go to `cooldown(consensus, identity)` (batch) or `paused` (single).
- **cooldown:** output `waiting`.
  - No sheet continuously for `clearDuration` → `armed`.
  - A sheet with a different identity → `armed`, starting a new run with this frame.
  - A steady run of the same identity reaching a consensus that differs from the captured one in at least `differentAnswers` questions where both have a letter → `fire` that consensus (a new sheet laid on top without a gap).
  - Otherwise stay (hovering, flicker, glare and short losses can't fire again).
- **paused:** ignores frames, outputs `waiting`, until `resume(rescan:)`. `rescan: true` → `armed` (captures the same sheet again). `rescan: false` → `cooldown` with the last capture.
- `reset()` → `armed` with empty history (camera start, mode change).

Constants (tunable, all in one place): `steadyStep = 0.01`, `steadyDrift = 0.03` (normalized image units), `lockDuration = 0.35 s`, `minReads = 6`, `window = 15`, `agreement = 0.6`, `clearDuration = 0.5 s`, `differentAnswers = 2`.

Known limit: two sheets with identical answers swapped with no gap at all capture once. A physical swap nearly always hides the sheet for over 0.5 s; if not, the tray count shows it and the sheet can be scanned again.

### Scanner changes

- Per frame: find the box → read the test code (keep the steady fallback) → read answers, period and printed student number → `gate.step` → emit a lightweight frame event (outline map, quiz, gate output) for the overlay. Stop building the name strip every frame.
- Timestamps come from the sample buffer's presentation time.
- On `fire`: build the name strip once from that video frame (fallback), start the photo, and emit `captured` right away (id, quiz, printed student number, period, answers, fallback strip) so the UI reacts instantly.
- Photo: largest supported size up to 4032 px wide (12 MP, not 48 MP), `.balanced`, shutter sound suppressed where allowed. From the photo read answers, period, the name strip at 200 ppi and the marked sheet JPEG (150 ppi). Emit `photo(id, answers?, period?, strip?, jpeg?)`. Photo answers win except where the photo says "?"; the photo period wins when present.
- Controls: `setMode(.single/.batch)`, `resume(rescan:)`, `reset()`, and `expect(quizId?)` for rescans (sheets of another test show "This sheet is for <title>" and never fire).

### Duplicate safety net (in the session, not the gate)

When a capture is finalized (after the photo and handwriting read):

- Same quiz and same assigned student as an item already in this batch → the new capture **replaces** that item in its slot; the old one is discarded (server delete, or removed from the pending queue). Note shown: "Replaced Maria's scan".
- No student match, but the handwriting read is similar (`NameMatch.similarity ≥ 0.8`) and every question where both have a letter agrees → same replacement.
- Otherwise it is a new item. If its answers are identical to another item and the reads are loosely similar (≥ 0.6), review flags it "Looks like the same sheet as #4".

The server's existing upsert on `(quiz_id, student_id)` still replaces across sessions.

## Screens

Tabs: **Scan** and **Tests**. The Students tab, `addStudent` and `removeStudent` are removed. The class list still loads for matching, named sheets and the student picker.

### Scan tab

- Opens straight to the camera. Top: flashlight and ⋯ menu (Reload tests, Retry uploads, Sign out). Bottom: Single / Batch switch, remembered in `UserDefaults`.
- Overlay: white outline of the found sheet, with a sage stroke that grows around it as it locks; a short flash on capture; sage outline and "Next sheet" while waiting; amber outline for a blank sheet.
- Status pill: "Point at a sheet" → "Hold steady" → "✓ 18/20 · Maria G." (name fills in when read) → "Next sheet". Also "Nothing filled in", "This sheet isn't one of your tests" (with Reload), "Camera access is off" (with Open Settings).
- Haptics: success on capture; warning once when an unknown test appears.
- Banner when uploads are waiting: "3 waiting to upload · Retry".

**Batch:** each capture adds a thumbnail to the tray and bumps the count; the camera stays live. Tapping a thumbnail opens that item's card (with Rescan and discard). **Done** opens review. An unfinished batch shows **Review 7** when the tab opens again, including after the app was closed.

**Single:** on capture the camera pauses and the result card slides up. **Rescan** → `resume(rescan: true)`. **Next sheet** → marks it reviewed, dismisses, `resume(rescan: false)`.

### Result card (shared by single mode, review and the test page)

Marked sheet photo (local file, or downloaded for older scans; placeholder while the photo is processing); score, percent and test title; student row with the handwriting picture, "Read as …" and the assigned student or an amber "Who is this?" that opens the picker; period chips 1–9; each unclear question as a row of letter bubbles plus blank; notes for "No clear photo — check this sheet on paper", "Looks like the same sheet as #4" and "Replaced …". Anything needing attention is amber.

Student picker: the existing `WhoSheet`, adapted: best handwriting matches first, period breaks near-ties, search, and "Not on the list" (clears the student, keeps the read name).

### Review (full screen from the Scan tab)

- One card at a time in scan order. Header "3 of 12" with a progress bar; close keeps progress; trash discards (with confirmation).
- **Approve** marks it reviewed and shows the next unreviewed card. **Rescan** opens the camera locked to that test in single mode; the capture replaces the item in its slot (discard old + add new) and returns to its card.
- After the last card: "12 saved · average 84%" with **Scan more** and **Done**. Both clear the batch.

### Tests tab

- Each row: title and "24 scanned · average 82%" (or "No scans yet"). `+` still creates a test. Pull to refresh.
- **Test page:** title and "20 questions · A–D · 1 pt each"; **Scan** switches to the Scan tab; tiles for average, median, scanned, and high · low; grade bars with Swift Charts (A ≥ 90%, B ≥ 80%, C ≥ 70%, D ≥ 60%, F below); average and count per period (no period last); hardest five questions with percent right and the most common wrong answer ("most chose B", "most left blank", "most marked two", "most unclear"), expandable to all; results grouped by period with name (or handwriting picture), score and an amber "Check" when there's no student, no period or an unclear answer. Tapping a result opens its result card (change student or period, settle answers, delete).
- Scores use `score_override` when set. Percent = score / max, where max excludes bonus questions (can exceed 100%). Local scans still waiting to upload are merged in by id.

## Data and sync

- Upload queue (`pending`, `send()`) stays as is and still handles edits and deletes made while a row is in flight.
- An item uploads when it is finalized (photo and name read done, usually within a second of capture).
- A local marked photo is deleted once it is uploaded and no longer shown in the session (the batch or the single-mode card), or when its item is discarded or replaced. Unreferenced photo files are pruned at launch.
- The batch persists as JSON in Application Support.
- New API calls: `scans(quizId)` (id, period, student_id, student_name, name_image, answers, score_override, scanned_at, photo_path); `scanSummaries()` (quiz_id, answers, score_override for all scans, for the tests list); `photo(path)` via `GET /storage/v1/object/authenticated/sheets/{path}`.

## Code structure

- `CaptureGate.swift`: the state machine and consensus (pure).
- `TestStats.swift`: stats math (pure).
- `BatchRules.swift`: replacement and possible-duplicate rules (pure).
- `ScanSession.swift`: `@MainActor` model owning the scanner, preview, mode, batch items, review position and persistence; talks to `AppStore` for tests, students and the upload queue.
- `AppStore.swift`: keeps auth, tests, students, the upload queue and `fix`/`remove`; loses `history`, `askWho`, `frozen`, the voting and dedupe fields, `handle`, `accept`, `undoLast`, `goLive` and the student add/remove calls.
- Views: `ScanScreen`, `ResultCard`, `ReviewScreen`, `StudentPicker`, `TestsView`, `TestDetailView`. `Tabs.swift` loses `StudentsView`.

## Error handling

- Camera denied → pill plus Open Settings.
- Unknown test → pill plus Reload; wrong test during a rescan → "This sheet is for <title>".
- Photo fails or can't find the sheet → keep the video reading, mark the item "No clear photo", flag it for review.
- Handwriting unreadable → no student, flagged.
- Offline or server error → queued with the retry banner (existing behavior).
- Test page load error → inline "Couldn't load scans" with pull to refresh.

## Testing

- New unit test target `GradeScanTests` (Swift Testing), run on the iPhone 17 Pro simulator with `xcodebuild test`.
- `CaptureGate`: hover jitter with "?" flicker over one sheet for 5 s → 1 fire; a 0.3 s loss mid-hover → 1 fire; removed for 0.6 s then a new sheet → 2 fires; new sheet with 2+ differing answers and no gap → 2 fires; identical answers with no gap → 1 fire (documents the limit); different printed student number with no gap → 2 fires; a moving sheet never fires; blank sheet → `blank`, no fire; single mode pause, `resume(rescan: true)` fires again on the same sheet, `resume(rescan: false)` waits for a clear; consensus majority and "?" on disagreement.
- `TestStats`: average and median (odd and even counts), overrides, bonus above 100%, grade buckets, periods with nil last, question stats including a `*` key and blank/two-marks/unclear labels.
- `BatchRules`: replace by student, replace by similar read with agreeing answers, no replace when answers disagree, possible-duplicate flag.
- A DEBUG-only `-demo` launch argument loads sample tests, scans and a batch without signing in, to check the review and stats screens in the simulator.
- On device: build with team M4FC8J36X8, install on the iPhone, scan a real stack in both modes.

## Out of scope

Portal and schema changes, bulk "approve all", editing answer keys on the phone, live marks on the camera.
