# WorkspaceManager in Windows Terminal

Use this when you want the Dashboard (or orchestrator) to show **WorkspaceManager** branding on the tab and taskbar while running under [Windows Terminal](https://github.com/microsoft/terminal), instead of the default `pwsh.exe` icon.

## Prerequisites

- Windows Terminal installed (Microsoft Store or built-in on recent Windows 11).
- PowerShell 7 (`pwsh.exe`) on `PATH`.
- Repo clone path: adjust every **absolute** path below to match your machine.

## Settings file

Open Windows Terminal **Settings** (Ctrl+,), choose **Open JSON file**, or edit:

`%LOCALAPPDATA%\Microsoft\Windows Terminal\settings.json`

Add a profile under `profiles.list` (or merge into your existing `profiles` object, depending on your schema version).

## Example profile (Dashboard)

Replace `D:\path\to\WorkspaceManager` with your repository root. The `icon` path must point at `Assets\Dashboard.ico` in that root.

```json
{
  "name": "WorkspaceManager Dashboard",
  "commandline": "pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File \"D:\\path\\to\\WorkspaceManager\\Scripts\\Dashboard.ps1\"",
  "startingDirectory": "D:\\path\\to\\WorkspaceManager",
  "icon": "D:\\path\\to\\WorkspaceManager\\Assets\\Dashboard.ico"
}
```

Alternative `commandline` using the repo launcher (same `startingDirectory`):

```json
"commandline": "cmd.exe /c \"D:\\path\\to\\WorkspaceManager\\Scripts\\Run-Dashboard.cmd\""
```

## Team distribution

You can ship read-only **JSON fragments** so each machine merges profiles without hand-editing `settings.json`. See Microsoft’s documentation: [Windows Terminal JSON fragment extensions](https://learn.microsoft.com/en-us/windows/terminal/json-fragment-extensions).

## Related

- Desktop shortcut with the same icon: [Dashboard.md](Dashboard.md) (`Create-DashboardShortcut.ps1`).
- Interactive repo bootstrap (root + optional desktop/start menu links): `Setup.cmd`.
- Start Menu orchestration shortcuts: [Configuration.md](Configuration.md) (`Generate-Shortcuts.ps1`).
