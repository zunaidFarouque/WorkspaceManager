# Edge cases and mitigation

This document reflects **current** behavior in `Orchestrator.ps1`, `WorkspaceState.ps1`, `Dashboard.Impl.ps1`, and `Interceptor.ps1`.

## 1. Race conditions and ordering

**Global sequencing:** Dashboard commit uses a fixed seven-phase sequencer (stop execs → stop services → stop hardware → power plan → start hardware → start services → start execs). This reduces order drift from per-row commit iteration. **Scope gating:** the planner never expands the **full** mode `hardware_targets` map on commit—only **queued** components (Tab 2 **A** fills non-compliant rows; Tab 3 queues manual toggles) plus workload `hardware_targets` on **start**. A mode-only blueprint change applies **power plan** (phase 4) only. This avoids accidental hardware churn when toggling workloads or when only one device was queued.

**Hardware overrides:** `action_override_*` entries run **sequentially** with `Invoke-ExecutionToken -Wait` and a finite wait (`ExecutionWaitTimeoutMs`, default 15 seconds). Hung children may be killed with a warning so the pipeline can continue.

**Interceptors:** `interceptor_poll_max_seconds` in `_config` caps how long `Interceptor.ps1` polls for required services/processes before giving up (default 15). Tune per machine if license services are slow.

## 2. Shared services across workloads

The Dashboard now computes one global commit plan, but service dependencies are still user-defined. If workload **A** and **B** share mutable services, the final desired workload set determines whether service start/stop phases include those entries.

**Mitigation:** Design workloads so their service sets do not conflict, stop workloads in a safe order manually, or split shared infrastructure into `Hardware_Definitions` / `System_Modes` instead of per-app workload services.

## 3. Stop path and data loss

**App workload Stop** uses `taskkill` on the **executable file name** derived from each token (after path resolution). There is **no** `protected_processes` gate in this codebase—closing workloads from the Dashboard or shortcuts can terminate unsaved work.

**Mitigation:** Only stop workloads when safe; prefer closing applications manually first; use separate test profiles.

## 4. Duplicate workload names

`Resolve-AppWorkloadByName` returns the **first** workload with a matching name across `App_Workloads` domains. Duplicates cause ambiguous shortcuts and headless runs.

**Mitigation:** Keep `WorkloadName` unique across all domains. `Generate-Shortcuts.ps1` warns and skips later duplicates.

## 5. PowerShell / console hosts

The Dashboard requires interactive **console** key input. Remote sessions, piped stdin, or hosts without `KeyAvailable` show an error and exit.

**Mitigation:** Run from Windows Terminal or `pwsh` in a local interactive session; use `Scripts\Run-Dashboard.cmd`, `Setup.cmd`, or `Create-DashboardShortcut.ps1` for a predictable console.

## 6. Windows Search and Start Menu shortcuts

Shortcuts live under `%APPDATA%\Microsoft\Windows\Start Menu\Programs\RigShift`. Bulk delete/recreate can confuse indexing briefly.

**Mitigation:** Run `Generate-Shortcuts.ps1` when profiles are stable; allow indexing to catch up before relying on PowerToys Run.

## 7. IFEO and security software

Managed IFEO keys are tagged with `RigShift_Managed` and `RigShift_Owner`. **Cleanup only removes hooks whose owner matches the literal `BG-Services-Orchestrator`** string baked into `Orchestrator.ps1`. If you fork the project and change that tag, machines with mixed builds may leave stale or “foreign” managed keys until you align versions and owner values.

Third-party security tools may still flag Debugger-based redirection.

**Mitigation:** Use `enable_interceptors = false` (or Tab 4 / `Reset_Interceptors`) when debugging policy issues.

### Optional escape hatch (advanced)

If environment variable **`RigShift_InterceptorBypass=1`** is set in the process environment when `Interceptor.ps1` runs, the script launches the target executable immediately without readiness polling or workload activation. Intended for troubleshooting only; not a supported configuration surface in `workspaces.json`.

### Elevation attribution and gsudo cache

`Interceptor.ps1` invokes `gsudo` for several operations: starting required services, setting Disabled services to Manual, launching `admin:` executables, and toggling the managed IFEO `Debugger` value around the real launch (recursion safety). Some of these may occur even on the "rule already active" path, so a UAC prompt can appear without the main Yes/No/Cancel dialog being shown first. To make the source of that UAC prompt obvious, the interceptor probes `gsudo status --json` before each elevated call:

- `CacheAvailable: true` (warm cache) - no window is shown; gsudo runs silently as before.
- `CacheAvailable: false` (cold cache) - a small top-most window appears in the bottom-right naming the workload and the operation, then gsudo proceeds. The window auto-dismisses after ~2.5s (or sooner once gsudo returns).

Probing adds roughly 50 ms per cold check. Set `_config.elevation_attribution = false` to disable the window entirely. Note that this only attributes elevation; it does not avoid it. Removing UAC prompts on the active-rule path requires a privileged broker (out of scope for this script).

---

## 8. `@alias` wildcard expansion risk

`hardware_targets` supports shorthand keys like `@bluetooth` which expand to wildcard `*bluetooth*` against `Hardware_Definitions` component ids.

- A shorthand can match multiple components, which is intentional.
- If a shorthand matches nothing, dashboard commit raises warnings and asks for explicit confirmation before continuing.

Mitigation: keep component ids explicit and descriptive; review warnings before confirming commit.

## Related documentation

- [Configuration.md](Configuration.md) — JSON and intercept rules.
- [Orchestrator-Flow.md](Orchestrator-Flow.md) — phases and IFEO sync.
- [Dashboard.md](Dashboard.md) — Tab 4 `Reset_Interceptors`.
- [Architecture.md](Architecture.md) — component overview.
- [_schema.md](_schema.md) — configuration entry point (links to readme).
- [Audit.md](Audit.md) — doc ↔ code matrix.
