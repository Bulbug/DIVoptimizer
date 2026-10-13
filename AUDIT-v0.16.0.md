# Audit v0.16.0 (junk cleaner)

## What changed
- New junk cleaner with six categories, quarantine-first, optional permanent delete.

## Safety checks
- Roots are fixed in code; each must be a real folder whose name is a known junk folder name, never a drive root or profile/system root.
- An item must be exactly the root (browser caches) or a direct child of it. Links and junctions are skipped. `..` paths refused.
- Age rule: items changed in the last 24 hours are kept (folders by their newest file). Browser caches are exempt but only run when the browser is closed.
- Every item is re-validated immediately before moving, including the exclude list and the age rule.
- Moves reuse the quarantine manifest format, so the existing Restore, Delete and list code applies. Permanent delete goes through Remove-QuarantineFolder (only a folder directly inside quarantine with a manifest).
- Not touched: Recycle Bin, Downloads, Documents, Desktop, browser history/cookies/passwords. No shredder or evidence-removal tool.

## Verified here (Linux PowerShell 7, temp folders)
- Scripts parse with 0 errors; shared restore core unchanged.
- 27 new checks pass.

## NOT verified (needs Windows)
- Real %TEMP%, Windows\Temp, WER and browser profile layouts; the WPF page; timing on a large temp folder. Pester has never been run. v0.11 to v0.16 are untested on Windows.

## Known gaps
- Moving thousands of small files is slower than a plain delete; listing is capped at 5000 items per category per run.
- Chromium cache layout may differ on future browser versions (those folders are simply not found).
- MEMORY.DMP is not included on purpose.
