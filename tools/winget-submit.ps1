# Sends a new Isle version to winget (Windows Package Manager): writes the manifests for it
# (copied from the newest one in winget\manifests, with the new version, download link and
# SHA256), validates them and opens a pull request on microsoft/winget-pkgs from your fork.
# Run by tools\release.ps1 after the GitHub release exists; can also be run by itself:
#   powershell -ExecutionPolicy Bypass -File tools\winget-submit.ps1 -Version 1.2.0
param([Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version)
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
$id = 'Devinhansaja.Isle'
$repo = 'Devinhansaja/Dyamic-Island-'
$fork = 'Devinhansaja/winget-pkgs'
$base = Join-Path $src 'winget\manifests\d\Devinhansaja\Isle'
$url = "https://github.com/$repo/releases/download/v$Version/Isle-Setup.exe"

# 1. Manifests for this version, from the newest earlier one
$prev = Get-ChildItem $base -Directory | Where-Object { $_.Name -ne $Version } | Sort-Object { [version]$_.Name } | Select-Object -Last 1
if (-not $prev) { throw "No earlier manifest in $base" }
$dir = Join-Path $base $Version
New-Item -ItemType Directory -Force $dir | Out-Null

# The hash of the file GitHub actually serves
$tmp = Join-Path $env:TEMP "isle-winget-$Version.exe"
Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
$sha = (Get-FileHash $tmp -Algorithm SHA256).Hash
Remove-Item $tmp -Force

foreach ($f in Get-ChildItem $prev.FullName -File) {
    $t = [IO.File]::ReadAllText($f.FullName)
    $t = $t -replace '(?m)^PackageVersion: .*$', "PackageVersion: $Version"
    $t = $t -replace '(?m)^(\s*InstallerUrl: ).*$', "`${1}$url"
    $t = $t -replace '(?m)^(\s*InstallerSha256: ).*$', "`${1}$sha"
    $t = $t -replace '(?m)^ReleaseDate: .*$', "ReleaseDate: $(Get-Date -Format 'yyyy-MM-dd')"
    $t = $t -replace '(?m)^ReleaseNotesUrl: .*$', "ReleaseNotesUrl: https://github.com/$repo/releases/tag/v$Version"
    [IO.File]::WriteAllText((Join-Path $dir $f.Name), $t, (New-Object Text.UTF8Encoding $false))
}
winget validate --manifest $dir | Out-Host
if ($LASTEXITCODE -ne 0) { throw 'winget manifest validation failed' }

# 2. Branch in the fork (made from Microsoft's current master), files, pull request
$branch = "$id-$Version"
$head = gh api repos/microsoft/winget-pkgs/git/ref/heads/master --jq .object.sha
gh api -X POST "repos/$fork/git/refs" -f ref="refs/heads/$branch" -f sha=$head --jq .ref | Out-Host
foreach ($f in Get-ChildItem $dir -File) {
    $path = "manifests/d/Devinhansaja/Isle/$Version/$($f.Name)"
    $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.FullName))
    gh api -X PUT "repos/$fork/contents/$path" -f message="New version: $id version $Version" -f content=$b64 -f branch=$branch --jq .content.path | Out-Host
}
$body = @"
- [x] Have you signed the [Contributor License Agreement](https://cla.opensource.microsoft.com/microsoft/winget-pkgs)?
- [ ] Is there a linked Issue?

Manifests
- [x] Have you checked that there aren't other open [pull requests](https://github.com/microsoft/winget-pkgs/pulls) for the same manifest update/change?
- [x] This PR only modifies one (1) manifest
- [x] Have you [validated](https://github.com/microsoft/winget-pkgs/blob/master/doc/Authoring.md#validation) your manifest locally with ``winget validate --manifest <path>``?
- [ ] Have you tested your manifest locally with ``winget install --manifest <path>``?
- [x] Does your manifest conform to the [1.10 schema](https://github.com/microsoft/winget-pkgs/tree/master/doc/manifest/schema/1.10.0)?

New version of Isle: https://github.com/$repo/releases/tag/v$Version
"@
$bodyFile = Join-Path $env:TEMP 'isle-winget-pr.md'
[IO.File]::WriteAllText($bodyFile, $body)
gh pr create --repo microsoft/winget-pkgs --base master --head "Devinhansaja:$branch" --title "New version: $id version $Version" --body-file $bodyFile 2>$null | Out-Host
Remove-Item $bodyFile -Force

# 3. Keep the manifests in Isle's own repo too
Push-Location $src
git add winget
git commit -m "winget manifest for $Version" | Out-Host
git push origin HEAD | Out-Host
Pop-Location
"Sent Isle $Version to winget"
