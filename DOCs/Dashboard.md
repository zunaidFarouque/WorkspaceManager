# RigShift Dashboard (`Dashboard.ps1`)

The Dashboard is an interactive PowerShell console UI for inspecting compliance, editing `_config`, staging workload and mode changes, and committing them through `Orchestrator.ps1`.

## Dashboard state (`state.json`)

Beside `workspaces.json`, the dashboard persists **`state.json`** in `Scripts\`. Tab 2 (multi-mode) writes **`Active_System_Mode`** there when you set the blueprint (`Set-DashboardActiveBlueprint` in `Dashboard.Impl.ps1`). `WorkspaceState.ps1` reads the same file so mode compliance and workload summaries stay aligned with the chosen active system mode.

## Launch

From the repository root (PowerShell 7):

```powershell
.\Scripts\Run-Dashboard.cmd
```

**Windows PowerShell 5.1:** If you run `Dashboard.ps1` under `powershell.exe`, it detects PowerShell 7 and **re-launches** `Dashboard.Impl.ps1` with `pwsh.exe` in the same console so keyboard input works reliably.

Optional parameters (passed through to `Dashboard.Impl.ps1`):

| Parameter | Purpose |
|-----------|---------|
| `AutoCommitWorkloadName` | Auto-start flow for a named workload (headless bootstrap scenarios). |
| `ObserveWorkloadName` | Observe a workload by name after startup. |
| `ObserveSeconds` | Seconds for observe window (default 10). |

### Desktop shortcut with icon

`Create-DashboardShortcut.ps1` writes a `.lnk` that targets `Scripts\Run-Dashboard.cmd` and uses `Assets\Dashboard.ico` when present. Default shortcut path is the user Desktop (`RigShift Dashboard.lnk`). Override with `-ShortcutPath`.

`Setup.cmd` (repository root) always creates `RigShift Dashboard.lnk` in the project root first, then offers optional Desktop and Start Menu shortcut generation.

For a **custom icon while the dashboard runs** (tab and taskbar under Windows Terminal), add a profile with `icon` pointing at the same `.ico` file—see [Windows-Terminal.md](Windows-Terminal.md).

---

## Tab bar and availability

Tabs are selected with **1**–**4** (or numpad **1**–**4**).

- **Tab 2 (System Modes)** appears only when `System_Modes` contains **more than one** mode (`HasMultipleModes` in `Dashboard.Impl.ps1`). With a single mode, key **2** does nothing and the header shows **Tab 3** as **System Health** instead of **Hardware Compliance**.
- **Tab 3** is always present: either **Hardware Compliance** (multi-mode) or **System Health** (single-mode label only).

Footer hints on each tab summarize keys; **`C`** toggles **CommitMode** between `Exit` and `Return` on every tab. The **`R`** key is reserved for **Queue Restart** on Tab 1 (workload restart) and Tab 3 (hardware restart) — see those tab sections below.

---

## Tab 1 — App Workloads

Grouped profiles (`App_Workloads.<Domain>.<Workload>`) with services and executables.

- **Up / Down:** move selection.
- **Space:** toggle desired state for the selected workload (Active / Inactive / Mixed handling via `Update-DashboardDesiredStateOnSpace`).
- **R:** queue a **Restart** for the selected workload (`Set-DashboardWorkloadDesiredRestart` sets `DesiredState = "Restart"`). On commit the workload is stopped (phases 1-2) and started again (phases 6-7) within the same global sequence; its `hardware_targets` apply on the start side, exactly like a transition to Active.
- **Oem3** (grave accent **\`** on typical US layouts): cycle workload runtime detail mode `None` → `MixedOnly` → `All` → `None` for expandable `svc` / `exe` rows.
- **Search:** the footer shows `[/]Filters`; the handler uses `ConsoleKey.Oem2` (on many US layouts this is the `/` key—layout-dependent). Opens **search** prompt (`Read-DashboardLineWithEscCancel`); Enter applies, Esc cancels.
- **G:** cycle **domain** filter (all domains → each domain → all).
- **F:** toggle **favorites-only** (`favorite = true`).
- **M:** toggle **mixed-only** (rows whose current state is Mixed).

Hidden workloads (`hidden = true`) stay out of the list unless the current search matches name, domain, tags, or aliases.

Large lists use a **windowed renderer** around the cursor; the description line always reflects the **selected** row.

---

## Tab 2 — System Modes (multi-mode only)

Each row is a `System_Modes` entry.

- **Space:** set the **blueprint** — marks the selected mode Active/Inactive in UI and writes `Active_System_Mode` to `state.json` (`Set-DashboardActiveBlueprint`).
- **A:** **queue ideal hardware** — for compliance rows that are non-compliant and not `ANY`, enqueue `Hardware_Override` pending ON/OFF to match the active mode’s `hardware_targets` (`Add-DashboardIdealHardwareToQueue`). Tab 2 **A** never queues `RESTART`; that is a manual user intent on Tab 3.
- **Enter:** commit (see [Commit flow](#commit-flow)).

Footer line 1: `[Space] Set Mode | [A] Queue Ideal States`.
Footer line 2: `[C] CommitMode | [Enter] Commit & <Exit|Return> | [Esc] Cancel`.

---

## Tab 3 — Hardware Compliance / System Health

Shows **compliance rows** from `WorkspaceState` for each `Hardware_Definitions` component vs the active system mode’s `hardware_targets`.

- **Space:** **toggle** a pending hardware override for the selected component (`Toggle-DashboardQueueOverride` cycles ON/OFF in the in-memory queue). Queued rows show `[QUEUED: ON|OFF]` in the presentation helper.
- **R:** queue a **Restart** for the selected hardware component (`Set-DashboardQueueOverrideRestart` writes `RESTART` into the queue). Queued rows then show `[QUEUED: RESTART]`. On commit the component is driven OFF in phase 3 and back ON in phase 5 of the same global sequence — useful for cycling drivers (e.g. Bluetooth, Wi-Fi adapters).
- **Backspace:** **clear** the queue entry for the selected component only (`Clear-DashboardQueueOverride`).

Footer line 1: `[Space] Toggle Override | [R] Queue Restart | [Bksp] Clear Queue`.
Footer line 2: `[C] CommitMode | [Enter] Commit & <Exit|Return> | [Esc] Cancel`.

---

## Tab 4 — Settings and actions

Two regions merged into one navigable list:

### Settings

Rows come from `Get-DashboardSettingsDefinitions`: `console_style`, `enable_interceptors`, `notifications`, `interceptor_poll_max_seconds`, `shortcut_prefix_start`, `shortcut_prefix_stop`.

- **Space:** cycle or toggle the setting (bool / choice).
- **Right arrow:** open string edit prompt where applicable.
- **Left arrow / + / - (Add/Subtract):** adjust numeric `interceptor_poll_max_seconds`.

### Actions

Defined actions come from `Get-DashboardActionDefinitions` in `Dashboard.Impl.ps1`. Currently there is one: **`Reset_Interceptors`**.

- **Enter** arms confirmation (`Confirm: Enter`); **Enter** again on the same row runs the action.
- If settings rows have **pending edits**, actions are blocked until settings are committed or reverted (exclusive flow).

`Reset_Interceptors` forces `enable_interceptors = false` in JSON, re-syncs IFEO hooks through the orchestrator path, and tears down helper processes for `Interceptor.ps1` / `InterceptorPoll.ps1`, only touching keys marked `RigShift_Managed`.

Footer is context-aware by selected Tab 4 row:
- Bool/choice setting: line 1 shows `[Space] Edit Setting`.
- String setting: line 1 adds `[Right] Edit`.
- Int setting (`interceptor_poll_max_seconds`): line 1 adds `[Left/Right or +/-] Poll Seconds`.
- Section row: line 1 shows only tab navigation.
- Action row: line 1 shows only tab navigation (no duplicate Enter hint).

Line 2 behavior:
- Non-action rows: `[C] CommitMode | [Enter] Commit & <Exit|Return> | [Esc] Cancel`.
- Action rows: `[C] CommitMode | [Enter] Confirm/Run Action | [Esc] Cancel`.

---

## Commit flow

When you press **Enter** to commit:

1. Pending **Tab 4 settings** may be written to `workspaces.json` first (`Save-DashboardConfigSettings`).
2. **Interceptor sync pass:** `Invoke-OrchestratorScript` runs once with `-WorkspaceName "__SYNC_ONLY__" -Action Start`. The orchestrator runs Phase B (sync) then fails name resolution; the Dashboard **expects** that failure message and continues. Per-row calls then use `-SkipInterceptorSync`.
3. **Global sequencer plan:** the dashboard builds one operation stack using **explicit user intent only**:
   - **Tab 1:** workload start/stop is always scheduled (phases 1–2 and 6–7). Workload `hardware_targets` run in phases 3/5 **only for workloads that are transitioning to Active or Restart** (start path).
   - **Tab 1 Restart:** a workload with `DesiredState = "Restart"` is scheduled on **both** the stop side (phases 1, 2) **and** the start side (phases 6, 7) within the same commit. Its `hardware_targets` are merged once on the start side, exactly like an Active transition — they are not stop+start cycled themselves.
   - **Tab 2:** a **mode blueprint change** schedules **phase 4 (power plan) only** unless hardware was explicitly queued. It does **not** implicitly apply `System_Modes.hardware_targets`.
   - **Tab 2 `A` / Tab 3:** any non-empty `PendingHardwareChanges` schedules phases 3/5 **only for those queued components** (Tab 2 **A** pre-fills non-compliant rows from the active blueprint). `@alias` expansion applies to workload/mode maps when those maps are consulted; the commit list itself is queue + workload starts. **Precedence on overlap:** `App_Workloads.hardware_targets` (start path) wins over a queued ON/OFF/RESTART for the same component.
   - **Tab 3 RESTART:** a queued `RESTART` value expands into a **phase 3 Stop** and a **phase 5 Start** op for the same component within the same commit (no orchestrator changes — it still receives discrete `Start`/`Stop` calls per `Hardware_Override`).
   - Operations always run in one deterministic seven-phase order (execution buckets only—nothing runs unless it appears in the plan).
4. **Execution log format:** before executing the operations, Dashboard prints intent-grouped sections (for example `STARTING SERVICES`, `STARTING EXECUTABLES`) and concrete bullets using `- Reason: task`. During execution, the same block is live-updated so the current task is highlighted with `->` and completed tasks are marked `OK`. Numeric phase labels are internal sequencing only and are not shown in this user-facing log.
5. **Runtime failure handling:** if an operation throws, Dashboard classifies the failure (`ServiceDisabled`, `NotFound`, `AccessDenied`, `Timeout`, `Unknown`) and resolves it explicitly:
   - baseline actions: `Abort Commit`, `Skip Step`, `Retry Step`
   - service-disabled remediation: `Set StartupType Manual and Retry` (when service context is available)
   - row markers during recovery: failed `XX`, skipped `SK`, aborted `AB`
   - operation summary is printed after the loop (`Done | Skipped | Failed | Aborted`)
6. **Non-interactive policy:** `_config.commit_error_policy` controls deterministic behavior when prompt input is unavailable:
   - `Prompt` (default): prompt in interactive hosts; falls back to `Abort` in non-interactive hosts
   - `Abort`: abort current commit immediately on operation failure
   - `Skip`: skip failed operation and continue sequencer order
7. **Warnings gate:** unresolved `@alias` keys are shown before execution and require explicit keypress confirmation to proceed.
8. **Post-commit messages:** message candidates are derived from sequencer operations (deduped by name/profile/action; `ExecutionScope` does not duplicate messages), then strings from `post_change_message`, `post_start_message`, `post_stop_message` on matching `System_Modes` or `Hardware_Definitions` nodes may print a **REQUIRED ACTIONS** block and wait for a keypress (`Get-DashboardPostCommitMessages`).
9. **CommitMode:** `Exit` exits after commit (with optional wait for messages). `Return` offers “any key to return to dashboard, Esc to exit” (`Resolve-DashboardPostCommitAction`).

---

## Escape and input

- **Esc:** cancel dashboard (clears host, prints `Cancelled.`, exits).
- If `[Console]::KeyAvailable` fails (non-interactive host), the Dashboard prints guidance and exits with code **1**.

---

## Related documentation

- [Configuration.md](Configuration.md) — JSON schema.
- [Orchestrator-Flow.md](Orchestrator-Flow.md) — orchestrator phases including `__SYNC_ONLY__`.
- [Edge-Cases.md](Edge-Cases.md) — operational caveats.
- [Architecture.md](Architecture.md) — components and data flow.
- [_schema.md](_schema.md) — configuration entry point (links to readme).
- [Audit.md](Audit.md) — doc ↔ code matrix.
