# DIVoptimizer v0.16.0

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

Nothing to download or install. Open **PowerShell** (Windows PowerShell 5.1 or PowerShell 7) and run:

```powershell
irm "https://raw.githubusercontent.com/Bulbug/DIVoptimizer/refs/heads/main/DIVoptimizer.ps1" | iex
```

That starts the GUI. If your Windows is old and you get a TLS error, run this first: `[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12`

You can also save the script and run the file; everything works the same either way.

**Trust note.** Running `irm | iex` executes whatever is currently published at that URL, with your privileges. Only run it from a repository you trust, and if you maintain the repo, protect `main` (2FA, branch protection). To use a fixed, reviewed version instead of the latest `main`, pin a tag or commit:

```powershell
$env:DIVOPTIMIZER_URL = "https://raw.githubusercontent.com/Bulbug/DIVoptimizer/v0.16.0/DIVoptimizer.ps1"
irm $env:DIVOPTIMIZER_URL | iex
```

(`DIVOPTIMIZER_URL` is also what the Administrator relaunch uses, so the elevated copy is the same pinned version. It must be an HTTPS github.com / raw.githubusercontent.com address or it is ignored.)

## Usage

`irm | iex` cannot take switches. To pass switches, use the script-block form (replace `<url>` with the address above):

```powershell
& ([scriptblock]::Create((irm "<url>"))) -Console
```

```powershell
# GUI (default)
irm "<url>" | iex

# Console menu
& ([scriptblock]::Create((irm "<url>"))) -Console

# Read-only scan: changes nothing, writes no log or backup
& ([scriptblock]::Create((irm "<url>"))) -Scan

# Dry run: shows system, potential changes, current -> proposed values,
# risk levels and restart needs. Makes ZERO changes.
& ([scriptblock]::Create((irm "<url>"))) -WhatIf

# Quick Optimize (LOW RISK only, still previews and asks)
& ([scriptblock]::Create((irm "<url>"))) -Quick

# A profile: Gaming | Laptop | Desktop | LowResource
& ([scriptblock]::Create((irm "<url>"))) -ProfileName Gaming

# Export a report (no personal data)
& ([scriptblock]::Create((irm "<url>"))) -Scan -Report C:\Temp\report.json -Format json
```

If you saved the file, the same switches work directly: `.\DIVoptimizer.ps1 -Console`, `-Scan`, `-WhatIf`, `-Quick`, `-ProfileName`, `-Report`, `-CheckUpdate`, `-ShowVersion`.

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

DIVoptimizer **requires Administrator** for the app itself (GUI, console, Quick Optimize, profiles), because it backs up and changes system settings, services, scheduled tasks and restore points. If you start it normally it explains why and relaunches itself through the Windows UAC prompt, in the same mode you asked for. If you decline, nothing is started.

The read-only modes do **not** need Administrator: `-Scan`, `-WhatIf`, `-Report`, `-CheckUpdate`, `-ShowVersion`.

When started with `irm | iex`, the relaunch re-runs the same one-liner from the fixed HTTPS GitHub URL (selection IDs are validated to plain identifiers before going into the command). When the remote run ends, DIVoptimizer removes the functions and variables it added to your PowerShell session.

### Progress while it works

Every task shows what it is doing. In the console, a progress bar appears at the top of the window (scan stages, backup, each change being applied, cleanup, benchmark). In the GUI, a loading panel with a progress bar covers the window during scans, backups, restores, cleanup estimates, app and startup checks, applying changes, benchmarking and update checks. It always clears when the task finishes or fails. A single long step can make the GUI look unresponsive until that step ends; DISM and SFC run in their own console window for that reason.

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
irm "https://raw.githubusercontent.com/Bulbug/DIVoptimizer/refs/heads/main/DIVoptimizer-Reset.ps1" | iex
```
(or run `DIVoptimizer-Reset.ps1` as a file)

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
| "running scripts is disabled" (saved file only) | Use the one-liner (not subject to execution policy) or `powershell -ExecutionPolicy Bypass -File .\DIVoptimizer.ps1`. |
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

**Does it phone home?** No telemetry. Network use is limited to the `irm` that starts it, the Administrator relaunch (same URL), and the explicit update check.

**Can I remove apps and get them back?** Not automatically. Reinstall from Microsoft Store or another official source.

## Updates

When started with `irm | iex` you always get the latest published script, so an update check mainly matters for saved copies. `-CheckUpdate` (or *Check for updates* in the app) fetches a manifest from `$Script:UpdateManifestUrl` and shows current vs latest version, release notes, download source, SHA-256 and signature status. You can have it download the package to a staging folder where the SHA-256 is verified; it **never** replaces or runs anything. Manifest format:

```json
{ "version": "0.7.1", "notes": "What changed", "url": "https://github.com/<owner>/<repo>/releases/download/v0.7.1/DIVoptimizer-v0.7.1.zip", "sha256": "<64 hex characters>" }
```

Allowed download hosts: `github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`. Publish `update.json` at the manifest URL (defined at the top of `DIVoptimizer.ps1`). Code-signing the release is recommended; until then the signature status will read `NotSigned`.

## Development

```
DIVoptimizer.ps1          main program (GUI + console); runs from a file or via irm | iex
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


