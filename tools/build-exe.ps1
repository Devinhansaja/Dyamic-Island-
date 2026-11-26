# Builds a portable Isle.exe folder from the Electron runtime already in node_modules
# (no downloads): copies the runtime, renames it, adds Isle's files, and sets the exe's
# icon and name (so Explorer and Task Manager show "Isle" instead of "Electron").
#   powershell -ExecutionPolicy Bypass -File tools\build-exe.ps1 -Out "$env:USERPROFILE\Downloads\Isle"
param([Parameter(Mandatory)][string]$Out)
$ErrorActionPreference = 'Stop'
$src = Split-Path $PSScriptRoot -Parent
$dist = Join-Path $src 'node_modules\electron\dist'
if (-not (Test-Path (Join-Path $dist 'electron.exe'))) { throw "Electron runtime not found in $dist (run npm install first)" }
$pkg = Get-Content (Join-Path $src 'package.json') -Raw | ConvertFrom-Json

# 1. Runtime
New-Item -ItemType Directory -Force $Out | Out-Null
robocopy $dist $Out /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "copy failed ($LASTEXITCODE)" }
$exe = Join-Path $Out 'Isle.exe'
if (Test-Path $exe) { Remove-Item $exe -Force }
Move-Item (Join-Path $Out 'electron.exe') $exe
Remove-Item (Join-Path $Out 'resources\default_app.asar') -Force -ErrorAction SilentlyContinue

# 2. App files -> resources\app
$app = Join-Path $Out 'resources\app'
if (Test-Path $app) { Remove-Item $app -Recurse -Force }
New-Item -ItemType Directory -Force $app | Out-Null
foreach ($f in Get-ChildItem $src -File | Where-Object { $_.Extension -in '.js', '.html', '.css', '.ps1', '.json' -and $_.Name -ne 'package-lock.json' }) {
    Copy-Item $f.FullName $app
}
foreach ($d in 'assets', 'bin') { Copy-Item (Join-Path $src $d) $app -Recurse }

# 3. Icon (.ico made from assets\icon.png) and version info inside Isle.exe
Add-Type -AssemblyName System.Drawing
$png = [Drawing.Image]::FromFile((Join-Path $src 'assets\icon.png'))
$images = foreach ($s in 16, 24, 32, 48, 64, 128, 256) {
    $bmp = New-Object Drawing.Bitmap $s, $s
    $g = [Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode = 'HighQualityBicubic'; $g.SmoothingMode = 'HighQuality'
    $g.DrawImage($png, 0, 0, $s, $s); $g.Dispose()
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose()
    ,@($s, $ms.ToArray())
}
$png.Dispose()
# Also write Isle.ico next to the exe (handy for shortcuts).
$ico = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter $ico
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$images.Count)
$offset = 6 + 16 * $images.Count
foreach ($im in $images) { $s = $im[0]; $bw.Write([byte]($s % 256)); $bw.Write([byte]($s % 256)); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]$im[1].Length); $bw.Write([uint32]$offset); $offset += $im[1].Length }
foreach ($im in $images) { $bw.Write($im[1]) }
[IO.File]::WriteAllBytes((Join-Path $Out 'Isle.ico'), $ico.ToArray())

Add-Type -TypeDefinition @'
using System; using System.IO; using System.Text; using System.Runtime.InteropServices; using System.Collections.Generic;
public static class ResEdit {
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr BeginUpdateResource(string file, bool deleteExisting);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateResource(IntPtr h, IntPtr type, IntPtr name, ushort lang, byte[] data, uint size);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool UpdateResourceW(IntPtr h, IntPtr type, string name, ushort lang, byte[] data, uint size);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool EndUpdateResource(IntPtr h, bool discard);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr LoadLibraryEx(string f, IntPtr h, uint flags);
  [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr h);
  delegate bool EnumName(IntPtr mod, IntPtr type, IntPtr name, IntPtr p);
  delegate bool EnumLang(IntPtr mod, IntPtr type, IntPtr name, ushort lang, IntPtr p);
  [DllImport("kernel32.dll")] static extern bool EnumResourceNames(IntPtr mod, IntPtr type, EnumName cb, IntPtr p);
  [DllImport("kernel32.dll")] static extern bool EnumResourceLanguages(IntPtr mod, IntPtr type, IntPtr name, EnumLang cb, IntPtr p);
  const int RT_ICON = 3, RT_GROUP_ICON = 14, RT_VERSION = 16;

  // Existing resources of a type: (name, lang). name is a string or an int id.
  static List<KeyValuePair<object, ushort>> List(string file, int type) {
    var res = new List<KeyValuePair<object, ushort>>();
    IntPtr mod = LoadLibraryEx(file, IntPtr.Zero, 0x2 /* LOAD_LIBRARY_AS_DATAFILE */);
    if (mod == IntPtr.Zero) return res;
    EnumResourceNames(mod, (IntPtr)type, (m, t, n, p) => {
      object key = ((long)n >> 16) == 0 ? (object)(int)(long)n : Marshal.PtrToStringUni(n);
      EnumResourceLanguages(m, t, n, (m2, t2, n2, lang, p2) => { res.Add(new KeyValuePair<object, ushort>(key, lang)); return true; }, IntPtr.Zero);
      return true;
    }, IntPtr.Zero);
    FreeLibrary(mod);
    return res;
  }
  static void Put(IntPtr h, int type, object name, ushort lang, byte[] data) {
    bool ok = name is int ? UpdateResource(h, (IntPtr)type, (IntPtr)(int)name, lang, data, data == null ? 0u : (uint)data.Length)
                          : UpdateResourceW(h, (IntPtr)type, (string)name, lang, data, data == null ? 0u : (uint)data.Length);
    if (!ok) throw new Exception("UpdateResource failed: " + Marshal.GetLastWin32Error());
  }

