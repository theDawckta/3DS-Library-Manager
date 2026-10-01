Option Explicit

Dim shell
Dim fileSystem
Dim projectDirectory
Dim appScript
Dim arguments

Set fileSystem = CreateObject("Scripting.FileSystemObject")
projectDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
appScript = projectDirectory & "\scripts\library-manager.ps1"

If Not fileSystem.FileExists(appScript) Then
    MsgBox "The 3DS Game Installer could not be found:" & vbCrLf & appScript, _
        vbCritical, "Cannot start"
    WScript.Quit 1
End If

arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ _
    & appScript & """"

Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = projectDirectory
shell.Run "powershell.exe " & arguments, 0, False
