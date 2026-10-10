# DIVoptimizer v0.8.0 - Audit report

DIVoptimizer is a conservative utility. It is **not risk-free**, and it is **not verified** against WinUtil or any Windows build. It does not guarantee FPS increases, lower latency, lower temperatures, or faster Windows performance.

## Removed
- Twelve services from the Advanced Tools catalog: WSearch, dmwappushservice, MapsBroker, RetailDemo, Fax, XblAuthManager, XblGameSave, XboxNetApiSvc, XboxGipSvc, WerSvc, TabletInputService, PhoneSvc (the app can no longer change any of them).
- Timestamp-plus-counter backup IDs for new backups (old IDs still restore).

## Kept (unchanged from v0.7.0)
Scan, recommend, preview (current to new), backup, approve, apply, verify, log, restore flow; JSON backups with SHA-256; atomic batch rollback; Optional Apps with exact package names; update check; emergency reset script; `-Scan`, `-WhatIf`, `-Console`, `-Quick`, `-Report`; `irm | iex` remote run with UAC relaunch.

## Moved to Advanced / BALANCED
Tiers are derived from the existing risk level: LOW RISK = SAFE, OPTIONAL = BALANCED, ADVANCED = ADVANCED. DiagTrack stays BALANCED, SysMain ADVANCED. No tweak was reclassified by hand.

## New safety features
- Deny-by-default services: only DiagTrack and SysMain can be changed.
- Pre-selection rule: SAFE tier, fully reversible, laptop-safe, no conflict, not information-only.
- Laptop/tablet protection: power-performance and hibernate-off are never pre-selected.
- Conflict check: settings already changed by another tool to a different value are flagged and not pre-selected.
- `-Health` (read-only self-check) and `-Undo` (restore newest verified backup, asks first).
- Plain-text log next to the JSON log.

## WinUtil compatibility features
Designed for compatibility, not verified: already-configured settings are skipped, differing values are reported as conflicts, and DIVoptimizer never silently overwrites them. A standalone `compatibility.json` rules file was **not** built; the rules are inside the script.

## Protected components
Defender, Windows Update, networking/RPC/core services (do-not-touch list), every service outside the allow-list, Store/runtime/shell packages, protected registry areas and cleanup paths.

## Backup and rollback changes
New ID format `backup-yyyy-MM-dd-HHmmss-XXXX`. `-Undo` skips backups that fail verification. Cleanup deletions, app removal and working-set trim remain not automatically reversible, and the app says so.

## Laptop protections
See above. The laptop check uses chassis type; a mis-reported chassis would defeat it.

## Remaining risks
- **Nothing has been run on Windows.** Runtime errors are likely; earlier ones were found only when you ran it.
- Pester tests have not been executed.
- A tweak can still have side effects on unusual hardware or managed PCs.
- Conflict detection covers registry and power-plan tweaks only, not services, tasks or apps.
- `irm | iex` runs whatever is at the URL; pin a reviewed version if that matters to you.
- Registry settings other tools or Windows updates change later are not tracked.

## Files changed
DIVoptimizer.ps1, DIVoptimizer-Reset.ps1 (version only), tests/DIVoptimizer.Tests.ps1, README.md, CHANGELOG.md, docs/TWEAK-INVENTORY.md, docs/TEST-MATRIX.md, website/index.html.

## Tests performed
Static only: delimiter balance (parentheses were off by two before and after, from text in strings), ASCII-only source, shared restore core byte-identical in both scripts.

## Test results
No dynamic test results exist. See docs/TEST-MATRIX.md; every row is "not run".
