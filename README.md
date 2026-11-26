# Isle

A Dynamic Island–style notch for Windows: music, calls, notifications, volume / brightness HUD,
focus timer, eye breaks, battery rings for your devices, weather, clipboard history and video downloads.

## Install

```powershell
winget install Devinhansaja.Isle
```

or download **Isle-Setup.exe** from the [latest release](../../releases/latest) and run it.
Isle installs for your Windows account only (no admin), adds itself to the Start menu and desktop,
and starts with Windows. It updates itself from the releases here (Settings → App → Updates).
Uninstall from Settings → Apps → Installed apps.

## Develop

```powershell
npm install          # Electron runtime
npm start            # run from source
```

| Script | What it does |
| --- | --- |
| `tools\build-exe.ps1 -Out <folder>` | Portable Isle folder (Isle.exe with its own icon) |
| `tools\build-setup.ps1 -Out <file.exe>` | One-file installer (`installer\`) |
| `tools\release.ps1 -Version x.y.z -Notes "..."` | Bump the version, build the setup, commit, tag, push and publish a GitHub release |

Windows features (media, volume, brightness, calls, notifications, devices, game detection) come from
`helper.ps1`, a PowerShell helper with embedded C# that talks to the app over stdin / stdout.
