# WorkspaceManager: Architecture and Nomenclature

WorkspaceManager is a declarative Windows state tool. You describe **what should be true** on the machine—services, apps, power plan, registry, PnP devices, and optional launch interception—in `workspaces.json`. The **Orchestrator** applies changes; the **Dashboard** inspects state and batches commits; **Interceptors** optionally prime workloads before selected executables run.

**Naming:** User-facing strings (toasts, window titles, Start Menu folder) use **WorkspaceManager**. Managed IFEO registry values include `WorkspaceManager_Owner`, which is set to the fixed literal **`BG-Services-Orchestrator`** in `Orchestrator.ps1` so cleanup only touches hooks owned by this deployment (see [Edge-Cases.md](Edge-Cases.md)).

The full JSON contract lives in [Configuration.md](Configuration.md). For the readme's collapsible cross-link index, start from [_schema.md](_schema.md).

## 1. Configuration layout (`workspaces.json`)

The file is one JSON object with reserved top-level sections:

| Section | Role |
|---------|------|
| `_config` | Global flags: notifications, interceptor toggle, poll cap, shortcut prefixes, dashboard console style. Consumed by Orchestrator, Dashboard, shortcut generator, and Interceptor scripts. |
| `Hardware_Definitions` | **Catalog** of named hardware or host components (registry, service, PnP device, process, or stateless). Each entry defines how to drive that component **ON** or **OFF**, often via `action_override_on` / `action_override_off` execution tokens. |
| `System_Modes` | **Profiles** that combine a **power plan** and a **target map**: for each component name, desired `ON`, `OFF`, or `ANY` (no enforcement) while that mode is active. |
| `App_Workloads` | **Nested** `Domain.WorkloadName` objects with `services`, `executables`, optional UI metadata (`description`, `tags`, `priority`, `favorite`, `hidden`, `aliases`), and optional `intercepts` for IFEO-based launch hooks. |

Optional metadata keys at the root or inside objects (`comment`, `description`) are ignored by the engine except where the Dashboard displays human text.

## 2. Runtime components

| Component | Script(s) | Responsibility |
|-----------|-----------|------------------|
| Orchestrator | `Orchestrator.ps1` | Load JSON; sync IFEO interceptors when enabled; resolve **profile type**; run Start or Stop for `App_Workload`, `System_Mode`, or `Hardware_Override`. |
| Workspace state | `WorkspaceState.ps1` | Compute physical state (services, PnP, registry, processes, refresh-rate heuristics) and compliance rows for the Dashboard. |
| Dashboard | `Dashboard.ps1`, `Dashboard.Impl.ps1` | Four-tab TUI: workloads, system modes (when more than one mode exists), hardware compliance / overrides, settings and actions. Commits call the Orchestrator with optional `-ProfileType`. |
| Interceptors | `Interceptor.ps1`, `InterceptorPoll.ps1`, `Interceptor.vbs` | When enabled, IFEO **Debugger** entries under `HKLM\...\Image File Execution Options` launch the wrapper; poll script brings up required services/executables before the real executable runs. |
| Shortcuts | `Generate-Shortcuts.ps1` | Writes Start Menu `.lnk` files that invoke `pwsh` + `Orchestrator.ps1` for each **System Mode** name and each **App Workload** name (see [Configuration.md](Configuration.md)). Icons use `Assets\Dashboard.ico` when present. |
| Dashboard launch | `Scripts\Run-Dashboard.cmd`, `Create-DashboardShortcut.ps1`, `Setup.cmd` | `Scripts\Run-Dashboard.cmd` changes to the repo root and runs `Dashboard.ps1` under `pwsh`. `Create-DashboardShortcut.ps1` creates a `.lnk` to that cmd file with optional `Assets\Dashboard.ico`. `Setup.cmd` creates a repo-root dashboard shortcut and optionally Desktop + Start Menu shortcuts. Optional Windows Terminal branding: [Windows-Terminal.md](Windows-Terminal.md). |

## 3. States in the Dashboard

The UI uses **Active** / **Inactive** / **Mixed** for workloads and modes, and **ON** / **OFF** / **ANY** for hardware targets inside the active system mode. “Mixed” means measured state does not match the declared workload or mode.

Colors and symbols in the TUI follow the implementation in `Dashboard.Impl.ps1` (for example compliance ✓ vs violation vs queued override).

## 4. Orchestration model (high level)

- **App workload:** Start = start each listed service, then launch each executable token; Stop = kill processes by executable leaf name (reverse order), then stop services. No merge of duplicate service names across workloads at commit time—operators should avoid conflicting profiles.
- **System mode:** Start = set `power_plan` if present, then for each target set each `Hardware_Definitions` component to the target’s ON/OFF/ANY semantics; Stop = invert ON/OFF targets (ANY unchanged) and apply.
- **Hardware override:** A single component from `Hardware_Definitions` is driven to ON or OFF (used when the Dashboard queues per-component overrides with `-ProfileType Hardware_Override`).

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
      "targets": {
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
        "aliases": []
      }
    }
  }
}
```

Field-by-field rules, execution tokens, and IFEO intercept schema are in [Configuration.md](Configuration.md). Operational caveats: [Edge-Cases.md](Edge-Cases.md). Doc ↔ code matrix: [Audit.md](Audit.md).
