# WorkspaceManager: Configuration Schema & Syntax Rules

**WorkspaceManager** is configured entirely via a single `workspaces.json` file. There is no built-in GUI editor for configurations; the tool assumes users are comfortable editing JSON. 

To ensure the orchestration engine parses your environment flawlessly and safely, your JSON file must adhere to the following strict syntax rules.

## The JSON Blueprint

```json
{
  "Audio_Production": {
    "services": [
      "eLicenserSvc",
      "t 3000",
      "Audiosrv"
    ],
    "executables": [
      "'C:/Program Files/Steinberg/Cubase 12/Cubase12.exe' --profile Live",
      "C:\\Tools\\AudioMixer.exe"
    ],
    "protected_processes": [
      "Cubase12",
      "AudioMixer"
    ],
    "reverse_relations": [
      "wuauserv"
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

### 4. Protected Processes (No Extensions)
The `protected_processes` array acts as a safety net to prevent data loss. If the engine attempts to stop a Workspace and detects one of these processes in RAM, it will halt and ask for user confirmation.
* Enter the raw process name exactly as it appears in Task Manager's "Details" tab.
* **Do NOT include the `.exe` extension.** (Note: The engine will auto-strip `.exe` if accidentally included, but standard practice is to omit it).
* *Correct:* `"WINWORD"` | *Incorrect:* `"WINWORD.exe"`

### 5. True Service Names
When listing background services, you must use the internal **Service Name**, not the "Display Name" shown in the Windows GUI. 
* To find the true name, open `services.msc`, right-click a service -> Properties, and look at the "Service name:" field at the top.
* *Correct:* `"wuauserv"` | *Incorrect:* `"Windows Update"`
