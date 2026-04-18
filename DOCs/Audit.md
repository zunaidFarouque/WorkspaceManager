# DOCs audit matrix (implementation cross-check)

This checklist records **doc claim → source of truth → result** as of the audit pass that refreshed [DOCs](.). Use it when changing `Orchestrator.ps1`, `WorkspaceState.ps1`, `Dashboard.Impl.ps1`, `Interceptor.ps1`, or `Generate-Shortcuts.ps1` so DOCs stay aligned.

Legend: **Pass** = matches code; **Doc updated** = fixed in same change set as this file.

| Doc / section | Claim | Source | Result |
|---------------|-------|--------|--------|
| Architecture — runtime table | Orchestrator / WorkspaceState / Dashboard / Interceptors / Shortcuts roles | respective `.ps1` | Pass |
| Architecture — Interceptor.vbs | IFEO Debugger points at VBS wrapper | `Orchestrator.ps1` (~368) | Pass |
| Architecture — IFEO owner | Docs now name literal owner tag for managed keys | `Orchestrator.ps1` (~338) | Doc updated |
| Configuration.md — `_config` | Keys consumed per component | `Orchestrator.ps1`, `Dashboard.Impl.ps1` `Get-DashboardSettingsDefinitions`, `Interceptor.ps1`, `Generate-Shortcuts.ps1` | Pass |
| Configuration.md — `console_style` | Split: shortcuts only `Hidden`; Dashboard choices `Normal`/`Compact` coerce unknowns | `Generate-Shortcuts.ps1` (~20–23), `Dashboard.Impl.ps1` (~942–946) | Doc updated |
| Configuration.md — Generate-Shortcuts | Only `System_Modes` + `App_Workloads` names; no root-key skip list | `Generate-Shortcuts.ps1` (~100–116) | Doc updated |
| Configuration.md — Generate-Shortcuts icon | `.lnk` uses `Assets\Dashboard.ico` when present; else `pwsh`; `WorkingDirectory` = `Scripts` | `Generate-Shortcuts.ps1` (~46–54, ~140–152) | Pass |
| Configuration.md — Intercepts `requires` | Legacy string = full workload; object + `requires` resets lists; omitted `services`/`executables` properties leave empty arrays | `Interceptor.ps1` `Resolve-InterceptedWorkload` (~113–132) | Doc updated (clarified `services`) |
| Configuration.md — Not implemented list | Timer in orchestrator service path, etc. | `Orchestrator.ps1` | Pass |
| Configuration.md — Tokens / WorkspaceState | `#` and `t N` ignored for “is exe running” only | `WorkspaceState.ps1` `Get-ExecutableIsRunning` (~53–55) | Doc updated |
| Orchestrator-Flow.md — phases A–E | Load, IFEO sync, resolve, execute, pipeline output | `Orchestrator.ps1` | Pass |
| Orchestrator-Flow.md — App Stop order | Reverse executables taskkill, forward Stop-Service | `Orchestrator.ps1` (~525–541) | Pass |
| Orchestrator-Flow.md — Phase labels | Doc uses Phase A–E; script comments say Phase 1 / Phase 3/4 | `Orchestrator.ps1` (~454, ~509) | Doc updated (note) |
| Dashboard.md — tabs / HasMultipleModes | Single mode hides Tab 2 relabel Tab 3 | `Dashboard.Impl.ps1` (~1666, ~1467–1471) | Pass |
| Dashboard.md — blueprint persistence | `state.json` + `Active_System_Mode` | `Dashboard.Impl.ps1` (~1731, ~129–142) | Doc updated |
| Dashboard.md — Tab 4 actions | Only `Reset_Interceptors` in `Get-DashboardActionDefinitions` | `Dashboard.Impl.ps1` (~968–978) | Doc updated |
| Dashboard.md — params | `AutoCommitWorkloadName`, `ObserveWorkloadName`, `ObserveSeconds` | `Dashboard.ps1` (~1–5) | Pass |
| Edge-Cases.md — IFEO | Owner-scoped cleanup + hardcoded tag | `Orchestrator.ps1` (~338–357) | Doc updated |
| Edge-Cases.md — bypass env | Optional `WorkspaceManager_InterceptorBypass` | `Interceptor.ps1` (~549–551) | Doc updated (optional) |

## Tests as contracts

| Area | File |
|------|------|
| Routing, IFEO metadata, Hardware_Override | `Orchestrator.Tests.ps1` |
| Dashboard keys, `__SYNC_ONLY__`, commit | `Dashboard.Tests.ps1` |
| `Active_System_Mode`, WorkspaceState | `WorkspaceState.Tests.ps1` |
| Interceptor behavior | `Interceptor.Tests.ps1` |

When a test and a doc disagree, update the **doc** unless the test documents obsolete behavior.
