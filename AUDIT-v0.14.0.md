# Audit v0.14.0 (install monitor)

## What changed
- Before/after snapshot trace logs and clean-up from a log. See README for scope and limits.

## Safety checks
- Snapshots read names only. Nothing is changed while tracing except writing the snapshot/log files in the DIVoptimizer data folder.
- Clean-up goes through the same path as every other leftover: Test-LeftoverPathAllowed, protected names, the exclude list (re-checked at move time), review screen, quarantine with registry export, restore.
- Only items that still exist are listed. Services are never removed.
- Noise reduction: Microsoft/Classes/Policies registry keys, DIVoptimizer's own data, and temp folders are not tracked; children are collapsed into new parents so a move cannot hit a path that is already gone.
- Log deletion is limited to a folder directly inside the traces folder that holds a trace.json.

## Verified here (Linux PowerShell 7, temp folders and synthetic snapshots)
- All three scripts parse with 0 errors; shared restore core unchanged and identical.
- 28 new checks pass; earlier 59, 49, 20 and 19 still pass (175 total).

## NOT verified (needs Windows)
- Real registry and Program Files snapshots: how long they take and how big they are on your PC, and how much unrelated change shows up in a real install window.
- The page in WPF.
- Pester has still never been run. v0.11 to v0.14 are all untested on Windows.

## Known gaps
- Not real-time: changes outside the folders and keys it looks at (for example files written elsewhere, or deeper than two levels inside an existing folder) are not recorded.
- No Custom Uninstall editor, merge/export/import of logs, or a cloud log database.
- Per-user programs that install to unusual locations will be missed.
