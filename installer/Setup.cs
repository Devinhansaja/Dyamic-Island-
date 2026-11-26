// "Isle Setup.exe": a small window that unpacks the zip attached to the end of this exe
// (the app folder + install.ps1 / uninstall.ps1) and runs install.ps1. Per-user, no admin.
// Layout of the file: [this program][zip][8-byte zip length][8-byte "ISLESFX1"].
using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Compression;
using System.Text;
using System.Threading;
using System.Windows.Forms;

static class IsleSetup {
  [STAThread]
  static int Main(string[] args) {
    // /S: silent install (no windows); exit code 0 = installed.
    if (args.Length > 0 && args[0].Equals("/S", StringComparison.OrdinalIgnoreCase)) {
      try { Install(msg => { }); return 0; } catch (Exception ex) { Console.Error.WriteLine(ex.Message); return 1; }
    }
    Application.EnableVisualStyles();
    var r = MessageBox.Show("Install Isle on this PC?\n\nIt will be added to the Start menu and the desktop, and start with Windows.",
      "Isle Setup", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
    if (r != DialogResult.OK) return 1;

    var form = new Form {
      Text = "Isle Setup", FormBorderStyle = FormBorderStyle.FixedDialog, MaximizeBox = false, MinimizeBox = false,
      StartPosition = FormStartPosition.CenterScreen, ClientSize = new Size(360, 96), ShowIcon = true,
      Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath)
    };
    var label = new Label { Text = "Installing Isle...", Left = 20, Top = 18, Width = 320 };
    var bar = new ProgressBar { Style = ProgressBarStyle.Marquee, Left = 20, Top = 48, Width = 320, Height = 18, MarqueeAnimationSpeed = 30 };
    form.Controls.Add(label); form.Controls.Add(bar);

    string error = null;
    form.Shown += (s, e) => {
      var t = new Thread(() => {
        try { Install(msg => form.BeginInvoke((Action)(() => label.Text = msg))); }
        catch (Exception ex) { error = ex.Message; }
        form.BeginInvoke((Action)(() => form.Close()));
      });
      t.IsBackground = true;
      t.Start();
    };
    Application.Run(form);

    if (error != null) { MessageBox.Show("Isle could not be installed.\n\n" + error, "Isle Setup", MessageBoxButtons.OK, MessageBoxIcon.Error); return 1; }
    MessageBox.Show("Isle is installed and running.\n\nYou'll find it in the Start menu, and it starts with Windows.", "Isle Setup", MessageBoxButtons.OK, MessageBoxIcon.Information);
    return 0;
  }

  static void Install(Action<string> status) {
    string work = Path.Combine(Path.GetTempPath(), "IsleSetup-" + Guid.NewGuid().ToString("N").Substring(0, 8));
    Directory.CreateDirectory(work);
    try {
      status("Unpacking...");
      string zip = Path.Combine(work, "payload.zip");
      using (var self = new FileStream(Application.ExecutablePath, FileMode.Open, FileAccess.Read, FileShare.Read)) {
        var tail = new byte[16];
        self.Seek(-16, SeekOrigin.End);
        self.Read(tail, 0, 16);
        if (Encoding.ASCII.GetString(tail, 8, 8) != "ISLESFX1") throw new Exception("This setup file is damaged (no app inside).");
        long len = BitConverter.ToInt64(tail, 0);
        self.Seek(-16 - len, SeekOrigin.End);
        using (var outp = File.Create(zip)) {
          var buf = new byte[1 << 20];
          long left = len;
          while (left > 0) {
            int n = self.Read(buf, 0, (int)Math.Min(buf.Length, left));
            if (n <= 0) throw new Exception("This setup file is damaged (cut short).");
            outp.Write(buf, 0, n); left -= n;
          }
        }
      }
      string files = Path.Combine(work, "files");
      ZipFile.ExtractToDirectory(zip, files);
      File.Delete(zip);

      status("Installing Isle...");
      // Output goes to a file, not a pipe, and Isle is started here afterwards: a program started
      // by the script would keep a pipe open and setup would wait for it forever.
      string log = Path.Combine(work, "install.log");
      var psi = new ProcessStartInfo("cmd.exe",
        "/c powershell.exe -NoProfile -ExecutionPolicy Bypass -File \"" + Path.Combine(files, "install.ps1") + "\" -Source \"" +
        Path.Combine(files, "app") + "\" -NoStart > \"" + log + "\" 2>&1") { UseShellExecute = false, CreateNoWindow = true };
      using (var p = Process.Start(psi)) {
        p.WaitForExit();
        if (p.ExitCode != 0) {
          string msg = File.Exists(log) ? File.ReadAllText(log).Trim() : "exit code " + p.ExitCode;
          throw new Exception(msg.Length > 600 ? msg.Substring(0, 600) : msg);
        }
      }
      string isle = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs\\Isle\\Isle.exe");
      Process.Start(new ProcessStartInfo(isle) { UseShellExecute = true, WorkingDirectory = Path.GetDirectoryName(isle) });
    } finally {
      try { Directory.Delete(work, true); } catch { }
    }
  }
}