## New in v0.8.0

- `-Health` - read-only self-check.
- `-Undo` - restore the newest verified backup (asks first).
- Plain-text `.log` alongside the JSON log in `%LOCALAPPDATA%\DIVoptimizer\Logs`.
- Live command echo: while it works, the PowerShell window prints each exact command as a `PS>` line, so you can see it really is doing what the preview said. (This also applies in the GUI; keep the PowerShell window visible.)

## DIVuninstaller (v0.16.0)

A Revo-style uninstaller: remove a program with its own uninstaller, then clear what it leaves behind, with a way back. Open it from the app (Tweaks > DIVuninstaller, or Maintain > DIVuninstaller) or from the console menu (option 20).

**Program list.** Built from the uninstall entries Windows keeps (machine, 32-bit and per-user). Search, sort by name, size, install date or publisher, and a details panel (publisher, install date, size, install folder, uninstall entry). System components and updates are hidden. System, runtime, driver and security software is marked **protected** and cannot be uninstalled here.

**Uninstall.** Makes a restore point (if Windows allows it), backs up the program's registry entry, then runs the program's **own** uninstaller. The exact command is shown first and printed as a `PS>` line.

**Leftover scan level** (you choose before uninstalling):

| Level | What it looks for |
|---|---|
| Built-in | Nothing. Only the program's uninstaller runs. |
| Safe | The install folder, plus folders under Program Files and ProgramData and registry keys under Software with the program's exact name. |
| Moderate (default) | Safe, plus AppData folders and startup (Run) entries pointing into the install folder. |
| Advanced | Moderate, plus Start Menu and Desktop shortcuts, App Paths entries, the program's own uninstall entry, and the publisher folder if it ends up empty. |

**Forced uninstall.** For a program whose uninstaller is missing or broken. It does **not** run the uninstaller; it makes a restore point, backs up the registry entry, then scans at the Advanced level and lists everything it finds, including the program's own uninstall entry.

**Review screen (v0.11).** Each leftover is shown by how sure we are of it:

| Look | Meaning |
|---|---|
| **Bold**, with a check box | Matched to this program by exact name or path. Can be selected. |
| Grey line "In ..." | Only shows where the bold items sit. Cannot be selected. |
| Red | On your **exclude list**. Cannot be selected and is never touched. |

Right-click an item: **Open in Regedit** (registry items), **Open containing folder** (folders and files), **Add to exclude list**. The exclude list (EXCLUDE LIST button, or `E` in the console) is saved in `%LOCALAPPDATA%\DIVoptimizer\uninstaller-exclude.json`. A pattern covers everything under it; `*` is any text and `?` one character. Patterns that would match almost everything (`*`, `C:\*`, `HKLM:\*`) are refused. The list is checked again at the moment of moving, not only when the scan ran.

**Options (v0.11).** All off by default: check all matched leftovers (you still confirm), force-stop programs running from the install folder before uninstalling, and only run the built-in uninstaller (never scan).

**Forced uninstall by name (v0.11).** FORCED BY NAME (or `N` in the console) is for a program that is not listed, was removed earlier or was half-installed. Type an exact name (several can be separated with `;`, `*` and `?` work when searching) and/or a folder inside Program Files, ProgramData or AppData. It lists any installed program or earlier record that matches, then scans at the Advanced level. It never runs an uninstaller from there, and partial names do not match.

**Batch uninstall (v0.12).** Hold Ctrl or Shift in the program list and press UNINSTALL (console: `1,3,5`). The whole batch is checked first (protected programs and unreadable uninstall commands stop it before anything runs), then ONE restore point is made, then each program's own uninstaller runs one after another. It does not guess silent switches, so each uninstaller may open its own window. If one fails or is cancelled the rest still run. You get one combined leftover list; selected items are quarantined as one entry per program, so each can be restored on its own.

