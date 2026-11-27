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

# The Dock set Windows' taskbar to auto-hide (and Isle was closed before it could undo that): undo it.
$isleReg = Get-ItemProperty 'HKCU:\Software\Isle' -ErrorAction SilentlyContinue
if ($isleReg.TaskbarAutoHide -or $isleReg.TaskbarHidden) {
    Add-Type @'
using System; using System.Runtime.InteropServices;
public static class IsleTaskbar {
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] struct APPBARDATA { public int cbSize; public IntPtr hWnd; public uint cb; public uint edge; public RECT rc; public IntPtr lp; }
  [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint m, ref APPBARDATA d);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  public static void Show() {
    foreach (var cls in new[] { "Shell_TrayWnd", "Shell_SecondaryTrayWnd" }) { IntPtr h = IntPtr.Zero; while ((h = FindWindowEx(IntPtr.Zero, h, cls, null)) != IntPtr.Zero) ShowWindow(h, 5); }
    var d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d); d.hWnd = FindWindow("Shell_TrayWnd", null); d.lp = IntPtr.Zero; SHAppBarMessage(10, ref d);
  }
}
'@
    [IsleTaskbar]::Show()
}
Remove-Item 'HKCU:\Software\Isle' -Recurse -Force
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
