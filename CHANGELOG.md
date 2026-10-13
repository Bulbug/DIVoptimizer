# Changelog

## 0.16.0
- Junk cleaner (GUI button in DIVuninstaller and Tweaks, console menu `21` or `J`): read-only scan with sizes for user temp, Windows temp, crash dumps, error reports, thumbnail cache and browser caches (Chrome, Edge, Brave, Firefox). Nothing is ticked by default.
- Items go to quarantine and can be restored; DELETE PERMANENTLY is separate and asks first. Every item is re-checked right before it moves (direct child of the junk folder, not a link, not on the exclude list, not changed in 24 hours; browser closed). Files in use are skipped and counted.
- Robust when an environment variable such as LOCALAPPDATA is missing.
- 27 new checks on Linux PowerShell. Not yet seen on Windows.

## 0.15.0
- Custom uninstall editor (install monitor page, console `E`/`M`/`P`/`I`): rename a trace log, add a comment, remove items from it, add a folder, file, registry key or startup value by hand, merge logs into a new one, export a log to a `.json` file and import one from a file. Only the log changes; cleaning up from a log still goes through review and quarantine.
- Typed, edited and imported items pass the same safety checks (full path, no wildcards or `..`, no protected, drive-root or top-level folders, registry keys two levels deep and not under Microsoft, Classes or Policies; the standard Run key is allowed for startup values). Failing items are skipped on import and counted. Export never overwrites a file; import is limited to 5 MB and 20000 items.
- Dry run changes nothing for every editor action.
- 41 new checks on Linux PowerShell. Not yet seen on Windows.

## 0.14.0
- Install monitor (GUI and console `T`): take a snapshot, install a program, take a second snapshot, and save the difference as a trace log. Clean up from a log later: only items that were created in that window and still exist are listed, with the same review screen, exclude list and quarantine as any leftover.
- Snapshots hold names only (folders two levels deep, shortcuts, registry keys two levels deep, uninstall and Run entries, service names). Microsoft, Classes and Policies keys are not tracked, protected and DIVoptimizer-own folders are skipped, children of a new folder or key are collapsed into it, and services are listed but never removed.
- A pending trace survives closing the app. Trace logs can be listed and deleted (only inside the traces folder).
- 28 new checks on Linux PowerShell (175 in total with the earlier ones). Not yet seen on Windows.

## 0.13.0
- Browser extensions page (GUI and console `X`): Chrome, Edge, Brave and Firefox, all profiles, names read from each manifest. Removal moves the extension to quarantine (restorable); the browser must be closed; only an extension's own folder or `.xpi` inside an Extensions folder can be moved.
- Startup Manager is now reachable from DIVuninstaller (button, console `S`). It already existed, so no second autorun tool was added.
- 19 new checks on Linux PowerShell with fake browser folders (147 in total with the earlier ones). Not yet seen on Windows.

## 0.12.0
- Batch uninstall: select several programs, one restore point, each program's own uninstaller in turn, one combined leftover list, one quarantine entry per program. The whole batch is checked before anything runs.
- Windows Apps list (GUI and console `W`): search, multi-select, remove for your account or for all users (Administrator). Protected and system apps are left out or marked protected. Wildcard package names are refused.
- `Remove-AppPackageExact` gained `-CurrentUserOnly`; the Optional Apps behavior is unchanged.
- Console review split into its own function so single and batch uninstalls share it.
- 20 new checks on Linux PowerShell (128 in total with the earlier ones). Not yet seen on Windows.

## 0.11.0
- Leftover review screen: bold items are matched to the program and can be selected, grey lines show where they sit, red items are on your exclude list and are never touched.
- Exclude list with `*` and `?` wildcards, saved as JSON. Too-broad patterns are refused. It is checked again when moving, so it cannot be bypassed by the scan result.
- Right-click on a leftover: Open in Regedit, Open containing folder, Add to exclude list. Console: `X`, `R`, `F` with the item number.
- Options (all off by default): check all matched leftovers, force-stop programs running from the install folder, only run the built-in uninstaller.
- Forced uninstall by name or folder: finds installed programs and earlier records by exact name, wildcard, several names or folder, then scans at the Advanced level. A hand-typed folder must be inside Program Files, ProgramData or AppData.
- Fix: App Paths leftovers used a registry path form that `reg.exe` cannot export, so they would have been kept instead of moved. They now use a path `reg.exe` accepts, and `ConvertTo-RegExePath` strips the PowerShell provider prefix.
- Fix: a forced stand-in without an uninstall key is no longer reported as "still installed" or backed up with an empty path.
- 49 new checks on Linux PowerShell (108 in total with the earlier 59). Not yet seen on Windows.

