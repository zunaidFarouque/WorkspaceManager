# Edge cases and mitigation

This document reflects **current** behavior in `Orchestrator.ps1`, `WorkspaceState.ps1`, `Dashboard.Impl.ps1`, and `Interceptor.ps1`.

## 1. Race conditions and ordering

**Services vs apps:** App workloads start **all** services in list order, then launch executables. The orchestrator does **not** implement sleep/timer semantics for `t 3000`-style lines (and they are not special-cased in `Invoke-ExecutionToken`). For **Dashboard** workload state, `WorkspaceState.ps1` treats `#…` and `t N` tokens as not representing a running process—see [Configuration.md](Configuration.md). If a service needs warm-up time, use a hardware-definition `action_override_on` that runs a script or shortcut which waits, or chain a small `.ps1` in `executables` that sleeps before launching the main app.

**Hardware overrides:** `action_override_*` entries run **sequentially** with `Invoke-ExecutionToken -Wait` and a finite wait (`ExecutionWaitTimeoutMs`, default 15 seconds). Hung children may be killed with a warning so the pipeline can continue.

**Interceptors:** `interceptor_poll_max_seconds` in `_config` caps how long `Interceptor.ps1` polls for required services/processes before giving up (default 15). Tune per machine if license services are slow.

## 2. Shared services across workloads

The Dashboard **does not** compute a global dependency graph or merge overlapping `services` arrays across workloads.

`Invoke-WorkspaceCommit` iterates pending UI rows and calls the orchestrator **once per row**, with a short sleep between calls. Stopping workload **A** may stop a service that workload **B** still expects to be running.

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

Shortcuts live under `%APPDATA%\Microsoft\Windows\Start Menu\Programs\WorkspaceManager`. Bulk delete/recreate can confuse indexing briefly.

**Mitigation:** Run `Generate-Shortcuts.ps1` when profiles are stable; allow indexing to catch up before relying on PowerToys Run.

## 7. IFEO and security software

Managed IFEO keys are tagged with `WorkspaceManager_Managed` and `WorkspaceManager_Owner`. **Cleanup only removes hooks whose owner matches the literal `BG-Services-Orchestrator`** string baked into `Orchestrator.ps1`. If you fork the project and change that tag, machines with mixed builds may leave stale or “foreign” managed keys until you align versions and owner values.

Third-party security tools may still flag Debugger-based redirection.

**Mitigation:** Use `enable_interceptors = false` (or Tab 4 / `Reset_Interceptors`) when debugging policy issues.

### Optional escape hatch (advanced)

If environment variable **`WorkspaceManager_InterceptorBypass=1`** is set in the process environment when `Interceptor.ps1` runs, the script launches the target executable immediately without readiness polling or workload activation. Intended for troubleshooting only; not a supported configuration surface in `workspaces.json`.

---

## Related documentation

- [Configuration.md](Configuration.md) — JSON and intercept rules.
- [Orchestrator-Flow.md](Orchestrator-Flow.md) — phases and IFEO sync.
- [Dashboard.md](Dashboard.md) — Tab 4 `Reset_Interceptors`.
- [Architecture.md](Architecture.md) — component overview.
- [_schema.md](_schema.md) — configuration entry point (links to readme).
- [Audit.md](Audit.md) — doc ↔ code matrix.
