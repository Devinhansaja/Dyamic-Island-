# Installs Isle for the current user (no admin needed):
#   - copies the app to %LOCALAPPDATA%\Programs\Isle
#   - Start menu + desktop shortcuts
#   - starts with Windows (Run entry, marked enabled in Startup apps)
#   - "Isle" in Settings > Apps > Installed apps, with Uninstall
# Run by "Isle Setup.exe" with -Zip (the packed app), or with -Source (an unpacked Isle folder).
param([string]$Zip, [string]$Source, [switch]$NoStart)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$name    = 'Isle'
$dest    = Join-Path $env:LOCALAPPDATA 'Programs\Isle'
$exe     = Join-Path $dest 'Isle.exe'
$runKey  = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$runName = 'electron.app.Isle'   # the same name Isle itself uses for "Launch at login"
$approved = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$uninstKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Isle'

function Stop-Isle {
    # Closing Isle normally lets it put the Windows volume pop-up back; then make sure it's gone.
    Get-Process Isle -ErrorAction SilentlyContinue | ForEach-Object { try { $_.CloseMainWindow() | Out-Null } catch {} }
    Start-Sleep -Milliseconds 800
    Get-Process Isle -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt 20 -and (Get-Process Isle -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
}

Write-Host 'Installing Isle...'
# Never "stand in" the folder being replaced (Windows won't delete a folder that is some
# program's current directory - this one's included).
Set-Location $env:TEMP
Stop-Isle
# The helper's small guard program (it puts the Windows volume pop-up back, then exits) and
# helper scripts from the old install can linger a moment.
for ($i = 0; $i -lt 12 -and (Get-Process IsleGuard-1 -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 250 }
Get-Process IsleGuard-1 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$dest*" -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

# 1. Files: unpack next to the install, then replace the old files with them. The old folder is
#    removed first (a few tries, something may still be letting go of it); if a file stays locked,
#    the new files are mirrored over the old ones instead, so the install never ends half-done.
if ($Zip) {
    $unpacked = Join-Path $env:TEMP ('IsleUnpack-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path $Zip).Path, $unpacked)
    $Source = $unpacked
} elseif (-not $Source) { throw 'Give -Zip or -Source' }
for ($i = 0; $i -lt 10 -and (Test-Path $dest); $i++) {
    try { Remove-Item $dest -Recurse -Force -ErrorAction Stop } catch { Start-Sleep -Milliseconds 600 }
}
New-Item -ItemType Directory -Force $dest | Out-Null
robocopy $Source $dest /MIR /R:5 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "copy failed (robocopy $LASTEXITCODE)" }
if ($unpacked) { Remove-Item $unpacked -Recurse -Force -ErrorAction SilentlyContinue }
if (-not (Test-Path $exe)) { throw "Isle.exe missing after copy" }
Copy-Item (Join-Path $PSScriptRoot 'uninstall.ps1') $dest -Force

# 2. Shortcuts
$shell = New-Object -ComObject WScript.Shell
$ico = Join-Path $dest 'Isle.ico'
foreach ($lnkPath in @(
        (Join-Path ([Environment]::GetFolderPath('Programs')) 'Isle.lnk'),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Isle.lnk'))) {
    $l = $shell.CreateShortcut($lnkPath)
    $l.TargetPath = $exe
    $l.WorkingDirectory = $dest
    $l.Description = 'Isle - dynamic island for Windows'
    if (Test-Path $ico) { $l.IconLocation = "$ico,0" }
    $l.Save()
}

# 3. Start with Windows. Windows only runs entries that Startup apps has marked enabled.
# (Written the way Electron writes it, so Isle's own "Launch at login" check sees it as on.)
Set-ItemProperty $runKey $runName $(if ($exe -match ' ') { "`"$exe`"" } else { $exe })
if (-not (Test-Path $approved)) { New-Item $approved -Force | Out-Null }
Set-ItemProperty $approved $runName ([byte[]](2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) -Type Binary
# An older copy started from elsewhere (e.g. Downloads) used another entry name.
Remove-ItemProperty $runKey 'electron.app.Electron' -ErrorAction SilentlyContinue

# 4. Installed apps entry
$ver = '1.0.0'
try { $ver = (Get-Content (Join-Path $dest 'resources\app\package.json') -Raw | ConvertFrom-Json).version } catch {}
$size = [int]((Get-ChildItem $dest -Recurse -File | Measure-Object Length -Sum).Sum / 1KB)
New-Item $uninstKey -Force | Out-Null
$un = "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dest\uninstall.ps1`""
$props = @{
    DisplayName = 'Isle'; DisplayVersion = $ver; Publisher = 'Isle'; DisplayIcon = "$exe,0"
    InstallLocation = $dest; UninstallString = $un; QuietUninstallString = "$un -Quiet"
    InstallDate = (Get-Date -Format 'yyyyMMdd')
}
foreach ($k in $props.Keys) { Set-ItemProperty $uninstKey $k $props[$k] }
Set-ItemProperty $uninstKey 'EstimatedSize' $size -Type DWord
Set-ItemProperty $uninstKey 'NoModify' 1 -Type DWord
Set-ItemProperty $uninstKey 'NoRepair' 1 -Type DWord

Write-Host "Installed to $dest"
if (-not $NoStart) { Start-Process $exe -WorkingDirectory $dest }
