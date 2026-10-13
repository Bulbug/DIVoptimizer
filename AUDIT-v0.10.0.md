# DIVoptimizer v0.10.0 - Audit addendum (DIVuninstaller, Revo-style)

Adds to AUDIT-v0.8.0.md and AUDIT-v0.9.0.md. DIVoptimizer is a conservative utility, not risk-free. **None of this has been run on Windows.**

## New in v0.10.0
- Scan levels (Built-in, Safe, Moderate, Advanced), forced uninstall, details and sorting, uninstall logs, single-file quarantine, empty publisher folder cleanup, console parity.

## What the new parts can change
- Forced uninstall changes nothing by itself: it makes a restore point, backs up the program's registry entry, and lists candidates. Only items you select are moved or removed.
- Advanced can offer the program's own uninstall entry (marked CHECK) and App Paths entries (CHECK). Both are exported to .reg before removal; if the export fails the key is kept.
- An empty publisher folder is deleted (not quarantined) only when it contains no files at that moment; otherwise it is kept.

## Safeguards (unchanged and extended)
- Protected programs cannot be uninstalled or force-removed.
- Protected names, drive roots, the Windows folder, profile roots, and folders containing another installed program are never offered or touched, even if passed in directly.
- Exact-name matching only; no fuzzy matching at any level.
- Quarantine delete refuses anything outside the quarantine folder or without a manifest.

## Tested here (Linux PowerShell 7.4.6, temp folders)
59 checks pass, including: scan-level differences (Safe < Moderate < Advanced), shortcut and Start Menu matches, unrelated shortcuts ignored, publisher folder only removed after its children and refused while it has files, file quarantine and restore, uninstall record merge and history, dry run changing nothing, forced mode in dry run, protected programs refused.

## Not tested
Real uninstallers, restore points, `reg.exe` export/import, registry-key and App Paths cleanup, shortcut target resolution (needs the Windows shell COM object), the GUI pages, the console page.

## Remaining risks
- A program's uninstaller can be incomplete, interactive or misbehave.
- Exact-name matching can miss leftovers, and can match a folder another program happens to share by name. Review each item; Advanced items marked CHECK deserve a closer look.
- Not included compared with Revo: Hunter mode, install monitoring, batch uninstall, browser-extension cleanup, Windows Apps list.
- The emergency reset script does not restore the quarantine.
