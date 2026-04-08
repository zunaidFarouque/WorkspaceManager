# WorkspaceManager: Configuration Schema & Syntax Rules

**WorkspaceManager** is configured entirely via a single `workspaces.json` file. There is no built-in GUI editor for configurations; the tool assumes users are comfortable editing JSON. 

To ensure the orchestration engine parses your environment flawlessly and safely, your JSON file must adhere to the following strict syntax rules.

## The JSON Blueprint

```json
{
  "comment": "Top-level note: this file configures workstation modes.",
  "description": "WorkspaceManager profiles for this machine.",
  "_config": {
    "shortcut_prefix_start": "!Start-",
    "shortcut_prefix_stop": "!Stop-"
  },
  "Audio_Production": {
    "comment": "Live tracking and low-latency profile.",
    "description": "Primary DAW workspace for recording sessions.",
    "type": "stateful",
    "tags": ["Audio", "Live"],
    "power_plan": "High performance",
    "pnp_devices_enable": ["*USB Audio*"],
    "pnp_devices_disable": ["*Bluetooth*"],
    "registry_toggles": [
      { "path": "HKLM:\\SOFTWARE\\Contoso\\Audio", "name": "LowLatency", "value": 1, "type": "DWord" }
    ],
    "services": [
      "eLicenserSvc",
      "t 3000",
      "Audiosrv"
    ],
    "executables": [
      "'C:/Program Files/Steinberg/Cubase 12/Cubase12.exe' --profile Live",
      "C:\\Tools\\AudioMixer.exe"
    ],
    "scripts_start": [
      "'C:/Program Files/My Scripts/start.ps1' -Verb"
    ],
    "scripts_stop": [
      "C:/Program Files/My Scripts/stop.bat"
    ],
    "protected_processes": [
      "Cubase12",
      "AudioMixer"
    ],
    "reverse_relations": [
      "wuauserv"
    ],
    "firewall_groups": [
      "File and Printer Sharing",
      "Core Networking"
    ]
  }
}
```

## Syntax Rules & Constraints

### 1. The Execution String (Paths & Arguments)
Windows file paths often contain spaces, and many applications require command-line arguments. To pass these safely through JSON into the orchestration engine, follow this rule:
* **No Arguments & No Spaces:** Just provide the path. 
  `"C:/Tools/App.exe"`
* **Spaces in Path or Adding Arguments:** You **MUST** wrap the executable path in single quotes (`'`), followed by a space, followed by your arguments. The engine will safely split these before execution.
  *Correct:* `"'C:/Program Files/My App/app.exe' --fullscreen -v"`

### 2. The Slash Rule (`\\` or `/`)
If you copy and paste a file path directly from Windows Explorer, it will contain single backslashes (e.g., `C:\Program Files`). **This will crash the JSON parser.** JSON treats a single backslash as an escape character.
* You must either manually double every backslash: `"C:\\Program Files\\App.exe"`
* Or replace them with forward slashes: `"C:/Program Files/App.exe"`

