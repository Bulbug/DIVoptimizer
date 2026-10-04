# DIVoptimizer v0.7.0

A transparent, hardware-aware, **reversible** Windows optimization and maintenance utility written in PowerShell.

It scans your PC, recommends only what makes sense for *your* hardware, shows the exact **current -> new** value of every change, backs up what it touches, applies only what you approve, verifies the result, logs everything, and lets you restore.

```
SCAN -> DETECT -> ANALYZE -> RECOMMEND -> SHOW EXACT CHANGES -> BACKUP -> ASK -> APPLY -> VERIFY -> LOG -> RESTORE
```

## What it does NOT promise

> DIVoptimizer does not guarantee FPS increases, lower latency, lower temperatures, or faster Windows performance.
>
> Windows performance depends on hardware, drivers, applications, configuration, thermals, and workload.
>
> DIVoptimizer therefore focuses on transparent configuration changes, maintenance, cleanup, and user-controlled optimization rather than guaranteed performance claims.

It will never show "+50 FPS", "-30% input lag", a fake "87% optimized" score, or similar. The dashboard shows facts (CPU %, RAM %, free disk space, startup count, feature states). The optional benchmark records only values it actually measured.

## What it does

| Area | What you get |
|---|---|
| **Scan** | Windows edition/build/support status, CPU, RAM, GPU + driver, storage (SSD/HDD/NVMe), laptop/desktop/tablet/VM, battery + AC, touchscreen, Game Mode, Game DVR, HAGS, Search, SysMain, Defender, Windows Update (restart pending), System Restore, hibernation, startup items, services, detected games. Read-only. |
| **Recommendations** | Hardware-aware, grouped as LOW RISK / OPTIONAL / ADVANCED, each with *why*, *potential downside*, *restart required* and *rollback availability*. |
| **Profiles** | Gaming, Laptop, Desktop, Low Resource. |
| **Quick Optimize** | Applies **only LOW RISK** recommendations, after preview, restore point and backup. Never advanced items. |
| **Performance / Gaming / Privacy** | Separate pages. Privacy is never forced and is separate from performance. |
| **Optional Apps** | You choose what to remove. Exact package names only; system components are protected. |
| **Startup Manager** | Enable/disable/open location. Entries are **never deleted**. |
| **Cleanup** | User Temp, Windows Temp, Recycle Bin, thumbnail cache, Delivery Optimization cache, Windows Update cache - with estimated size, file count and locked-file count. |
| **Network Tools** | Diagnostics, Repair (flush DNS), Reset (Winsock, TCP/IP). Not called optimization. |
| **Windows Maintenance** | DISM Check/Scan/RestoreHealth, SFC, component cleanup. Repair tools, not performance boosters. |
| **Backup / Restore / History** | Verified, checksummed backups; view, create, restore, delete, open folder, retention (5/10/20/All); change history. |
| **Advanced Tools** | Service Manager, registry tweaks, scheduled tasks, hibernation, power plan, Temporary Working-Set Trim, benchmark. |
| **Reports** | TXT or JSON system report with no user name, computer name, serial numbers, file paths or startup command lines. |

## Supported Windows versions

Windows 10 (1809 or later) and Windows 11, **client editions**, 64-bit recommended. Windows Server is reported as unsupported. Individual tweaks carry their own compatibility metadata; an unsupported tweak says *"This tweak is not available on this Windows version."* and is never applied.

Requires Windows PowerShell 5.1 (included with Windows). PowerShell 7 on Windows also works.

## Installation

1. Download the release zip `DIVoptimizer-v0.7.0.zip` and extract it anywhere.
2. If Windows blocked the files: right-click each `.ps1` -> Properties -> **Unblock** (or run `Get-ChildItem . -Recurse | Unblock-File`).
3. Run it from the extracted folder.

**There is deliberately no `irm <url> | iex` installer.** DIVoptimizer never downloads and executes remote code as Administrator. Download, inspect, then run a local file.

## Usage

```powershell
# GUI (default)
powershell -ExecutionPolicy Bypass -File .\DIVoptimizer.ps1

# Console menu
.\DIVoptimizer.ps1 -Console

# Read-only scan: changes nothing, writes no log or backup
.\DIVoptimizer.ps1 -Scan

# Dry run: shows system, potential changes, current -> proposed values,
# risk levels and restart needs. Makes ZERO changes.
.\DIVoptimizer.ps1 -WhatIf

# Quick Optimize (LOW RISK only, still previews and asks)
.\DIVoptimizer.ps1 -Quick

# A profile
.\DIVoptimizer.ps1 -ProfileName Gaming        # Gaming | Laptop | Desktop | LowResource

# Export a report (no personal data)
.\DIVoptimizer.ps1 -Scan -Report C:\Temp\report.json -Format json

# Check for a newer release (never installs anything)
.\DIVoptimizer.ps1 -CheckUpdate
```

