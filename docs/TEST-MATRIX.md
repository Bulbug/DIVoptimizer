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
