# Isle system helper.
# Prints one JSON object per line:
#   {"t":"media", has,title,artist,album,app,playing,pos,dur}   (pos/dur in ms)
#   {"t":"art", key, url}                                       (album art as a data URL)
#   {"t":"vol", v (0-100), m (muted)}
#   {"t":"bright", v (0-100)}
# Reads commands from stdin, one per line:
#   play | next | prev | seek <seconds> | vol <0-100> | mute | bright <0-100>
param([int]$ParentPid = 0)

$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$inv = [Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------- Core Audio (volume)
$nativeSource = @'
using System;
using System.Runtime.InteropServices;
namespace IsleNative {
  // Core Audio calls this the moment the volume or mute state changes.
  [Guid("657804FA-D6AD-4496-8A60-352752AF4F89"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IAudioEndpointVolumeCallback {
    [PreserveSig] int OnNotify(IntPtr pNotify);
  }
  [ComVisible(true)]
  public class VolumeCallback : IAudioEndpointVolumeCallback {
    // AUDIO_VOLUME_NOTIFICATION_DATA: GUID (16 bytes), BOOL bMuted, float fMasterVolume, ...
    public int OnNotify(IntPtr pNotify) {
      try {
        bool muted = Marshal.ReadInt32(pNotify, 16) != 0;
        float level = BitConverter.ToSingle(BitConverter.GetBytes(Marshal.ReadInt32(pNotify, 20)), 0);
        Audio.Report((int)Math.Round(level * 100), muted);
      } catch { }
      return 0;
    }
  }

  // Writes one JSON line to stdout. Used straight from event threads so volume and
  // brightness never wait behind slower work in the PowerShell loop.
  public static class Out {
    static readonly object gate = new object();
    public static void Line(string json) {
      lock (gate) { Console.Out.WriteLine(json); Console.Out.Flush(); }
    }
  }

  [Guid("5CDF2C82-841E-4546-9722-0CF74078229A"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioEndpointVolume {
    int RegisterControlChangeNotify(IAudioEndpointVolumeCallback cb);
    int UnregisterControlChangeNotify(IAudioEndpointVolumeCallback cb);
    int h(); int i();
    int SetMasterVolumeLevelScalar(float fLevel, Guid pguidEventContext);
    int j();
    int GetMasterVolumeLevelScalar(out float pfLevel);
    int k(); int l(); int m(); int n();
    int SetMute([MarshalAs(UnmanagedType.Bool)] bool bMute, Guid pguidEventContext);
    int GetMute(out bool pbMute);
  }
  [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDevice {
    int Activate(ref Guid id, int clsCtx, int activationParams, out IAudioEndpointVolume aev);
  }
  [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumerator {
    int f();
    int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice endpoint);
  }
  [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")] class MMDeviceEnumeratorComObject { }

  public static class Win {
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder sb, int n);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);

    // True when the foreground window covers its whole monitor (fullscreen video, games, slideshows).
    public static bool ForegroundFullscreen() {
      try {
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero || h == GetShellWindow() || h == GetDesktopWindow()) return false;
        var sb = new System.Text.StringBuilder(256);
        GetClassName(h, sb, 256);
        string c = sb.ToString();
        if (c == "WorkerW" || c == "Progman" || c == "Shell_TrayWnd") return false;
        // A maximized app (e.g. with an auto-hiding taskbar) can cover the screen too; that's not full-screen.
        if (IsZoomed(h)) return false;
        RECT r;
        if (!GetWindowRect(h, out r)) return false;
        var mi = new MONITORINFO();
        mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(MonitorFromWindow(h, 2), ref mi)) return false;
        return r.Left <= mi.rcMonitor.Left && r.Top <= mi.rcMonitor.Top &&
               r.Right >= mi.rcMonitor.Right && r.Bottom >= mi.rcMonitor.Bottom;
      } catch { return false; }
    }

    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);

    // Process name of the foreground window ("chrome", "valorant", ...).
    public static string ForegroundProcess() {
      try {
        uint pid;
        GetWindowThreadProcessId(GetForegroundWindow(), out pid);
        return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName;
      } catch { return ""; }
    }
  }

  // Charger plugged in? Battery %? Straight from Windows (more reliable than the browser's battery API).
  public static class Power {
    [StructLayout(LayoutKind.Sequential)]
    struct SYSTEM_POWER_STATUS { public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag; public int BatteryLifeTime, BatteryFullLifeTime; }
    [DllImport("kernel32.dll")] static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS s);
    public static string Json() {
      SYSTEM_POWER_STATUS s;
      if (!GetSystemPowerStatus(out s)) return "";
      bool hasBattery = s.BatteryFlag != 128 && s.BatteryFlag != 255;
      bool ac = s.ACLineStatus == 1;
      bool charging = (s.BatteryFlag & 8) != 0;
      int pct = s.BatteryLifePercent == 255 ? -1 : s.BatteryLifePercent;
      return "{\"t\":\"power\",\"ac\":" + (ac ? "true" : "false") + ",\"charging\":" + (charging ? "true" : "false") +
             ",\"pct\":" + pct + ",\"battery\":" + (hasBattery ? "true" : "false") + "}";
    }
  }

  // Which apps use the most CPU / memory right now (for the "running hot" alert).
  // Runs on its own thread for ~1 s and prints {"t":"top",...} when done.
  public static class TopApps {
    static volatile bool busy = false;
    static string Label(string name) {
      if (string.IsNullOrEmpty(name)) return name;
      return char.ToUpper(name[0]) + name.Substring(1);
    }
    public static void Start() {
      if (busy) return;
      busy = true;
      var t = new System.Threading.Thread(() => {
        try {
          var before = new System.Collections.Generic.Dictionary<int, double>();
          foreach (var p in System.Diagnostics.Process.GetProcesses()) {
            try { before[p.Id] = p.TotalProcessorTime.TotalMilliseconds; } catch { }
          }
          var sw = System.Diagnostics.Stopwatch.StartNew();
          System.Threading.Thread.Sleep(1000);
          double elapsed = sw.Elapsed.TotalMilliseconds * Environment.ProcessorCount;
          var cpu = new System.Collections.Generic.Dictionary<string, double>();
          var mem = new System.Collections.Generic.Dictionary<string, long>();
          foreach (var p in System.Diagnostics.Process.GetProcesses()) {
            string n;
            try { n = p.ProcessName; } catch { continue; }
            if (n == "Idle" || n == "System" || n == "Memory Compression" || n == "Registry") continue;
            try { long ws = p.WorkingSet64; long cur; mem.TryGetValue(n, out cur); mem[n] = cur + ws; } catch { }
            double b;
            if (before.TryGetValue(p.Id, out b)) {
              try { double d = p.TotalProcessorTime.TotalMilliseconds - b; double c; cpu.TryGetValue(n, out c); cpu[n] = c + Math.Max(0, d); } catch { }
            }
          }
          var cpuList = new System.Collections.Generic.List<System.Collections.Generic.KeyValuePair<string, double>>(cpu);
          cpuList.Sort((x, y) => y.Value.CompareTo(x.Value));
          var memList = new System.Collections.Generic.List<System.Collections.Generic.KeyValuePair<string, long>>(mem);
          memList.Sort((x, y) => y.Value.CompareTo(x.Value));
          var sb = new System.Text.StringBuilder("{\"t\":\"top\",\"cpu\":[");
          for (int i = 0; i < Math.Min(3, cpuList.Count); i++) {
            if (i > 0) sb.Append(',');
            sb.Append("{\"name\":\"" + Label(cpuList[i].Key).Replace("\"", "") + "\",\"pct\":" + (int)Math.Round(cpuList[i].Value / elapsed * 100) + "}");
          }
          sb.Append("],\"mem\":[");
          for (int i = 0; i < Math.Min(3, memList.Count); i++) {
            if (i > 0) sb.Append(',');
            sb.Append("{\"name\":\"" + Label(memList[i].Key).Replace("\"", "") + "\",\"mb\":" + (memList[i].Value / 1048576) + "}");
          }
          sb.Append("]}");
          Out.Line(sb.ToString());
        } catch { }
        finally { busy = false; }
      });
      t.IsBackground = true;
      t.Start();
    }
  }

  // Performance numbers for the in-game strip.
  public static class Perf {
    static long lastRx = -1, lastTx = -1;
    static DateTime lastNet = DateTime.MinValue;

    // Bytes per second received / sent over all active adapters.
    public static long[] Net() {
      long rx = 0, tx = 0;
      try {
        foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()) {
          if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) continue;
          if (ni.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;
          var s = ni.GetIPStatistics();
          rx += s.BytesReceived;
          tx += s.BytesSent;
        }
      } catch { }
      var now = DateTime.UtcNow;
      long[] r = new long[] { 0, 0 };
      if (lastRx >= 0) {
        double secs = Math.Max(0.2, (now - lastNet).TotalSeconds);
        r[0] = (long)Math.Max(0, (rx - lastRx) / secs);
        r[1] = (long)Math.Max(0, (tx - lastTx) / secs);
      }
      lastRx = rx; lastTx = tx; lastNet = now;
      return r;
    }

    // GPU 3D load from Windows performance counters (fallback when nvidia-smi isn't available).
    static System.Collections.Generic.Dictionary<string, System.Diagnostics.PerformanceCounter> gpu =
      new System.Collections.Generic.Dictionary<string, System.Diagnostics.PerformanceCounter>();
    static DateTime lastScan = DateTime.MinValue;

    public static int Gpu() {
      try {
        if ((DateTime.UtcNow - lastScan).TotalSeconds > 5) {
          lastScan = DateTime.UtcNow;
          var names = new System.Diagnostics.PerformanceCounterCategory("GPU Engine").GetInstanceNames();
          var keep = new System.Collections.Generic.HashSet<string>();
          foreach (var n in names) {
            if (!n.EndsWith("engtype_3D")) continue;
            keep.Add(n);
            if (!gpu.ContainsKey(n)) gpu[n] = new System.Diagnostics.PerformanceCounter("GPU Engine", "Utilization Percentage", n, true);
          }
          var drop = new System.Collections.Generic.List<string>();
          foreach (var k in gpu.Keys) if (!keep.Contains(k)) drop.Add(k);
          foreach (var k in drop) { gpu[k].Dispose(); gpu.Remove(k); }
        }
        // Sum per adapter (luid), report the busiest adapter.
        var perLuid = new System.Collections.Generic.Dictionary<string, float>();
        foreach (var kv in gpu) {
          float v;
          try { v = kv.Value.NextValue(); } catch { continue; }
          int a = kv.Key.IndexOf("luid_"), b = kv.Key.IndexOf("_phys");
          string luid = a >= 0 && b > a ? kv.Key.Substring(a, b - a) : "x";
          float cur;
          perLuid.TryGetValue(luid, out cur);
          perLuid[luid] = cur + v;
        }
        float max = 0;
        foreach (var v in perLuid.Values) if (v > max) max = v;
        return (int)Math.Round(Math.Min(100, max));
      } catch { return -1; }
    }
  }

  public static class Audio {
    static IAudioEndpointVolume Vol() {
      var en = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
      IMMDevice dev = null;
      Marshal.ThrowExceptionForHR(en.GetDefaultAudioEndpoint(0, 1, out dev));
      IAudioEndpointVolume epv = null;
      var id = typeof(IAudioEndpointVolume).GUID;
      Marshal.ThrowExceptionForHR(dev.Activate(ref id, 23, 0, out epv));
      return epv;
    }
    public static int GetVolume() {
      try { float v; Marshal.ThrowExceptionForHR(Vol().GetMasterVolumeLevelScalar(out v)); return (int)Math.Round(v * 100); }
      catch { return -1; }
    }
    public static bool GetMute() {
      try { bool m; Marshal.ThrowExceptionForHR(Vol().GetMute(out m)); return m; }
      catch { return false; }
    }
    public static void SetVolume(int p) {
      try { Vol().SetMasterVolumeLevelScalar(Math.Max(0, Math.Min(100, p)) / 100f, Guid.Empty); } catch { }
    }
    public static void ToggleMute() {
      try { var v = Vol(); bool m; v.GetMute(out m); v.SetMute(!m, Guid.Empty); } catch { }
    }
    public static void SetMute(bool on) {
      try { Vol().SetMute(on, Guid.Empty); } catch { }
    }

    // Wakes the helper's main loop immediately when volume or brightness changes.
    public static readonly System.Threading.AutoResetEvent Signal = new System.Threading.AutoResetEvent(false);

    static int lastV = -2, lastM = -1;
    static readonly object reportGate = new object();
    // Sends {"t":"vol"} only when the value actually changed.
    public static void Report(int v, bool m) {
      int mi = m ? 1 : 0;
      lock (reportGate) {
        if (v == lastV && mi == lastM) return;
        lastV = v; lastM = mi;
      }
      Out.Line("{\"t\":\"vol\",\"v\":" + v + ",\"m\":" + (m ? "true" : "false") + "}");
    }
    public static void ReportNow() { int v = GetVolume(); if (v >= 0) Report(v, GetMute()); }
    static IAudioEndpointVolume watched;
    static VolumeCallback callback;

    // (Re)subscribe to change notifications on the current default output device.
    public static void Watch() {
      try { if (watched != null && callback != null) watched.UnregisterControlChangeNotify(callback); } catch { }
      try {
        watched = Vol();
        callback = new VolumeCallback();
        Marshal.ThrowExceptionForHR(watched.RegisterControlChangeNotify(callback));
      } catch { watched = null; }
    }
  }

  // Windows "Do not disturb" (quiet hours profile). Isle turns it on while it runs so Windows'
  // own banners stay away; notifications still reach the notification center, where Isle reads them.
  [ComImport, Guid("6bff4732-81ec-4ffb-ae67-b6c1bc29631f"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IQuietHoursSettings {
    [PreserveSig] int get_UserSelectedProfile([MarshalAs(UnmanagedType.LPWStr)] out string id);
    [PreserveSig] int put_UserSelectedProfile([MarshalAs(UnmanagedType.LPWStr)] string id);
  }
  public static class Dnd {
    const string Off = "Microsoft.QuietHoursProfile.Unrestricted";
    const string On = "Microsoft.QuietHoursProfile.AlarmsOnly";
    static bool weTurnedOn = false;
    static IQuietHoursSettings S() {
      return (IQuietHoursSettings)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("f53321fa-34f8-4b7f-b9a3-361877cb94cf")));
    }
    public static string Current() { try { string id; S().get_UserSelectedProfile(out id); return id; } catch { return ""; } }
    // Turn DND on, but only remember to undo it if it was off (never override the user's own DND).
    public static void Enable() {
      try {
        if (weTurnedOn) return;
        if (Current() != Off) return;
        if (S().put_UserSelectedProfile(On) == 0) weTurnedOn = true;
      } catch { }
    }
    public static void Restore() {
      try {
        if (!weTurnedOn) return;
        if (Current() == On) S().put_UserSelectedProfile(Off);
        weTurnedOn = false;
      } catch { }
    }
    public static bool Active { get { return weTurnedOn; } }
  }

  // Reads a toast's full XML from the Windows notification database (for images such as
  // the sender's photo or a sticker). Works on a private copy so Windows is never blocked.
  public static class Wpn {
    [DllImport("winsqlite3.dll")] static extern int sqlite3_open_v2(byte[] file, out IntPtr db, int flags, IntPtr vfs);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_prepare_v2(IntPtr db, byte[] sql, int n, out IntPtr st, IntPtr tail);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_step(IntPtr st);
    [DllImport("winsqlite3.dll")] static extern IntPtr sqlite3_column_blob(IntPtr st, int i);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_column_bytes(IntPtr st, int i);
    [DllImport("winsqlite3.dll")] static extern long sqlite3_column_int64(IntPtr st, int i);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_finalize(IntPtr st);
    [DllImport("winsqlite3.dll")] static extern int sqlite3_close(IntPtr db);

    static void CopyShared(string from, string to) {
      using (var src = new System.IO.FileStream(from, System.IO.FileMode.Open, System.IO.FileAccess.Read, System.IO.FileShare.ReadWrite | System.IO.FileShare.Delete))
      using (var dst = new System.IO.FileStream(to, System.IO.FileMode.Create, System.IO.FileAccess.Write)) src.CopyTo(dst);
    }

    // Returns id -> payload XML for the given notification ids.
    public static System.Collections.Generic.Dictionary<long, string> Payloads(long[] ids) {
      var result = new System.Collections.Generic.Dictionary<long, string>();
      if (ids == null || ids.Length == 0) return result;
      string dir = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "isle-wpn");
      string src = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Microsoft\Windows\Notifications\wpndatabase.db");
      string db = System.IO.Path.Combine(dir, "wpn.db");
      try {
        System.IO.Directory.CreateDirectory(dir);
        CopyShared(src, db);
        if (System.IO.File.Exists(src + "-wal")) CopyShared(src + "-wal", db + "-wal"); else if (System.IO.File.Exists(db + "-wal")) System.IO.File.Delete(db + "-wal");
        if (System.IO.File.Exists(db + "-shm")) System.IO.File.Delete(db + "-shm");
        IntPtr h;
        if (sqlite3_open_v2(Encoding(db), out h, 2 /* READWRITE: needed to replay the WAL copy */, IntPtr.Zero) != 0) return result;
        var parts = new string[ids.Length];
        for (int i = 0; i < ids.Length; i++) parts[i] = ids[i].ToString();
        string sql = "SELECT Id, Payload FROM Notification WHERE Id IN (" + string.Join(",", parts) + ")";
        IntPtr st;
        if (sqlite3_prepare_v2(h, Encoding(sql), -1, out st, IntPtr.Zero) == 0) {
          while (sqlite3_step(st) == 100) {
            int n = sqlite3_column_bytes(st, 1);
            IntPtr p = sqlite3_column_blob(st, 1);
            if (p == IntPtr.Zero || n == 0) continue;
            var b = new byte[n]; Marshal.Copy(p, b, 0, n);
            result[sqlite3_column_int64(st, 0)] = System.Text.Encoding.UTF8.GetString(b);
          }
          sqlite3_finalize(st);
        }
        sqlite3_close(h);
      } catch { }
      finally {
        foreach (var f in new[] { db, db + "-wal", db + "-shm" }) { try { if (System.IO.File.Exists(f)) System.IO.File.Delete(f); } catch { } }
      }
      return result;
    }
    static byte[] Encoding(string s) { return System.Text.Encoding.UTF8.GetBytes(s + "\0"); }
  }

  // ---- Core Audio capture sessions: which processes are recording from a microphone right now.
  [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceEnumeratorFull {
    int EnumAudioEndpoints(int dataFlow, int stateMask, out IMMDeviceCollection devices);
  }
  [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceCollection {
    int GetCount(out uint count);
    int Item(uint index, out IMMDeviceAny device);
  }
  [Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IMMDeviceAny {
    int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
  }
  [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioSessionManager2 {
    int a(); int b();
    int GetSessionEnumerator(out IAudioSessionEnumerator sessions);
  }
  [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioSessionEnumerator {
    int GetCount(out int count);
    int GetSession(int index, out IAudioSessionControl2 session);
  }
  [Guid("bfb7ff88-7239-4fc9-8fa2-07c950be9c6d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  interface IAudioSessionControl2 {
    int GetState(out int state);
    int c(); int d(); int e(); int f(); int g(); int h(); int i(); int j();
    int k(); int l();
    int GetProcessId(out uint pid);
  }

  // ---- Calls: which calling app has the microphone open, the system mic mute, and pressing
  // the Accept / Decline / End-call buttons in that app's own window (UI Automation).
  public static class Calls {
    // Process names of apps that make voice / video calls.
    static readonly string[] CallApps = {
      "whatsapp", "whatsapp.root", "discord", "ms-teams", "teams", "zoom", "skype", "telegram",
      "messenger", "signal", "phoneexperiencehost", "viber", "slack", "webex", "ciscocollabhost", "lync"
    };
    public static bool IsCallApp(string proc) {
      string p = (proc ?? "").ToLowerInvariant();
      foreach (var a in CallApps) if (p == a) return true;
      return false;
    }

    // ---- Process tree: WhatsApp / Teams run their calls inside WebView2 child processes
    // (msedgewebview2.exe), so a mic or window owner is traced back up to the calling app.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PE32 {
      public uint dwSize; public uint cntUsage; public uint th32ProcessID; public IntPtr th32DefaultHeapID;
      public uint th32ModuleID; public uint cntThreads; public uint th32ParentProcessID; public int pcPriClassBase;
      public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32FirstW")] static extern bool PFirst(IntPtr h, ref PE32 e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, EntryPoint = "Process32NextW")] static extern bool PNext(IntPtr h, ref PE32 e);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);

    public class Proc { public uint Parent; public string Name; }
    // The process list barely changes, so one snapshot is reused for a few seconds.
    static System.Collections.Generic.Dictionary<uint, Proc> treeCache;
    static int treeAt;
    public static System.Collections.Generic.Dictionary<uint, Proc> Tree() {
      int now = Environment.TickCount;
      if (treeCache != null && unchecked(now - treeAt) < 4000) return treeCache;
      treeCache = Snapshot(); treeAt = now;
      return treeCache;
    }
    static System.Collections.Generic.Dictionary<uint, Proc> Snapshot() {
      var map = new System.Collections.Generic.Dictionary<uint, Proc>();
      IntPtr h = CreateToolhelp32Snapshot(2 /* TH32CS_SNAPPROCESS */, 0);
      if (h == IntPtr.Zero || h == new IntPtr(-1)) return map;
      try {
        var e = new PE32(); e.dwSize = (uint)Marshal.SizeOf(typeof(PE32));
        if (PFirst(h, ref e)) do {
          string n = e.szExeFile ?? "";
          if (n.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) n = n.Substring(0, n.Length - 4);
          map[e.th32ProcessID] = new Proc { Parent = e.th32ParentProcessID, Name = n };
        } while (PNext(h, ref e));
      } finally { CloseHandle(h); }
      return map;
    }
    // The calling app a process belongs to (itself or a parent), or null.
    public static string AppFor(uint pid, System.Collections.Generic.Dictionary<uint, Proc> map) {
      for (int i = 0; i < 8 && pid != 0; i++) {
        Proc p;
        if (!map.TryGetValue(pid, out p)) return null;
        if (IsCallApp(p.Name)) return p.Name;
        if (p.Parent == pid) return null;
        pid = p.Parent;
      }
      return null;
    }

    // On a call = a calling app (or one of its helper processes) has the microphone open.
    public static string ActiveCall() {
      var pids = MicUse.SessionPids(1);
      if (pids.Count == 0) return "";
      var map = Tree();
      // A process that started after the cached snapshot (e.g. the call's audio process): re-read.
      foreach (var pid in pids) if (!map.ContainsKey(pid)) { treeCache = Snapshot(); treeAt = Environment.TickCount; map = treeCache; break; }
      foreach (var pid in pids) { var a = AppFor(pid, map); if (a != null) return a; }
      return "";
    }

    // ---- Incoming call window. WhatsApp shows incoming calls in a small window of its own
    // (not always as a Windows notification). Returns "app\ttitle" or "".
    delegate bool EnumWinProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWinProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }

    static readonly System.Text.RegularExpressions.Regex CallTitle = new System.Text.RegularExpressions.Regex(
      @"\b(incoming|calling|ringing)\b|\b(voice|video|audio|group)\s+call\b|\bcall\b", System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    // Visible top-level windows of calling apps: "app\ttitle\tclass\tWxH" lines (also for the debug log).
    // smallOnly: only pop-up sized windows with a title (incoming-call candidates).
    public static System.Collections.Generic.List<string[]> CallWindows(bool smallOnly) {
      var list = new System.Collections.Generic.List<string[]>();
      var cand = new System.Collections.Generic.List<object[]>();
      EnumWindows((h, l) => {
        if (!IsWindowVisible(h)) return true;
        RECT r; GetWindowRect(h, out r);
        int w = r.R - r.L, hh = r.B - r.T;
        if (w < 80 || hh < 40) return true;
        if (smallOnly && (w > 720 || hh > 720)) return true;
        var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
        if (smallOnly && t.Length == 0) return true;
        int cloaked = 0;
        if (DwmGetWindowAttribute(h, 14 /* DWMWA_CLOAKED */, out cloaked, 4) == 0 && cloaked != 0) return true;
        uint pid; GetWindowThreadProcessId(h, out pid);
        cand.Add(new object[] { h, pid, t.ToString(), w, hh });
        return true;
      }, IntPtr.Zero);
      if (cand.Count == 0) return list;
      var map = Tree();
      foreach (var c in cand) {
        string app = AppFor((uint)c[1], map);
        if (app == null) continue;
        var cls = new System.Text.StringBuilder(256); GetClassName((IntPtr)c[0], cls, 256);
        list.Add(new[] { app, (string)c[2], cls.ToString(), c[3].ToString(), c[4].ToString(), ((IntPtr)c[0]).ToInt64().ToString() });
      }
      return list;
    }

    public static string RingWindow() {
      var wins = CallWindows(true);
      if (wins.Count == 0) return "";
      var map = Tree();
      // A ringtone (the app playing sound) helps tell a call pop-up from other small windows.
      var playing = new System.Collections.Generic.HashSet<string>();
      foreach (var pid in MicUse.SessionPids(0)) { var a = AppFor(pid, map); if (a != null) playing.Add(a.ToLowerInvariant()); }
      foreach (var w in wins) {
        string title = w[1];
        int ww = int.Parse(w[3]), wh = int.Parse(w[4]);
        bool small = ww <= 720 && wh <= 720;
        if ((CallTitle.IsMatch(title) && small) || (small && playing.Contains(w[0].ToLowerInvariant()) && title.Length > 0)) {
          lastCallHwnd = long.Parse(w[5]);
          return w[0] + "\t" + title + "\t" + CallerName(new IntPtr(lastCallHwnd), title);
        }
      }
      return "";
    }

    // Caller's name from the call window's own text (UI Automation), read once per window.
    static long callerHwnd; static string callerName = "";
    static readonly System.Text.RegularExpressions.Regex NotAName = new System.Text.RegularExpressions.Regex(
      @"\b(call|calling|ringing|incoming|whatsapp|encrypted|end-to-end|accept|decline|answer|reject|message|mute|camera|video|voice|minimi[sz]e|maximi[sz]e|close|restore)\b|^\d+:\d+$",
      System.Text.RegularExpressions.RegexOptions.IgnoreCase);
    public static string CallerName(IntPtr hwnd, string title) {
      if (hwnd.ToInt64() == callerHwnd) return callerName;
      callerHwnd = hwnd.ToInt64(); callerName = "";
      var log = new System.Text.StringBuilder();
      log.Append("[uia ").Append(DateTime.Now.ToString("HH:mm:ss")).Append("] ").Append(title).Append('\n');
      try {
        var el = System.Windows.Automation.AutomationElement.FromHandle(hwnd);
        var all = el.FindAll(System.Windows.Automation.TreeScope.Descendants, System.Windows.Automation.Condition.TrueCondition);
        int n = 0;
        foreach (System.Windows.Automation.AutomationElement e in all) {
          if (++n > 300) break;
          string name, type;
          try { name = (e.Current.Name ?? "").Trim(); type = e.Current.ControlType.ProgrammaticName.Replace("ControlType.", ""); } catch { continue; }
          if (name.Length == 0) continue;
          log.Append("  ").Append(type).Append(": ").Append(name.Length > 80 ? name.Substring(0, 80) : name).Append('\n');
          if (callerName.Length == 0 && type == "Text" && name.Length <= 40 && !NotAName.IsMatch(name)) callerName = name;
        }
      } catch (Exception ex) { log.Append("  error: ").Append(ex.Message).Append('\n'); }
      try { System.IO.File.AppendAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "isle-calls.log"), log.ToString()); } catch { }
      return callerName;
    }

    // Snapshot for the debug log: calling-app windows and which apps hold mic / speakers.
    public static string Debug() {
      var map = Tree();
      var sb = new System.Text.StringBuilder();
      foreach (var w in CallWindows(false)) sb.Append("win ").Append(string.Join(" | ", w)).Append('\n');
      foreach (var pid in MicUse.SessionPids(1)) { Proc p; map.TryGetValue(pid, out p); sb.Append("mic ").Append(p != null ? p.Name : "?").Append(" -> ").Append(AppFor(pid, map) ?? "-").Append('\n'); }
      foreach (var pid in MicUse.SessionPids(0)) { var a = AppFor(pid, map); if (a != null) sb.Append("spk ").Append(a).Append('\n'); }
      return sb.ToString();
    }

    // Capture-endpoint volume (default communications microphone).
    static IAudioEndpointVolume MicVol() {
      var en = new MMDeviceEnumeratorComObject() as IMMDeviceEnumerator;
      IMMDevice dev = null;
      Marshal.ThrowExceptionForHR(en.GetDefaultAudioEndpoint(1 /* eCapture */, 2 /* eCommunications */, out dev));
      IAudioEndpointVolume epv = null;
      var id = typeof(IAudioEndpointVolume).GUID;
      Marshal.ThrowExceptionForHR(dev.Activate(ref id, 23, 0, out epv));
      return epv;
    }
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    // Bring the calling app's window to the front (fallback when a button can't be pressed).
    public static void FocusApp(string proc) {
      try {
        foreach (var pname in proc.Split('|'))
          foreach (var p in System.Diagnostics.Process.GetProcessesByName(pname.Trim())) {
            IntPtr h = p.MainWindowHandle;
            if (h == IntPtr.Zero) continue;
            if (IsIconic(h)) ShowWindow(h, 9 /* SW_RESTORE */);
            SetForegroundWindow(h);
            return;
          }
      } catch { }
    }

    public static int MicMuted() { try { bool m; Marshal.ThrowExceptionForHR(MicVol().GetMute(out m)); return m ? 1 : 0; } catch { return -1; } }
    public static void SetMicMute(bool on) { try { MicVol().SetMute(on, Guid.Empty); } catch { } }

    // Find a button in the app's windows whose name matches and press it.
    // Runs on its own thread (UI trees can be slow) and reports {"t":"callbtn",...}.
    // The incoming-call window found by RingWindow (its buttons are pressed first).
    public static long lastCallHwnd;
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);

    public static void PressAsync(string proc, string kind, string pattern) {
      var t = new System.Threading.Thread(() => {
        bool ok = false; string hit = ""; var log = new System.Text.StringBuilder();
        log.Append("[press ").Append(kind).Append(' ').Append(DateTime.Now.ToString("HH:mm:ss")).Append("] ");
        try {
          var rx = new System.Text.RegularExpressions.Regex(pattern, System.Text.RegularExpressions.RegexOptions.IgnoreCase);
          var pids = new System.Collections.Generic.HashSet<uint>();
          foreach (var pname in proc.Split('|'))
            foreach (var p in System.Diagnostics.Process.GetProcessesByName(pname.Trim())) pids.Add((uint)p.Id);
          var buttons = new System.Windows.Automation.PropertyCondition(
            System.Windows.Automation.AutomationElement.ControlTypeProperty, System.Windows.Automation.ControlType.Button);
          // Chromium-based apps only build their accessibility tree after the first request, so look a few times.
          for (int attempt = 0; attempt < 4 && !ok; attempt++) {
            if (attempt > 0) System.Threading.Thread.Sleep(600);
            // Windows to search: the call window first, then every visible window of the app
            // (and of its WebView2 helper processes).
            var hwnds = new System.Collections.Generic.List<IntPtr>();
            if (lastCallHwnd != 0 && IsWindow(new IntPtr(lastCallHwnd))) hwnds.Add(new IntPtr(lastCallHwnd));
            var map = Snapshot();
            EnumWindows((h, l) => {
              if (!IsWindowVisible(h)) return true;
              uint pid; GetWindowThreadProcessId(h, out pid);
              uint up = pid;
              for (int i = 0; i < 8 && up != 0; i++) {
                if (pids.Contains(up)) { if (!hwnds.Contains(h)) hwnds.Add(h); break; }
                Proc pp; if (!map.TryGetValue(up, out pp) || pp.Parent == up) break;
                up = pp.Parent;
              }
              return true;
            }, IntPtr.Zero);
            if (attempt == 0) log.Append(hwnds.Count).Append(" windows; ");
            foreach (var h in hwnds) {
              System.Windows.Automation.AutomationElementCollection found;
              try { found = System.Windows.Automation.AutomationElement.FromHandle(h).FindAll(System.Windows.Automation.TreeScope.Descendants, buttons); }
              catch { continue; }
              foreach (System.Windows.Automation.AutomationElement b in found) {
                string name;
                try { name = b.Current.Name ?? ""; } catch { continue; }
                if (!rx.IsMatch(name)) continue;
                log.Append("found '").Append(name).Append("' ");
                object pat;
                try {
                  if (b.TryGetCurrentPattern(System.Windows.Automation.InvokePattern.Pattern, out pat)) {
                    ((System.Windows.Automation.InvokePattern)pat).Invoke(); ok = true;
                  } else if (b.TryGetCurrentPattern(System.Windows.Automation.TogglePattern.Pattern, out pat)) {
                    ((System.Windows.Automation.TogglePattern)pat).Toggle(); ok = true;
                  } else log.Append("(no invoke) ");
                } catch (Exception ex) { log.Append("(error ").Append(ex.Message).Append(") "); }
                if (ok) { hit = name; break; }
              }
              if (ok) break;
            }
          }
        } catch (Exception ex) { log.Append("error ").Append(ex.Message); }
        log.Append(ok ? "-> pressed" : "-> not pressed").Append('\n');
        try { System.IO.File.AppendAllText(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "isle-calls.log"), log.ToString()); } catch { }
        Out.Line("{\"t\":\"callbtn\",\"kind\":\"" + kind + "\",\"ok\":" + (ok ? "true" : "false") + ",\"name\":\"" + hit.Replace("\\", "").Replace("\"", "") + "\"}");
      });
      t.IsBackground = true;
      t.SetApartmentState(System.Threading.ApartmentState.STA);
      t.Start();
    }
  }

  // Give unused memory of Isle's own processes back to Windows (working-set trim).
  public static class Mem {
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool SetProcessWorkingSetSize(IntPtr h, IntPtr min, IntPtr max);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    public static void Trim(int pid) {
      IntPtr h = OpenProcess(0x0100 /* SET_QUOTA */ | 0x0400 /* QUERY_INFORMATION */, false, pid);
      if (h == IntPtr.Zero) return;
      try { SetProcessWorkingSetSize(h, new IntPtr(-1), new IntPtr(-1)); } finally { CloseHandle(h); }
    }
  }

  public static class MicUse {
    // Process ids with an active audio session: flow 1 = microphone (capture), 0 = speakers (render).
    public static System.Collections.Generic.List<uint> SessionPids(int flow) {
      var names = new System.Collections.Generic.List<uint>();
      int self = System.Diagnostics.Process.GetCurrentProcess().Id;
      try {
        var en = (IMMDeviceEnumeratorFull)(new MMDeviceEnumeratorComObject());
        IMMDeviceCollection col;
        if (en.EnumAudioEndpoints(flow, 1, out col) != 0) return names;
        uint count; col.GetCount(out count);
        var iid = typeof(IAudioSessionManager2).GUID;
        for (uint n = 0; n < count; n++) {
          IMMDeviceAny dev;
          if (col.Item(n, out dev) != 0) continue;
          object o;
          if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) continue;
          IAudioSessionEnumerator sessions;
          if (((IAudioSessionManager2)o).GetSessionEnumerator(out sessions) != 0) continue;
          int sc; sessions.GetCount(out sc);
          for (int s = 0; s < sc; s++) {
            IAudioSessionControl2 ctl;
            if (sessions.GetSession(s, out ctl) != 0 || ctl == null) continue;
            int state; ctl.GetState(out state);
            if (state != 1) continue;
            uint pid; ctl.GetProcessId(out pid);
            if (pid == 0 || pid == self) continue;
            if (!names.Contains(pid)) names.Add(pid);
          }
        }
      } catch { }
      return names;
    }

    // Names of processes with an active capture (recording) session on any microphone.
    public static System.Collections.Generic.List<string> Apps() {
      var names = new System.Collections.Generic.List<string>();
      int self = System.Diagnostics.Process.GetCurrentProcess().Id;
      try {
        var en = (IMMDeviceEnumeratorFull)(new MMDeviceEnumeratorComObject());
        IMMDeviceCollection col;
        if (en.EnumAudioEndpoints(1 /* eCapture */, 1 /* ACTIVE */, out col) != 0) return names;
        uint count; col.GetCount(out count);
        var iid = typeof(IAudioSessionManager2).GUID;
        for (uint n = 0; n < count; n++) {
          IMMDeviceAny dev;
          if (col.Item(n, out dev) != 0) continue;
          object o;
          if (dev.Activate(ref iid, 23, IntPtr.Zero, out o) != 0) continue;
          IAudioSessionEnumerator sessions;
          if (((IAudioSessionManager2)o).GetSessionEnumerator(out sessions) != 0) continue;
          int sc; sessions.GetCount(out sc);
          for (int s = 0; s < sc; s++) {
            IAudioSessionControl2 ctl;
            if (sessions.GetSession(s, out ctl) != 0 || ctl == null) continue;
            int state; ctl.GetState(out state);
            if (state != 1 /* AudioSessionStateActive */) continue;
            uint pid; ctl.GetProcessId(out pid);
            if (pid == 0 || pid == self) continue;
            string name = Privacy.ProcessLabel((int)pid);
            if (name != null && !names.Contains(name)) names.Add(name);
          }
        }
      } catch { }
      return names;
    }
  }

  // Which apps are using the microphone / camera right now. Windows records this for its own
  // privacy indicators: LastUsedTimeStop == 0 means "still in use".
  public static class Privacy {
    // Friendly app name for a process id ("Discord", "Google Chrome", ...).
    // Uses only the program's file path (limited query access) and remembers the answer: reading
    // a process's module list instead was slow (~0.8 s for games with anti-cheat) and ran every second.
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, System.Text.StringBuilder path, ref int size);
    static readonly System.Collections.Generic.Dictionary<string, string> labels = new System.Collections.Generic.Dictionary<string, string>();
    public static string ProcessLabel(int pid) {
      try {
        // Key on pid + process name, so a reused pid isn't mixed up with an old program.
        Calls.Proc pr; string pname = Calls.Tree().TryGetValue((uint)pid, out pr) ? pr.Name : "";
        string key = pid + ":" + pname, cached;
        lock (labels) if (labels.TryGetValue(key, out cached)) return cached;
        string path = null;
        IntPtr h = OpenProcess(0x1000 /* PROCESS_QUERY_LIMITED_INFORMATION */, false, pid);
        if (h != IntPtr.Zero) {
          var sb = new System.Text.StringBuilder(1024); int size = sb.Capacity;
          if (QueryFullProcessImageName(h, 0, sb, ref size)) path = sb.ToString();
          CloseHandle(h);
        }
        string desc = null;
        if (path != null) { try { desc = System.Diagnostics.FileVersionInfo.GetVersionInfo(path).FileDescription; } catch { } }
        string n = !string.IsNullOrWhiteSpace(desc) && desc.Length <= 32 ? desc.Trim()
                 : path != null ? System.IO.Path.GetFileNameWithoutExtension(path)
                 : pname.Length > 0 ? pname : System.Diagnostics.Process.GetProcessById(pid).ProcessName;
        if (n.Length > 0) n = char.ToUpper(n[0]) + n.Substring(1);
        lock (labels) { if (labels.Count > 300) labels.Clear(); labels[key] = n; }
        return n;
      } catch { return null; }
    }
    const string Root = @"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\";

    static bool InUse(Microsoft.Win32.RegistryKey k) {
      if (k == null) return false;
      object start = k.GetValue("LastUsedTimeStart"), stop = k.GetValue("LastUsedTimeStop");
      return start != null && stop != null && Convert.ToInt64(start) != 0 && Convert.ToInt64(stop) == 0;
    }

    static string Pretty(string key, bool desktop) {
      string s = key;
      if (desktop) {                       // C:#Program Files#Discord#Discord.exe
        s = s.Replace('#', '\\');
        int i = s.LastIndexOf('\\'); if (i >= 0) s = s.Substring(i + 1);
        if (s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase)) s = s.Substring(0, s.Length - 4);
      } else {                             // Microsoft.WindowsCamera_8wekyb3d8bbwe
        int u = s.IndexOf('_'); if (u > 0) s = s.Substring(0, u);
        int d = s.LastIndexOf('.'); if (d >= 0) s = s.Substring(d + 1);
      }
      return s.Length > 0 ? char.ToUpper(s[0]) + s.Substring(1) : key;
    }

    static string[] Scan(string capability) {
      var found = new System.Collections.Generic.List<string>();
      foreach (var hive in new[] { Microsoft.Win32.Registry.CurrentUser, Microsoft.Win32.Registry.LocalMachine }) {
        try {
          using (var root = hive.OpenSubKey(Root + capability)) {
            if (root == null) continue;
            foreach (var name in root.GetSubKeyNames()) {
              using (var k = root.OpenSubKey(name)) {
                if (k == null) continue;
                if (name == "NonPackaged") {
                  foreach (var sub in k.GetSubKeyNames())
                    using (var k2 = k.OpenSubKey(sub)) if (InUse(k2)) { var p = Pretty(sub, true); if (!found.Contains(p)) found.Add(p); }
                } else if (InUse(k)) { var p = Pretty(name, false); if (!found.Contains(p)) found.Add(p); }
              }
            }
          }
        } catch { }
      }
      return found.ToArray();
    }

    static string Arr(string[] a) {
      var parts = new string[a.Length];
      for (int i = 0; i < a.Length; i++) parts[i] = "\"" + a[i].Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
      return "[" + string.Join(",", parts) + "]";
    }

    public static string Json() {
      // Microphone: live Core Audio sessions (works on every build), plus the older privacy records.
      var mic = MicUse.Apps();
      foreach (var n in Scan("microphone")) if (!mic.Contains(n)) mic.Add(n);
      // Camera: apps that use the camera go through the Windows Camera Frame Server, which starts
      // the moment a camera opens (it lingers ~30-60 s after the camera closes).
      var cam = new System.Collections.Generic.List<string>(Scan("webcam"));
      if (cam.Count == 0 && FrameServerRunning()) cam.Add("Camera");
      return "{\"t\":\"privacy\",\"mic\":" + Arr(mic.ToArray()) + ",\"cam\":" + Arr(cam.ToArray()) + "}";
    }

    static bool FrameServerRunning() {
      try {
        using (var sc = new System.ServiceProcess.ServiceController("FrameServer"))
          return sc.Status == System.ServiceProcess.ServiceControllerStatus.Running;
      } catch { return false; }
    }
  }

  // Game controllers on USB or a wireless USB receiver (Xbox-style / XInput). These aren't
  // Bluetooth devices, so the Bluetooth list never sees them. Up to 4, like Windows.
  public static class Pads {
    [StructLayout(LayoutKind.Sequential)] struct XS { public uint packet; public ushort buttons; public byte lt, rt; public short lx, ly, rx, ry; }
    [StructLayout(LayoutKind.Sequential)] struct XB { public byte type; public byte level; }
    [DllImport("xinput1_4.dll")] static extern uint XInputGetState(uint i, out XS s);
    [DllImport("xinput1_4.dll")] static extern uint XInputGetBatteryInformation(uint i, byte dev, out XB b);
    static bool broken;

    // One entry per connected controller: name, and battery 0-100 (-1 = wired / not reported).
    public static System.Collections.Generic.List<System.Collections.Generic.KeyValuePair<string, int>> List() {
      var o = new System.Collections.Generic.List<System.Collections.Generic.KeyValuePair<string, int>>();
      if (broken) return o;
      try {
        int n = 0;
        for (uint i = 0; i < 4; i++) {
          XS s;
          if (XInputGetState(i, out s) != 0) continue;
          n++;
          int level = -1;
          XB b;
          // type 2 = alkaline, 3 = NiMH (1 = wired, 0xFF = unknown); level 0-3 = empty..full
          if (XInputGetBatteryInformation(i, 0, out b) == 0 && (b.type == 2 || b.type == 3))
            level = new[] { 5, 30, 65, 100 }[Math.Min((int)b.level, 3)];
          o.Add(new System.Collections.Generic.KeyValuePair<string, int>(n == 1 ? "Controller" : "Controller " + n, level));
        }
      } catch { broken = true; }   // no XInput on this PC
      return o;
    }

    public static string Json(System.Collections.Generic.List<System.Collections.Generic.KeyValuePair<string, int>> list) {
      var sb = new System.Text.StringBuilder("{\"t\":\"pads\",\"list\":[");
      for (int i = 0; i < list.Count; i++) {
        if (i > 0) sb.Append(',');
        sb.Append("{\"name\":\"").Append(list[i].Key).Append("\",\"kind\":\"gamepad\",\"battery\":")
          .Append(list[i].Value < 0 ? "null,\"wired\":true" : list[i].Value.ToString()).Append('}');
      }
      return sb.Append("]}").ToString();
    }
  }

  // ---------------------------------------------------------------- Dock
  // The apps that have windows on the taskbar (grouped like the taskbar: by app ID, else by
  // program file), their icons, switching to them, Windows' taskbar auto-hide, and keeping
  // screen space for the Dock (an "app bar", like the taskbar's own, so maximized windows
  // stop above it).
  public static class Dock {
    delegate bool EnumProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string cls, string title);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out int v, int size);
    [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access, bool inherit, uint pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, System.Text.StringBuilder s, ref int size);
    [DllImport("shell32.dll")] static extern int SHGetPropertyStoreForWindow(IntPtr h, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHGetPropertyStoreFromParsingName(string path, IntPtr bc, int flags, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IPropertyStore store);
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern int SHCreateItemFromParsingName(string path, IntPtr bc, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory f);
    [DllImport("ole32.dll")] static extern int PropVariantClear(ref PROPVARIANT v);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    [DllImport("gdi32.dll")] static extern int GetObject(IntPtr h, int size, ref BITMAP bm);
    [DllImport("gdi32.dll")] static extern int GetDIBits(IntPtr hdc, IntPtr hbmp, uint start, uint lines, byte[] bits, ref BITMAPINFOHEADER bi, uint usage);
    [DllImport("user32.dll")] static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("shell32.dll")] static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA d);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(POINT p, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr ctx);

    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
      [PreserveSig] int GetCount(out uint c);
      [PreserveSig] int GetAt(uint i, out PROPERTYKEY k);
      [PreserveSig] int GetValue(ref PROPERTYKEY k, out PROPVARIANT v);
      [PreserveSig] int SetValue(ref PROPERTYKEY k, ref PROPVARIANT v);
      [PreserveSig] int Commit();
    }
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItemImageFactory { [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr hbmp); }
    [StructLayout(LayoutKind.Sequential, Pack = 4)] struct PROPERTYKEY { public Guid fmtid; public uint pid; }
    [StructLayout(LayoutKind.Explicit, Size = 24)] struct PROPVARIANT { [FieldOffset(0)] public ushort vt; [FieldOffset(8)] public IntPtr p; }
    [StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential)] struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public ushort bmPlanes, bmBitsPixel; public IntPtr bmBits; }
    [StructLayout(LayoutKind.Sequential)] struct BITMAPINFOHEADER { public int biSize, biWidth, biHeight; public ushort biPlanes, biBitCount; public int biCompression, biSizeImage, biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [StructLayout(LayoutKind.Sequential)] struct APPBARDATA { public int cbSize; public IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public IntPtr lParam; }

    static Guid IID_PropStore = new Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99");
    static Guid IID_ImageFactory = new Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b");
    static PROPERTYKEY PKEY_AUMID = new PROPERTYKEY { fmtid = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), pid = 5 };

    static string ReadAumid(IPropertyStore st) {
      if (st == null) return null;
      try {
        PROPVARIANT v;
        if (st.GetValue(ref PKEY_AUMID, out v) != 0) return null;
        string s = v.vt == 31 ? Marshal.PtrToStringUni(v.p) : null;   // VT_LPWSTR
        PropVariantClear(ref v);
        return string.IsNullOrEmpty(s) ? null : s;
      } catch { return null; } finally { try { Marshal.ReleaseComObject(st); } catch { } }
    }
    static string WindowAumid(IntPtr h) {
      IPropertyStore st; return SHGetPropertyStoreForWindow(h, ref IID_PropStore, out st) == 0 ? ReadAumid(st) : null;
    }
    // App ID written in a shortcut (.lnk), e.g. Discord's; null when it has none.
    public static string FileAumid(string path) {
      IPropertyStore st; return SHGetPropertyStoreFromParsingName(path, IntPtr.Zero, 0, ref IID_PropStore, out st) == 0 ? ReadAumid(st) : null;
    }

    // ---- Store (packaged) apps such as WhatsApp: their program file has only a blank icon and a
    // name like "WhatsApp.Root"; the real icon and name belong to the package. Work out the app's
    // ID (package family name + "!" + app id from its manifest) from the install folder.
    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IShellItem {
      [PreserveSig] int BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
      [PreserveSig] int GetParent(out IShellItem ppsi);
      [PreserveSig] int GetDisplayName(uint sigdn, out IntPtr name);
      [PreserveSig] int GetAttributes(uint mask, out uint attrs);
      [PreserveSig] int Compare(IShellItem psi, uint hint, out int order);
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "SHCreateItemFromParsingName")]
    static extern int SHCreateShellItem(string path, IntPtr bc, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out IShellItem item);
    static Guid IID_ShellItem = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
    static readonly System.Collections.Generic.Dictionary<string, string[]> pkgCache = new System.Collections.Generic.Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);
    // { app ID, display name } for a program inside a Store package; null for other programs.
    public static string[] PackagedApp(string exe) {
      if (string.IsNullOrEmpty(exe) || exe.IndexOf(@"\WindowsApps\", StringComparison.OrdinalIgnoreCase) < 0) return null;
      string[] r;
      if (pkgCache.TryGetValue(exe, out r)) return r;
      r = null;
      try {
        // ...\WindowsApps\<Name>_<Version>_<Arch>_<ResourceId>_<PublisherId>\...
        var m = System.Text.RegularExpressions.Regex.Match(exe, @"\\WindowsApps\\([^\\_]+)_[^\\_]*_[^\\_]*_[^\\_]*_([^\\_]+)\\", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        if (m.Success) {
          string pfn = m.Groups[1].Value + "_" + m.Groups[2].Value;
          string dir = exe.Substring(0, m.Index + m.Length);
          string appId = "App";
          try {
            string xml = System.IO.File.ReadAllText(System.IO.Path.Combine(dir, "AppxManifest.xml"));
            string leaf = System.IO.Path.GetFileName(exe);
            string first = null;
            foreach (System.Text.RegularExpressions.Match a in System.Text.RegularExpressions.Regex.Matches(xml, @"<Application\b[^>]*>", System.Text.RegularExpressions.RegexOptions.IgnoreCase)) {
              var id = System.Text.RegularExpressions.Regex.Match(a.Value, @"\bId=""([^""]+)""");
              var ex = System.Text.RegularExpressions.Regex.Match(a.Value, @"\bExecutable=""([^""]+)""");
              if (!id.Success) continue;
              if (first == null) first = id.Groups[1].Value;
              if (ex.Success && ex.Groups[1].Value.EndsWith(leaf, StringComparison.OrdinalIgnoreCase)) { appId = id.Groups[1].Value; first = null; break; }
            }
            if (first != null) appId = first;
          } catch { }
          string aumid = pfn + "!" + appId;
          string name = null;
          IShellItem it;
          if (SHCreateShellItem(@"shell:AppsFolder\" + aumid, IntPtr.Zero, ref IID_ShellItem, out it) == 0 && it != null) {
            IntPtr p;
            if (it.GetDisplayName(0, out p) == 0 && p != IntPtr.Zero) { name = Marshal.PtrToStringUni(p); Marshal.FreeCoTaskMem(p); }
            Marshal.ReleaseComObject(it);
            r = new[] { aumid, string.IsNullOrEmpty(name) ? AppName(exe) : name };
          }
        }
      } catch { }
      pkgCache[exe] = r;
      return r;
    }

    static readonly System.Collections.Generic.Dictionary<uint, string> exeCache = new System.Collections.Generic.Dictionary<uint, string>();
    static string ExePath(uint pid) {
      string s;
      if (exeCache.TryGetValue(pid, out s)) return s;
      s = null;
      IntPtr h = OpenProcess(0x1000, false, pid);   // PROCESS_QUERY_LIMITED_INFORMATION
      if (h != IntPtr.Zero) {
        var sb = new System.Text.StringBuilder(1024); int n = sb.Capacity;
        if (QueryFullProcessImageName(h, 0, sb, ref n)) s = sb.ToString();
        CloseHandle(h);
      }
      if (exeCache.Count > 400) exeCache.Clear();
      exeCache[pid] = s;
      return s;
    }
    static readonly System.Collections.Generic.Dictionary<string, string> nameCache = new System.Collections.Generic.Dictionary<string, string>();
    static string AppName(string exe) {
      string n;
      if (nameCache.TryGetValue(exe, out n)) return n;
      n = null;
      try { var vi = System.Diagnostics.FileVersionInfo.GetVersionInfo(exe); n = (vi.FileDescription ?? "").Trim(); if (n.Length == 0) n = (vi.ProductName ?? "").Trim(); } catch { }
      if (string.IsNullOrEmpty(n)) n = System.IO.Path.GetFileNameWithoutExtension(exe);
      nameCache[exe] = n;
      return n;
    }

    class Win { public IntPtr H; public string Key, Exe, Aumid, Title; public bool Min; }
    static readonly string[] SkipClass = { "Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd", "Windows.UI.Core.CoreWindow" };
    static readonly string[] SkipExe = { "isle", "textinputhost", "shellexperiencehost", "searchhost", "startmenuexperiencehost", "lockapp", "applicationframehost_hidden" };

    // Windows the taskbar would show, front to back.
    static System.Collections.Generic.List<Win> TaskWindows() {
      var list = new System.Collections.Generic.List<Win>();
      var cls = new System.Text.StringBuilder(128);
      EnumWindows((h, l) => {
        if (!IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero) return true;   // GW_OWNER: owned pop-ups aren't on the taskbar
        int ex = GetWindowLong(h, -20);
        bool appWin = (ex & 0x40000) != 0;                                          // WS_EX_APPWINDOW
        if (!appWin && ((ex & 0x80) != 0 || (ex & 0x08000000) != 0)) return true;   // tool / no-activate windows
        if ((ex & 0x80020) == 0x80020) return true;                                // click-through overlays (layered + transparent)
        int cloaked; if (DwmGetWindowAttribute(h, 14, out cloaked, 4) == 0 && cloaked != 0) return true;   // hidden UWP / other desktops
        if (GetWindowTextLength(h) == 0) return true;
        cls.Length = 0; GetClassName(h, cls, 128);
        if (Array.IndexOf(SkipClass, cls.ToString()) >= 0) return true;
        uint pid; GetWindowThreadProcessId(h, out pid);
        string exe = ExePath(pid);
        if (exe == null) return true;
        if (Array.IndexOf(SkipExe, System.IO.Path.GetFileNameWithoutExtension(exe).ToLowerInvariant()) >= 0) return true;
        var t = new System.Text.StringBuilder(256); GetWindowText(h, t, 256);
        string aumid = WindowAumid(h);
        if (aumid == null) { var pk = PackagedApp(exe); if (pk != null) aumid = pk[0]; }   // Store apps: the package's app ID
        list.Add(new Win { H = h, Exe = exe, Aumid = aumid, Title = t.ToString(), Min = IsIconic(h), Key = (aumid ?? exe).ToLowerInvariant() });
        return true;
      }, IntPtr.Zero);
      return list;
    }

    static string Esc(string s) {
      if (s == null) return "";
      var sb = new System.Text.StringBuilder();
      foreach (char c in s) {
        if (c == '"' || c == '\\') sb.Append('\\').Append(c);
        else if (c < 32) sb.Append("\\u").Append(((int)c).ToString("x4"));
        else sb.Append(c);
      }
      return sb.ToString();
    }

    // {"t":"dockapps","apps":[{key, exe, aumid, name, n (windows), active, min}]}, front-most app first.
    public static string AppsJson() {
      IntPtr fg = GetForegroundWindow();
      var order = new System.Collections.Generic.List<string>();
      var groups = new System.Collections.Generic.Dictionary<string, System.Collections.Generic.List<Win>>();
      foreach (var w in TaskWindows()) {
        if (!groups.ContainsKey(w.Key)) { groups[w.Key] = new System.Collections.Generic.List<Win>(); order.Add(w.Key); }
        groups[w.Key].Add(w);
      }
      var sb = new System.Text.StringBuilder("{\"t\":\"dockapps\",\"apps\":[");
      bool first = true;
      foreach (var k in order) {
        var g = groups[k]; var w0 = g[0];
        bool active = false, allMin = true;
        foreach (var w in g) { if (w.H == fg) active = true; if (!w.Min) allMin = false; }
        bool frame = System.IO.Path.GetFileName(w0.Exe).Equals("ApplicationFrameHost.exe", StringComparison.OrdinalIgnoreCase);
        var pkg = frame ? null : PackagedApp(w0.Exe);
        string name = frame ? w0.Title : pkg != null ? pkg[1] : AppName(w0.Exe);
        if (!first) sb.Append(','); first = false;
        sb.Append("{\"key\":\"").Append(Esc(k)).Append("\",\"exe\":\"").Append(Esc(frame ? "" : w0.Exe))
          .Append("\",\"aumid\":\"").Append(Esc(w0.Aumid)).Append("\",\"name\":\"").Append(Esc(name))
          .Append("\",\"n\":").Append(g.Count).Append(",\"active\":").Append(active ? "true" : "false")
          .Append(",\"min\":").Append(allMin ? "true" : "false").Append('}');
      }
      return sb.Append("]}").ToString();
    }

    // The Dock's key for a window's app (same as the open-apps list): app ID, else program file.
    public static string KeyOf(IntPtr h) {
      uint pid; GetWindowThreadProcessId(h, out pid);
      string exe = ExePath(pid);
      if (exe == null) return null;
      string aumid = WindowAumid(h);
      if (aumid == null) { var pk = PackagedApp(exe); if (pk != null) aumid = pk[0]; }
      return (aumid ?? exe).ToLowerInvariant();
    }
    // A window the taskbar / Dock would show (not a tool window, pop-up or Isle's own).
    public static bool IsAppWindow(IntPtr h) {
      if (!IsWindowVisible(h) || GetWindow(h, 4) != IntPtr.Zero || GetWindowTextLength(h) == 0) return false;
      int ex = GetWindowLong(h, -20);
      if ((ex & 0x40000) == 0 && ((ex & 0x80) != 0 || (ex & 0x08000000) != 0)) return false;
      if ((ex & 0x80020) == 0x80020) return false;   // click-through overlays: nothing to animate
      var cls = new System.Text.StringBuilder(128); GetClassName(h, cls, 128);
      if (Array.IndexOf(SkipClass, cls.ToString()) >= 0) return false;
      uint pid; GetWindowThreadProcessId(h, out pid);
      string exe = ExePath(pid);
      return exe != null && Array.IndexOf(SkipExe, System.IO.Path.GetFileNameWithoutExtension(exe).ToLowerInvariant()) < 0;
    }

    internal static void Front(IntPtr h) {
      if (IsIconic(h)) ShowWindow(h, 9);   // SW_RESTORE
      IntPtr fg = GetForegroundWindow();
      uint dummy; uint fgThread = GetWindowThreadProcessId(fg, out dummy), me = GetCurrentThreadId();
      bool attached = fgThread != 0 && fgThread != me && AttachThreadInput(me, fgThread, true);
      SetForegroundWindow(h);
      BringWindowToTop(h);
      if (attached) AttachThreadInput(me, fgThread, false);
      if (GetForegroundWindow() != h) SwitchToThisWindow(h, true);
    }

    // Clicking a running app: bring its front window forward; if it's already in front, minimize
    // it (like the taskbar). With several windows already in front, the next one comes forward.
    public static string Activate(string key) {
      key = (key ?? "").ToLowerInvariant();
      var mine = TaskWindows().FindAll(w => w.Key == key);
      if (mine.Count == 0) return "none";
      IntPtr fg = GetForegroundWindow();
      int at = mine.FindIndex(w => w.H == fg);
      if (at < 0) {
        Front(mine[0].H); return "front";
      }
      if (mine.Count > 1) { Front(mine[mine.Count - 1].H); return "next"; }
      ShowWindow(fg, 6);   // SW_MINIMIZE
      return "min";
    }

    public static int Quit(string key) {
      key = (key ?? "").ToLowerInvariant();
      int n = 0;
      foreach (var w in TaskWindows()) if (w.Key == key) { PostMessage(w.H, 0x10, IntPtr.Zero, IntPtr.Zero); n++; }   // WM_CLOSE
      return n;
    }

    // A file's / app's icon as a PNG data URL (with transparency). Tries each path in turn:
    // a shortcut, a program, a folder, or "shell:AppsFolder\<app ID>" for Store apps.
    public static string IconUrl(string[] paths, int size) {
      foreach (var p in paths) {
        if (string.IsNullOrEmpty(p)) continue;
        try {
          IShellItemImageFactory f;
          if (SHCreateItemFromParsingName(p, IntPtr.Zero, ref IID_ImageFactory, out f) != 0 || f == null) continue;
          IntPtr hb;
          int hr = f.GetImage(new SIZE { cx = size, cy = size }, 0x1 | 0x4, out hb);   // BIGGERSIZEOK | ICONONLY
          Marshal.ReleaseComObject(f);
          if (hr != 0 || hb == IntPtr.Zero) continue;
          try { var url = ToPng(hb); if (url != null) return url; } finally { DeleteObject(hb); }
        } catch { }
      }
      return null;
    }
    static string ToPng(IntPtr hb) {
      var bm = new BITMAP();
      if (GetObject(hb, Marshal.SizeOf(typeof(BITMAP)), ref bm) == 0) return null;
      int w = bm.bmWidth, h = Math.Abs(bm.bmHeight);
      if (w <= 0 || h <= 0) return null;
      var bi = new BITMAPINFOHEADER { biSize = 40, biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
      var bytes = new byte[w * h * 4];
      IntPtr dc = GetDC(IntPtr.Zero);
      int got = GetDIBits(dc, hb, 0, (uint)h, bytes, ref bi, 0);
      ReleaseDC(IntPtr.Zero, dc);
      if (got == 0) return null;
      bool anyAlpha = false;
      for (int i = 3; i < bytes.Length; i += 4) if (bytes[i] != 0) { anyAlpha = true; break; }
      if (!anyAlpha) for (int i = 3; i < bytes.Length; i += 4) bytes[i] = 255;   // old icons without transparency
      using (var bmp = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppPArgb)) {
        var data = bmp.LockBits(new System.Drawing.Rectangle(0, 0, w, h), System.Drawing.Imaging.ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppPArgb);
        for (int y = 0; y < h; y++) Marshal.Copy(bytes, y * w * 4, data.Scan0 + y * data.Stride, w * 4);
        bmp.UnlockBits(data);
        using (var ms = new System.IO.MemoryStream()) {
          bmp.Save(ms, System.Drawing.Imaging.ImageFormat.Png);
          return "data:image/png;base64," + Convert.ToBase64String(ms.ToArray());
        }
      }
    }

    // ---- Windows' taskbar: auto-hide on / back to how it was.
    const uint ABM_NEW = 0, ABM_REMOVE = 1, ABM_QUERYPOS = 2, ABM_SETPOS = 3, ABM_GETSTATE = 4, ABM_SETSTATE = 10;
    public static bool TaskbarAutoHide {
      get { var d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d); return ((uint)SHAppBarMessage(ABM_GETSTATE, ref d) & 1) != 0; }
      set {
        var d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d);
        d.hWnd = FindWindow("Shell_TrayWnd", null);
        d.lParam = (IntPtr)(value ? 1 : 0);
        SHAppBarMessage(ABM_SETSTATE, ref d);
      }
    }

    // ---- Screen space kept free on the main screen (px = physical pixels): the Dock at the bottom,
    // the menu bar at the top. Reserve(hwnd, 0) gives one back; Reserve(Zero, 0) gives all back.
    static readonly System.Collections.Generic.Dictionary<IntPtr, bool> bars = new System.Collections.Generic.Dictionary<IntPtr, bool>();
    public static void Reserve(IntPtr hwnd, int px) { Reserve(hwnd, px, false); }
    public static void Reserve(IntPtr hwnd, int px, bool top) {
      IntPtr old = SetThreadDpiAwarenessContext((IntPtr)(-4));   // per-monitor aware: real pixels
      try {
        var d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d);
        if (hwnd == IntPtr.Zero) {
          foreach (var h in new System.Collections.Generic.List<IntPtr>(bars.Keys)) { d.hWnd = h; SHAppBarMessage(ABM_REMOVE, ref d); }
          bars.Clear();
          return;
        }
        if (px <= 0) {
          if (bars.ContainsKey(hwnd)) { d.hWnd = hwnd; SHAppBarMessage(ABM_REMOVE, ref d); bars.Remove(hwnd); }
          return;
        }
        if (!bars.ContainsKey(hwnd)) {
          d.hWnd = hwnd; d.uCallbackMessage = 0x400 + 0x1A0;
          SHAppBarMessage(ABM_NEW, ref d);
        }
        bars[hwnd] = top;
        var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(mi);
        GetMonitorInfo(MonitorFromPoint(new POINT(), 1), ref mi);   // MONITOR_DEFAULTTOPRIMARY
        d.hWnd = hwnd; d.uEdge = top ? 1u : 3u;                      // ABE_TOP / ABE_BOTTOM
        d.rc = mi.rcMonitor;
        if (top) d.rc.B = d.rc.T + px; else d.rc.T = d.rc.B - px;
        SHAppBarMessage(ABM_QUERYPOS, ref d);
        if (top) d.rc.B = d.rc.T + px; else d.rc.T = d.rc.B - px;
        SHAppBarMessage(ABM_SETPOS, ref d);
      } finally { if (old != IntPtr.Zero) SetThreadDpiAwarenessContext(old); }
    }

    // ---- Windows' taskbar hidden completely (the Dock + menu bar replace it), and back.
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    static System.Collections.Generic.List<IntPtr> Taskbars() {
      var l = new System.Collections.Generic.List<IntPtr>();
      foreach (var cls in new[] { "Shell_TrayWnd", "Shell_SecondaryTrayWnd" }) {
        IntPtr h = IntPtr.Zero;
        while ((h = FindWindowEx(IntPtr.Zero, h, cls, null)) != IntPtr.Zero) l.Add(h);
      }
      return l;
    }
    public static bool TaskbarShown { get { var h = FindWindow("Shell_TrayWnd", null); return h != IntPtr.Zero && IsWindowVisible(h); } }
    public static void ShowTaskbar(bool show) { foreach (var h in Taskbars()) ShowWindow(h, show ? 5 : 0); }   // SW_SHOW / SW_HIDE
    // The Windows key: opens Start even with the taskbar hidden.
    public static void StartMenu() { keybd_event(0x5B, 0, 0, UIntPtr.Zero); keybd_event(0x5B, 0, 2, UIntPtr.Zero); }
    // Windows key + a letter: Win+A quick settings (Wi-Fi, sound...), Win+N notifications and calendar.
    public static void WinKey(char c) {
      byte k = (byte)char.ToUpperInvariant(c);
      keybd_event(0x5B, 0, 0, UIntPtr.Zero); keybd_event(k, 0, 0, UIntPtr.Zero);
      keybd_event(k, 0, 2, UIntPtr.Zero); keybd_event(0x5B, 0, 2, UIntPtr.Zero);
    }

    // ---- Background apps: running programs that show an icon in Windows' tray ("menu bar extras").
    // Windows lists every app that has had a tray icon under NotifyIconSettings; the ones running now
    // are the background apps.
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
    static string KnownPath(string p) {
      var m = System.Text.RegularExpressions.Regex.Match(p ?? "", @"^\{([0-9A-Fa-f-]{36})\}(.*)$");
      if (!m.Success) return p;
      try {
        Guid g = new Guid(m.Groups[1].Value); IntPtr ptr;
        if (SHGetKnownFolderPath(ref g, 0, IntPtr.Zero, out ptr) != 0) return null;
        string root = Marshal.PtrToStringUni(ptr); Marshal.FreeCoTaskMem(ptr);
        return root + m.Groups[2].Value;
      } catch { return null; }
    }
    static readonly string[] TraySkip = { "explorer.exe", "isle.exe", "electron.exe", "rundll32.exe" };
    public static string TrayAppsJson() {
      var running = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
      foreach (var pr in System.Diagnostics.Process.GetProcesses()) {
        try { var e = ExePath((uint)pr.Id); if (e != null) running.Add(e); } catch { } finally { pr.Dispose(); }
      }
      var apps = new System.Collections.Generic.SortedDictionary<string, string[]>(StringComparer.OrdinalIgnoreCase);   // name -> exe, tip, app ID
      var seen = new System.Collections.Generic.HashSet<string>(StringComparer.OrdinalIgnoreCase);
      try {
        using (var k = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Control Panel\NotifyIconSettings")) {
          if (k != null) foreach (var sub in k.GetSubKeyNames()) {
            using (var s = k.OpenSubKey(sub)) {
              if (s == null) continue;
              string exe = KnownPath(s.GetValue("ExecutablePath") as string);
              if (string.IsNullOrEmpty(exe) || seen.Contains(exe) || !running.Contains(exe)) continue;
              if (Array.IndexOf(TraySkip, System.IO.Path.GetFileName(exe).ToLowerInvariant()) >= 0) continue;
              seen.Add(exe);
              var pkg = PackagedApp(exe);   // Store apps (WhatsApp...): real name and app ID
              string name = pkg != null ? pkg[1] : AppName(exe);
              string tip = (s.GetValue("InitialTooltip") as string) ?? "";
              string key = name; int n = 2;
              while (apps.ContainsKey(key)) key = name + " " + (n++);   // two different programs with the same name stay two
              apps[key] = new[] { exe, tip, pkg != null ? pkg[0] : "" };
            }
          }
        }
      } catch { }
      var sb = new System.Text.StringBuilder("{\"t\":\"trayapps\",\"apps\":[");
      bool first = true;
      foreach (var kv in apps) {
        if (!first) sb.Append(','); first = false;
        sb.Append("{\"name\":\"").Append(Esc(kv.Key)).Append("\",\"exe\":\"").Append(Esc(kv.Value[0])).Append("\",\"tip\":\"").Append(Esc(kv.Value[1])).Append("\",\"aumid\":\"").Append(Esc(kv.Value[2])).Append("\"}");
      }
      return sb.Append("]}").ToString();
    }
    // Clicking a background app: show its window (tray apps keep it hidden). "launch" = it has none.
    public static string TrayOpen(string exe) {
      IntPtr best = IntPtr.Zero;
      EnumWindows((h, l) => {
        if (GetWindow(h, 4) != IntPtr.Zero || GetWindowTextLength(h) == 0) return true;
        uint pid; GetWindowThreadProcessId(h, out pid);
        string e = ExePath(pid);
        if (e == null || !e.Equals(exe, StringComparison.OrdinalIgnoreCase)) return true;
        int st = GetWindowLong(h, -16), ex = GetWindowLong(h, -20);
        if ((st & 0x00C00000) != 0x00C00000 || (ex & 0x80) != 0) return true;   // needs a title bar; no tool windows
        best = h;
        return false;
      }, IntPtr.Zero);
      if (best == IntPtr.Zero) return "launch";
      ShowWindow(best, IsIconic(best) ? 9 : 5);
      Front(best);
      return "shown";
    }

    // An earlier Isle (1.4 test builds) switched Windows' minimize / maximize animation off for the
    // session; if it was closed abruptly that stayed off. Put it back to the user's saved setting.
    [StructLayout(LayoutKind.Sequential)] struct ANIMINFO { public uint cb; public int v; }
    [DllImport("user32.dll", EntryPoint = "SystemParametersInfo")] static extern bool SpiAnim(uint a, uint b, ref ANIMINFO ai, uint f);
    public static void FixMinAnimate() {
      try {
        string saved = Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Control Panel\Desktop\WindowMetrics", "MinAnimate", null) as string;
        var ai = new ANIMINFO(); ai.cb = (uint)Marshal.SizeOf(ai);
        SpiAnim(0x48, ai.cb, ref ai, 0);
        if (saved == "1" && ai.v == 0) { ai.v = 1; SpiAnim(0x49, ai.cb, ref ai, 2); }
      } catch { }
    }

    // If Isle was closed abruptly, Windows may still keep the Dock's space. Registering and
    // removing a bar makes Windows drop bars whose windows are gone. (Done at every start.)
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    public static void Prune() {
      IntPtr h = GetConsoleWindow();
      if (h == IntPtr.Zero) return;
      var d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d); d.hWnd = h; d.uCallbackMessage = 0x400 + 0x1A1;
      SHAppBarMessage(ABM_NEW, ref d);
      SHAppBarMessage(ABM_REMOVE, ref d);
    }

    // Isle is closing: give the space back and put the taskbar back as it was (when Isle changed it).
    public static bool AutoHideChangedByIsle;
    public static void Restore() {
      try { Reserve(IntPtr.Zero, 0); } catch { }
      try { if (AutoHideChangedByIsle) { TaskbarAutoHide = false; AutoHideChangedByIsle = false; } } catch { }
    }
  }

  // Brightness changes arrive as WMI events (laptop panels), so no slow polling is needed.
  // Brightness of every active display: the laptop panel through Windows (WMI), external
  // monitors through DDC/CI (the standard monitor-control channel over the video cable).
  // Brightness keys only reach the laptop panel, so a key press is passed on to the external
  // monitors as the same step. When the laptop panel is off (lid closed / second screen only),
  // its (invisible) level is kept at 50 so the keys always have room to go up and down.
  public static class Monitors {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct PHYSICAL_MONITOR { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string desc; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct DISPLAY_DEVICE { public int cb; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString; public int StateFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey; }
    delegate bool MonEnum(IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonEnum cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFOEX mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
    [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYSICAL_MONITOR[] a);
    [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitor(IntPtr h);
    [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, out uint type, out uint cur, out uint max);
    [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

    class Mon { public string Id, Name, Kind; public bool Primary; public IntPtr Phys; public bool HasPhys; public int Value = -1; public uint Max = 100; }   // note: a physical-monitor handle can be 0
    static readonly object gate = new object();
    static System.Collections.Generic.List<Mon> list = new System.Collections.Generic.List<Mon>();
    static string topo = "";
    static string internalCode;            // e.g. "AUO7EAD" (the laptop panel)
    static bool internalActive;
    static int lastInternal = -1;
    static int suppressUntil;              // ignore WMI events caused by our own changes
    static readonly System.Collections.Generic.Dictionary<string, int> pending = new System.Collections.Generic.Dictionary<string, int>();   // monitor id -> newest level
    static readonly System.Threading.AutoResetEvent wake = new System.Threading.AutoResetEvent(false);
    static System.Threading.Thread worker;

    static string Code(string deviceId) {   // "MONITOR\MSI30C6\{...}\0003" or "DISPLAY\AUO7EAD\..." -> "MSI30C6"
      var p = (deviceId ?? "").Split('\\');
      return p.Length > 1 ? p[1].ToUpperInvariant() : "";
    }

    // Friendly names from the monitors' own EDID ("MSI MP225").
    static System.Collections.Generic.Dictionary<string, string> Names() {
      var d = new System.Collections.Generic.Dictionary<string, string>();
      try {
        using (var s = new System.Management.ManagementObjectSearcher("root\\WMI", "SELECT InstanceName, UserFriendlyName FROM WmiMonitorID"))
          foreach (System.Management.ManagementObject o in s.Get()) {
            var chars = o["UserFriendlyName"] as ushort[];
            string name = "";
            if (chars != null) foreach (var c in chars) if (c != 0) name += (char)c;
            string code = Code((string)o["InstanceName"]);
            if (code.Length > 0 && name.Trim().Length > 0) d[code] = name.Trim();
          }
      } catch { }
      return d;
    }

    static int InternalLevel() {
      try {
        using (var s = new System.Management.ManagementObjectSearcher("root\\WMI", "SELECT InstanceName, CurrentBrightness FROM WmiMonitorBrightness"))
          foreach (System.Management.ManagementObject o in s.Get()) { internalCode = Code((string)o["InstanceName"]); return Convert.ToInt32(o["CurrentBrightness"]); }
      } catch { }
      return -1;
    }

    // Sets the laptop panel. Windows answers with a brightness event, which must not be taken for
    // a brightness key (that would move the external monitors too), so events shortly after one
    // of our own writes are ignored.
    static readonly object wmiGate = new object();
    static System.Management.ManagementObject wmiSet;   // re-used: looking it up costs ~50 ms
    static void SetInternal(int v) {
      v = Math.Max(0, Math.Min(100, v));
      lock (wmiGate) {
        lastInternal = v;
        suppressUntil = Environment.TickCount + 1500;
        try {
          if (wmiSet == null)
            using (var c = new System.Management.ManagementClass("root\\WMI", "WmiMonitorBrightnessMethods", null))
              foreach (System.Management.ManagementObject o in c.GetInstances()) { wmiSet = o; break; }
          if (wmiSet != null) wmiSet.InvokeMethod("WmiSetBrightness", new object[] { (uint)0, (byte)v });
        } catch { wmiSet = null; }
        suppressUntil = Environment.TickCount + 1500;
      }
    }

    // Re-reads which displays are on. Returns true when that changed (then the list is resent).
    public static bool Refresh() {
      var found = new System.Collections.Generic.List<object[]>();   // hmonitor, code, primary
      EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr hm, IntPtr hdc, ref RECT r, IntPtr d) => {
        var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(mi); GetMonitorInfo(hm, ref mi);
        var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
        string code = EnumDisplayDevices(mi.szDevice, 0, ref dd, 0) ? Code(dd.DeviceID) : "";
        found.Add(new object[] { hm, code, (mi.dwFlags & 1) != 0 });
        return true;
      }, IntPtr.Zero);
      var sig = new System.Text.StringBuilder();
      foreach (var f in found) sig.Append(f[1]).Append(f[2]).Append(';');
      lock (gate) {
        if (sig.ToString() == topo) return false;
        topo = sig.ToString();
        foreach (var m in list) if (m.HasPhys) DestroyPhysicalMonitor(m.Phys);
        list.Clear();
        int level = InternalLevel();
        var names = Names();
        internalActive = false;
        foreach (var f in found) {
          string code = (string)f[1];
          var m = new Mon { Id = code, Primary = (bool)f[2] };
          if (internalCode != null && code == internalCode) {
            internalActive = true;
            m.Kind = "laptop"; m.Name = "Laptop screen"; m.Value = level;
          } else {
            m.Kind = "monitor";
            m.Name = names.ContainsKey(code) ? names[code] : "Monitor";
            uint n;
            if (GetNumberOfPhysicalMonitorsFromHMONITOR((IntPtr)f[0], out n) && n > 0) {
              var a = new PHYSICAL_MONITOR[n];
              if (GetPhysicalMonitorsFromHMONITOR((IntPtr)f[0], n, a)) {
                m.Phys = a[0].h; m.HasPhys = true;
                for (int i = 1; i < a.Length; i++) DestroyPhysicalMonitor(a[i].h);
                uint t, cur, max;
                if (GetVCPFeatureAndVCPFeatureReply(m.Phys, 0x10, out t, out cur, out max) && max > 0) { m.Max = max; m.Value = (int)Math.Round(cur * 100.0 / max); }
              }
            }
          }
          // Two of the same model: tell them apart.
          int same = 0; foreach (var x in list) if (x.Id == m.Id || x.Id.StartsWith(m.Id + "#")) same++;
          if (same > 0) { m.Id += "#" + (same + 1); m.Name += " " + (same + 1); }
          list.Add(m);
        }
        // Laptop panel off: park its level at 50, so brightness keys can always go both ways.
        if (!internalActive && level >= 0 && HasExternal()) { if (level != 50) SetInternal(50); else lastInternal = 50; }
        else lastInternal = level;
      }
      if (worker == null) {
        worker = new System.Threading.Thread(Work); worker.IsBackground = true; worker.Start();
      }
      return true;
    }

    static bool HasExternal() { foreach (var m in list) if (m.Kind == "monitor" && m.HasPhys && m.Value >= 0) return true; return false; }

    // DDC/CI is slow (~50 ms a write), so writes are done here, only the newest value per monitor.
    static void Work() {
      while (true) {
        wake.WaitOne();
        while (true) {
          string id = null; int v = 0; Mon target = null;
          lock (gate) {
            foreach (var kv in pending) { id = kv.Key; v = kv.Value; break; }
            if (id == null) break;
            pending.Remove(id);
            foreach (var m in list) if (m.Id == id && (m.HasPhys || m.Kind == "laptop")) target = m;
          }
          if (target == null) continue;
          if (target.Kind == "laptop") SetInternal(v);
          else { try { SetVCPFeature(target.Phys, 0x10, (uint)Math.Round(v * target.Max / 100.0)); } catch { } }
        }
      }
    }

    static void Queue(Mon m, int v) {
      m.Value = Math.Max(0, Math.Min(100, v));
      if (m.Kind != "laptop" && !m.HasPhys) return;
      // Laptop panel and monitors alike: written on the worker, only the newest value, so a
      // drag never piles up writes (or their echoes) behind it.
      if (m.Kind == "laptop") suppressUntil = Environment.TickCount + 1500;
      lock (gate) pending[m.Id] = m.Value;
      wake.Set();
    }

    // From the notch's sliders.
    public static void Set(string id, int v) {
      Mon target = null;
      lock (gate) foreach (var m in list) if (m.Id == id) target = m;
      if (target != null) Queue(target, v);
    }

    // A brightness key changed the laptop panel's level (WMI event).
    public static void OnInternalEvent(int v) {
      // An echo of our own write (slider / parking): the notch already shows it; not a key press.
      if (unchecked(Environment.TickCount - suppressUntil) < 0) { lastInternal = v; return; }
      int delta;
      lock (gate) {
        delta = lastInternal < 0 ? 0 : v - lastInternal;
        lastInternal = v;
        foreach (var m in list) if (m.Kind == "laptop") m.Value = v;
      }
      if (delta != 0) {
        var ext = new System.Collections.Generic.List<Mon>();
        lock (gate) foreach (var m in list) if (m.Kind == "monitor" && m.Value >= 0) ext.Add(m);
        foreach (var m in ext) Queue(m, m.Value + delta);
        if (!internalActive && ext.Count > 0) SetInternal(50);
      }
      Report(true);
    }

    public static void Report(bool show) { Out.Line(Json(show)); }

    static string Esc(string s) { return (s ?? "").Replace("\\", "\\\\").Replace("\"", "\\\""); }
    public static string Json(bool show) {
      var sb = new System.Text.StringBuilder("{\"t\":\"monitors\",\"show\":" + (show ? "true" : "false") + ",\"list\":[");
      lock (gate) {
        bool first = true;
        foreach (var m in list) {
          if (m.Value < 0) continue;   // no way to control it (no DDC/CI)
          if (!first) sb.Append(','); first = false;
          sb.Append("{\"id\":\"").Append(Esc(m.Id)).Append("\",\"name\":\"").Append(Esc(m.Name)).Append("\",\"kind\":\"").Append(m.Kind)
            .Append("\",\"primary\":").Append(m.Primary ? "true" : "false").Append(",\"v\":").Append(m.Value).Append('}');
        }
      }
      return sb.Append("]}").ToString();
    }
  }

  public static class Bright {
    public static volatile int Last = -1;
    static int lastSent = -2;
    static readonly object gate = new object();
    static System.Management.ManagementEventWatcher watcher;

    public static void Report(int v) {
      lock (gate) { if (v == lastSent) return; lastSent = v; }
      Last = v;
      Out.Line("{\"t\":\"bright\",\"v\":" + v + "}");
    }

    public static bool Watch() {
      try {
        watcher = new System.Management.ManagementEventWatcher(
          new System.Management.ManagementScope("root\\WMI"),
          new System.Management.EventQuery("SELECT * FROM WmiMonitorBrightnessEvent"));
        watcher.EventArrived += (s, e) => {
          try {
            int v = Convert.ToInt32(e.NewEvent["Brightness"]);
            Report(v);
            Monitors.OnInternalEvent(v);   // pass the key press on to external monitors too
          } catch { }
        };
        watcher.Start();
        return true;
      } catch { return false; }
    }
  }

  // Volume keys: when Enabled, we handle them ourselves and swallow them, so
  // Windows never shows its own volume pop-up (the notch shows its HUD instead).
  // Hides Windows' own volume / brightness pop-up (the small bar above the taskbar) while the
  // notch shows its HUD. Windows 11 draws it in a small "XamlExplorerHostIslandWindow" of
  // Explorer that it re-uses every time. That window is made fully transparent, so the bar
  // never shows, not even for a frame (hiding it after it appeared made it flash on brightness
  // keys). It is made visible again when this is switched off, in games / full-screen video,
  // and when Isle exits (and at the next start, in case Isle was ever killed).
  public static class Osd {
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc fn, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string title);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
    [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint key, byte alpha, uint flags);
    [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr h, out uint key, out byte alpha, out uint flags);
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint m; public IntPtr w; public IntPtr l; public uint t; public int x; public int y; }
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    const int GWL_EXSTYLE = -20, WS_EX_LAYERED = 0x80000;
    static WinEventProc proc;
    static bool enabled;
    static readonly object gate = new object();

    public static bool Enabled {
      get { return enabled; }
      set { lock (gate) { enabled = value; foreach (var h in FindAll()) Apply(h); } }
    }

    public static void Start() {
      if (proc != null) return;
      proc = OnShow;
      var t = new System.Threading.Thread(() => {
        // EVENT_OBJECT_SHOW from any process (so it survives Explorer restarting), out of context.
        SetWinEventHook(0x8002, 0x8002, IntPtr.Zero, proc, 0, 0, 0x0000 | 0x0002 /* OUTOFCONTEXT | SKIPOWNPROCESS */);
        MSG m; while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
      });
      t.IsBackground = true;
      t.Start();
      // Make sure it's put back if this helper exits normally.
      AppDomain.CurrentDomain.ProcessExit += (s, e) => Restore();
    }

    public static void Restore() { lock (gate) { enabled = false; foreach (var h in FindAll()) Apply(h); } }

    // Is this Explorer's small volume / brightness pop-up window?
    static bool IsPopup(IntPtr hwnd) {
      var c = new System.Text.StringBuilder(64);
      GetClassName(hwnd, c, 64);
      if (c.ToString() != "XamlExplorerHostIslandWindow") return false;
      RECT r; GetWindowRect(hwnd, out r);
      int w = r.R - r.L, h = r.B - r.T;
      if (w < 100 || w > 420 || h < 30 || h > 140) return false;   // only the small pop-up, not other flyouts
      uint pid; GetWindowThreadProcessId(hwnd, out pid);
      try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName == "explorer"; } catch { return false; }
    }

    static System.Collections.Generic.List<IntPtr> FindAll() {
      var list = new System.Collections.Generic.List<IntPtr>();
      IntPtr h = IntPtr.Zero;
      while ((h = FindWindowEx(IntPtr.Zero, h, "XamlExplorerHostIslandWindow", null)) != IntPtr.Zero)
        if (IsPopup(h)) list.Add(h);
      return list;
    }

    // Transparent while enabled, normal otherwise. Returns true if it had to change something.
    static bool Apply(IntPtr hwnd) {
      int ex = GetWindowLong(hwnd, GWL_EXSTYLE);
      if (enabled) {
        uint key; byte alpha; uint flags;
        bool done = (ex & WS_EX_LAYERED) != 0 && GetLayeredWindowAttributes(hwnd, out key, out alpha, out flags) && (flags & 2) != 0 && alpha == 0;
        if (done) return false;
        SetWindowLong(hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
        SetLayeredWindowAttributes(hwnd, 0, 0, 2 /* LWA_ALPHA */);
        return true;
      }
      if ((ex & WS_EX_LAYERED) == 0) return false;
      SetLayeredWindowAttributes(hwnd, 0, 255, 2);
      SetWindowLong(hwnd, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
      return true;
    }

    static void OnShow(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
      if (idObject != 0 || hwnd == IntPtr.Zero) return;
      lock (gate) {
        if (!enabled || !IsPopup(hwnd)) return;
        // A new pop-up window (first use, or Explorer restarted): make it transparent and,
        // since it's already on screen this once, hide it too.
        if (Apply(hwnd)) ShowWindow(hwnd, 0 /* SW_HIDE */);
      }
    }
  }

  public static class Keys {
    delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int idHook, HookProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

    const int VK_MUTE = 0xAD, VK_DOWN = 0xAE, VK_UP = 0xAF;
    static HookProc proc;
    static IntPtr hook = IntPtr.Zero;
    public static volatile bool Enabled = false;
    public static volatile int Step = 2;   // same step as Windows

    public static void Start() {
      if (proc != null) return;
      proc = Callback;
      var t = new System.Threading.Thread(() => {
        hook = SetWindowsHookEx(13 /* WH_KEYBOARD_LL */, proc, GetModuleHandle(null), 0);
        MSG m;
        while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
      });
      t.IsBackground = true;
      t.Start();
    }

    static IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam) {
      if (nCode >= 0 && Enabled) {
        int vk = Marshal.ReadInt32(lParam);
        if (vk == VK_UP || vk == VK_DOWN || vk == VK_MUTE) {
          int msg = wParam.ToInt32();
          if (msg == 0x100 || msg == 0x104) {          // key down (repeats while held)
            if (vk == VK_MUTE) Audio.ToggleMute();
            else {
              if (Audio.GetMute()) Audio.SetMute(false);  // like Windows: volume keys unmute
              int v = Audio.GetVolume();
              if (v >= 0) Audio.SetVolume(v + (vk == VK_UP ? Step : -Step));
            }
          }
          return (IntPtr)1;                             // swallow: no Windows pop-up
        }
      }
      return CallNextHookEx(hook, nCode, wParam, lParam);
    }
  }
}
'@
Add-Type -TypeDefinition $nativeSource -ReferencedAssemblies System.Management, System.ServiceProcess, UIAutomationClient, UIAutomationTypes, WindowsBase, System.Drawing
try { [IsleNative.Dock]::Prune() } catch {}   # drop the Dock's space if Isle was closed abruptly
try { [IsleNative.Dock]::FixMinAnimate() } catch {}   # Windows' minimize animation back if an old build left it off