Example `-WhatIf` output:

```
DIVoptimizer DRY RUN

System:
  Windows 11
  16 GB RAM
  SSD
  Laptop

Potential changes (recommended for this PC):

[LOW RISK]
Disable Game DVR / background recording
Default (not set) -> Disabled

[OPTIONAL]
Turn off the advertising ID
Enabled -> Disabled

NO CHANGES WERE MADE.
```

### Administrator rights

DIVoptimizer starts as a normal user. Scanning, reports and per-user (HKCU) tweaks work without elevation. When a selected change needs Administrator (HKLM settings, services, scheduled tasks, restore points), it tells you **why** and offers a UAC relaunch of the same local file with your selection carried over.

## Risk levels

| Level | Meaning | Selected automatically? |
|---|---|---|
| **LOW RISK** | Minimal side effects, easily reversed (or harmless, such as Game DVR). | Ticked by default; applied only after you review and approve. |
| **OPTIONAL** | A preference or a trade-off (privacy, visual effects, HAGS, power plan). | Never. |
| **ADVANCED** | Can affect Windows functionality (services, hibernation, tasks, apps, telemetry policy, delivery policy). | Never. Requires an explicit acknowledgement (GUI checkbox / typing `YES`). |

When DIVoptimizer is unsure, it classifies a change as OPTIONAL or ADVANCED instead of applying it automatically. Defender and Windows Update are never touched by any profile.

## Safety

- **Backup before change.** Every registry value, service, scheduled task, startup flag, power plan and hibernation state a change touches is recorded first, written, re-read and checksummed (SHA-256) *before* anything is modified.
- **Transaction per change:** PRECHECK -> BACKUP -> CHANGE -> VERIFY. If verification fails, that change is rolled back.
- **Honest results.** Mixed outcomes are shown as *COMPLETED WITH WARNINGS* with successful/failed/skipped counts - never a false "complete".
- **Protected lists are enforced in code**: Defender, Windows Update, networking/RPC/core services and Store/runtime packages cannot be modified even if requested.
- **Apps are removed by exact package name** (never wildcards) and the UI states plainly that removal is *not* automatically reversible.
- **Not reversible = said so.** Cleanup, app removal and network resets are listed as "not reversible automatically" in the review screen.
- Advanced changes are cancelled if the backup fails.

## Backups

Stored per user in `%LOCALAPPDATA%\DIVoptimizer\Backups\<ID>\` where the ID is `yyyy-MM-dd_HHmmss` (for example `2026-10-03_071500`):

```
backup.json        metadata, counts, system-restore status, change list, SHA-256 of every data file
registry\registry.json
services\services.json
tasks\tasks.json
startup\startup.json
power\powerplan.json
settings\hibernation.json
settings\apps.json  (removed apps - informational, not restorable automatically)
```

Registry records are JSON with `Path`, `Name`, `Type`, `Exists`, `Value`, `KeyExisted`. Supported types: String, ExpandString (stored unexpanded), DWord, QWord, MultiString, Binary (Base64). A value that did not exist is removed on restore; a key DIVoptimizer created is removed again if it is empty.

Logs: `%LOCALAPPDATA%\DIVoptimizer\Logs\*.jsonl` (timestamp, user, computer, Windows version, action, target, before, after, backup ID, result, error). Use *View Log* in the GUI/History or the console for a readable form.

Backups are **never deleted silently**. Retention (5/10/20/All, default All) only *proposes* deletions; you see the date, size and ID and confirm.

### Backups from v0.6.0

v0.6.0 kept its manifest under `%ProgramData%\DIVoptimizer\Backups`. v0.7.0 lists them as *legacy*. It restores **only records that parse unambiguously** (services, DWord/QWord/String registry values, power plan - using the *first* recorded value as the original) and skips scheduled-task and app records. If the manifest cannot be verified at all you get:

```
This backup was created by DIVoptimizer v0.6.0.

Automatic migration is not available.

