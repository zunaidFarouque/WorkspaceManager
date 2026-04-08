# WorkspaceManager

**A declarative, bare-metal state management engine for Windows.**

WorkspaceManager is a zero-latency orchestration tool that allows you to define complex software environments (Workspaces) using a single JSON configuration. It guarantees that your machine only runs the exact compute resources—background services and executables—required for your current task, mathematically eliminating configuration drift, DPC latency spikes, and background bloat.

Whether you are configuring a sterile environment for live audio/VJ performance, spinning up local GIS licensing servers, or routing Docker containers, WorkspaceManager ensures your operating system obeys your workflow, not the other way around.

---

## 📖 The Philosophy

Modern Windows applications (like ArcGIS, Cubase, or Adobe CC) deploy persistent background services, telemetry hooks, and update agents that run constantly—even when the application is closed. This causes hardware interrupts, drains battery, and monopolizes the PCIe bus. 

Standard "debloat" scripts are blunt instruments that break core OS functionality. "Game Boosters" are black-box consumer tools that blindly kill random services. 

**WorkspaceManager is a scalpel.** It treats your local machine like a Kubernetes cluster. You declare the exact state you want in a JSON file, and the engine handles the precise sequence of service toggles, UAC elevations, timing delays, and teardowns required to achieve it.

## ✨ Core Features

* **Declarative JSON Architecture:** Define exactly what a Workspace requires (Services, Executables, Timers). The engine handles the execution logic.
* **Race-Condition Immunity:** Inject explicit millisecond delays (`t 3000`) between sequential service starts to ensure background dependencies are fully initialized before GUI applications launch.
* **Zombie Process Handling:** Teardown sequences feature built-in timeouts to catch silently crashed applications and prevent system locks.
* **Protected Processes:** Define critical executables that halt the teardown sequence if detected in RAM, completely preventing accidental data loss.
* **Headless & Dashboard Modes:** Run silently via Start Menu shortcuts (perfect for PowerToys Run), or manage state interactively via the PowerShell TUI Dashboard (`Dashboard.ps1`). In the main list, **Space** toggles desired Start/Stop (for **Mixed** current state, only `Ready`/`Stopped`), and **Backspace** clears pending changes; see [Configuration Schema & Syntax Rules](DOCs/CONFIGURATION.md#11-workspace-type-type).
* **Zero External Dependencies:** Built entirely in native PowerShell 7. No background agents, no electron wrappers, no telemetry.

## 🚀 Prerequisites

WorkspaceManager requires a modern, sterile Windows terminal environment.

1. **Windows 10 / 11**
2. **PowerShell 7+** (`pwsh.exe`)
3. **gsudo** (Linux-style `sudo` for Windows. Highly recommended to install via [Scoop](https://scoop.sh/))

```powershell
# Install gsudo via Scoop
scoop install gsudo
gsudo config CacheMode Auto
````

## 🛠️ Quick Start

**1. Clone the repository:**

```powershell
git clone [https://github.com/yourusername/WorkspaceManager.git](https://github.com/yourusername/WorkspaceManager.git)
cd WorkspaceManager
```

**2. Define your Workspaces:**
Edit the `workspaces.json` file. Follow the strict syntax rules defined in the [Configuration Schema](SCHEMA.md).

```json
{
  "Audio_Production": {
    "services": ["eLicenserSvc", "t 3000", "Audiosrv"],
    "executables": ["'C:/Program Files/Steinberg/Cubase 12/Cubase12.exe' --profile Live"],
    "protected_processes": ["Cubase12"],
    "reverse_relations": ["wuauserv"]
  }
}
```

**3. Generate Shortcuts (Optional):**
If you want to use PowerToys Run or Windows Search for instant, headless orchestration, run the indexer once to generate `!Start-Workspace` and `!Stop-Workspace` shortcuts.

```powershell
.\Generate-Shortcuts.ps1
```

**4. Execute:**
Run the Orchestrator manually, or use your newly created shortcuts.

```powershell
gsudo pwsh -File Orchestrator.ps1 -WorkspaceName "Audio_Production" -Action "Start"
```

## 📚 Documentation

For advanced configuration, edge-case mitigation, and TDD contribution guidelines, please refer to the official documentation:

  * [Configuration Schema & Syntax Rules](SCHEMA.md)
  * [Edge Cases & Mitigation Strategies](https://www.google.com/search?q=EDGE_CASES.md)
  * [Contributing & Testing (Pester)](https://www.google.com/search?q=CONTRIBUTING.md)

## 🛡️ License

Distributed under the MIT License. See `LICENSE` for more information.
