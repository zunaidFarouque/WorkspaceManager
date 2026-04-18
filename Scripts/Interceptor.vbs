Set objShell = CreateObject("WScript.Shell")
args = ""
For i = 0 To WScript.Arguments.Count - 1
    args = args & " """ & WScript.Arguments(i) & """"
Next
objShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & Replace(WScript.ScriptFullName, ".vbs", ".ps1") & """" & args, 0, False
