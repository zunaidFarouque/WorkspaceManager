# WorkspaceManager: Architecture & Nomenclature

**WorkspaceManager** is a declarative, bare-metal state management engine for Windows. It allows users to orchestrate complex software environments (background services, executables, and system states) using a single JSON configuration file. It ensures your machine is only running the exact compute resources needed for the current task, eliminating configuration drift and background bloat.

## 1. Core Terminology

### The Grouping
* **Workspace**: The logical grouping of all services, executables, and rules required for a specific environment (e.g., `ArcGIS Workspace`, `Audio Production Workspace`, `Gaming Workspace`).

### The States
Workspaces exist in one of three mathematical states, visually represented in the upcoming Dashboard TUI:
* **Ready (Red 🔴)**: The Workspace is fully active. All required services and executables are running. *(Note: Red signifies "Active/In-Use/Do Not Disturb").*
* **Stopped (Green 🟢)**: The Workspace is completely dormant. Zero background footprint. *(Note: Green signifies "Safe/Clear/Available").*
* **Mixed (Yellow 🟡)**: Configuration drift detected. The Workspace is partially running or an error occurred during state transition.

## 2. Workspace Components

Each Workspace is defined by its required components:
* **Services**: Windows background services required for the Workspace to function (e.g., license managers, SQL servers).
* **Executables**: The primary GUI applications or CLI tools that belong to the Workspace.
* **Protected Processes**: Critical executables that prevent the Workspace from being safely `Stopped` if they are currently running (to prevent accidental data loss, such as an unsaved Word document or a rendering video).
* **Reverse Relations**: Background services or applications that should be explicitly turned **ON** when the Workspace is transitioned to `Stopped` (e.g., re-enabling an Antivirus service when a Game Workspace is closed).

## 3. The Execution Pipeline

To ensure dependencies are met without racing conditions, WorkspaceManager follows a strict, sequential execution pipeline. 

Arrays defined in the JSON configuration dictate the execution order. 

### Transitioning to `Ready` (Starting)
Execution flows **Left to Right** (Index 0 $\rightarrow$ Index N).
1. **Services** are started sequentially (Left $\rightarrow$ Right).
2. **Executables** are launched sequentially (Left $\rightarrow$ Right).

### Transitioning to `Stopped` (Killing)
Execution flows **Right to Left** (Index N $\rightarrow$ Index 0) to cleanly unwind dependencies.
1. Engine checks RAM for **Protected Processes**. If found, execution halts and prompts the user.
2. **Executables** are violently terminated sequentially (Right $\rightarrow$ Left).
3. **Services** are stopped and disabled sequentially (Right $\rightarrow$ Left).
4. **Reverse Relations** are executed.

### Custom Execution Order (Roadmap Feature)
While the default pipeline covers 95% of use cases, advanced Workspaces may require interwoven execution (e.g., Start Service A $\rightarrow$ Launch Executable 1 $\rightarrow$ Wait 5s $\rightarrow$ Start Service B). Future releases will support overriding the default pipeline with a custom, step-by-step execution array.

## 4. Configuration Schema (`workspaces.json`)

```json
{
  "ArcGIS": {
    "services": ["ArcGISLicenseService", "EsriCoreSvc"],
    "executables": ["C:\\Program Files\\ArcGIS\\Pro\\bin\\ArcGISPro.exe"],
    "protected_processes": ["ArcGISPro"],
    "reverse_relations": []
  },
  "Gaming": {
    "services": ["Steam Client Service", "EasyAntiCheat"],
    "executables": ["D:\\Games\\Steam\\steam.exe"],
    "protected_processes": ["Cyberpunk2077", "steam"],
    "reverse_relations": ["WindowsDefenderSvc"]
  }
}
```