# ---------------------------------------------------------------- WinRT (media session)
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]

function Wait-WinRt($op, [Type]$type) {
    $task = $asTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    $null = $task.Wait(3000)
    $task.Result
}

$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
$inputStreamType = [Windows.Storage.Streams.IInputStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$asStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@($inputStreamType))
$mgrType    = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]
$propType   = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties]
$streamType = [Windows.Storage.Streams.IRandomAccessStreamWithContentType]

$mgr = Wait-WinRt ($mgrType::RequestAsync()) $mgrType
$shell = New-Object -ComObject WScript.Shell

function Send-Msg($obj) {
    $json = $obj | ConvertTo-Json -Compress -Depth 3
    [IsleNative.Out]::Line($json)
}

# The session to show: whichever app is actually playing right now. Windows' "current" session
# can stay on something you paused minutes ago while another tab or app plays.
function Get-Session {
    try {
        $current = $mgr.GetCurrentSession()
        if ($current -and "$($current.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing') { return $current }
        foreach ($x in $mgr.GetSessions()) {
            if ("$($x.GetPlaybackInfo().PlaybackStatus)" -eq 'Playing') { return $x }
        }
        return $current
    } catch { return $null }
}

function Get-Art($props) {
    try {
        if (-not $props.Thumbnail) { return $null }
        $stream = Wait-WinRt ($props.Thumbnail.OpenReadAsync()) $streamType
        if (-not $stream) { return $null }
        # PowerShell can't call WinRT interface methods directly, so go through .NET's stream adapter.
        $net = $asStreamForRead.Invoke($null, @($stream))
        $ms = New-Object System.IO.MemoryStream
        $net.CopyTo($ms)
        $net.Dispose()
        $bytes = $ms.ToArray()
        if ($bytes.Length -lt 8) { return $null }
        $type = 'image/png'
        if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { $type = 'image/jpeg' }
        return "data:$type;base64," + [Convert]::ToBase64String($bytes)
    } catch { return $null }
}

# ---------------------------------------------------------------- Brightness (laptop panels)
$script:hasBright = $true
function Get-Bright {
    try {
        $b = Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightness -ErrorAction Stop | Select-Object -First 1
        if ($null -eq $b) { return -1 }
        return [int]$b.CurrentBrightness
    } catch { return -1 }
}
function Set-Bright([int]$v) {
    try {
        $m = Get-CimInstance -Namespace root/wmi -ClassName WmiMonitorBrightnessMethods -ErrorAction Stop | Select-Object -First 1
        $null = Invoke-CimMethod -InputObject $m -MethodName WmiSetBrightness -Arguments @{ Timeout = [uint32]0; Brightness = [byte][Math]::Max(0, [Math]::Min(100, $v)) }
    } catch {}
}

# ---------------------------------------------------------------- Commands
function Invoke-Cmd([string]$line) {
    $parts = $line.Trim().Split(' ', 2)
    $c = $parts[0]
    $a = if ($parts.Count -gt 1) { $parts[1] } else { '0' }
    $s = Get-Session
    switch ($c) {
        'play'   { if ($s) { $null = $s.TryTogglePlayPauseAsync() } else { $shell.SendKeys([string][char]179) } }
        'next'   { if ($s) { $null = $s.TrySkipNextAsync() }       else { $shell.SendKeys([string][char]176) } }
        'prev'   { if ($s) { $null = $s.TrySkipPreviousAsync() }   else { $shell.SendKeys([string][char]177) } }
        'seek'   { if ($s) { $null = $s.TryChangePlaybackPositionAsync([long]([double]::Parse($a, $inv) * 10000000)) } }
        'vol'    { [IsleNative.Audio]::SetVolume([int][double]::Parse($a, $inv)) }
        'mute'   { [IsleNative.Audio]::ToggleMute() }
        'bright' { Set-Bright ([int][double]::Parse($a, $inv)); $script:forceBright = $true }
        'osd'    { [IsleNative.Osd]::Enabled = ($a.Trim() -eq '1') }
        # mbright <monitor id> <0-100>: one display's brightness (from the notch's sliders)
        'mbright' {
            $f = "$a".Trim().Split(' ')
            if ($f.Count -ge 2) { [IsleNative.Monitors]::Set($f[0], [int][double]::Parse($f[1], $inv)) }
        }
        'monitors' { [IsleNative.Monitors]::Report($false) }
        # ---- Dock
        'dock'     { $script:dockOn = ($a.Trim() -eq '1'); $script:lastDock = '' }
        'dockact'  { $null = [IsleNative.Dock]::Activate($a.Trim()); $script:lastDock = ''; $script:due['dock'] = 0 }
        'dockquit' { $null = [IsleNative.Dock]::Quit($a.Trim()) }
        # dockicon <id> <path>|<path>...: the first path that has an icon wins
        'dockicon' {
            $p = $a.Trim().Split(' ', 2)
            if ($p.Count -eq 2) {
                $url = [IsleNative.Dock]::IconUrl([string[]]($p[1] -split '\|'), 128)
                Send-Msg ([ordered]@{ t = 'dockicon'; id = $p[0]; url = $url })
            }
        }
        'dockpins' { Send-DockPins }
        # taskbar hidden | autohide | normal  (1 / 0 = autohide / normal)
        'taskbar'  { Set-TaskbarMode $a.Trim() }
        # tbpeek <seconds>: show the hidden taskbar for a moment (to reach its tray icons)
        'tbpeek'   { $script:tbPeekUntil = $clock.ElapsedMilliseconds + 1000 * [int]$a.Trim(); [IsleNative.Dock]::ShowTaskbar($true) }
        'startmenu' { [IsleNative.Dock]::StartMenu() }
        'winkey'    { $k = $a.Trim(); if ($k -match '^[a-zA-Z]$') { [IsleNative.Dock]::WinKey($k[0]) } }
        # ---- background (tray) apps for the menu bar
        'trayapps' { $script:trayOn = ($a.Trim() -eq '1'); $script:lastTray = ''; $script:due['tray'] = 0 }
        'trayopen' {
            $exe = $a.Trim()
            if ([IsleNative.Dock]::TrayOpen($exe) -eq 'launch') {
                # No window to show: start it again (single-instance apps open their window); Store apps
                # by their app ID; for script hosts the Windows tray is shown for a moment instead.
                $leaf = [IO.Path]::GetFileName($exe).ToLowerInvariant()
                $pkg = [IsleNative.Dock]::PackagedApp($exe)
                if ($pkg) { Start-Process explorer.exe "shell:AppsFolder\$($pkg[0])" }   # Store apps (WhatsApp...): by their app ID
                elseif ($leaf -in 'python.exe', 'pythonw.exe', 'java.exe', 'javaw.exe', 'node.exe', 'wscript.exe', 'cscript.exe', 'powershell.exe', 'pwsh.exe', 'cmd.exe') {
                    $script:tbPeekUntil = $clock.ElapsedMilliseconds + 10000; [IsleNative.Dock]::ShowTaskbar($true)
                } else { try { Start-Process -FilePath $exe -WorkingDirectory (Split-Path $exe) } catch {} }
            }
        }
        'trayquit' { $exe = $a.Trim(); Get-Process | Where-Object { $_.Path -eq $exe } | Stop-Process -Force -ErrorAction SilentlyContinue }
        # appbar <window handle> <pixels> [top]: keep that much space at the bottom (Dock) or top
        # (menu bar) of the main screen; <pixels> 0 = give that window's back; "appbar 0" = all back
        'appbar' {
            $p = $a.Trim().Split(' ')
            if ($p.Count -ge 2) { try { [IsleNative.Dock]::Reserve([IntPtr][long]$p[0], [int]$p[1], ($p.Count -ge 3 -and $p[2] -eq 'top')) } catch {} }
            else { try { [IsleNative.Dock]::Reserve([IntPtr]::Zero, 0) } catch {} }
        }
        # trim <pid,pid,...>: free unused memory in Isle's processes and in this helper.
        'trim' {
            [GC]::Collect(); [GC]::WaitForPendingFinalizers()
            foreach ($p in ("$a".Trim() -split ',')) { $n = 0; if ([int]::TryParse($p, [ref]$n) -and $n -gt 0) { [IsleNative.Mem]::Trim($n) } }
            [IsleNative.Mem]::Trim($PID)
        }
        # While a game is in front, check everything 4x less often.
        'mode'   { $script:slow = if ($a.Trim() -eq 'game') { 4 } else { 1 } }
        'top'    { [IsleNative.TopApps]::Start() }
        'micmute' {
            $m = [IsleNative.Calls]::MicMuted()
            if ($m -ge 0) { [IsleNative.Calls]::SetMicMute($m -eq 0) }
            $script:forceCall = $true
        }
        'focusapp' { [IsleNative.Calls]::FocusApp($a.Trim()) }
        'callbtn' {
            # callbtn <proc1|proc2> <answer|decline|end>
            $f = $a.Trim().Split(' ')
            $kind = if ($f.Count -gt 1) { $f[1] } else { 'end' }
            $pattern = switch ($kind) {
                'answer'  { '\b(accept|answer|pick ?up)\b' }
                'decline' { '\b(decline|reject|ignore)\b' }
                default   { '\b(end( call)?|leave( call)?|hang ?up|disconnect)\b' }
            }
            [IsleNative.Calls]::PressAsync($f[0], $kind, $pattern)
        }
        'windnd' { if ($a.Trim() -eq '1') { [IsleNative.Dnd]::Enable() } else { [IsleNative.Dnd]::Restore() } }
        'notif'  {
            $script:notifOn = ($a.Trim() -eq '1')
            if ($script:notifOn -and -not $script:listener) { Initialize-Notif }
        }
        'perf'   {
            # perf <on 0|1> <sample GPU counters 0|1>
            $f = $a.Split(' ')
            $script:perf = $f[0] -eq '1'
            $script:perfGpu = ($f.Count -gt 1) -and ($f[1] -eq '1')
            if ($script:perf) { $null = [IsleNative.Perf]::Net() }
        }
    }
    $script:forceMedia = $true
}

# ---------------------------------------------------------------- Media polling
# Map the media session's app id ("Brave", "Spotify.exe", "MSEdge", ...) to the
# running program's .exe, so the UI can show that app's own icon.
$script:appPaths = @{}
function Resolve-AppPath([string]$id) {
    if (-not $id) { return '' }
    if ($script:appPaths.ContainsKey($id)) { return $script:appPaths[$id] }
    $path = ''
    try {
        if ($id -match '!') {
            # Store app: use the package's main executable when we can find it.
            $family = $id.Split('!')[0]
            $pkg = Get-AppxPackage | Where-Object { $_.PackageFamilyName -eq $family } | Select-Object -First 1
            if ($pkg) {
                $exe = Get-ChildItem -Path $pkg.InstallLocation -Filter *.exe -Recurse -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($exe) { $path = $exe.FullName }
            }
        } else {
            $name = $id -replace '\.exe$', ''
            if ($name -match '^[0-9A-F]{16}$') { $name = 'firefox' }
            $proc = Get-Process -Name $name -ErrorAction SilentlyContinue | Where-Object { $_.Path } | Select-Object -First 1
            if ($proc) { $path = $proc.Path }
        }
    } catch {}
    $script:appPaths[$id] = $path
    return $path
}

$script:lastMedia = ''
$script:artKey = ''
$script:artTries = 0
$script:artSent = $false

# Small signature of the media state that is cheap to read (no async calls, no JSON).
function Get-MediaQuick {
    try {
        $s = Get-Session
        if (-not $s) { return '' }
        $tl = $s.GetTimelineProperties()
        return "$($s.SourceAppUserModelId)|$($s.GetPlaybackInfo().PlaybackStatus)|$($tl.LastUpdatedTime.UtcTicks)|$($tl.EndTime.Ticks)"
    } catch { return '?' }
}

function Update-Media {
    $out = [ordered]@{ t = 'media'; has = $false }
    $s = Get-Session
    if ($s) {
        $p = Wait-WinRt ($s.TryGetMediaPropertiesAsync()) $propType
        if ($p -and $p.Title) {
            $info = $s.GetPlaybackInfo()
            $playing = $info.PlaybackStatus.ToString() -eq 'Playing'
            # 1.5x / 2x speed: the position moves that much faster than the clock.
            $rate = 1.0
            try { if ($info.PlaybackRate -and [double]$info.PlaybackRate -gt 0) { $rate = [double]$info.PlaybackRate } } catch {}
            $dur = 0; $pos = 0
            try {
                $tl = $s.GetTimelineProperties()
                $dur = ($tl.EndTime - $tl.StartTime).TotalMilliseconds
                $pos = ($tl.Position - $tl.StartTime).TotalMilliseconds
                if ($playing -and $tl.LastUpdatedTime.Year -gt 2000) {
                    $pos += ([DateTimeOffset]::Now - $tl.LastUpdatedTime).TotalMilliseconds * $rate
                }
                if ($dur -gt 0 -and $pos -gt $dur) { $pos = $dur }
            } catch {}
            $key = "$($p.Title)|$($p.Artist)"
            $out = [ordered]@{
                t       = 'media'
                has     = $true
                key     = $key
                title   = [string]$p.Title
                artist  = [string]$p.Artist
                album   = [string]$p.AlbumTitle
                app     = [string]$s.SourceAppUserModelId
                appPath = Resolve-AppPath ([string]$s.SourceAppUserModelId)
                playing = $playing
                rate    = [Math]::Round($rate, 2)
                pos     = [long][Math]::Max(0, $pos)
                dur     = [long][Math]::Max(0, $dur)
            }

            if ($key -ne $script:artKey) { $script:artKey = $key; $script:artTries = 0; $script:artSent = $false }
            # Thumbnails often arrive a moment after the title, so retry a few times.
            if (-not $script:artSent -and $script:artTries -lt 8) {
                $script:artTries++
                $url = Get-Art $p
                if ($url) { Send-Msg ([ordered]@{ t = 'art'; key = $key; url = $url }); $script:artSent = $true }
            }
        }
    }
    # Send right away when anything but the moving position changes (new song, play/pause,
    # speed). While a song just plays on, the notch moves the position itself, so only resend
    # if the real position drifts (a seek) or every few seconds as a check.
    $pos = if ($out.Contains('pos')) { [long]$out.pos } else { 0 }
    if ($out.Contains('pos')) { $out.Remove('pos') }
    $sig = $out | ConvertTo-Json -Compress
    $now = [Environment]::TickCount
    $rate = if ($out.Contains('rate')) { [double]$out.rate } else { 1.0 }
    $expected = $script:sentPos + $(if ($script:sentPlaying) { ($now - $script:sentAt) * $rate } else { 0 })
    $drift = [Math]::Abs($pos - $expected)
    if ($sig -ne $script:lastMedia -or $drift -gt 1500 -or ($now - $script:sentAt) -gt 5000) {
        if ($out.Contains('has') -and $out.has) { $out.pos = $pos }
        [IsleNative.Out]::Line(($out | ConvertTo-Json -Compress))
        $script:lastMedia = $sig
        $script:sentPos = $pos
        $script:sentAt = $now
        $script:sentPlaying = [bool]($out.Contains('playing') -and $out.playing)
    }
}
$script:sentPos = 0
$script:sentAt = 0
$script:sentPlaying = $false
$script:lastCall = ''
$script:forceCall = $true
$script:lastPower = ''

# ---------------------------------------------------------------- Notifications
# Reads toasts that apps post to the Windows notification center. Kept in memory only.
$null = [Windows.UI.Notifications.Management.UserNotificationListener, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.UI.Notifications.UserNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
$null = [Windows.UI.Notifications.KnownNotificationBindings, Windows.UI.Notifications, ContentType = WindowsRuntime]
# Bluetooth devices that are connected right now (classic + Bluetooth LE), for connect / disconnect pop-ups.
$script:btSel = @()
try {
    $null = [Windows.Devices.Enumeration.DeviceInformation, Windows.Devices.Enumeration, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $null = [Windows.Devices.Bluetooth.BluetoothLEDevice, Windows.Devices.Bluetooth, ContentType = WindowsRuntime]
    $script:btSel = @(
        [Windows.Devices.Bluetooth.BluetoothDevice]::GetDeviceSelectorFromConnectionStatus('Connected'),
        [Windows.Devices.Bluetooth.BluetoothLEDevice]::GetDeviceSelectorFromConnectionStatus('Connected'))
} catch {}
$btColType = [Windows.Devices.Enumeration.DeviceInformationCollection]
$script:btLast = $null
$script:padsJson = ''
function Update-Bluetooth {
    $names = New-Object 'System.Collections.Generic.SortedSet[string]'
    foreach ($sel in $script:btSel) {
        # (Not Wait-WinRt: a function's empty result comes back as $null, which looked like a
        # failed query whenever no Bluetooth LE device was connected.)
        $task = $asTaskGeneric.MakeGenericMethod($btColType).Invoke($null, @([Windows.Devices.Enumeration.DeviceInformation]::FindAllAsync($sel)))
        if (-not $task.Wait(3000) -or $task.IsFaulted) { return }   # query failed: try again next time
        foreach ($d in $task.Result) { if ($d.Name) { $null = $names.Add([string]$d.Name) } }
    }
    # USB / wireless-receiver controllers: same connect / disconnect pop-ups, and their own
    # entries in the battery list (sent before the pop-up, so it can show the level).
    $pads = [IsleNative.Pads]::List()
    foreach ($p in $pads) { $null = $names.Add($p.Key) }
    $pj = [IsleNative.Pads]::Json($pads)
    if ($pj -ne $script:padsJson) { $script:padsJson = $pj; [IsleNative.Out]::Line($pj) }
    $now = @($names)
    if ($null -eq $script:btLast) { $script:btLast = $now; return }   # first look: just remember
    $added = @($now | Where-Object { $script:btLast -notcontains $_ })
    $removed = @($script:btLast | Where-Object { $now -notcontains $_ })
    $script:btLast = $now
    if ($added.Count -or $removed.Count) { Send-Msg ([ordered]@{ t = 'bt'; added = $added; removed = $removed }) }
}

# ---------------------------------------------------------------- Dock
$script:dockOn = $false
$script:lastDock = ''
$isleRegKey = 'HKCU:\Software\Isle'

# The apps pinned to Windows' taskbar (its shortcuts), in the taskbar's order.
function Send-DockPins {
    $dir = Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'
    $files = @(Get-ChildItem $dir -Filter *.lnk -ErrorAction SilentlyContinue)
    # The taskbar keeps its order in a binary value that contains the shortcuts' file names.
    $order = ''
    try { $order = [Text.Encoding]::Unicode.GetString((Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -ErrorAction Stop).Favorites) } catch {}
    $files = $files | Sort-Object { $i = $order.IndexOf($_.Name); if ($i -lt 0) { [int]::MaxValue } else { $i } }, Name
    $sh = New-Object -ComObject WScript.Shell
    $list = @()
    foreach ($f in $files) {
        $exe = ''
        try { $exe = [string]$sh.CreateShortcut($f.FullName).TargetPath } catch {}
        $aumid = [IsleNative.Dock]::FileAumid($f.FullName)
        if ($aumid -eq 'Microsoft.Windows.Explorer' -and -not $exe) { $exe = Join-Path $env:WINDIR 'explorer.exe' }
        $list += [ordered]@{ name = ($f.BaseName -replace ' - Shortcut$', ''); lnk = $f.FullName; exe = $exe; aumid = [string]$aumid }
    }
    Send-Msg ([ordered]@{ t = 'dockpins'; list = @($list) })
}

# Windows' taskbar auto-hide while the Dock is on. A marker in the registry remembers that Isle
# turned it on, so it's put back even after Isle was closed abruptly.
function Set-TaskbarAutoHide([bool]$on) {
    $marked = $false
    try { $marked = [bool](Get-ItemProperty $isleRegKey -Name TaskbarAutoHide -ErrorAction Stop).TaskbarAutoHide } catch {}
    if ($on) {
        if (-not [IsleNative.Dock]::TaskbarAutoHide) {
            [IsleNative.Dock]::TaskbarAutoHide = $true
            $marked = $true
            try { New-Item $isleRegKey -Force -ErrorAction Stop | Out-Null; Set-ItemProperty $isleRegKey TaskbarAutoHide 1 } catch {}
        }
        if ($marked) { [IsleNative.Dock]::AutoHideChangedByIsle = $true }
    } elseif ([IsleNative.Dock]::AutoHideChangedByIsle -or $marked) {
        [IsleNative.Dock]::TaskbarAutoHide = $false
        [IsleNative.Dock]::AutoHideChangedByIsle = $false
        Remove-ItemProperty $isleRegKey -Name TaskbarAutoHide -ErrorAction SilentlyContinue
    }
}
# hidden: gone completely (auto-hide on too, so it takes no space); autohide; normal.
$script:tbHidden = $false
$script:tbPeekUntil = 0
$script:trayOn = $false
$script:lastTray = ''
function Set-TaskbarMode([string]$mode) {
    if ($mode -eq '1') { $mode = 'autohide' } elseif ($mode -eq '0') { $mode = 'normal' }
    if ($mode -eq 'hidden') {
        Set-TaskbarAutoHide $true
        [IsleNative.Dock]::ShowTaskbar($false)
        $script:tbHidden = $true
        try { New-Item $isleRegKey -Force -ErrorAction Stop | Out-Null; Set-ItemProperty $isleRegKey TaskbarHidden 1 } catch {}
    } else {
        $wasHidden = $script:tbHidden
        try { if ((Get-ItemProperty $isleRegKey -Name TaskbarHidden -ErrorAction Stop).TaskbarHidden) { $wasHidden = $true } } catch {}
        if ($wasHidden) { [IsleNative.Dock]::ShowTaskbar($true) }
        $script:tbHidden = $false
        Remove-ItemProperty $isleRegKey -Name TaskbarHidden -ErrorAction SilentlyContinue
        Set-TaskbarAutoHide ($mode -eq 'autohide')
    }
}
function Restore-Dock {
    $was = [IsleNative.Dock]::AutoHideChangedByIsle
    if ($script:tbHidden) { [IsleNative.Dock]::ShowTaskbar($true); Remove-ItemProperty $isleRegKey -Name TaskbarHidden -ErrorAction SilentlyContinue }
    [IsleNative.Dock]::Restore()
    if ($was) { Remove-ItemProperty $isleRegKey -Name TaskbarAutoHide -ErrorAction SilentlyContinue }
}

$notifAccessType = [Windows.UI.Notifications.Management.UserNotificationListenerAccessStatus]
$notifListType = [System.Collections.Generic.IReadOnlyList[Windows.UI.Notifications.UserNotification]]
$script:listener = $null
$script:notifOn = $false
$script:notifPrimed = $false
$script:notifSeen = New-Object 'System.Collections.Generic.HashSet[uint32]'
$script:logoSent = @{}

function Initialize-Notif {
    try {
        $l = [Windows.UI.Notifications.Management.UserNotificationListener]::Current
        $st = "$($l.GetAccessStatus())"
        if ($st -ne 'Allowed') { $st = "$(Wait-WinRt ($l.RequestAccessAsync()) $notifAccessType)" }
        Send-Msg ([ordered]@{ t = 'notifaccess'; v = $st })
        if ($st -eq 'Allowed') { $script:listener = $l }
    } catch {
        Send-Msg ([ordered]@{ t = 'notifaccess'; v = 'Unavailable' })
    }
}

function Get-NotifLogo($n) {
    try {
        $ref = $n.AppInfo.DisplayInfo.GetLogo((New-Object Windows.Foundation.Size 48, 48))
        if (-not $ref) { return $null }
        $stream = Wait-WinRt ($ref.OpenReadAsync()) $streamType
        if (-not $stream) { return $null }
        $net = $asStreamForRead.Invoke($null, @($stream))
        $ms = New-Object System.IO.MemoryStream
        $net.CopyTo($ms); $net.Dispose()
        $bytes = $ms.ToArray()
        if ($bytes.Length -lt 8) { return $null }
        $type = if ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xD8) { 'image/jpeg' } else { 'image/png' }
        return "data:$type;base64," + [Convert]::ToBase64String($bytes)
    } catch { return $null }
}

# Windows can take seconds to hand over the notification list (e.g. while a game runs), so it's
# asked for without waiting: the answer is picked up on a later pass, and the next request is
# sent straight away. The helper never sits blocked on it.
$script:notifTask = $null
function Update-Notif {
    if (-not $script:listener) { return }
    $list = $null
    if ($null -ne $script:notifTask) {
        if (-not $script:notifTask.IsCompleted) { return }
        $t = $script:notifTask
        $script:notifTask = $null
        if (-not $t.IsFaulted -and -not $t.IsCanceled) { $list = $t.Result }
    }
    try { $script:notifTask = $asTaskGeneric.MakeGenericMethod($notifListType).Invoke($null, @($script:listener.GetNotificationsAsync([Windows.UI.Notifications.NotificationKinds]::Toast))) } catch { $script:notifTask = $null }
    if ($null -eq $list) { return }
    $fresh = @()
    foreach ($n in $list) { if ($script:notifSeen.Add([uint32]$n.Id)) { $fresh += $n } }
    # The first pass only records what was already there, so old toasts don't pop up.
    if (-not $script:notifPrimed) { $script:notifPrimed = $true; return }
    if (-not $fresh.Count) { return }
    # Full toast XML (for the sender's photo and any sticker / picture in the message).
    $payloads = [IsleNative.Wpn]::Payloads([long[]]@($fresh | ForEach-Object { [long]$_.Id }))
    foreach ($n in ($fresh | Sort-Object { $_.CreationTime })) {
        $app = [string]$n.AppInfo.DisplayInfo.DisplayName
        $texts = @()
        try {
            $b = $n.Notification.Visual.GetBinding([Windows.UI.Notifications.KnownNotificationBindings]::ToastGeneric)
            if ($b) { $texts = @($b.GetTextElements() | ForEach-Object { [string]$_.Text } | Where-Object { $_ }) }
        } catch {}
        $title = if ($texts.Count) { $texts[0] } else { $app }
        $body = if ($texts.Count -gt 1) { ($texts[1..($texts.Count - 1)] -join ' ') } else { '' }
        if ($body.Length -gt 300) { $body = $body.Substring(0, 300) + '…' }
        $msg = [ordered]@{
            t     = 'notif'
            id    = [uint32]$n.Id
            app   = $app
            title = $title
            body  = $body
            at    = [long]$n.CreationTime.ToUnixTimeMilliseconds()
        }
        $msg.aumid = [string]$n.AppInfo.AppUserModelId
        $xmlText = $null
        # Incoming call: the toast is marked as a call, or reads like one from a calling app.
        if (("$title $body") -match '(?i)\b(incoming|calling)\b.*\b(call|video|voice)\b|\b(voice|video) call\b') { $msg.incoming = $true }
        if ($payloads.TryGetValue([long]$n.Id, [ref]$xmlText) -and $xmlText -match 'scenario="incomingCall"') { $msg.incoming = $true }
        if ($payloads.TryGetValue([long]$n.Id, [ref]$xmlText) -and $xmlText) {
            foreach ($m in [regex]::Matches($xmlText, '<image\b[^>]*>')) {
                $tag = $m.Value
                if ($tag -notmatch '\bsrc="([^"]+)"') { continue }
                $src = [System.Net.WebUtility]::HtmlDecode($Matches[1])
                $placement = if ($tag -match '\bplacement="([^"]+)"') { $Matches[1] } else { 'inline' }
                if ($placement -eq 'appLogoOverride') { if (-not $msg.Contains('avatar')) { $msg.avatar = $src } }
                elseif ($placement -eq 'hero' -or $placement -eq 'inline') { if (-not $msg.Contains('image')) { $msg.image = $src } }
            }
        }
        if (-not $script:logoSent.ContainsKey($app)) {
            $script:logoSent[$app] = $true
            $logo = Get-NotifLogo $n
            if ($logo) { $msg.logo = $logo }
        }
        Send-Msg $msg
    }
}

# ---------------------------------------------------------------- Guard
# If Isle is force-closed (Task Manager, crash), Windows kills this helper at once, before it can
# put Windows' volume / brightness bar back (it's kept transparent while Isle runs). Programs this
# helper starts are not killed with it, so a tiny guard program waits for the helper to end and
# then restores that bar. It's compiled once (a few KB) into Isle's local app-data folder.
$guardSource = @'
using System; using System.Diagnostics; using System.Runtime.InteropServices; using System.Text;
static class IsleGuard {
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr p, IntPtr a, string c, string t);
  [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int i, int v);
  [DllImport("user32.dll")] static extern bool GetLayeredWindowAttributes(IntPtr h, out uint k, out byte a, out uint f);
  [DllImport("user32.dll")] static extern bool SetLayeredWindowAttributes(IntPtr h, uint k, byte a, uint f);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
  static void Main(string[] args) {
    int pid;
    if (args.Length < 1 || !int.TryParse(args[0], out pid)) return;
    try { Process.GetProcessById(pid).WaitForExit(); } catch { }
    IntPtr h = IntPtr.Zero;
    while ((h = FindWindowEx(IntPtr.Zero, h, "XamlExplorerHostIslandWindow", null)) != IntPtr.Zero) {
      RECT r; GetWindowRect(h, out r);
      int w = r.R - r.L, hh = r.B - r.T;
      if (w < 100 || w > 420 || hh < 30 || hh > 140) continue;
      int ex = GetWindowLong(h, -20);
      uint k, f; byte a;
      if ((ex & 0x80000) == 0 || !GetLayeredWindowAttributes(h, out k, out a, out f) || a != 0) continue;  // not ours
      SetLayeredWindowAttributes(h, 0, 255, 2);
      SetWindowLong(h, -20, ex & ~0x80000);
    }
  }
}
'@
try {
    $guardDir = Join-Path $env:LOCALAPPDATA 'Isle'
    $guardExe = Join-Path $guardDir 'IsleGuard-1.exe'
    if (-not (Test-Path $guardExe)) {
        New-Item -ItemType Directory -Force $guardDir | Out-Null
        Add-Type -TypeDefinition $guardSource -OutputAssembly $guardExe -OutputType WindowsApplication
    }
    Start-Process -FilePath $guardExe -ArgumentList $PID -WindowStyle Hidden
} catch {}

# ---------------------------------------------------------------- Main loop
# (The old volume-key hook, [IsleNative.Keys], is no longer started: hiding the pop-up window
# works for brightness too and doesn't need to watch every key press.)
[IsleNative.Osd]::Start()
$stdin = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
$readTask = $stdin.ReadLineAsync()
$lastVol = ''
$lastBright = -2
$lastSeq = [uint32]0
$lastFs = ''
$script:perf = $false
$script:perfGpu = $false
$script:slow = 1
$script:mediaQuick = $null
$script:forceMedia = $true
$script:forceBright = $true

# Volume and brightness push change events, so the HUD can follow the keys instantly.
[IsleNative.Audio]::Watch()
$brightEvents = [IsleNative.Bright]::Watch()

# Time-based schedule for the slower checks (independent of how often we wake up).
$clock = [System.Diagnostics.Stopwatch]::StartNew()
$script:due = @{}
function Test-Due([string]$name, [int]$everyMs) {
    $now = $clock.ElapsedMilliseconds
    if (-not $script:due.ContainsKey($name) -or $now -ge $script:due[$name]) {
        $script:due[$name] = $now + $everyMs
        return $true
    }
    return $false
}

# Volume and brightness are reported by C# straight from their event threads
# ([IsleNative.Audio]::Report / [IsleNative.Bright]::Report); these are just safety-net polls.
function Send-Volume { [IsleNative.Audio]::ReportNow() }

# Logs any helper-loop step that blocks for more than 0.3 s (to find slow checks).
$script:stepAt = 0
function Mark-Step([string]$name) {
    $now = $clock.ElapsedMilliseconds
    $d = $now - $script:stepAt
    if ($d -gt 300) { try { Add-Content -LiteralPath (Join-Path $env:TEMP 'isle-slow.log') -Value ("{0:HH:mm:ss} {1} took {2} ms" -f (Get-Date), $name, $d) } catch {} }
    $script:stepAt = $clock.ElapsedMilliseconds
}
while ($true) {
    $script:stepAt = $clock.ElapsedMilliseconds
    while ($readTask.IsCompleted) {
        $line = $readTask.Result
        if ($null -eq $line) { [IsleNative.Dnd]::Restore(); [IsleNative.Osd]::Restore(); Restore-Dock; exit }   # stdin closed: the app is gone
        Invoke-Cmd $line
        $readTask = $stdin.ReadLineAsync()
    }

    if ((Test-Due 'parent' 3000) -and $ParentPid -gt 0 -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { [IsleNative.Dnd]::Restore(); [IsleNative.Osd]::Restore(); Restore-Dock; exit }

    # Safety-net poll for volume (events normally report it within milliseconds).
    Mark-Step 'start'
    if (Test-Due 'vol' 1000) { Send-Volume }

    # Brightness: WMI events report changes instantly; poll slowly in case events aren't available.
    $pollEvery = if ($brightEvents) { 5000 } else { 500 }
    Mark-Step 'vol'
    if ($script:hasBright -and ($script:forceBright -or (Test-Due 'bright' $pollEvery))) {
        $script:forceBright = $false
        $b = Get-Bright
        if ($b -lt 0) { $script:hasBright = $false }
        else { [IsleNative.Bright]::Report($b) }
    }

    # Displays switched on / off or plugged in: re-read them and their brightness.
    Mark-Step 'bright'
    if (Test-Due 'monitors' (3000 * $script:slow)) {
        if ([IsleNative.Monitors]::Refresh()) { [IsleNative.Monitors]::Report($false) }
    }

    # Charger / battery state from Windows; sent only when something changes.
    Mark-Step 'monitors'
    if (Test-Due 'power' 1000) {
        $pj = [IsleNative.Power]::Json()
        if ($pj -and $pj -ne $script:lastPower) { [IsleNative.Out]::Line($pj); $script:lastPower = $pj }
    }

    # Calls: a calling app (WhatsApp, Discord, Teams, ...) with the microphone open = on a call.
    Mark-Step 'power'
    if ($script:forceCall -or (Test-Due 'call' (500 * $script:slow))) {
        $script:forceCall = $false
        $callApp = [IsleNative.Calls]::ActiveCall()
        $micMuted = [IsleNative.Calls]::MicMuted() -eq 1
        $ck = "$callApp|$micMuted"
        if ($ck -ne $script:lastCall) {
            Send-Msg ([ordered]@{ t = 'call'; app = $callApp; muted = $micMuted })
            $script:lastCall = $ck
        }
        # Incoming call shown in the app's own pop-up window (no Windows notification).
        $ring = if ($callApp) { '' } else { [IsleNative.Calls]::RingWindow() }
        if ($ring -ne $script:lastRing) {
            $parts = $ring -split "`t", 3
            Send-Msg ([ordered]@{ t = 'ringwin'; app = $(if ($ring) { $parts[0] } else { '' }); title = $(if ($parts.Count -gt 1) { $parts[1] } else { '' }); name = $(if ($parts.Count -gt 2) { $parts[2] } else { '' }) })
            $script:lastRing = $ring
        }
        # Short log of call changes only (to tune call detection); nothing is written otherwise.
        $dbgKey = "$ck|$ring"
        if ($dbgKey -ne $script:lastCallDbg) {
            $script:lastCallDbg = $dbgKey
            if ($callApp -or $ring) {
                try { Add-Content -LiteralPath (Join-Path $env:TEMP 'isle-calls.log') -Value ("[{0:HH:mm:ss}]`n{1}" -f (Get-Date), [IsleNative.Calls]::Debug()) -Encoding UTF8 } catch {}
            }
        }
    }

    # Mic / camera in use (Windows privacy indicators).
    Mark-Step 'call'
    if (Test-Due 'privacy' (1000 * $script:slow)) {
        $pj = [IsleNative.Privacy]::Json()
        if ($pj -ne $script:lastPrivacy) { [IsleNative.Out]::Line($pj); $script:lastPrivacy = $pj }
    }

    # Bluetooth device connected / disconnected.
    Mark-Step 'privacy'
    if (Test-Due 'bt' (2000 * $script:slow)) { Update-Bluetooth }

    # Dock: the apps with windows open (sent when they change).
    Mark-Step 'bt-only'
    if ($script:dockOn -and (Test-Due 'dock' (700 * $script:slow))) {
        $dj = [IsleNative.Dock]::AppsJson()
        if ($dj -ne $script:lastDock) { [IsleNative.Out]::Line($dj); $script:lastDock = $dj }
    }
    # Windows' taskbar stays hidden (Windows shows it again now and then), except while peeking.
    if ($script:tbHidden -and (Test-Due 'tbhide' 1500) -and $clock.ElapsedMilliseconds -gt $script:tbPeekUntil -and [IsleNative.Dock]::TaskbarShown) { [IsleNative.Dock]::ShowTaskbar($false) }
    # Background (tray) apps for the menu bar.
    if ($script:trayOn -and (Test-Due 'tray' (4000 * $script:slow))) {
        $tj = [IsleNative.Dock]::TrayAppsJson()
        if ($tj -ne $script:lastTray) { [IsleNative.Out]::Line($tj); $script:lastTray = $tj }
    }

    # Follow the default output device (e.g. when headphones connect).
    Mark-Step 'bt'
    if (Test-Due 'rewatch' 5000) { [IsleNative.Audio]::Watch() }

    Mark-Step 'rewatch'
    if (Test-Due 'clip' (150 * $script:slow)) {
        $seq = [IsleNative.Win]::GetClipboardSequenceNumber()
        if ($seq -ne $lastSeq) { Send-Msg ([ordered]@{ t = 'clip'; v = $seq }); $lastSeq = $seq }
    }

    Mark-Step 'clip'
    if (Test-Due 'fs' 500) {
        $fs = [IsleNative.Win]::ForegroundFullscreen()
        $fsApp = if ($fs) { [IsleNative.Win]::ForegroundProcess() } else { '' }
        $fsKey = "$fs|$fsApp"
        if ($fsKey -ne $lastFs) { Send-Msg ([ordered]@{ t = 'fs'; v = $fs; app = $fsApp }); $lastFs = $fsKey }
    }

    Mark-Step 'fs'
    if ($script:perf -and (Test-Due 'perf' 1000)) {
        $n = [IsleNative.Perf]::Net()
        $msg = [ordered]@{ t = 'perf'; down = $n[0]; up = $n[1] }
        if ($script:perfGpu) { $msg.gpu = [IsleNative.Perf]::Gpu() }
        Send-Msg $msg
    }

    Mark-Step 'perf'
    if ($script:notifOn -and (Test-Due 'notif' (750 * $script:slow))) {
        try { Update-Notif } catch {}
    }

    # Media: a cheap look every 150 ms (app, play state, timeline stamp); the full read (title,
    # artist, JSON) only when that changes, or once a second to catch anything else.
    Mark-Step 'notif'
    if ($script:forceMedia -or (Test-Due 'media' (150 * $script:slow))) {
        $q = Get-MediaQuick
        if ($script:forceMedia -or $q -ne $script:mediaQuick -or (Test-Due 'mediafull' (1000 * $script:slow))) {
            $script:forceMedia = $false
            $script:mediaQuick = $q
            try { Update-Media } catch {}
        }
    }

    # Sleep until something changes, or at most 75 ms.
    Mark-Step 'media'
    $null = [IsleNative.Audio]::Signal.WaitOne(75)
}
