# Orchestrator execution flow

This document matches `Orchestrator.ps1` as shipped. Parameters and order matter for shortcuts, Dashboard commits, and tests.

## Parameters

| Parameter | Required | Purpose |
|-----------|----------|---------|
| `WorkspaceName` | Yes | Mode name (`System_Modes`), workload name (`App_Workloads`, matched across domains), hardware component name (`Hardware_Definitions` when using `Hardware_Override`), or the sentinel `__SYNC_ONLY__` (see below). |
| `Action` | Yes | `Start` or `Stop`. |
| `ProfileType` | No | If set: `App_Workload`, `System_Mode`, or `Hardware_Override`. Forces which branch resolves `WorkspaceName`. |
| `SkipInterceptorSync` | No | Switch. When present, skips the IFEO interceptor sync block (used when the Dashboard has already performed a sync pass). |

## Phase A — Load and parse

1. Resolve `workspaces.json` next to `Scripts\Orchestrator.ps1` (wrapper `Orchestrator.ps1` calls into `Scripts\Orchestrator.ps1`). Missing file → fatal error.
2. Read UTF-8 JSON with `ConvertFrom-Json`. Parse failure → fatal error with exception text.
3. Read `_config` if present:
   - `notifications` → boolean: when `$true`, successful Start/Stop may show a Windows toast (best effort).
   - `enable_interceptors` → boolean: when `$true`, Phase B installs or refreshes managed IFEO hooks from `App_Workloads` intercept rules.

**Note:** `Orchestrator.ps1` comments label routing as “Phase 1” and execution as “Phase 3/4”; this document’s Phase A–E labels map to the same blocks in reading order.

## Phase B — Interceptor sync (unless skipped)

If `-SkipInterceptorSync` is **not** set:

- When `enable_interceptors` is `$false`, managed keys under `HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options` that carry `WorkspaceManager_Managed = 1` and matching `WorkspaceManager_Owner` equal to **`BG-Services-Orchestrator`** are cleaned (Debugger and WorkspaceManager metadata removed). Keys owned by another tag are left intact.
- When `enable_interceptors` is `$true`, hooks are written for each intercept rule on each app workload (see [Configuration.md](Configuration.md) intercepts section). A small `Scripts\Interceptor.vbs` wrapper path is stored in the Debugger value.

Console prints a one-line summary of adds or removals.

## Phase C — Resolve profile type and payload

If `ProfileType` is provided:

- `Hardware_Override` → `WorkspaceName` must be a key under `Hardware_Definitions`. Payload is that definition object.
- `System_Mode` → `WorkspaceName` must be a key under `System_Modes`. Payload is that mode object.
- `App_Workload` → `WorkspaceName` must match a workload **name** under any `App_Workloads.<Domain>`. First match wins if names collide across domains (avoid duplicates).

If `ProfileType` is omitted:

1. If `WorkspaceName` exists under `System_Modes`, treat as **System_Mode**.
2. Else resolve `WorkspaceName` against `App_Workloads` (flatten domains). If found, treat as **App_Workload**.
3. Else throw: workspace not defined.

**Sentinel `__SYNC_ONLY__`:** Not stored in JSON. The Dashboard calls `Orchestrator.ps1` with this name and `Action Start` to run **Phase B only**; name resolution then fails by design. The Dashboard catches the expected “not defined” message and continues. This yields one interceptor sync per commit without duplicating hook writes for each row.

## Phase D — Execute by profile type

### D1 — `App_Workload`

**Start**

1. For each non-empty string in `services` (in order): `gsudo Start-Service -Name …` (errors suppressed on stderr).
2. For each non-empty `executables` token (in order): `Invoke-ExecutionToken` without wait (see [Configuration.md](Configuration.md) for token rules).
3. Optional toast: workspace ready.

**Stop**

1. Reverse `executables`. Resolve path; take file leaf; `gsudo taskkill /F /IM <leaf> /T` (best effort).
2. For each `services` in **original** order: `gsudo Stop-Service -Force` (not reverse of the legacy doc—current code stops in forward order after kills).
3. Optional toast: workspace stopped.

### D2 — `System_Mode`

**Start**

1. If `power_plan` is a non-empty string: `Set-PowerPlanByName` (substring match against `powercfg /l` output).
2. For each property in `targets` (component name → `ON` / `OFF` / `ANY`):
   - `ANY` → skip.
   - Else load `Hardware_Definitions.<ComponentName>` if present and call `Invoke-HardwareDefinitionTransition` with desired `ON` or `OFF`.

**Stop**

- For each target, desired flips: `ON` becomes `OFF` and `OFF` becomes `ON` for transition purposes; `ANY` still skipped.
- Power plan is **not** automatically reverted on Stop unless you model that via targets and definitions.

Toasts may fire on Start/Stop when notifications are enabled.

### D3 — `Hardware_Override`

- Reads optional `target_state` on the definition: if missing, maps `Start` → `ON`, `Stop` → `OFF`. If `ANY`, returns without applying.
- Invokes `Invoke-HardwareDefinitionTransition` for that single definition.

### Hardware definition transitions (shared helper)

Order of precedence when driving a component:

1. If `action_override_on` / `action_override_off` string arrays exist for the requested side, each non-empty entry is run via `Invoke-ExecutionToken -Wait` (scripts, `.lnk`, `.url`, and other paths use the same resolver as workloads).
2. Else by `type`:
   - `pnp_device` — `match` patterns: elevated `Enable-PnpDevice` / `Disable-PnpDevice` per pattern.
   - `service` — elevated `Start-Service` / `Stop-Service` for `name`.
   - `registry` — elevated `New-ItemProperty` with `value_on` / `value_off` and optional `value_type` (default `DWord`).
   - `process` / `stateless` — no native path without overrides.

## Phase E — Script output

The orchestrator emits the resolved profile **object** to the pipeline at the end (tests and tooling may capture it). Normal interactive use may ignore it.

## Related reading

- [Architecture.md](Architecture.md) — mental model.
- [Configuration.md](Configuration.md) — JSON schema and execution tokens.
- [Dashboard.md](Dashboard.md) — interactive console UI.
- [Edge-Cases.md](Edge-Cases.md) — operational caveats.
- [_schema.md](_schema.md) — entry point into configuration reference (links to readme).
- [Audit.md](Audit.md) — doc ↔ code matrix.
- Pester: `Orchestrator.Tests.ps1` encodes routing and interceptor ownership behavior.
