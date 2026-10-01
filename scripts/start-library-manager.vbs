Option Explicit

Dim shell
Dim fileSystem
Dim scriptDirectory
Dim arguments

Set fileSystem = CreateObject("Scripting.FileSystemObject")
scriptDirectory = fileSystem.GetParentFolderName(WScript.ScriptFullName)
arguments = "-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File """ _
    & scriptDirectory & "\library-manager.ps1"""

' Launch with the interactive user's normal token and no console window. The app's
' exact disk-safety checks still fail closed before any write if Windows denies a query.
Set shell = CreateObject("WScript.Shell")
shell.CurrentDirectory = scriptDirectory
shell.Run "powershell.exe " & arguments, 0, False
