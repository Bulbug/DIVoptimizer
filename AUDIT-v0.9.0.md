# DIVoptimizer v0.9.0 - Audit addendum (DIVuninstalled)

Adds to AUDIT-v0.8.0.md. Same caveat: DIVoptimizer is a conservative utility, not risk-free, and DIVuninstalled has **not been run on Windows**.

## What it can change
- Runs a program's own uninstaller (that program decides what it removes).
- Moves folders to a quarantine, removes registry keys and Run values after exporting them.
- Permanently deletes a quarantine entry, only on request and only inside the quarantine folder.

## Safeguards
- Protected programs (Visual C++/.NET/Windows/Edge/WebView2/DirectX, Defender, drivers, chipset, security updates) cannot be uninstalled here.
- Protected leaf names (Microsoft, Windows, Common Files, ProgramData, Users, Software, Run and similar), drive roots, the Windows folder and the profile roots are never offered or touched, even if passed in directly.
- Leftovers are exact-name matches; a folder that contains another installed program's install location is skipped.
- Registry keys are exported first; if the export fails, the key is kept.
- Quarantine delete refuses anything outside the quarantine folder or without a manifest.
- MSI uninstall strings are always converted to `/x {product code}`; unparsable or relative commands are not run.

## Tested here (Linux PowerShell 7.4.6, temp folders)
38 checks pass: command parsing, protection lists, path gate, leftover scan (dedupe, protected, shared-folder skip), quarantine move, list, restore (including not overwriting), delete guards, dry run.

## Not tested
Real uninstallers, restore point creation, `reg.exe` export/import, registry-key and Run-value cleanup, HKLM permission cases, the GUI pages, the console page. See docs/TEST-MATRIX.md.

## Remaining risks
- A program's uninstaller can be incomplete, interactive or misbehave; DIVuninstalled cannot control it.
- Exact-name matching can miss leftovers; it can also match a folder that a *different* program happens to share by name. Review each item.
- Per-user vs machine installs: an uninstall entry that points at a missing uninstaller is refused.
- The emergency reset script does not restore the quarantine.
