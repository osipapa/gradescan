# GradeScan

Scan paper tests with an iPhone, grade them automatically, and move the scores into Jupiter. No ZipGrade and no roster.

- `portal/index.html`: desktop portal. Create a test, print its answer sheet, see results by class, and send scores to Jupiter.
- `ios/`: iPhone app (Xcode). Pick the test and hold the phone over a sheet. It reads the bubbles and the handwritten name, marks wrong answers with a red X, shows the score, and uploads it.
- `supabase_setup.sql`: the database. Every row is locked to her account.

## 1. Supabase (once, ~10 min)
1. Create a free project at supabase.com.
2. Go to SQL Editor › New query, paste `supabase_setup.sql`, and click Run.
   - Set up before the roster was removed? Run `supabase_upgrade_v2.sql` instead. It keeps existing tests and scans.
3. Go to Authentication › Users › Add user, enter her email and password, and tick Auto confirm.
4. Go to Authentication › Sign In / Providers and turn off "Allow new users to sign up".
5. Go to Project Settings › API Keys and copy the Project URL and the publishable (or anon) key.

## 2. Portal (desktop)
The portal is live at **https://osipapa.github.io/gradescan/**. Every push to `main` that changes `portal/` redeploys it (`.github/workflows/pages.yml`). Only accounts added in step 1.3 can sign in.

1. At the top of the script in `portal/index.html`, paste the URL and key into `SUPABASE_URL` and `SUPABASE_KEY`.
2. Open the portal (or the file in Chrome) and sign in.
3. Click **New test**. Enter the name (same as in Jupiter), the number of questions (1–50), the answer choices, points per question, bonus questions, and the answer key.
4. Print the answer sheets (a 20-question sheet fits 4 to a page; cut along the gaps). Or choose **Copy image** and paste the answer box into your own test document.

## 3. iPhone app
1. Open `ios/GradeScan.xcodeproj` in Xcode 27 or newer.
2. In `ios/GradeScan/Supabase.swift`, paste the same URL and key into `Config`.
3. Go to Target GradeScan › Signing & Capabilities, set Team to your Apple ID, and change the Bundle Identifier to something unique (for example, `com.yourname.gradescan`).
4. Plug in her iPhone, select it as the run destination, and press Run.
   - First time on the phone: turn on Developer Mode (Settings › Privacy & Security), then trust the developer (Settings › General › VPN & Device Management).
5. With a free Apple ID, the app stops opening after 7 days. Plug the phone in and press Run again.

## The answer sheet
- **Named sheets (recommended):** on a test's page, **Print named sheets**. Each student gets a sheet with their name and period already on it, and the phone knows who it is without reading handwriting.
- **Blank sheets:** students write their name and fill in their period; the phone reads the handwriting and matches it to your Students list.
- The black squares let the phone find the box anywhere on a page. The small squares along the bottom say which test it is (and along the top, on named sheets, which student). Don't cover or cut them off.
- **Copy image** pastes the answer box into your own test document.

## Grading a stack
1. Open the app on the **Scan** tab and choose **Batch** or **Single** at the bottom. In Batch you can lay several sheets out and scan them all at once.
2. Hold the phone over a sheet. The outline fills in as it locks on; when it's steady it buzzes once and shows the score. A sheet is captured once: it won't capture again until that sheet is out of view or a different one is under the camera.
3. **Batch:** put the next sheets down; the tray counts them. Tap **Review** (or a thumbnail) and swipe through the sheets: **Next** when a sheet looks right, the trash can to delete a bad capture (instant; swipe back to undo), or **Rescan**. The **×** in the tray discards the whole batch.
4. **Single:** the result opens right away with **Rescan** or **Next sheet**.
5. On each sheet photo the phone draws a ✓ or ✗ by every number, so you can copy them onto the paper. Rows it couldn't call are outlined with an amber dot; tap **Right** or **Wrong** and the mark on the photo updates. **Undo** takes it back.
6. The name is matched to your class list even when the handwriting reads a little off ("roah Sim" is Noah Kim). A clear match is filled in; a likely one asks you to confirm with one tap.
7. If a student ends up with two scans for a test, nothing is replaced: both sheets show side by side with the differences outlined, and you keep one.
8. Scores upload as soon as each sheet is read. The portal shows the same photos, marks and decisions, and you can settle rows there too.

