Here is the exact logical flow the Orchestrator will follow from the moment a shortcut is clicked to the moment the console window closes.

### Phase 1: Ingestion & Input Sanitization
The engine wakes up via a shortcut (e.g., `!Start-ArcGIS.lnk`), receiving two parameters: `$WorkspaceName` and `$Action`.

1. **Load Database:** It reads `workspaces.json` using `ConvertFrom-Json`. If the file is missing or corrupted, it throws a fatal red error and exits.
2. **Target Acquisition:** It isolates the specific JSON object matching `$WorkspaceName`. If the workspace doesn't exist, it aborts.
3. **Data Sanitization:**
   * It loops through the `protected_processes` array. It runs a regex replace (`-replace '\.exe$', ''`) to strip out any accidental `.exe` extensions the user might have typed, ensuring `Get-Process` won't fail later.

### Phase 2: The Pre-Flight Safety Checks
The engine determines the requested `$Action` (Start or Stop) and performs safety checks *before* touching a single system service.

* **If Action is "Start":** The engine assumes the runway is clear. It proceeds directly to Phase 3.
* **If Action is "Stop":** The engine hits the brakes. 
  * It queries the system RAM (`Get-Process`) against the sanitized `protected_processes` array. 
  * If a protected process is found (e.g., `Cubase12` is still running), the engine completely halts. It changes the console text to yellow and prompts: *"Protected process [Cubase12] is active. Save your work. Force kill anyway? (Y/N)."* * If N, it aborts. If Y, it proceeds to Phase 4.

### Phase 3: The Start Pipeline (Left-to-Right)
Execution flows forward. The engine parses the arrays sequentially.

1. **Service Array:**
   * It reads index 0. Is it a timer (e.g., `t 3000`)? If yes, `Start-Sleep -Milliseconds 3000`. 
   * If it is a service name, it triggers `gsudo sc config [name] start= demand` and `gsudo net start [name]`.
   * **The Polling Loop:** It runs a fast `while` loop, checking `Get-Service` until the status physically returns `Running` or a 10-second timeout hits. 
2. **Executable Array:**
   * It reads the executable string. 
   * **The Regex Split:** If the string starts with a single quote (`'`), the engine uses regex to split the string at the closing quote. The first part becomes the `$FilePath`, the second part becomes the `$ArgumentList`. If no quotes are found, the whole string is the `$FilePath`.
   * It triggers `Start-Process -FilePath $FilePath -ArgumentList $ArgumentList`.

### Phase 4: The Stop Pipeline (Right-to-Left)
Execution flows backward to cleanly unwind dependencies without crashing running software.

1. **Executable Array (Reversed):**
   * The engine reverses the `executables` array.
   * It ignores timers here (usually not needed on teardown).
   * It extracts the `.exe` name from the file path and runs `gsudo taskkill /F /IM [name.exe] /T`. 
   * It waits 1 second to ensure the process releases its memory hooks.
2. **Service Array (Reversed):**
   * The engine reverses the `services` array.
   * It runs `gsudo net stop [name] /y` and `gsudo sc config [name] start= disabled`.
3. **Reverse Relations:**
   * If any services are listed in `reverse_relations`, it wakes them up using the start protocol from Phase 3.
