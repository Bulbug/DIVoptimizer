# DIVoptimizer v0.8.0 - Tweak inventory

Generated from the catalog in `DIVoptimizer.ps1`. Tier: SAFE = low risk, BALANCED = optional/preference, ADVANCED = never pre-selected.
"Pre-selected" means ticked by default when it is recommended for this PC. Only SAFE + fully reversible + laptop-safe + no conflict qualifies.

| Id | What it does | Category | Tier | Kind | Reversible | Pre-selected | Notes |
|---|---|---|---|---|---|---|---|
| gamemode-on | Enable Game Mode | Gaming | SAFE | Registry | Yes | Yes (if recommended) | |
| gamedvr-off | Disable Game DVR / background recording | Gaming | SAFE | Registry | Yes | Yes (if recommended) | |
| clean-usertemp | Clean user temp files | Cleanup | SAFE | Cleanup | **No** (files deleted) | No | Rollback is not "Full", so never pre-selected by the new rule |
| startup-review | Review startup apps | Startup | SAFE | Info | n/a | No | Information only |
| visual-reduce | Reduce animations and transparency | Performance | BALANCED | Registry | Yes | No | |
| bgapps-off | Block background apps | Performance | BALANCED | Registry | Yes | No | |
| power-performance | Performance power plan | Performance | BALANCED | PowerPlan | Yes | No | Never pre-selected on laptops/tablets |
| power-balanced | Return to Balanced plan | Performance | BALANCED | PowerPlan | Yes | No | |
| hags-on | Hardware GPU scheduling | Gaming | BALANCED | Registry | Yes | No | Restart needed |
| privacy-adid | Turn off advertising ID | Privacy | BALANCED | Registry | Yes | No | |
| privacy-tailored | Turn off tailored experiences | Privacy | BALANCED | Registry | Yes | No | |
| privacy-diag | Limit diagnostic data | Privacy | BALANCED | Registry (HKLM) | Yes | No | Administrator |
| privacy-feedback | Reduce feedback prompts | Privacy | BALANCED | Registry | Yes | No | |
| privacy-websearch | Web results in Start search off | Privacy | BALANCED | Registry | Yes | No | Two variants, chosen by Windows build |
| delivery-opt-off | Delivery Optimization: no peer sharing | Windows Update | ADVANCED | Registry (HKLM) | Yes | No | Administrator |
| hibernate-off | Disable hibernation | Power | ADVANCED | Hibernation | Yes | No | Never pre-selected on laptops/tablets |
| tasks-telemetry | Disable telemetry scheduled tasks | Scheduled Tasks | ADVANCED | Task | Yes | No | Administrator |
| trim-workingset | Temporary working-set trim | Advanced Tools | ADVANCED | Trim | No | No | Temporary effect |

## Services (Advanced Tools; deny-by-default, allow-list of two)

| Service | Tier | Pre-selected | Notes |
|---|---|---|---|
| SysMain | ADVANCED | No | Little effect on SSDs |
| DiagTrack | BALANCED | No | Privacy preference only |

Every other service is protected and cannot be changed, even if requested.

## Other items (not in the tweak catalog)

- Optional Apps: exact package names only, removal is not automatically reversible, protected packages are blocked.
- Startup items: enable/disable per item, backed up before change.
- Cleanup targets: temp, thumbnails, Delivery Optimization cache, Windows Update cache, Recycle Bin (deleted files cannot be restored).
