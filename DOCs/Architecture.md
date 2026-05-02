# RigShift: Architecture and Nomenclature

RigShift is a declarative Windows state tool. You describe **what should be true** on the machine—services, apps, power plan, registry, PnP devices, and optional launch interception—in `workspaces.json`. The **Orchestrator** applies changes; the **Dashboard** inspects state and batches commits; **Interceptors** optionally prime workloads before selected executables run.

**Naming:** User-facing strings (toasts, window titles, Start Menu folder) use **RigShift**. Managed IFEO registry values include `RigShift_Owner`, which is set to the fixed literal **`BG-Services-Orchestrator`** in `Orchestrator.ps1` so cleanup only touches hooks owned by this deployment (see [Edge-Cases.md](Edge-Cases.md)).

The full JSON contract lives in [Configuration.md](Configuration.md). For the readme's collapsible cross-link index, start from [_schema.md](_schema.md).

## 1. Configuration layout (`workspaces.json`)

The file is one JSON object with reserved top-level sections:

| Section | Role |
|---------|------|
| `_config` | Global flags: notifications, interceptor toggle, poll cap, shortcut prefixes, dashboard console style. Consumed by Orchestrator, Dashboard, shortcut generator, and Interceptor scripts. |
| `Hardware_Definitions` | **Catalog** of named hardware or host components (registry, service, PnP device, process, or stateless). Each entry defines how to drive that component **ON** or **OFF**, often via `action_override_on` / `action_override_off` execution tokens. |
| `System_Modes` | **Profiles** that combine a **power plan** and a **hardware map** (`hardware_targets`): per component desired `ON`, `OFF`, or `ANY`. |
| `App_Workloads` | **Nested** `Domain.WorkloadName` objects with `services`, `executables`, optional `hardware_targets`, metadata (`description`, `tags`, `priority`, `favorite`, `hidden`, `aliases`), and optional `intercepts` for IFEO hooks. |

Optional metadata keys at the root or inside objects (`comment`, `description`) are ignored by the engine except where the Dashboard displays human text.

## 2. Runtime components

| Component | Script(s) | Responsibility |
|-----------|-----------|------------------|
| Orchestrator | `Orchestrator.ps1` | Load JSON; sync IFEO interceptors when enabled; resolve **profile type**; run Start or Stop for `App_Workload`, `System_Mode`, or `Hardware_Override`. |
| Workspace state | `WorkspaceState.ps1` | Compute physical state (services, PnP, registry, processes, refresh-rate heuristics) and compliance rows for the Dashboard. |
| Dashboard | `Dashboard.ps1`, `Dashboard.Impl.ps1` | Four-tab TUI: workloads, system modes (when more than one mode exists), hardware compliance / overrides, settings and actions. Commits build one **scope-gated** global sequencer plan (mode hardware only after Tab 2 **A** or Tab 3 queue; workload `hardware_targets` on start path) and call Orchestrator with phase-specific `ExecutionScope`. |
| Interceptors | `Interceptor.ps1`, `InterceptorPoll.ps1`, `Interceptor.vbs` | When enabled, IFEO **Debugger** entries under `HKLM\...\Image File Execution Options` launch the wrapper; poll script brings up required services/executables before the real executable runs. |
| Shortcuts | `Generate-Shortcuts.ps1` | Writes Start Menu `.lnk` files that invoke `pwsh` + `Orchestrator.ps1` for each **System Mode** name and each **App Workload** name (see [Configuration.md](Configuration.md)). Icons use `Assets\Dashboard.ico` when present. |
| Dashboard launch | `Scripts\Run-Dashboard.cmd`, `Create-DashboardShortcut.ps1`, `Setup.cmd` | `Scripts\Run-Dashboard.cmd` changes to the repo root and runs `Dashboard.ps1` under `pwsh`. `Create-DashboardShortcut.ps1` creates a `.lnk` to that cmd file with optional `Assets\Dashboard.ico`. `Setup.cmd` creates a repo-root dashboard shortcut and optionally Desktop + Start Menu shortcuts. Optional Windows Terminal branding: [Windows-Terminal.md](Windows-Terminal.md). |