**Windows Apps (v0.12).** WINDOWS APPS (console: `W`) lists the Store and built-in apps for your account, with search and multi-select. Frameworks, system packages and the apps Windows needs (Store, Edge, Defender UI, shell and search components, and similar) are not listed or are marked protected. Removal is by exact package name through the same guarded function as Optional Apps, for your account by default; "for all users" needs Administrator and also removes the copy new accounts would get. A restore point is made first, but Windows restore points do not bring Store apps back; reinstall them from the Microsoft Store. App removals are logged but there is no leftover scan for them (Windows removes the app's own data).

**Browser extensions (v0.13).** BROWSER EXTENSIONS (console: `X`) lists extensions for Chrome, Edge, Brave and Firefox (every profile), with search and multi-select. Names are read from the extension's own manifest. Removal moves the extension's own folder (or Firefox `.xpi` file) to quarantine, so it can be restored; browser databases are never edited. The browser must be closed first, or the removal is refused. An extension installed by browser sync or an organization policy may be added back by the browser; remove those from the browser's own extensions page. Firefox drops the missing entry the next time it starts.

**Startup manager.** STARTUP MANAGER (console: `S`) opens the existing Startup Manager, which turns startup items on and off the way Task Manager does, with a backup. It was already part of the app, so v0.13 links to it instead of adding a second one.

**Install monitor (v0.14).** INSTALL MONITOR (console: `T`) is a lightweight version of Revo's install tracing. Start a trace and name the program, install it, open it once, then press FINISH. DIVuninstaller takes a snapshot before and after (names only, no file contents: folders two levels deep under Program Files, ProgramData, AppData and Local; Start Menu and Desktop shortcuts; registry key names two levels deep under Software; uninstall entries; Run entries; service names) and saves the difference as a trace log. Later, CLEAN UP FROM LOG lists the items from that log that still exist and sends the ones you select to quarantine, the same as any leftover.

How it differs from Revo: it is a before/after comparison, not a real-time monitor, so it can miss changes in places it does not look and can include unrelated changes made by Windows or other programs during the window (you review every item). Keys under Microsoft, Classes and Policies are not tracked. Services are listed in the log but never removed. Files inside new folders are covered by moving the folder. Do not install anything else while a trace is running. Close other installers first. If the program is still installed when you clean up, you are asked to run its own uninstaller first.

**Custom uninstall editor (v0.15).** On the INSTALL MONITOR page, EDIT opens a trace log so you decide what it will undo: rename it, add a comment, remove items from the log, or add a folder, file, registry key or startup value by hand. MERGE (two or more logs into a new one; the originals stay), EXPORT (to a `.json` file; never overwrites) and IMPORT (from a `.json` file, saved as a new log). Console: `E <n>` edit, `M` merge, `P` export, `I` import. Editing only changes the log; nothing on the PC is touched until CLEAN UP FROM LOG, which still shows every item for review and uses quarantine. Typed and imported items must pass the same safety checks as scanned ones: full path, no wildcards or `..`, not a protected or top-level folder, registry keys at least two levels deep and not under Microsoft, Classes or Policies (the standard Run key is allowed for startup values). Items that fail are skipped on import, and the count is shown. Imported logs are marked as imported.

**Junk cleaner (v0.16).** JUNK CLEANER (console: menu `21`, or `J` inside DIVuninstaller) scans first, read-only, and shows the size of each category. Nothing is ticked for you.

| Category | What it covers |
|---|---|
| User temp files | Items in your temp folder not changed for 24 hours |
| Windows temp files | Same for the Windows temp folder (Administrator) |
| Crash dumps | Old `.dmp` files in your CrashDumps folder and `Windows\Minidump` (Administrator) |
| Windows error reports | Old report archives and queues |
| Thumbnail cache | `thumbcache_*.db` (Explorer rebuilds it) |
| Browser caches | Cache, Code Cache and GPUCache of Chrome, Edge and Brave profiles, and Firefox `cache2`. The browser must be closed. History, cookies, passwords and sign-ins are not touched |

Selected items are **moved to quarantine** and can be restored from the Quarantine page; disk space is freed once you delete that quarantine entry. DELETE PERMANENTLY skips the quarantine after a second confirmation and cannot be undone. Each item is checked again right before it moves: it must be a direct child of the known junk folder, not a link or junction, not on your exclude list, and not changed in the last 24 hours; files in use are skipped and counted. Never touched: Recycle Bin, Downloads, Documents, Desktop, and anything outside the folders above. Windows Update and Delivery Optimization caches stay on the Cleanup page. There is no file shredder or "evidence remover".

**Quarantine.** Nothing is pre-selected. Selected folders and shortcuts are **moved** to `%LOCALAPPDATA%\DIVoptimizer\Quarantine`, not deleted. Registry keys and startup values are exported to `.reg` files first. Restore from the Quarantine page. Only "Delete permanently" is irreversible, and it asks first. An empty publisher folder is only removed if it really has no files left at that moment.

**Logs.** Every uninstall writes a record (program, time, scan level, exit code, leftovers found and moved, quarantine location, and the registry backup) to `%LOCALAPPDATA%\DIVoptimizer\Uninstalled`. The Logs page lists them.

Always protected, whatever the scan level: Windows, Microsoft, Common Files and similar folders and keys, drive roots, profile roots, and any folder that contains another installed program.

**Compared with Revo Uninstaller.** Included: program list and details, batch uninstall, a Windows Apps list, browser extensions, an install monitor with trace logs, uninstall levels, forced uninstall (also by name), leftover scan with a bold/grey/red review screen, exclude list, per-item Regedit and folder shortcuts, logs. Not included: Hunter mode (drag a crosshair onto a window; planned), silent batch uninstall and real-time install monitoring (the install monitor is a before/after comparison). Trace logs can be edited, merged, exported and imported (v0.15). Autorun tools are covered by the Startup Manager. A junk cleaner was added in v0.16.

Limits: matching is by exact name, so some leftovers will be missed rather than risk removing something shared. The program's own uninstaller may itself be incomplete or interactive. The emergency reset script does not cover the quarantine; restore from the app, or double-click the `.reg` files and move the folders back by hand.
