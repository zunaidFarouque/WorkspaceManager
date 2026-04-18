# WorkspaceManager Dashboard (`Dashboard.ps1`)

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

`Create-DashboardShortcut.ps1` writes a `.lnk` that targets `Scripts\Run-Dashboard.cmd` and uses `Assets\Dashboard.ico` when present. Default shortcut path is the user Desktop (`Workspace Manager Dashboard.lnk`). Override with `-ShortcutPath`.

`Setup.cmd` (repository root) always creates `Workspace Manager Dashboard.lnk` in the project root first, then offers optional Desktop and Start Menu shortcut generation.

For a **custom icon while the dashboard runs** (tab and taskbar under Windows Terminal), add a profile with `icon` pointing at the same `.ico` file—see [Windows-Terminal.md](Windows-Terminal.md).

---

## Tab bar and availability

Tabs are selected with **1**–**4** (or numpad **1**–**4**).

- **Tab 2 (System Modes)** appears only when `System_Modes` contains **more than one** mode (`HasMultipleModes` in `Dashboard.Impl.ps1`). With a single mode, key **2** does nothing and the header shows **Tab 3** as **System Health** instead of **Hardware Compliance**.
- **Tab 3** is always present: either **Hardware Compliance** (multi-mode) or **System Health** (single-mode label only).

Footer hints on each tab summarize keys; **`R`** toggles **CommitMode** between `Exit` and `Return` on every tab.

---

## Tab 1 — App Workloads

Grouped profiles (`App_Workloads.<Domain>.<Workload>`) with services and executables.

- **Up / Down:** move selection.
- **Space:** toggle desired state for the selected workload (Active / Inactive / Mixed handling via `Update-DashboardDesiredStateOnSpace`).
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
- **A:** **queue ideal hardware** — for compliance rows that are non-compliant and not `ANY`, enqueue `Hardware_Override` pending ON/OFF to match the active mode’s targets (`Add-DashboardIdealHardwareToQueue`).
- **Enter:** commit (see [Commit flow](#commit-flow)).

Footer: `[Space] Set Blueprint | [A] Queue Ideal States | [Enter] Commit`.

---

## Tab 3 — Hardware Compliance / System Health

Shows **compliance rows** from `WorkspaceState` for each `Hardware_Definitions` component vs the active system mode’s `targets`.

- **Space:** **toggle** a pending hardware override for the selected component (`Toggle-DashboardQueueOverride` cycles ON/OFF in the in-memory queue). Queued rows show `[QUEUED: ON|OFF]` in the presentation helper.
- **Backspace:** **clear** the queue entry for the selected component only (`Clear-DashboardQueueOverride`).

Footer (multi-mode): `[Space] Toggle Override | [Bksp] Clear Queue | [Enter] Commit`.

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

`Reset_Interceptors` forces `enable_interceptors = false` in JSON, re-syncs IFEO hooks through the orchestrator path, and tears down helper processes for `Interceptor.ps1` / `InterceptorPoll.ps1`, only touching keys marked `WorkspaceManager_Managed`.

Footer: `[Space] Edit Setting | [Right] Edit | [Left or +/-] Poll Seconds | [Enter] Commit/Confirm Action | Actions are exclusive`.

---

## Commit flow

When you press **Enter** to commit:

1. Pending **Tab 4 settings** may be written to `workspaces.json` first (`Save-DashboardConfigSettings`).
2. **Interceptor sync pass:** `Invoke-OrchestratorScript` runs once with `-WorkspaceName "__SYNC_ONLY__" -Action Start`. The orchestrator runs Phase B (sync) then fails name resolution; the Dashboard **expects** that failure message and continues. Per-row calls then use `-SkipInterceptorSync`.
3. **Profile rows:** `Invoke-WorkspaceCommit` walks pending workload/mode/hardware states; for each row whose desired ≠ current and desired ≠ Mixed, it logs and calls `Orchestrator.ps1` with `ProfileType` when the row carries it (hardware overrides use `Hardware_Override`). A **1 second** sleep runs between invocations.
4. **Post-commit messages:** strings from `post_change_message`, `post_start_message`, `post_stop_message` on matching `System_Modes` or `Hardware_Definitions` nodes may print a **REQUIRED ACTIONS** block and wait for a keypress (`Get-DashboardPostCommitMessages`).
5. **CommitMode:** `Exit` exits after commit (with optional wait for messages). `Return` offers “any key to return to dashboard, Esc to exit” (`Resolve-DashboardPostCommitAction`).

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
