# DIVoptimizer v0.8.0 - Test matrix

**Status: NOT YET RUN.** No part of DIVoptimizer has been executed on Windows. Checks done so far: the real PowerShell parser (0 errors, PowerShell 7.4.6 on Linux), a dot-source smoke test of the pure functions on Linux, ASCII-only source, and identical shared restore core. Nothing that touches the Windows registry, services, tasks or the GUI has run. Mark each row when you run it.

| # | Environment | Run | Expected | Result |
|---|---|---|---|---|
| 1 | Windows 10 22H2 desktop, Administrator | GUI, Scan, WhatIf, apply, Undo | no errors, backup verifies | not run |
| 2 | Windows 11 23H2/24H2 desktop | same | same | not run |
| 3 | Windows 11 laptop on battery | Recommendations | no power-plan/hibernation pre-selected | not run |
| 4 | Tablet / touchscreen | Recommendations | touch-related items blocked | not run |
| 5 | 8 GB RAM PC | Recommendations | memory-aware advice | not run |
| 6 | 32 GB RAM PC | Recommendations | no memory-pressure advice | not run |
| 7 | Non-admin user | -Scan, -WhatIf, -Health | work without UAC | not run |
| 8 | Non-admin user | normal start | UAC relaunch, mode preserved | not run |
| 9 | `irm \| iex` remote run | start, finish | session left clean | not run |
| 10 | Windows already tuned with WinUtil | Recommendations | conflicts shown, not pre-selected | not run |
| 11 | System Restore disabled | apply | warning, backup still created | not run |
| 12 | Corrupted backup file | Restore / -Undo | refused, next valid backup offered by -Undo | not run |
| 13 | Old v0.6/v0.7 backups present | Restore | legacy rules, ambiguous items skipped | not run |

## WinUtil order matrix

| Order | Expected | Result |
|---|---|---|
| WinUtil first, then DIVoptimizer | already-set values reported as conflicts, nothing overwritten silently | not run |
| DIVoptimizer first, then WinUtil | DIVoptimizer backup still restores its own changes | not run |

Also run: `Invoke-Pester .\tests\DIVoptimizer.Tests.ps1` (Pester 5) and record the result here.

## DIVuninstaller (v0.9.0 and v0.10.0)

| # | Run | Expected | Result |
|---|---|---|---|
| U1 | Uninstall a small non-MSI app (e.g. a portable-style installer) | its uninstaller runs, leftovers listed, nothing pre-selected | not run |
| U2 | Uninstall an MSI app | runs `msiexec.exe /x {GUID}` | not run |
| U3 | Select a protected program (Visual C++) | refused with a message | not run |
| U4 | Move a registry leftover to quarantine | `.reg` exported, key removed; Restore re-imports it | not run |
| U5 | Move a folder leftover, then Restore | folder returns, files intact | not run |
| U6 | Cancel the uninstaller window | "still installed", no leftover scan | not run |
| U7 | Quarantine > Delete permanently | asks, deletes only that entry | not run |
| U8 | Dry run (`-WhatIf`) | no uninstall or move happens | not run |

Run on Linux (temp folders): command parsing, protection rules, leftover scan, quarantine move/restore/delete guards - 38 checks passed.

| U9 | Uninstall with scan level Safe, then Moderate, then Advanced on similar apps | each level lists a superset of the one before | not run |
| U10 | Forced uninstall of a program whose uninstaller was deleted | no uninstaller runs; Advanced list includes its own uninstall entry; quarantine and restore work | not run |
| U11 | Advanced scan on an app with Start Menu and Desktop shortcuts | shortcuts listed; moving and restoring them works | not run |
| U12 | Logs page after several uninstalls | each shows scan level, leftovers moved, quarantine path | not run |
| U13 | Details panel and sorting | details match the program; sort by size/date works | not run |

Run on Linux (temp folders): 59 checks passed (parsing, protection, all three scan levels, shortcuts, publisher folder, file/folder quarantine and restore, records, dry run, forced dry run).

| U14 | Uninstall an app, Moderate scan, right-click a registry leftover > Open in Regedit | Regedit opens at that key (if Regedit was already open it may only come to the front) | not run |
| U15 | Right-click a folder leftover > Add to exclude list, then rescan or press MOVE | the item turns red, cannot be ticked, and is not moved | not run |
| U16 | Exclude List page: add `C:\*`, then a real path, then remove it | `C:\*` is refused; the real path is added and removed | not run |
| U17 | Options: turn on Check all, then uninstall and scan | matched items are pre-ticked; red items are not; you still confirm | not run |
| U18 | Options: Only run the built-in uninstaller | no leftover scan happens at any level | not run |
| U19 | Options: Force-stop, uninstall an app that is running | its processes from the install folder are stopped first (PS> lines show them) | not run |
| U20 | Forced by name: a program removed earlier, with its folder | no uninstaller runs; leftovers listed; protected names refused | not run |
| U21 | Advanced scan on an app with an App Paths entry, move it | the key is exported by `reg.exe` and removed; Restore re-imports it | not run |