## 0.10.0
- DIVuninstalled is now **DIVuninstaller** (the data folders keep their names, so nothing already saved is orphaned).
- Leftover scan levels: Built-in (no scan), Safe, Moderate (default) and Advanced. Advanced adds Start Menu and Desktop shortcuts, App Paths entries, the program's own uninstall entry and an empty publisher folder.
- Forced uninstall for programs whose uninstaller is missing or broken: restore point, registry backup, then an Advanced scan, without running the uninstaller.
- Program details panel and sorting (name, size, install date, publisher). Open the install folder from the list.
- Uninstall logs: every uninstall is recorded (scan level, exit code, leftovers found and moved, quarantine location) and listed on a Logs page, in the GUI and in the console.
- Quarantine now handles single files (shortcuts) and removes an empty publisher folder only if it has no files at that moment.
- Select all low-risk / Select none in the leftover list.
- Console parity: scan-level prompt, F<n> forced uninstall, D<n> details, L logs.
- Tested on Linux PowerShell with temp folders (59 checks). Not yet seen on Windows.

## 0.9.0
- New DIVuninstalled tab (renamed DIVuninstaller in 0.10.0) (GUI: Tweaks > DIVuninstalled and Maintain > DIVuninstalled; console option 20).
- Lists installed programs (machine, 32-bit and per-user entries), with search. System, runtime, driver and security programs are protected.
- Uninstall runs the program's own uninstaller after a restore point and a backup of its registry entry. MSI uninstall commands are always converted to /x with the product code. The exact command is shown first and printed as a PS> line.
- Leftover scan by exact name only: install folder, folders under Program Files, ProgramData and AppData, Software registry keys, and Run entries pointing into the install folder. Protected names and folders holding another installed program are never offered. Nothing is pre-selected.
- Cleanup goes to a quarantine: folders are moved, registry keys are exported first. Restore any entry, or delete permanently (asks first, only inside the quarantine).
- New engine functions have real tests (command parsing, protection rules, leftover scan, quarantine move, restore and delete guards).
- Not yet seen on Windows: real uninstalls, registry export/import and the new GUI pages.

## 0.8.1
- New Tweaks page in the app with two tab-style buttons: DIVoptimizer Tweaks (Performance, Gaming, Privacy, Optional Apps) and YouTuber Optimizations.
- YouTuber Optimizations is a Coming soon page. It contains no tweaks and cannot change anything.
- The dashboard's Optimize row is replaced by a Tweaks row pointing to those two tabs.
- Version rule from now on: big update = 0.9.0, small change = 0.8.x.

## 0.8.0 (release candidate - untested on Windows)
- Services are now deny-by-default: only DiagTrack and SysMain can be changed; every other service is protected.
- The service catalog was reduced to those two services.
- New backup IDs: `backup-yyyy-MM-dd-HHmmss-XXXX`. Older IDs still restore.
- Every recommendation now has a tier: SAFE, BALANCED or ADVANCED.
- Only SAFE, fully reversible, laptop-safe tweaks are pre-selected. Nothing else ever is.
- Power-plan and hibernation tweaks are never pre-selected on laptops or tablets.
- Compatibility check: if a setting was already changed by another tool (WinUtil or similar) to a different value, the row says so and is not pre-selected. Settings already at our target are skipped.
- New `-Health`: read-only self-check (PowerShell version, Administrator, backup folder, backup verification, allow-list).
- New `-Undo`: finds the newest backup that passes verification, shows it, asks, then restores it. Needs Administrator (UAC relaunch keeps the mode).
- Every session now also writes a plain-text `.log` next to the JSON log.
- Every change (apply and restore) now prints the exact command in the PowerShell window as a `PS>` line before it runs: registry writes, service changes, scheduled tasks, power plan, hibernation, app removal and cleanup. Dry runs still print `[DRY RUN] would ...` and run nothing. The same lines go to the log.
- App window restyled: new navy and blue-violet palette, rounded buttons with hover and pressed states, rounder busy card, Segoe UI Variable font. Styling only; layout and behavior unchanged. Not yet seen on a real Windows desktop.
- Website redesigned with an interactive preview/apply/undo example.
- Added docs/TWEAK-INVENTORY.md, docs/TEST-MATRIX.md and AUDIT-v0.8.0.md.
- Nothing in this version has been run on Windows.

## DIVoptimizer v0.7.0

