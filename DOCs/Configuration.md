# RigShift: configuration reference

This file tracks **what the current PowerShell implementation reads** from `workspaces.json`. For execution order and parameters, see [Orchestrator-Flow.md](Orchestrator-Flow.md).

## JSON surface vs components (audit summary)

| Area | Read by | Notes |
|------|---------|------|
| `_config` keys listed below | Orchestrator, Dashboard (Tab 4), `Interceptor.ps1`, `Generate-Shortcuts.ps1` | Single source for flags and shortcut naming. |
| `Hardware_Definitions` | Orchestrator (`Invoke-HardwareDefinitionTransition`), WorkspaceState (compliance) | Catalog only; not started by name from shortcuts unless wrapped in a mode or override. |
| `System_Modes` | Orchestrator, WorkspaceState, Dashboard, shortcuts | Each mode name becomes a shortcut target. |
| `App_Workloads` | Orchestrator, WorkspaceState, Dashboard, intercept sync, shortcuts | Nested `Domain.WorkloadName`. |
| `comment`, `description` | Mostly ignored; Dashboard may show descriptions where wired | Safe metadata. |

**Not implemented in this repository’s orchestrator:** flat per-profile `services_disable`, `scripts_start` / `scripts_stop`, `reverse_relations`, `protected_processes`, per-workload `power_plan_start` / `power_plan_stop` / `registry_toggles` / `pnp_devices_*`, timer tokens `t 3000` inside service lists, `type: stateful|oneshot`, and `firewall_groups`. Older forks or docs may mention them; they are ignored if present because the code paths do not exist.

**Executables list vs Dashboard compliance:** `Invoke-ExecutionToken` in `Orchestrator.ps1` does **not** treat `#…` comment lines or `t 3000`-style timer tokens specially—if present in `executables`, they are still passed through (and may fail or behave oddly). For **workload Active/Inactive/Mixed** display, `WorkspaceState.ps1` `Get-ExecutableIsRunning` treats tokens matching `^#` or `^t\s+(\d+)$` as not representing a running process. Prefer real `.ps1` sleeps or hardware overrides instead of timer tokens in production JSON.

---

## Top-level layout

```json
{
  "_config": { },
  "Hardware_Definitions": { },
  "System_Modes": { },
  "App_Workloads": { }
}
```

The Orchestrator resolves runnable profiles only from **`System_Modes`** keys and **`App_Workloads`** workload names. Arbitrary top-level objects with `services` / `executables` are **not** invoked unless you move them under `App_Workloads`.

---

## `_config`

All keys are optional unless noted.

| Key | Type | Used by | Behavior |
|-----|------|---------|----------|
| `notifications` | bool | Orchestrator | When `true`, Start/Stop may show toasts (`Workspace Ready` / `Workspace Stopped`). |
| `enable_interceptors` | bool | Orchestrator | When `true`, Phase B syncs IFEO hooks from intercept rules; when `false`, removes managed hooks. |
| `interceptor_poll_max_seconds` | int | `Interceptor.ps1` | Positive integer; default 15. Caps how long the poll helper waits for readiness. |
| `elevation_attribution` | bool | `Interceptor.ps1` | Default `true`. When `true`, the interceptor shows a small auto-dismissing window naming the workload and operation just before any `gsudo` call whose UAC prompt is likely to appear (gsudo credential cache cold). When the cache is warm, no window is shown so the silent fast path is preserved. Set `false` to disable the attribution window entirely. |
| `shortcut_prefix_start` | string | `Generate-Shortcuts.ps1` | Prefix for Start `.lnk` filenames (default `!Start-`). |
| `shortcut_prefix_stop` | string | `Generate-Shortcuts.ps1` | Prefix for Stop `.lnk` filenames (default `!Stop-`). |
| `console_style` | string | `Generate-Shortcuts.ps1`, Dashboard Tab 4 | **Shortcuts:** `Generate-Shortcuts.ps1` sets `-WindowStyle Hidden` on generated `.lnk` files only when the value is exactly `Hidden`; otherwise shortcuts use `Normal`. **Dashboard:** Tab 4 only offers `Normal` and `Compact` for UI density (`Get-DashboardSettingsDefinitions` in `Dashboard.Impl.ps1`). When the dashboard builds settings rows, any value not in that set (including `Hidden`) is **coerced to `Normal`**—so hand-editing `Hidden` for shortcuts will be overwritten if you save settings from the Dashboard without re-adding `Hidden` manually afterward. |
| `disable_startup_logo` | bool | Dashboard | When `true`, skips the ASCII logo printed once before the hardware (PnP) scan at dashboard startup. Default when omitted: show the logo. |

---

## `Hardware_Definitions`

