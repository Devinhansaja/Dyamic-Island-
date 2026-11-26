# Removes Isle (from Settings > Apps > Installed apps). Settings in %APPDATA%\dynamic-island are kept
# unless -RemoveSettings is given.
param([switch]$Quiet, [switch]$RemoveSettings)
$ErrorActionPreference = 'SilentlyContinue'
$dest = Join-Path $env:LOCALAPPDATA 'Programs\Isle'

if (-not $Quiet) {
    Add-Type -AssemblyName System.Windows.Forms
    $r = [Windows.Forms.MessageBox]::Show('Remove Isle from this PC?', 'Uninstall Isle', 'YesNo', 'Question')
    if ($r -ne 'Yes') { exit }
}

# Close Isle (it puts the Windows volume pop-up back as it exits).
Get-Process Isle | ForEach-Object { $_.CloseMainWindow() | Out-Null }
Start-Sleep -Milliseconds 800
Get-Process Isle | Stop-Process -Force
for ($i = 0; $i -lt 20 -and (Get-Process Isle); $i++) { Start-Sleep -Milliseconds 250 }

Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' 'electron.app.Isle'
Remove-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' 'electron.app.Isle'
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Isle' -Recurse -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'Isle.lnk') -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Isle.lnk') -Force
Remove-Item (Join-Path $env:LOCALAPPDATA 'Isle') -Recurse -Force          # helper's small guard program
if ($RemoveSettings) { Remove-Item (Join-Path $env:APPDATA 'dynamic-island') -Recurse -Force }

# This script lives inside the folder being removed, so the folder goes once it has finished.
Start-Process cmd.exe -ArgumentList "/c timeout /t 2 /nobreak >nul & rd /s /q `"$dest`"" -WindowStyle Hidden
if (-not $Quiet) { [Windows.Forms.MessageBox]::Show('Isle has been removed.', 'Uninstall Isle') | Out-Null }