### Added
- System scanner (Windows, hardware, power, features, startup, services, storage, memory, detected games) and `-Scan` / **SCAN SYSTEM** (read-only).
- Hardware-aware recommendation engine; LOW RISK / OPTIONAL / ADVANCED classification; per-change *why*, *downside*, *restart*, *rollback*.
- Current -> New preview and review/confirmation page for every change; ADVANCED acknowledgement.
- `-WhatIf` dry run (zero changes, no log or backup writes).
- Transaction model per change: PRECHECK -> BACKUP -> CHANGE -> VERIFY -> ROLLBACK; "completed with warnings" reporting.
- Backup system v2: JSON records, SHA-256 integrity, verification before applying, services/tasks/startup/power/hibernation coverage, History, retention proposals, manual backup.
- `DIVoptimizer-Reset.ps1` emergency restore (embeds the identical restore core).
- Profiles (Gaming, Laptop, Desktop, Low Resource); Quick Optimize restricted to LOW RISK.
- Startup Manager using Windows' own StartupApproved flags (nothing deleted).
- Cleanup size estimates with locked-file counts; Network Tools and Windows Maintenance as separate, honestly-labelled areas.
- Compatibility metadata per tweak; touchscreen/battery/VM awareness; laptop warnings.
- Health dashboard of measured facts; resource monitor (CPU, RAM, disk, network, sortable processes); optional measured-only benchmark.
- System report export (TXT/JSON) without personal data.
- Explicit update check with HTTPS, host allow-list, SHA-256 and signature status (never auto-installs).
- Pester tests that never touch the real system.

### Improved
- Administrator is now required to run the app; it relaunches itself through UAC in the same mode. Read-only modes (`-Scan`, `-WhatIf`, `-Report`, `-CheckUpdate`) still work without it.
- Visible progress for every task: console progress bar and a GUI loading overlay with a progress bar (scan stages, backup, apply, cleanup, restore, benchmark, update check).
- The GUI window opens immediately and runs its first scan behind the loading overlay.
- "Safe Debloat" renamed **Optional Apps** with OPTIONAL / USER-DEPENDENT / ADVANCED categories and per-app selection; exact package matching.
- "Low RAM" mode replaced by Resource Optimization / Low Resource Profile (no blind service disabling).
- "Trim Memory" renamed **Temporary Working-Set Trim**, advanced-only, with an honest explanation.
- Power plan: Balanced / Performance / Maximum Performance with battery, heat and noise warnings; the original plan is restored.
- Diagnostic-data tweak uses the level the Windows edition actually honours (Home/Pro: 1).
- Visual-effects tweak changes real settings (animations/transparency) instead of a preset flag that does little.
- GUI reorganised around scan -> recommend -> review -> result.

### Fixed
- Registry backup used a pipe-delimited format that corrupted values containing `|`, dropped Binary/MultiString data and stored every value as DWord on restore. Now structured JSON with types.
- ExpandString values were expanded when backed up.
- Hibernation state was never recorded, so it could not be restored.
- Services that were originally stopped could be started on restore; delayed-auto start was lost.
- Scheduled-task state was stored as `State` (Ready is not Enabled).
- Duplicate backup records for the same value could make restore apply the wrong (already changed) value.
- Startup items were disabled by moving or renaming entries; now uses the Windows StartupApproved flag and never deletes.
- `-like "*name*"` wildcard app removal; the "never touch" package/service lists were defined but not enforced.
- Old backups were deleted without showing the user what would be removed.
- `config.ini` was silently ignored when run via `irm | iex`.

### Security
- Runs from a saved file **or** via `irm <url> | iex` (project owner's choice). The old unpinned self-download relaunch was replaced: elevation re-runs the same file, or for a remote run the same one-liner from a fixed HTTPS GitHub URL (host allow-list, optional pinned `DIVOPTIMIZER_URL`), and only validated plain identifiers are placed in the relaunch command line.
- A remote run leaves the user's PowerShell session clean (adds no lingering functions or variables).
- Running via `irm | iex` executes whatever is published at the URL with the user's privileges; protect the repository (2FA, branch protection) and use a pinned tag for fixed versions.
- No telemetry; no `exit` that would close the user's terminal.
- Protected-service and protected-package lists enforced in code. Defender and Windows Update are never part of any profile.

### Known limitations
- The PowerShell code, GUI and tests were authored without access to a Windows machine and have **not been executed**. Run the Pester suite and exercise the GUI/console on a test PC (ideally a VM with a snapshot) before relying on it.
- Backup location moved to `%LOCALAPPDATA%\DIVoptimizer` (per user). v0.6.0 backups under `%ProgramData%` are read as *legacy* with limited, strict restore.
- Startup "impact" is observed RAM of running programs only; Windows does not expose boot-time impact.
- Application start-up time and FPS are not measured by the built-in benchmark.
- SysMain/Windows Search appear only under Advanced Tools (never recommended automatically), not in the main recommendation list.
- Thermal readings use the ACPI thermal zone, which many PCs do not expose or which may not reflect CPU/GPU temperature.
- HAGS support is not probed per GPU/driver; the setting simply has no effect on unsupported hardware.
- The release zip is not code-signed.