Each property name is a **component id** referenced from `System_Modes.hardware_targets`, `App_Workloads.<Domain>.<Workload>.hardware_targets`, or Dashboard hardware overrides (`-ProfileType Hardware_Override`).

Common properties:

| Property | Purpose |
|----------|---------|
| `description` | Human text; Dashboard / compliance may surface it. |
| `type` | `registry` \| `service` \| `pnp_device` \| `process` \| `stateless` (see Orchestrator switch). |
| `action_override_on` | String array of **execution tokens** run in order with **wait** when turning component **ON** (if present, native branch skipped). |
| `action_override_off` | Same for **OFF**. |
| `post_change_message` | Optional string; Dashboard may show after a commit affecting this node (see `Get-DashboardPostCommitMessages` in `Dashboard.Impl.ps1`). |
| `post_start_message` / `post_stop_message` | Optional; filtered by committed action when messages are collected. |
| `target_state` | Optional `ON` / `OFF` / `ANY` on a definition used with `-ProfileType Hardware_Override`: if present, drives override semantics; if missing, `Start` → `ON` and `Stop` → `OFF`; `ANY` skips apply. See [Orchestrator-Flow.md](Orchestrator-Flow.md). |

### By `type`

**`service`**

- `name`: Windows **service name** (not display name).

**`registry`**

- `path`, `name`: registry path and value name.
- `value_on` / `value_off`: values applied for ON vs OFF.
- `value_type`: optional; passed to `New-ItemProperty` (defaults to `DWord`).

**`pnp_device`**

- `match`: array of friendly-name **wildcards** (e.g. `*Bluetooth*`). Elevated enable/disable per pattern.

**`process`**

- `name`: process file name (e.g. `GCC.exe`). Without overrides, native ON/OFF is a no-op—use `action_override_*` for real work.

**`stateless`**

- No native path without `action_override_*` (used for scripted or `.lnk`-only toggles such as refresh-rate helpers).

---

## `System_Modes`

Each mode is a named profile.

| Property | Purpose |
|----------|---------|
| `description` | Metadata / UI. |
| `power_plan` | String matched against `powercfg /l` when the mode is **Started** (substring match). |
| `hardware_targets` | Object map: **component id** (or `@alias` wildcard shorthand) → `ON`, `OFF`, or `ANY`. `ANY` means “do not enforce this component for compliance in this mode.” |
| `create_shortcut_for` | Optional: `none` \| `start` \| `stop` (case-insensitive) for `Generate-Shortcuts.ps1` only. |
| `post_change_message`, `post_start_message`, `post_stop_message` | Optional Dashboard post-commit messages. |

On **Stop**, hardware target ON/OFF values are **inverted** for transition (ANY unchanged). There is no automatic “revert to previous power plan” unless you encode another mode or hardware action.

---

## `App_Workloads`

Structure: `App_Workloads.<DomainName>.<WorkloadName>`

| Property | Purpose |
|----------|---------|
| `description` | Shown in Dashboard when the row is highlighted. |
| `services` | Array of service **names**; started on Start, stopped on Stop (Orchestrator order: see flow doc). |
| `executables` | Array of **execution tokens** (see below). |
| `hardware_targets` | Optional object map: **component id** (or `@alias`) → `ON`/`OFF`/`ANY`. When a workload is Active, these targets override mode targets during commit planning. |
| `tags` | String array for search and filtering on Tab 1. |
| `priority` | Integer; lower sorts earlier in the Dashboard list. |
| `favorite` | Boolean; `F` filter on Tab 1. |
| `hidden` | Boolean; hidden rows appear only when search matches. |
| `aliases` | Extra strings matched by Tab 1 search. |
| `intercepts` | Optional IFEO rules (see next section). |
| `create_shortcut_for` | Same as for system modes; applies to this workload’s shortcuts. |

**Workload name uniqueness:** The Orchestrator resolves `App_Workload` by **workload name only** across domains. Keep names unique, or the first definition wins. `Generate-Shortcuts.ps1` warns and skips duplicates when building `.lnk` files.

### Hardware target shorthand (`@alias`)

- Keys starting with `@` are shorthand selectors. `@bluetooth` is resolved as wildcard `*bluetooth*` against `Hardware_Definitions` component ids.
- A shorthand key can match one or many components.
- If a shorthand key matches nothing, the dashboard warns before commit and asks for explicit confirmation.
- Expanded app workload hardware targets are applied with higher precedence than system-mode hardware targets for the same component.

---

## Intercepts (`intercepts` on workloads)

Interceptors are synced from JSON when `enable_interceptors` is `true`. Rules may be:

1. **Legacy string** — executable file name (e.g. `"OUTLOOK.EXE"`). Implies default required services/executables from the parent workload.
2. **Object** — supports:
   - `exe`: string or array of strings (exe file names compared case-insensitively to the launched image).
   - `requires`: optional object narrowing what to start (see `Resolve-InterceptedWorkload` in `Interceptor.ps1`):
     - If **`requires` is omitted** on an object rule, required services and executables default to the **full parent workload** lists (same idea as a legacy string rule, but with explicit `exe` matching).
     - If **`requires` is present**, both lists start empty and are filled only from properties that exist:
       - `requires.services` — if the property is **omitted**, **no** services are required for readiness (not the workload default).
       - `requires.executables` — if the property is **omitted**, **no** executables are required for readiness (not the workload default).

IFEO keys are stamped with `RigShift_Managed`, `RigShift_Owner`, `RigShift_InterceptorVersion`, and `RigShift_LastSyncedUtc`. Managed cleanup compares `RigShift_Owner` to the fixed tag **`BG-Services-Orchestrator`** in `Orchestrator.ps1` (forks that change the tag must keep docs and deployed machines consistent).

---

## Execution tokens (`Invoke-ExecutionToken`)

Used for `executables`, hardware `action_override_*`, and anywhere the Orchestrator launches a command.

### Paths with spaces or arguments

- If the path needs single quotes in JSON, use a leading **single-quoted** segment: `"'C:/Program Files/App/app.exe' -arg"` — the engine splits path vs argument list with a regex.
- Paths without spaces may be plain JSON strings: `"C:/Tools/Bin.exe"`.

### Relative paths

- A token may start with `'./` or `'.\` inside the quotes: `"'./CustomScripts/foo.ps1'"`. The segment is expanded to an absolute path rooted at the detected repo root (folder containing `CustomScripts`; if not found, fallback to the folder containing `workspaces.json`) before `Test-Path`, `Start-Process`, or ShellExecute.

### Command-style tokens

- Tokens such as `gsudo taskkill /F /IM Foo.exe` are detected when the first segment has no path-like slashes and is followed by more text; the first word is the file/command, remainder arguments.

### File types

- **`.ps1`:** launched with `pwsh.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File …` (arguments appended when quoted form used).
- **`.lnk` / `.url`:** started with `ProcessStartInfo.UseShellExecute = true` and working directory set to the shortcut’s folder (avoids wildcard issues with `Start-Process` and parentheses in names). Optional arguments are supported when using ShellExecute.
- **Other:** `Start-Process` with or without `-Wait` depending on caller; synchronous hardware overrides use **wait** with a timeout (`ExecutionWaitTimeoutMs`, default 15000 ms) and may kill hung child processes with a warning.

### JSON slashes

Use doubled backslashes or forward slashes in JSON string values.

---

## `Generate-Shortcuts.ps1` behavior

1. Clears existing `*.lnk` in `%APPDATA%\Microsoft\Windows\Start Menu\Programs\RigShift`.
2. Emits one Start and/or Stop shortcut per:
   - each **System_Modes** child name;
   - each **App_Workloads** leaf workload name (across all domains).
3. Shortcut basenames come **only** from those two sections—the script does not scan other top-level JSON keys, so `_config`, `Hardware_Definitions`, and other reserved sections never produce `.lnk` files unless you incorrectly nest them under `System_Modes` or `App_Workloads`.
4. Honors `create_shortcut_for` on each mode or workload object.
5. Shortcut arguments call `pwsh.exe` with `-File Orchestrator.ps1 -WorkspaceName "<Name>" -Action Start|Stop` (no `-ProfileType`; resolution uses Phase C defaults).
6. Each `.lnk` uses `IconLocation` **`Assets\Dashboard.ico`** at the repository root when that file exists; otherwise the PowerShell executable icon. `WorkingDirectory` is set to the `Scripts` folder (same directory as `Orchestrator.ps1`).

Hardware-only components do **not** get shortcuts unless you add a legacy flat object or a dedicated mode.

Example repo-relative automation lives under [Examples/](../Examples/) and [CustomScripts/](../CustomScripts/); reference them from `executables` or `action_override_*` using the `"'./path'"` token form documented above.

---

## Dashboard-only and compliance

Workspace state and compliance rows are computed in `WorkspaceState.ps1` and `Dashboard.Impl.ps1` from the same JSON. If a field is not listed in this document, assume it is **not** interpreted by `Orchestrator.ps1` unless you verify in code.

---

## Further reading

- [Architecture.md](Architecture.md)
- [Orchestrator-Flow.md](Orchestrator-Flow.md)
- [Dashboard.md](Dashboard.md)
- [Windows-Terminal.md](Windows-Terminal.md)
- [Edge-Cases.md](Edge-Cases.md)
- [_schema.md](_schema.md) (hub: readme entry point; this file remains the authoritative spec)
- [Audit.md](Audit.md) (doc ↔ code matrix)