Do not attempt restoration because the backup format cannot be verified.
```

## Restore

- **In the app:** Backup / Restore (or History) -> select -> Restore. A backup that fails checksum verification is refused.
- **Emergency (independent of the GUI):**

```powershell
powershell -ExecutionPolicy Bypass -File .\DIVoptimizer-Reset.ps1
```

```
[1] Restore latest backup   [2] Registry   [3] Services   [4] Scheduled tasks
[5] Startup settings        [6] Power plan [7] Hibernation [8] Exit   [L] choose another backup
```

`DIVoptimizer-Reset.ps1` embeds the same restore code as the main script (verified identical by a test), so it works even if the main script or GUI is broken.

- Restoring a backup returns settings to the state recorded **in that backup**. To undo several sessions, restore them newest to oldest.
- A service that was originally *stopped* is not started on restore. Scheduled tasks get their exact previous enabled/disabled flag.
- Windows **System Restore** is also attempted before significant changes (needs Administrator) and is shown as an alternative recovery path (`rstrui.exe`).

## Troubleshooting

| Symptom | Fix |
|---|---|
| "running scripts is disabled" | `powershell -ExecutionPolicy Bypass -File .\DIVoptimizer.ps1` (applies to that one run). |
| "Requires Administrator" | Accept the UAC prompt DIVoptimizer offers, or start PowerShell as Administrator. |
| No restore point created | Needs Administrator; Windows also allows one per 24 hours by default. DIVoptimizer's own backup is still made. |
| GUI does not open | Falls back to the console automatically; or run with `-Console`. |
| Restore shows "failed" for HKLM/services | Re-run as Administrator. |
| Settings did not change | Some need sign-out/restart; the review and result screens say which. |
| Elevated run shows different backups | Elevating as a *different* user account uses that account's `%LOCALAPPDATA%` and HKCU. Use the same account. |

## FAQ

**Will it make my games faster?** Maybe, maybe not; it does not claim to. Measure with the optional benchmark or the game itself.

**Why is Windows Search / SysMain / Xbox not disabled for me?** They are not "bloat". They are offered only under Advanced Tools, never recommended automatically, and Xbox services/apps are flagged because Game Pass, Minecraft and some Store games need them. The touch keyboard service is blocked outright when a touchscreen is detected.

**Is "Trim Memory" a RAM booster?** No. It is now *Temporary Working-Set Trim*, an advanced troubleshooting tool: it does not create RAM and Windows reloads the memory when needed. It is not part of Quick Optimize.

**Does it phone home?** No telemetry. The only network use is the explicit update check, which fetches a small JSON manifest over HTTPS.

**Can I remove apps and get them back?** Not automatically. Reinstall from Microsoft Store or another official source.

## Updates

`-CheckUpdate` (or *Check for updates* in the app) fetches a manifest from `$Script:UpdateManifestUrl` and shows current vs latest version, release notes, download source, SHA-256 and signature status. You can have it download the package to a staging folder where the SHA-256 is verified; it **never** replaces or runs anything. Manifest format:

```json
{ "version": "0.7.1", "notes": "What changed", "url": "https://github.com/<owner>/<repo>/releases/download/v0.7.1/DIVoptimizer-v0.7.1.zip", "sha256": "<64 hex characters>" }
```

Allowed download hosts: `github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`. Publish `update.json` at the manifest URL (defined at the top of `DIVoptimizer.ps1`). Code-signing the release is recommended; until then the signature status will read `NotSigned`.

## Development

```
DIVoptimizer.ps1          main program (GUI + console)
DIVoptimizer-Reset.ps1    emergency restore
tests\DIVoptimizer.Tests.ps1   Pester 5 tests
```

- The text between `# <<<CORE-BEGIN` and `# <<<CORE-END` is the shared restore core and must stay identical in both scripts (a test checks this).
- Source is ASCII-only so Windows PowerShell 5.1 parses it correctly without a BOM.
- All system writes go through a few primitives (`Set-RegistryValueSafe`, `Set-ServiceStartMode`, `Set-TaskEnabledSafe`, `Set-ActivePowerPlan`, `Set-HibernationState`, `Remove-AppPackageExact`, `Invoke-CleanupTarget`) that honor dry-run.
- Run the tests (they never touch your real configuration: TestRegistry drive, mocks, `$TestDrive`):

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser   # if needed
Invoke-Pester .\tests\DIVoptimizer.Tests.ps1 -Output Detailed
```

## License

No license has been chosen yet. See `LICENSE`.
