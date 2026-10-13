# Audit v0.12.0 (batch uninstall and Windows Apps)

## What changed
- Batch uninstall with one restore point and one combined leftover review; quarantine entries stay per program.
- Windows Apps list and guarded removal (current user by default, all users with Administrator).

## Safety checks
- The batch is validated as a whole before anything runs: any protected program or unreadable uninstall command stops it with the names listed.
- Each uninstaller is still the program's own; no silent switches are guessed. A failure in one does not stop the rest.
- Leftovers still use exact-name matching, the exclude list, and the protected-path gate; items from programs that are still installed are never scanned. Programs outside the batch count as "other programs" for protection.
- Windows Apps: removal goes through `Remove-AppPackageExact` (exact names, no wildcards, `Test-PackageProtected`), frameworks and non-removable packages are skipped, system-signed packages are not listed, and any protected app in a selection refuses the whole selection.
- Honest limit: Windows restore points do not reliably bring Store apps back. The UI says so.

## Verified here (Linux PowerShell 7, temp folders)
- All three scripts parse with 0 errors; shared restore core unchanged and identical.
- 20 new checks pass; the earlier 59 and 49 still pass (128 total).

## NOT verified (needs Windows)
- Multi-select list behavior and the new pages in WPF.
- Real uninstallers run in sequence, restore point creation, `Get-AppxPackage` / `Remove-AppxPackage` results, all-users removal.
- Pester has still never been run. v0.11 and v0.12 are both untested on Windows.

## Known gaps
- No silent uninstall, so a batch needs you present for each uninstaller window.
- Windows Apps has no "reset app", "terminate" or Store reset, and no leftover scan for apps.