  public static void SetIcon(string file, List<byte[]> pngs, int[] sizes) {
    var groups = List(file, RT_GROUP_ICON);
    var icons = List(file, RT_ICON);
    IntPtr h = BeginUpdateResource(file, false);
    if (h == IntPtr.Zero) throw new Exception("BeginUpdateResource failed: " + Marshal.GetLastWin32Error());
    object groupName = groups.Count > 0 ? groups[0].Key : (object)1;
    foreach (var g in groups) Put(h, RT_GROUP_ICON, g.Key, g.Value, null);
    foreach (var i in icons) Put(h, RT_ICON, i.Key, i.Value, null);
    var dir = new MemoryStream(); var w = new BinaryWriter(dir);
    w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)pngs.Count);
    for (int k = 0; k < pngs.Count; k++) {
      int s = sizes[k];
      w.Write((byte)(s % 256)); w.Write((byte)(s % 256)); w.Write((byte)0); w.Write((byte)0);
      w.Write((ushort)1); w.Write((ushort)32); w.Write((uint)pngs[k].Length); w.Write((ushort)(k + 1));
      Put(h, RT_ICON, k + 1, 1033, pngs[k]);
    }
    Put(h, RT_GROUP_ICON, groupName, 1033, dir.ToArray());
    if (!EndUpdateResource(h, false)) throw new Exception("EndUpdateResource failed: " + Marshal.GetLastWin32Error());
  }

  // ---- VERSIONINFO built from scratch
  static void Pad(MemoryStream m) { while (m.Length % 4 != 0) m.WriteByte(0); }
  static byte[] Block(string key, byte[] value, ushort valueLen, ushort type, List<byte[]> children) {
    var m = new MemoryStream(); var w = new BinaryWriter(m);
    w.Write((ushort)0); w.Write(valueLen); w.Write(type);
    w.Write(Encoding.Unicode.GetBytes(key + "\0")); Pad(m);
    if (value != null) { w.Write(value); Pad(m); }
    if (children != null) foreach (var c in children) { w.Write(c); Pad(m); }
    var b = m.ToArray(); BitConverter.GetBytes((ushort)b.Length).CopyTo(b, 0);
    return b;
  }
  static byte[] Str(string key, string val) {
    return Block(key, Encoding.Unicode.GetBytes(val + "\0"), (ushort)(val.Length + 1), 1, null);
  }
  public static void SetVersion(string file, string product, string description, string company, string version, string exeName) {
    var parts = (version + ".0.0.0").Split('.');
    ushort a = ushort.Parse(parts[0]), b = ushort.Parse(parts[1]), c = ushort.Parse(parts[2]), d = ushort.Parse(parts[3]);
    var f = new MemoryStream(); var fw = new BinaryWriter(f);
    fw.Write(0xFEEF04BDu); fw.Write(0x00010000u);
    fw.Write((uint)((a << 16) | b)); fw.Write((uint)((c << 16) | d));
    fw.Write((uint)((a << 16) | b)); fw.Write((uint)((c << 16) | d));
    fw.Write(0x3Fu); fw.Write(0u); fw.Write(0x40004u /* VOS_NT_WINDOWS32 */); fw.Write(1u /* VFT_APP */); fw.Write(0u); fw.Write(0u); fw.Write(0u);
    string v = a + "." + b + "." + c + "." + d;
    var strings = new List<byte[]> {
      Str("CompanyName", company), Str("FileDescription", description), Str("FileVersion", v),
      Str("InternalName", exeName), Str("LegalCopyright", company), Str("OriginalFilename", exeName + ".exe"),
      Str("ProductName", product), Str("ProductVersion", v)
    };
    var table = Block("040904b0", null, 0, 1, strings);
    var sfi = Block("StringFileInfo", null, 0, 1, new List<byte[]> { table });
    var var = Block("Translation", BitConverter.GetBytes(0x04B00409u), 4, 0, null);
    var vfi = Block("VarFileInfo", null, 0, 1, new List<byte[]> { var });
    var root = Block("VS_VERSION_INFO", f.ToArray(), 52, 0, new List<byte[]> { sfi, vfi });
    var old = List(file, RT_VERSION);
    IntPtr h = BeginUpdateResource(file, false);
    if (h == IntPtr.Zero) throw new Exception("BeginUpdateResource failed: " + Marshal.GetLastWin32Error());
    foreach (var o in old) Put(h, RT_VERSION, o.Key, o.Value, null);
    Put(h, RT_VERSION, 1, 1033, root);
    if (!EndUpdateResource(h, false)) throw new Exception("EndUpdateResource failed: " + Marshal.GetLastWin32Error());
  }
}
'@
$list = New-Object 'System.Collections.Generic.List[byte[]]'
foreach ($im in $images) { $list.Add($im[1]) }
# A freshly copied exe can be held for a moment (e.g. by the antivirus scan), so retry.
function Invoke-Retry([scriptblock]$Do) {
    for ($i = 1; ; $i++) {
        try { & $Do; return } catch { if ($i -ge 8) { throw }; Start-Sleep -Seconds 2 }
    }
}
Invoke-Retry { [ResEdit]::SetIcon($exe, $list, [int[]]@($images | ForEach-Object { $_[0] })) }
Invoke-Retry { [ResEdit]::SetVersion($exe, 'Isle', 'Isle', 'Isle', [string]$pkg.version, 'Isle') }

$size = (Get-ChildItem $Out -Recurse -File | Measure-Object Length -Sum).Sum / 1MB
"Built $exe  ({0:N0} MB folder)" -f $size
