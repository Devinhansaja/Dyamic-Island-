# Builds "Isle Setup.exe": one file that installs Isle for the current user (see installer\).
# The setup program (installer\Setup.cs) is compiled here with Windows' own C# compiler and the
# zipped app is attached to its end, so nothing is downloaded.
#   powershell -ExecutionPolicy Bypass -File tools\build-setup.ps1 -Out "$env:USERPROFILE\Downloads\Isle Setup.exe"
param([Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
$stage = Join-Path $env:TEMP 'isle-setup'
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
$pack = Join-Path $stage 'pack'
$appDir = Join-Path $pack 'app'
New-Item -ItemType Directory -Force $pack | Out-Null

# 1. The app folder + installer scripts, zipped
& (Join-Path $PSScriptRoot 'build-exe.ps1') -Out $appDir | Out-Host
Copy-Item (Join-Path $src 'installer\install.ps1'), (Join-Path $src 'installer\uninstall.ps1') $pack
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = Join-Path $stage 'payload.zip'
[IO.Compression.ZipFile]::CreateFromDirectory($pack, $zip, [IO.Compression.CompressionLevel]::Optimal, $false)

# 2. The setup program, with Isle's icon
$exe = Join-Path $stage 'setup.exe'
$cp = New-Object CodeDom.Compiler.CompilerParameters
$cp.GenerateExecutable = $true
$cp.OutputAssembly = $exe
$cp.CompilerOptions = "/target:winexe /optimize /win32icon:`"$(Join-Path $appDir 'Isle.ico')`""
foreach ($r in 'System.dll', 'System.Drawing.dll', 'System.Windows.Forms.dll', 'System.IO.Compression.dll', 'System.IO.Compression.FileSystem.dll') { [void]$cp.ReferencedAssemblies.Add($r) }
$res = (New-Object Microsoft.CSharp.CSharpCodeProvider).CompileAssemblyFromFile($cp, (Join-Path $src 'installer\Setup.cs'))
if ($res.Errors.HasErrors) { $res.Errors | Where-Object { -not $_.IsWarning } | ForEach-Object { Write-Host $_ }; throw 'Setup program did not compile' }

# 3. setup.exe + zip + length + marker
$fs = [IO.File]::Open($Out, 'Create')
try {
    $b = [IO.File]::ReadAllBytes($exe); $fs.Write($b, 0, $b.Length)
    $z = [IO.File]::OpenRead($zip); $z.CopyTo($fs); $len = $z.Length; $z.Dispose()
    $b = [BitConverter]::GetBytes([long]$len); $fs.Write($b, 0, 8)
    $b = [Text.Encoding]::ASCII.GetBytes('ISLESFX1'); $fs.Write($b, 0, 8)
} finally { $fs.Dispose() }
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
"Built $Out  ({0:N0} MB)" -f ((Get-Item $Out).Length / 1MB)
