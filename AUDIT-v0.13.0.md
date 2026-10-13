# Audit v0.13.0 (browser extensions)

## What changed
- Browser extensions page (Chrome, Edge, Brave, Firefox) with read-only listing and quarantine-based removal.
- Startup Manager linked from DIVuninstaller. No second autorun tool was written because one already exists.

## Safety checks
- Listing only reads folders and manifests. Nothing in a browser profile is edited.
- Only an extension's own folder (inside `...\Extensions\<id>`) or a Firefox `.xpi` (inside `Profiles\...\extensions\`) can be moved. Profile folders, the Extensions folder itself, and anything else are refused, and one bad item refuses the whole removal.
- The browser must be closed, otherwise the removal is refused.
- Removal goes through the existing quarantine, so each extension is restorable on its own.

## Verified here (Linux PowerShell 7, fake browser folders)
- All three scripts parse with 0 errors; shared restore core unchanged and identical.
- 19 new checks pass; earlier 59, 49 and 20 still pass (147 total).

## NOT verified (needs Windows)
- Real Chrome/Edge/Brave/Firefox profile layouts on your PC, and how browsers react to a missing extension folder.
- The new page in WPF.
- Pester has still never been run. v0.11, v0.12 and v0.13 are all untested on Windows.

## Known gaps
- Sync- or policy-installed extensions may come back; removing from the browser's own page is the reliable route for those.
- Opera and other Chromium browsers are not scanned. Chrome and Edge extension settings in the browser's preferences are left as they are.
- Firefox legacy or system-wide extensions are not listed.
