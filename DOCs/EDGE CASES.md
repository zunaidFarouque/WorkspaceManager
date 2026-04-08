# WorkspaceManager: Edge Cases & Mitigation Strategies

When orchestrating native Windows services and executables, the engine must handle the unpredictable nature of the operating system. `WorkspaceManager` is built to anticipate and gracefully mitigate the four primary orchestration failure states.

## 1. The Race Condition (Timing & Initialization)
**The Problem:** Background services (like `ArcGISLicenseService` or audio DSPs) do not initialize instantly. If the engine fires a start command for a service and immediately launches the dependent GUI application, the application will crash because the service has not yet bound to its local ports.

**The Solution:**
* **Explicit Wait Syntax:** The JSON schema supports explicit timer injections within the execution arrays. By adding `"t 3000"` to an array, the engine will pause execution for exactly 3,000 milliseconds before proceeding to the next item. This can be placed anywhere in the array (e.g., waiting for a service to spin up, or leaving a final buffer at the end of the executable array).
* **The Autorun Paradigm:** Workspaces distinguish between *Environment Priming* and a *Targeted Launch*.
    * *Environment Priming (e.g., Office):* The user wants the background services ready, but does not want to automatically open a specific document or app yet.
    * *Targeted Launch (e.g., Cubase):* The user designates an `autorun` executable. The engine will methodically start services, respect all `t` timers, and *only* launch the autorun executable once the environment is confirmed stable.

## 2. The Shared Dependency Trap
**The Problem:** Multiple Workspaces may require the same background service (e.g., a local PostgreSQL database or an audio driver). If a user transitions Workspace A to `Stopped`, a naive script would blindly kill the shared service, instantly crashing Workspace B.

**The Solution:**
* **State-Aware Commits:** `WorkspaceManager` does not execute state changes synchronously. When a user modifies their environment via the Dashboard TUI, they must explicitly "Commit" the changes. During the commit phase, the engine calculates the global delta between the *Current State* and the *Desired State*. It cross-references active dependencies to ensure a shared service is never terminated while another active Workspace still requires it.

## 3. The Hung Process Standoff (Zombie Processes)
**The Problem:** When transitioning a Workspace to `Stopped`, an application (like a video editor or DAW) may have crashed silently in the background, locking a system thread. Standard termination commands fail, preventing a clean teardown.

**The Solution:**
* **Interactive Triage:** The engine utilizes a timeout protocol during the teardown phase. If an executable is commanded to terminate but remains detected in RAM after the timeout period, the engine immediately halts the teardown sequence. The Workspace is flagged as `Mixed` (Yellow), and the user is prompted via the CLI/Dashboard: 
  > *"Process [Name] is unresponsive. [F] Force Kill (Risk of data loss) or [M] Manually Investigate?"*
* **Dashboard:** When a row’s current state is `Mixed`, **Space** toggles only the desired **Start** vs **Stop** target (`Ready` vs `Stopped`). **Backspace** drops any pending desired change so **Commit** leaves that workspace untouched.

## 4. The Indexing Ghost (PowerToys & Search Cache)
**The Problem:** The "Quick Run" mode relies on Windows indexing `.lnk` shortcuts for tools like PowerToys Run or Windows Search. Rapidly creating, deleting, or modifying these shortcuts via automated scripts can break the Windows Search cache, causing shortcuts to disappear or ghost entries to remain.

**The Solution:**
* **Decoupled Generation:** The JSON configuration and Dashboard TUI operate completely independently of the shortcut files. Users can edit, tweak, and test their JSON Workspaces continuously within the Dashboard. Shortcut creation is a deliberate, manual action triggered *only* when the user finalizes a profile, ensuring the Start Menu directory remains stable and perfectly indexed.