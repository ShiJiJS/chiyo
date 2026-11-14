// Research only. Independent receiver oracle reads only its own synthetic fields.
using System;
using System.IO;
using System.Threading;
using System.Text;
using System.Runtime.InteropServices;
using System.Collections;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Automation;
using System.Windows.Interop;
using F = System.Windows.Forms;

class ManagedFixture {
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int id);
    [DllImport("kernel32.dll")] static extern bool ReadFile(IntPtr file, byte[] data, uint count, out uint read, IntPtr overlapped);
    [DllImport("kernel32.dll")] static extern bool WriteFile(IntPtr file, byte[] data, uint count, out uint written, IntPtr overlapped);
    static string ReadLine() {
        using (var bytes = new MemoryStream()) {
            byte[] one = new byte[1]; uint count;
            while (ReadFile(GetStdHandle(-10), one, 1, out count, IntPtr.Zero) && count == 1) {
                if (one[0] == 10) return Encoding.UTF8.GetString(bytes.ToArray());
                if (one[0] != 13) bytes.WriteByte(one[0]);
                if (bytes.Length > 131072) return null;
            }
            return null;
        }
    }
    class PassiveForm : F.Form { protected override bool ShowWithoutActivation { get { return true; } } }
    static string expected = "";
    static bool jsonMode, armed, focusedSinceArmed;
    static string nonce, kind;
    static IntPtr rootWindow;
    static Func<bool> matches;
    static readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 131072 };
    static string Title { get { return jsonMode ? "Chiyo native acceptance " + nonce : "Chiyo synthetic background-fill fixture"; } }
    static Action<Action> dispatch;
    static Func<string, string> command;
    static Action shutdown;
    static string Decode(string hex) {
        char[] c = new char[hex.Length / 4];
        for (int i = 0; i < c.Length; i++) c[i] = (char)Convert.ToInt32(hex.Substring(i * 4, 4), 16);
        return new string(c);
    }
    static void Reply(string s) { byte[] bytes = Encoding.UTF8.GetBytes(s + "\n"); uint count; WriteFile(GetStdHandle(-11), bytes, (uint)bytes.Length, out count, IntPtr.Zero); }
    static string JsonCommand(string line) {
        try {
            var input = json.Deserialize<Dictionary<string, object>>(line);
            string operation = input["command"] as string;
            if (operation == "expect" && input.Count == 2) {
                var values = input["bytes"] as IList;
                if (values == null || values.Count == 0 || values.Count > 16384) throw new InvalidDataException();
                byte[] bytes = new byte[values.Count];
                try {
                    for (int i = 0; i < bytes.Length; i++) {
                        if (!(values[i] is int) || (int)values[i] < 0 || (int)values[i] > 255) throw new InvalidDataException();
                        bytes[i] = (byte)(int)values[i]; values[i] = 0;
                    }
                    string value = new UTF8Encoding(false, true).GetString(bytes);
                    if (value.Length > 4096) throw new InvalidDataException();
                    expected = value; focusedSinceArmed = false; armed = true;
                } finally { Array.Clear(bytes, 0, bytes.Length); }
                return "{\"state\":\"armed\"}";
            }
            if (operation == "check" && input.Count == 1) return json.Serialize(new {
                state = "checked", matched = armed && matches(), active = GetForegroundWindow() == rootWindow, focusedSinceArmed = focusedSinceArmed });
            if (operation == "rebuild" && input.Count == 1) {
                command("recreate"); return "{\"state\":\"rebuilt\"}";
            }
        } catch { /* Never return request material or exception text. */ }
        return "{\"state\":\"refused\",\"errorCode\":\"fixture_input_rejected\"}";
    }
    static void Server() {
        try {
            string s;
            while ((s = ReadLine()) != null) {
                if (!jsonMode && s.StartsWith("expect ")) { expected = Decode(s.Substring(7)); Reply("ok"); continue; }
                if (s == "close") break;
                string response = null;
                dispatch(delegate { response = jsonMode ? JsonCommand(s) : command(s); });
                Reply(response ?? "error");
            }
        } catch { /* Never print exceptions or request payloads. */ }
        try { dispatch(shutdown); } catch { }
    }
    static void Start(IntPtr h) {
        rootWindow = h;
        if (jsonMode) Reply(json.Serialize(new { state = "ready", nonce = nonce,
            appId = System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName,
            windowTitle = Title, fieldIdentifier = "101", controlKind = kind }));
        else Reply("ready " + h.ToInt64());
        var thread = new Thread(Server); thread.IsBackground = true; thread.Start();
    }
    static string Result(string a, string b, string c) {
        return "match=" + (a == expected ? "1" : "0") + " empty=" + (a.Length == 0 ? "1" : "0") +
            " others=" + (b.Length == 0 && c.Length == 0 ? "1" : "0");
    }
    static void Wpf() {
        int changes = 0; bool disableAfterSet = false;
        var app = new Application();
        var window = new Window { Title = Title, Width = 560, Height = 330,
            Left = 120, Top = 120, ShowActivated = false };
        var panel = new StackPanel { Margin = new Thickness(20) };
        panel.Children.Add(new TextBlock { Text = "Synthetic WPF PasswordBox. No network/login." });
        Func<string, PasswordBox> make = delegate(string id) {
            var p = new PasswordBox { Height = 35, Margin = new Thickness(0, 10, 0, 0) };
            AutomationProperties.SetAutomationId(p, id); AutomationProperties.SetName(p, "Password"); return p;
        };
        PasswordBox a = make("101"), b = make("102");
        Action<PasswordBox> watch = p => {
            p.PasswordChanged += delegate { changes++; if(disableAfterSet) { disableAfterSet = false; p.IsEnabled = false; } };
            p.GotKeyboardFocus += delegate { if (armed && p == a) focusedSinceArmed = true; };
        };
        watch(a); watch(b);
        matches = () => a.Password == expected;
        var plain = new TextBox { Height = 35, Margin = new Thickness(0, 10, 0, 0) };
        panel.Children.Add(a); panel.Children.Add(b); panel.Children.Add(plain); window.Content = panel;
        dispatch = action => window.Dispatcher.Invoke(action); shutdown = () => window.Close();
        command = delegate(string s) {
            switch(s) {
                case "reset": a.IsEnabled = true; a.Password = ""; b.Password = ""; plain.Text = ""; changes = 0; return "ok";
                case "seed": a.Password = "old synthetic value"; changes = 0; return "ok";
                case "verify": return Result(a.Password, b.Password, plain.Text) + " changes=" + changes;
                case "disable": a.IsEnabled = false; return "ok";
                case "enable": a.IsEnabled = true; return "ok";
                case "limit": a.MaxLength = 1; return "ok";
                case "readonly": return "not_supported"; // PasswordBox has no IsReadOnly property.
                case "recreate": panel.Children.Remove(a); a = make("101"); watch(a); panel.Children.Insert(1, a); return "ok";
                case "duplicate": panel.Children.Add(make("101")); return "ok";
                case "focus1": plain.Focus(); return "ok";
                case "focus2": b.Focus(); return "ok";
                case "focusA": a.Focus(); return "ok";
                case "focusB": b.Focus(); return "ok";
                case "disable-after-set": disableAfterSet = true; return "ok";
                case "hide": window.Hide(); return "ok";
                case "show": window.Show(); return "ok";
                case "minimize": window.WindowState = WindowState.Minimized; return "ok";
                case "normal": window.WindowState = WindowState.Normal; return "ok";
                case "retitle": window.Title = "Chiyo synthetic changed container"; return "ok";
                case "restoretitle": window.Title = "Chiyo synthetic background-fill fixture"; return "ok";
            }
            return "error";
        };
        bool announced = false;
        window.ContentRendered += delegate { if (!announced) { announced = true; Start(new WindowInteropHelper(window).Handle); } };
        app.Run(window);
    }
    static void Forms() {
        int changes = 0; bool disableAfterSet = false;
        F.Application.EnableVisualStyles();
        var window = new PassiveForm { Text = Title, Width = 560, Height = 330,
            StartPosition = F.FormStartPosition.Manual, Left = 120, Top = 120 };
        Func<string, int, F.TextBox> make = delegate(string id, int y) {
            return new F.TextBox { Name = id, AccessibleName = "Password", UseSystemPasswordChar = true,
                Left = 20, Top = y, Width = 490 };
        };
        F.TextBox a = make("101", 60), b = make("102", 110);
        Action<F.TextBox> watch = p => {
            p.TextChanged += delegate { changes++; if(disableAfterSet) { disableAfterSet = false; p.Enabled = false; } };
            p.GotFocus += delegate { if (armed && p == a) focusedSinceArmed = true; };
        };
        watch(a); watch(b);
        matches = () => a.Text == expected;
        var plain = new F.TextBox { Left = 20, Top = 160, Width = 490 };
        window.Controls.Add(a); window.Controls.Add(b); window.Controls.Add(plain);
        dispatch = action => window.Invoke(action); shutdown = () => window.Close();
        command = delegate(string s) {
            switch(s) {
                case "reset": a.Enabled = true; a.ReadOnly = false; a.Text = ""; b.Text = ""; plain.Text = ""; changes = 0; return "ok";
                case "seed": a.Text = "old synthetic value"; changes = 0; return "ok";
                case "verify": return Result(a.Text, b.Text, plain.Text) + " changes=" + changes;
                case "disable": a.Enabled = false; return "ok";
                case "enable": a.Enabled = true; return "ok";
                case "limit": a.MaxLength = 1; return "ok";
                case "readonly": a.ReadOnly = true; return "ok";
                case "recreate": window.Controls.Remove(a); a.Dispose(); a = make("101", 60); watch(a); window.Controls.Add(a); return "ok";
                case "duplicate": window.Controls.Add(make("101", 210)); return "ok";
                case "focus1": plain.Focus(); return "ok";
                case "focus2": b.Focus(); return "ok";
                case "focusA": a.Focus(); return "ok";
                case "focusB": b.Focus(); return "ok";
                case "disable-after-set": disableAfterSet = true; return "ok";
                case "hide": window.Hide(); return "ok";
                case "show": window.Show(); return "ok";
                case "minimize": window.WindowState = F.FormWindowState.Minimized; return "ok";
                case "normal": window.WindowState = F.FormWindowState.Normal; return "ok";
                case "retitle": window.Text = "Chiyo synthetic changed container"; return "ok";
                case "restoretitle": window.Text = "Chiyo synthetic background-fill fixture"; return "ok";
            }
            return "error";
        };
        window.Shown += delegate { Start(window.Handle); };
        F.Application.Run(window);
    }
    [STAThread] static void Main(string[] args) {
        if (args.Length > 0 && args[0] == "--native-fill-fixture") {
            if (args.Length != 5 || args[1] != "--nonce" || args[3] != "--kind") return;
            nonce = args[2]; kind = args[4];
            if (nonce.Length == 0 || nonce.Length > 128 ||
                !System.Text.RegularExpressions.Regex.IsMatch(nonce, "^[A-Za-z0-9_-]+$") ||
                (kind != "winforms_password" && kind != "wpf_password")) return;
            jsonMode = true;
            if (kind == "wpf_password") Wpf(); else Forms();
            return;
        }
        if (args.Length == 1 && args[0] == "wpf") Wpf(); else Forms();
    }
}
