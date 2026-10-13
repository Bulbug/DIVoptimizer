# Audit v0.11.0 (DIVuninstaller review screen, exclude list, forced by name)

Version rule: a feature release, but small and built on 0.10.0, so it is a minor step per the roadmap (0.11).

## What changed
- Review screen statuses (Created / Protected) plus a Parent shown as grey context.
- Exclude list (JSON, `*` and `?`), checked again at move time.
- Right-click: Open in Regedit, Open containing folder, Add to exclude list. Console: X, R, F.
- Options: check all, force-stop, only built-in (all off by default).
- Forced uninstall by name or folder, with lookup of installed programs and earlier records.

## Safety checks
- The exclude list cannot be bypassed: `Move-LeftoversToQuarantine` re-tests every item against the file, ignoring the item's own Status (tested with a forged "Created" item).
- Over-broad patterns (`*`, `C:\*`, `HKLM:\*`, very short) are refused.
- A hand-typed folder must sit strictly inside Program Files, ProgramData or AppData, and pass the existing protected-path gate.
- Partial names never match in the lookup (`Yeti` does not find `Yeti Tool`); wildcards only work when typed.
- Force-stop only touches processes whose executable is inside the program's own install folder, never this PowerShell process, and only when the option is on.
- Open in Regedit writes one viewer setting (`Applets\Regedit\LastKey`), nothing else. It is printed as a `PS>` line.

## Bugs found and fixed while planning this release
- App Paths leftovers were stored with the PowerShell provider path; `reg.exe` cannot export that form, so they would have been kept ("could not back up") instead of moved. Fixed in the scan and in `ConvertTo-RegExePath`.
- A forced stand-in with no uninstall key must not be backed up with an empty path or reported as still installed. Guarded.

## Verified here (Linux PowerShell 7, temp folders)
- All three scripts parse with 0 errors. Shared restore core identical in both scripts (`3a0caa9d689d`).
- 49 new checks pass, and the earlier 59 still pass (108 total).

## NOT verified (needs Windows)
- WPF layout of the review screen (bold, grey, red, right-click menus), the new Exclude List, Options and Forced by Name pages.
- Regedit actually opening at the key (if Regedit is already open it may only come to the front).
- `reg.exe` export of App Paths keys, force-stop on real processes, restore points.
- Pester has still never been run.

## Known gaps
- Grey context lines are the parent path of each item, not Revo's full registry tree.
- "Mark as created" and "Export all" from Revo are not included.
- Console review has no tree, only the numbered list.