## 3. States in the Dashboard

The UI uses **Active** / **Inactive** / **Mixed** for workloads and modes, and **ON** / **OFF** / **ANY** for hardware targets inside the active system mode. “Mixed” means measured state does not match the declared workload or mode.

Workloads also accept a transient **Restart** desired state (Tab 1 `R`); hardware compliance rows accept a transient **RESTART** queue value (Tab 3 `R`). Both expand into a stop-then-start pair within the same 7-phase commit (see §4) — no orchestrator changes are required because the planner just emits the same target on both the stop side and the start side. Restart is a Dashboard-only intent and is never persisted to `workspaces.json`.

Colors and symbols in the TUI follow the implementation in `Dashboard.Impl.ps1` (for example compliance ✓ vs violation vs queued override; `Restart` renders Cyan, `[QUEUED: RESTART]` renders Yellow).

## 4. Orchestration model (high level)

- **App workload:** Start = start each listed service, then launch each executable token; Stop = kill processes by executable leaf name (reverse order), then stop services. No merge of duplicate service names across workloads at commit time—operators should avoid conflicting profiles.
- **System mode:** Start = set `power_plan` if present, then apply `hardware_targets`; Stop = invert ON/OFF targets (ANY unchanged) and apply.
- **Hardware override:** A single component from `Hardware_Definitions` is driven to ON or OFF (used when the Dashboard queues per-component overrides with `-ProfileType Hardware_Override`).

Dashboard commit planning resolves hardware only from **explicit intent** (Tab 2 **A** / Tab 3 queue entries and/or workload starts). It does **not** apply the full `System_Modes.hardware_targets` map on commit unless those components were queued (Tab 2 **A** adds non-compliant rows explicitly). Overlapping keys use:

`App_Workloads.hardware_targets` (start path) > queued Tab 2/3 overrides > implicit `ANY`.

Use `Resolve-DashboardEffectiveHardwareTargets -IncludeSystemModeHardware` when you need an analytical merge of mode + workload + queue (for example in tests); the live commit planner keeps mode maps out of implicit execution.

Then executes phases:

1) stop executables, 2) stop services, 3) stop hardware, 4) power plan, 5) start hardware, 6) start services, 7) start executables.

Detailed ordering, parameters, and the `__SYNC_ONLY__` interceptor-only sync trick are documented in [Orchestrator-Flow.md](Orchestrator-Flow.md).

## 5. Example shape (abbreviated)

```json
{
  "_config": {
    "notifications": true,
    "enable_interceptors": true,
    "interceptor_poll_max_seconds": 15,
    "shortcut_prefix_start": "!Start-",
    "shortcut_prefix_stop": "!Stop-"
  },
  "Hardware_Definitions": {
    "Example_Service": {
      "description": "Example",
      "type": "service",
      "name": "wuauserv"
    }
  },
  "System_Modes": {
    "Example_Mode": {
      "description": "Example",
      "power_plan": "Balanced",
      "hardware_targets": {
        "Example_Service": "ON"
      }
    }
  },
  "App_Workloads": {
    "Dev": {
      "MyTool": {
        "description": "Tooling",
        "services": ["SomeSvc"],
        "executables": ["C:/Tools/MyTool.exe"],
        "tags": ["dev"],
        "priority": 10,
        "favorite": false,
        "hidden": false,
        "aliases": [],
        "hardware_targets": {
          "@bluetooth": "OFF"
        }
      }
    }
  }
}
```

Field-by-field rules, execution tokens, and IFEO intercept schema are in [Configuration.md](Configuration.md). Operational caveats: [Edge-Cases.md](Edge-Cases.md). Doc ↔ code matrix: [Audit.md](Audit.md).