### 3. Timers (`t [ms]`)
To prevent race conditions (e.g., an application crashing because its required background service hasn't fully spun up yet), you can inject delays directly into the `services` or `executables` arrays. 
* The syntax is strictly the lowercase letter `t`, a single space, and the duration in milliseconds.
* *Example:* `"t 5000"` will halt the pipeline execution for exactly 5 seconds before proceeding to the next item in the array.

### 4. Custom Synchronous Scripts (`scripts_start` / `scripts_stop`)
Use these arrays to run custom synchronous scripts during orchestration.

* **Syntax:** `scripts_start` and `scripts_stop` use the exact same *Execution String* rules as `executables`.
  * No arguments and no spaces: just provide the path. `"C:/Tools/MyScript.bat"`
  * Spaces in the path and/or arguments: wrap the script path in single quotes (`'`), then add a space and the arguments.
    * Correct example: `"'C:/My Script.ps1' -arg1 -v"`
* **Synchronous execution:** the engine pauses (`-Wait`) and waits for each script to finish before moving to the next item.
* **Timers:** you may include timer tokens like `t 3000` in `scripts_start` (it delays like `executables`). If included in `scripts_stop`, timer tokens are ignored/skipped.

### 5. Protected Processes (No Extensions)
The `protected_processes` array acts as a safety net to prevent data loss. If the engine attempts to stop a Workspace and detects one of these processes in RAM, it will halt and ask for user confirmation.
* Enter the raw process name exactly as it appears in Task Manager's "Details" tab.
* **Do NOT include the `.exe` extension.** (Note: The engine will auto-strip `.exe` if accidentally included, but standard practice is to omit it).
* *Correct:* `"WINWORD"` | *Incorrect:* `"WINWORD.exe"`

### 6. True Service Names
When listing background services, you must use the internal **Service Name**, not the "Display Name" shown in the Windows GUI. 
* To find the true name, open `services.msc`, right-click a service -> Properties, and look at the "Service name:" field at the top.
* *Correct:* `"wuauserv"` | *Incorrect:* `"Windows Update"`

### 7. Firewall Groups
The `firewall_groups` array controls Windows Firewall rule groups by exact Display Group name. During Start, the engine enables each group; during Stop, it disables each group.
* Use exact Display Group strings as shown in Windows Defender Firewall with Advanced Security.
* Commands used by the engine:
  * `Enable-NetFirewallRule -DisplayGroup "Name"`
  * `Disable-NetFirewallRule -DisplayGroup "Name"`
* *Example:* `"firewall_groups": ["File and Printer Sharing", "Core Networking"]`

### 8. Global Shortcut Prefixes (`_config`)
You can customize Start Menu shortcut prefixes globally through `_config`.

* `shortcut_prefix_start` controls the prefix used for Start shortcuts.
  * Default: `!Start-`
* `shortcut_prefix_stop` controls the prefix used for Stop shortcuts.
  * Default: `!Stop-`
* Example:
  * `"shortcut_prefix_start": "[BOOT]-"`
  * `"shortcut_prefix_stop": "[HALT]-"`

### 9. Optional Modifier (`?`) For Services And Executables
Prefix a service or executable with `?` to mark it optional.

* Services:
  * `"?warp-svc"`
* Executables:
  * `"?C:/Tools/App.exe"`
  * `"'?C:/Tools/App.exe' -arg"`
* Behavior:
  * If an optional item is missing on the host machine, the engine silently skips it.
  * No prompt and no terminating error are raised for missing optional items.

### 10. Ignored Operator (`#`) For Actionable Arrays
Prefix any actionable string-array item with `#` to fully ignore it at runtime.

* Applies to actionable arrays used by state/orchestration/editor workflows:
  * `services`, `executables`, `scripts_start`, `scripts_stop`, `pnp_devices_enable`, `pnp_devices_disable`, `reverse_relations`, `protected_processes`
* Ignored items are skipped by the engine:
  * no command is executed for that item
  * state math does not count that item
* Dashboard behavior:
  * ignored entries can be toggled on/off from the editor view
  * details view can hide/show ignored entries with `F2`

Example:
* Before: `"pnp_devices_disable": ["*Camera*"]`
* Ignored: `"pnp_devices_disable": ["#*Camera*"]`

### 11. Workspace Type (`type`)
Each workspace may define an optional `type` value.

* Valid values:
  * `"stateful"` (default)
  * `"oneshot"`
* `stateful` workspaces use normal runtime state math (`Ready` / `Stopped` / `Mixed`).
* `oneshot` workspaces are stateless triggers. They do not measure running state and are treated as `Idle` until explicitly run.
  * In Dashboard, oneshot entries are shown as triggerable tasks.
  * In commit flow, oneshot `Run` maps to Orchestrator `Start` only.

**Dashboard TUI (main list):**

* **[Space]** toggles the *desired* outcome for commit. For stateful workspaces, desired maps to Orchestrator **Start** when `Ready` and **Stop** when `Stopped`.
* When **current** state is **Mixed**, [Space] only flips the desired target between `Ready` and `Stopped` (push toward full up or full down). The first press from `Mixed` / `Mixed` sets desired to `Ready`.
* **[Backspace]** clears a pending desired change: desired is reset to **current** for stateful workspaces, or to `Idle` for oneshot (clears a queued **Run**). Those rows then contribute no delta on **Commit**.

### 12. Workspace Tags (`tags`)
Each workspace may define an optional `tags` array for Dashboard categorization tabs.

* Example:
  * `"tags": ["Live", "Audio"]`
* Tags are used for tab filtering in the Dashboard UI (for example: `All`, `Live`, `Audio`).

### 13. Hardware, Power, and Registry Desired State
These keys let a workspace enforce host-level desired state.

* `pnp_devices_enable`: array of FriendlyName patterns (wildcards supported). Matching devices must be enabled.
  * Example: `"pnp_devices_enable": ["*USB Audio*"]`
* `pnp_devices_disable`: array of FriendlyName patterns (wildcards supported). Matching devices must be disabled.
  * Example: `"pnp_devices_disable": ["*Bluetooth*"]`
* `power_plan`: exact friendly name of the power plan that must be active.
  * Example: `"power_plan": "High performance"`
* `registry_toggles`: array of objects in this format:
  * `{"path":"HKLM:\\...","name":"KeyName","value":1,"type":"DWord"}`

Stop behavior note:
* `power_plan` and `registry_toggles` are not automatically reverted on Stop.
* Use a dedicated Recovery workspace if you need reversible profile behavior.

### 14. Metadata Keys (`comment` and `description`)
To support human-readable notes inside strict JSON, metadata keys are allowed.

* `comment`: free-text note used as inline JSON comment replacement.
* `description`: free-text workspace/config description (reserved for richer terminal UI usage in the future).
* These keys are allowed at top-level and inside workspace/config objects.
* For current runtime behavior, both keys are metadata-only and do not change Start/Stop/state logic.
