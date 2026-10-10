# Changelog

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
