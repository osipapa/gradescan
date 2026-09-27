# Scan flow redesign implementation plan

> For agentic workers: executed natively (superpowers:executing-plans). Spec: docs/superpowers/specs/2026-09-27-scan-flow-redesign-design.md

**Goal:** One capture per sheet, Single/Batch modes with a review queue, test stats on the Tests tab, no Students tab.
**Architecture:** Pure `CaptureGate` on the scanner queue decides when to capture; `ScanSession` (@MainActor) owns the camera, batch, and review; `AppStore` keeps auth, tests, students, and the upload queue. Pure `TestStats` and `BatchRules` feed the views.
**Tech:** SwiftUI, AVFoundation, Vision, Swift Charts, Swift Testing, iOS 17+.

## Global constraints
- iOS 17.0 minimum; Xcode 27; no new dependencies; no portal or schema changes.
- Gate constants: steadyStep 0.01, steadyDrift 0.03, lockDuration 0.35 s, minReads 6, window 15, agreement 0.6, clearDuration 0.5 s, differentAnswers 2.
- Grades: A ≥ 90%, B ≥ 80%, C ≥ 70%, D ≥ 60%, F below. Max excludes bonus questions.

## Review focus
1. Phone lifted and returned to the same sheet after more than 0.5 s: the session replaces the item for the same student instead of adding one (BatchRules test).
2. Name area partly out of frame: the photo strip is used; a missing strip never counts as a different sheet (the gate ignores names entirely).
3. Borderline bubble flickering "?" while hovering: no second capture (gate test).
4. Rescan while the original is still uploading: the old row is deleted after its insert lands (existing `deleted` set), and the new one takes its slot.
5. Test with zero scans or all-bonus max 0: stats show empty states, no division by zero (stats test).

## Tasks
- [ ] 1. Test target `GradeScanTests` (Swift Testing) + `CaptureGate` with tests.
- [ ] 2. `TestStats` with tests.
- [ ] 3. `BatchRules` with tests.
- [ ] 4. Scanner: gate integration, capture/photo events, 12 MP photos, name strip from the photo, mode/resume/expect controls; overlay with lock progress.
- [ ] 5. `ScanSession` + `ScanItem`: captures → items, finalize (OCR, match, replace), upload via AppStore, persistence, review state.
- [ ] 6. AppStore slim-down; API additions (scans per test, summaries, photo download).
- [ ] 7. Views: ScanScreen (modes, pill, tray), ResultCard, StudentPicker, ReviewScreen, rescan camera.
- [ ] 8. Views: TestsView rows with averages, TestDetailView with stats and results; tabs Scan + Tests.
- [ ] 9. DEBUG `-demo` data; simulator screenshots; build and install on the iPhone.