Run on Linux (temp folders): 49 new checks passed (path normalisation, pattern rules, matching, status, re-check at delete time, settings, forced-by-name lookup and stand-in rules).

| U22 | Select two throwaway apps with Ctrl, press UNINSTALL | one restore point, two uninstallers run in turn, one combined leftover list | not run |
| U23 | Batch where one uninstaller is cancelled | that program is reported as still installed; the other is scanned and can be cleaned | not run |
| U24 | Batch containing a protected program (Visual C++) | refused before anything runs, naming the program | not run |
| U25 | Batch leftovers: move, then restore one program's quarantine entry | only that program's items return | not run |
| U26 | Windows Apps: remove a harmless app (e.g. a game) for me | app disappears; restore point made; it can be reinstalled from the Store | not run |
| U27 | Windows Apps: select the Microsoft Store | shown as protected; removal refused | not run |
| U28 | Windows Apps: remove for all users without Administrator | refused with a clear message | not run |

Run on Linux (temp folders): 20 new checks passed (batch pre-check, dry run, combined leftovers, per-program quarantine and restore, protected apps, wildcard names, all-users guard).

| U29 | Browser extensions page with Chrome and/or Edge installed | extensions listed with real names and versions | not run |
| U30 | Move one extension to quarantine with the browser OPEN | refused: "Close the browser first" | not run |
| U31 | Close the browser, move an extension, start the browser | extension is gone (or is re-added if sync or policy installs it) | not run |
| U32 | Restore that extension from Quarantine, start the browser | the extension works again | not run |
| U33 | Firefox: move an extension, start Firefox | extension gone; no error | not run |

Run on Linux (temp folders): 19 new checks passed (listing, names, locale lookup, skip rules, path rules, quarantine and restore, unsafe-path refusal).

| U34 | Install monitor: START TRACE, install a small app, open it once, FINISH TRACE | a log is saved with a plausible item count (not thousands) | not run |
| U35 | CLEAN UP FROM LOG while the app is still installed | warned to use UNINSTALL first; "anyway" lists items | not run |
| U36 | Uninstall the app normally, then CLEAN UP FROM LOG | only what the uninstaller left is listed; moving it works; restore works | not run |
| U37 | Close the app mid-trace and reopen it | the pending trace is still there and can be finished or cancelled | not run |
| U38 | DELETE LOG | only the log is removed; the app and quarantine are untouched | not run |
| U39 | Time both snapshots on your PC | each finishes in a reasonable time (report how long) | not run |

Run on Linux (temp folders): 28 new checks passed (snapshot diff on real temp folders, collapse rules, registry/startup/service diffs on synthetic data, noise and protected skips, trace life cycle, exclude-list marking, quarantine cleanup, delete guard).

## Custom uninstall editor (v0.15.0)

| # | Run | Expected | Result |
|---|---|---|---|
| U40 | Open EDIT on a trace log, rename it, add a comment | saved; the log list shows the new name | not run |
| U41 | Remove two items from a log, then CLEAN UP FROM LOG | removed items are not listed; nothing on the PC changed by the edit | not run |
| U42 | Add a folder under Program Files by hand | added; adding `C:\Windows` or `C:\Users` is refused with a reason | not run |
| U43 | Merge two logs | a new log with the union; both originals remain | not run |
| U44 | Export, then export again to the same file name | first works; second refused (no overwrite) | not run |
| U45 | Import the exported file on another PC | imported log marked as imported; unsafe items skipped and counted | not run |
| U46 | Hand-edit an exported file to add `C:\Windows\System32`, import it | that item is skipped | not run |
| U47 | Dry run (`-WhatIf`) editing | nothing saved | not run |

Run on Linux (temp folders): 41 checks passed (item rules, rename, add, remove, merge, export, import, hostile import, dry run).

## Junk cleaner (v0.16.0)

| # | Run | Expected | Result |
|---|---|---|---|
| U48 | Open JUNK CLEANER | sizes shown, nothing ticked | not run |
| U49 | Move User temp to quarantine | old items move; items from the last 24 hours stay; apps keep working | not run |
| U50 | Restore that quarantine entry | items return to the temp folder | not run |
| U51 | Browser caches with Chrome/Edge open | blocked with "close it first" | not run |
| U52 | Browser caches with the browser closed | cache folders move; you stay signed in; history intact | not run |
| U53 | Windows temp and crash dumps as a standard user | listed as needing Administrator, not touched | not run |
| U54 | DELETE PERMANENTLY on one category | asks first; space is freed; quarantine entry is gone | not run |
| U55 | Dry run (`-WhatIf`) | nothing moves | not run |
| U56 | Time the scan on a PC with a large temp folder | finishes in a reasonable time (report how long) | not run |

Run on Linux (temp folders): 27 checks passed (root and path gates, age rule, links, forged items, re-check at move time, restore round trip, exclude list, permanent delete, file filter, browser-running block, dry run).

