# GradeScan

Scan paper quizzes with an iPhone, grade them automatically, and move the scores into Jupiter. No ZipGrade.

- `supabase_setup.sql`: the database. Every row is locked to her account, and student names are encrypted in the browser before they're saved.
- `portal/index.html`: desktop portal for the roster, quizzes and answer keys, printable answer sheets, live results, CSV export, and filling Jupiter's import file.
- `ios/`: iPhone app (Xcode). It reads each sheet, draws a red X on wrong answers so she can cross them out, says the score, and uploads it.

## 1. Supabase (once, ~10 min)
1. Create a free project at supabase.com.
2. Go to SQL Editor › New query, paste `supabase_setup.sql`, and click Run.
3. Go to Authentication › Users › Add user, enter her email and password, and tick Auto confirm.
4. Go to Authentication › Sign In / Providers and turn off "Allow new users to sign up".
5. Go to Project Settings › API Keys and copy the Project URL and the publishable (or anon) key.

## 2. Portal (desktop)
1. At the top of the script in `portal/index.html`, paste the URL and key into `SUPABASE_URL` and `SUPABASE_KEY`.
2. Open the file in Chrome and sign in.
3. Choose a roster passphrase. It encrypts student names; write it down.
4. Roster: pick a period, paste the names exactly as Jupiter shows them (one per line), and click Add. Each student gets a 3-digit Student # (period + number). Print the Student # list for the class.
5. Quizzes: enter the title (same as in Jupiter), the number of questions (1–50), the choices (A–B through A–E), points per question, bonus, and the answer key. Click Create › Print sheet, then photocopy the sheet.

## 3. iPhone app
1. Open `ios/GradeScan.xcodeproj` in Xcode 16 or newer.
2. In `ios/GradeScan/Supabase.swift`, paste the same URL and key into `Config`.
3. Go to Target GradeScan › Signing & Capabilities, set Team to your Apple ID, and change the Bundle Identifier to something unique (for example, `com.yourname.gradescan`).
4. Plug in her iPhone, select it as the run destination, and press Run.
   - First time on the phone: turn on Developer Mode (Settings › Privacy & Security), then trust the developer (Settings › General › VPN & Device Management).
5. With a free Apple ID, the app stops opening after 7 days. Plug the phone in and press Run again.

## Grading a stack
1. Sign in on the phone. Add the roster passphrase if you want names shown instead of numbers.
2. Hold or mount the phone over a sheet so all four corner QR codes are in view. After a steady moment, the phone buzzes, says the score, and uploads it.
3. A red X marks the student's wrong answer, which she crosses out on paper. A green ring marks the right answer.
4. Put the next sheet on top. Results show up in the portal within a few seconds.

## Into Jupiter
In the portal, go to Results › Send to Jupiter:
1. In Jupiter, go to Setup › Import/Export › Export Assignments as Spreadsheet (this assignment, all classes).
2. Drop that file into the portal. It fills in the scores. Click Download filled file.
3. In Jupiter, go to Setup › Import/Export › Import Assignments from Spreadsheet, choose the file, review the changes, and save.

To get a plain list of scores instead, click Download CSV.

## Fixing things
- **Wrong answer key:** edit it on the Results page and click Save key & regrade. On the phone, tap ⋯ › Reload quizzes.
- **Unreadable Student #:** the scan is saved as `?XX`. Type the right number on the Results page.
- **Changing a score:** type the new score in the Override column.
- **Scanning a sheet again:** the new scan replaces that student's earlier scan.
- **Erasures read as answers:** raise `fillThreshold` in `Sheet.swift` (default 0.3).
- **Faint pencil marks missed:** lower `fillThreshold` in `Sheet.swift`.
- **Changing the sheet layout:** it's defined in two places, `L` in `portal/index.html` and `SheetLayout` in `Sheet.swift`. Change both together.

## Privacy
- Row-level security means only her login can read the data.
- Names are encrypted in the browser with her passphrase (AES-GCM), so Supabase stores only ciphertext.
- The phone keeps the derived key in the Keychain.
- Check the district's rules on storing student data in personal apps.
