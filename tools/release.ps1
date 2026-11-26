# Publishes a new version of Isle: sets the version, builds Isle-Setup.exe, commits, tags,
# pushes and creates a GitHub release with the setup attached. Installed copies of Isle find
# the release (Settings > App > Updates, or automatically) and update themselves.
#   powershell -ExecutionPolicy Bypass -File tools\release.ps1 -Version 1.2.0 -Notes "What changed"
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$Notes = '',
    [switch]$NoWinget   # don't send this version to winget
)
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
Set-Location $src

$current = (Get-Content package.json -Raw | ConvertFrom-Json).version
$newer = [version]$Version -gt [version]$current
if (-not $newer) { throw "Version $Version must be newer than $current" }
if (git tag --list "v$Version") { throw "Tag v$Version already exists" }

# 1. Version number (package.json is what Isle reports as its version)
$pkg = [IO.File]::ReadAllText((Join-Path $src 'package.json'))
$verRe = [regex]'"version"\s*:\s*"[^"]*"'   # (an instance: its Replace takes a count)
$pkg = $verRe.Replace($pkg, "`"version`": `"$Version`"", 1)
[IO.File]::WriteAllText((Join-Path $src 'package.json'), $pkg, (New-Object Text.UTF8Encoding $false))
# package-lock.json repeats it (top level and the root package)
$lockPath = Join-Path $src 'package-lock.json'
if (Test-Path $lockPath) {
    $lock = [IO.File]::ReadAllText($lockPath)
    $lock = $verRe.Replace($lock, "`"version`": `"$Version`"", 2)   # only the first two, not the dependencies'
    [IO.File]::WriteAllText($lockPath, $lock, (New-Object Text.UTF8Encoding $false))
}

# 2. Setup
$dist = Join-Path $src 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null
$setup = Join-Path $dist 'Isle-Setup.exe'
& (Join-Path $PSScriptRoot 'build-setup.ps1') -Out $setup | Out-Host

# 3. Git + GitHub release
git add -A
git commit -m "Isle $Version" | Out-Host
git tag "v$Version"
git push origin HEAD --tags | Out-Host
if (-not $Notes) { $Notes = "Isle $Version" }
gh release create "v$Version" $setup --title "Isle $Version" --notes $Notes | Out-Host
"Released Isle $Version"

# 4. winget (Windows Package Manager): a pull request with the new version's manifests
if (-not $NoWinget) { & (Join-Path $PSScriptRoot 'winget-submit.ps1') -Version $Version }
