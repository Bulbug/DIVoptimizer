# Audit v0.15.0 (custom uninstall editor)

## What changed
- Edit, merge, export and import of trace logs; hand-added items. See README.

## Safety checks
- One rule function (Get-TraceItemProblem) is used for typed, edited and imported items. Folders and files also pass Test-LeftoverPathAllowed.
- Editing writes only the log. Cleanup is unchanged: review screen, exclude list re-checked at move time, quarantine, restore.
- Every editor write goes through Test-TraceDirInside (a folder directly inside the traces folder with a trace.json). Export refuses to overwrite and requires .json. Import caps size (5 MB) and item count (20000) and creates a NEW log.
- Dry run writes nothing.

## Found and fixed while testing
- The standard Windows Run key was refused (Microsoft rule and protected leaf name), which would have rejected the most common startup entry the install monitor records. Exempted for startup values only.
- A drive root such as C:\ is now refused explicitly (it passed on Linux because of path handling).

## Verified here (Linux PowerShell 7, temp folders)
- All three scripts parse with 0 errors; shared restore core identical (3a0caa9d689d).
- 41 new checks pass. The earlier Linux check scripts were lost with the old work folder and were not re-run for this release.

## NOT verified (needs Windows)
- The WPF editor page, file dialogs, and real registry items. Pester has never been run. v0.11 to v0.15 are untested on Windows.

## Known gaps
- Imported logs are trusted only as far as the safety rules; the review screen is still the final check.
- No cloud log database.