## Students and Settings on the phone
- **Students** tab: the class list by period (chips at the top), with each student's average. Tap a student to edit their name or period (saved as you type) and see every score and their weakest topics.
- **Import from Jupiter** (the **+** on the Students tab): point the camera at a class page in Jupiter. The names are read live, and once the list holds steady they're added to the period that's highlighted on the page (it asks when it can't tell). Open another class and it's added too; **Undo** takes an import back. A screenshot works as well.
- **Settings** tab: your account, and which mode scanning starts in. Tests reload and uploads retry on their own.
- **Delete all my data** (Settings › Testing) is for testing only and will be removed before release.

## ZipGrade sheets
The phone also reads ZipGrade's standard 20-question form (the free one from zipgrade.com), printed at any size.
- When ZipGrade sheets are under the camera, the phone asks which test they're for, every batch: **Choose test**, or **Scan answer key** to set up a new test from a sheet with every answer right (name it, check the key, done). The batch's ZipGrade sheets go to that test; tap **ZipGrade · test name** above the status to change it.
- It reads the handwritten name, period and date, and the bubbles with the same rules as ours. The date shows next to the score, so a make-up test is easy to spot. If the period on the sheet isn't the student's period on your class list, the scan is flagged.
- ZipGrade's Test Version bubbles aren't used; every sheet is graded with the test's one answer key.

## How the phone reads marks
It never guesses. Anything it can't call scores no credit and is highlighted on the sheet photo in review, where you tap the right answer or leave it.
- **One mark in a row is the answer:** a fill, scribble, check, loop, or a lone X.
- **A bubble with an X or slash through it doesn't count** when another bubble in the row is marked. If the crossed-out bubble is the only mark, it's flagged.
- **Erased pencil:** when one mark is much lighter than the other, the darker one is the answer. Similar darkness: rejected as two answers. In between: flagged.
- **X's on two or more bubbles, or two real marks:** rejected (two answers).
- **Faint marks, a circled bubble, or a lone crossed-out fill:** flagged.
- **Small stray marks next to a real answer** are ignored.

## Tests, students and insights
- **Tests:** create them in the portal or on the phone (Tests tab, +).
- **Students:** **Import from Jupiter** (the same export file you use for grades) so names match Jupiter exactly, or add and paste names yourself.
- **Topics:** on a test's page, pick or type a topic and click question numbers to tag them.
- **Insights:** the **Dashboard** shows topics by class period and the questions most students missed. A test's page lists each question's share right and the wrong answer most chose. Each student has a page with their scores and weakest topics.

## Into Jupiter
On the test page, go to **Export › Send to Jupiter**:
1. In Jupiter, go to Setup › Import/Export › Export Assignments as Spreadsheet (this assignment, all classes).
2. Drop that file into the portal. It matches the names it read to Jupiter's students; check any marked **Check** or **No match**. Click **Download filled file**.
3. In Jupiter, go to Setup › Import/Export › Import Assignments from Spreadsheet, choose the file, review the changes, and save.

To get a plain list of scores instead, choose **Export › Download CSV**.

## Fixing things
- **Wrong answer key:** edit it in the Answer key card on the test page and save. Scores update right away. On the phone, tap ⋯ › Reload tests.
- **Wrong or unknown student:** pick the right one in the results table (portal) or under Scans (phone).
- **No period marked:** set it in the Needs review tab.
- **Changing a score:** type the new score in the Override column.
- **Same sheet scanned twice:** the phone saves a sheet once until it leaves the camera. If a duplicate appears, tap Undo or delete it in the portal.
- **Erasures or stray marks read as answers:** raise `markLevel` in `Sheet.swift` (default 0.2, the share of a bubble's inside that must be ink).
- **Light marks missed:** lower `markLevel` in `Sheet.swift`. X's, checks, slashes and circles inside a bubble count as marks, not only solid fills.
- **Changing the sheet design:** edit `sheetLayout` and `sheetSvg` in `portal/index.html`. Each test saves its layout and the phone reads sheets from it, so tests you already printed keep working.

## iOS 27
- Liquid Glass controls on iOS 26 and later. The app still runs on iOS 17.
- On cameras that support iOS 27 exposure signals, auto exposure is tuned for printed paper, classroom light flicker, and moving sheets.
- Scanning drops to 15 frames a second while the phone is hot, the battery is strained, or iOS asks apps to use less power.
- Debug builds are compiled with optimization because the sheet finder runs on every camera frame.

## Privacy
- Row-level security means only her login can read the data.
- Student names, a small picture of each handwritten name, and a marked-up picture of each sheet are stored in your Supabase project. Handwriting is read on the phone; nothing goes to other services.
- Check the district's rules on storing student data in personal apps.
