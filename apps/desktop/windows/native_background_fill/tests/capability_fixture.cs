// Synthetic, self-drawn native UIA provider. WinForms supplies only the top-level
// HWND/message pump; password fields are virtual custom providers, not TextBox,
// PasswordBox or Win32 Edit controls. No provider value is readable.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Automation.Provider;
using F = System.Windows.Forms;

public sealed class CapabilityState {
    public readonly object Gate = new object();
    public CapabilityWindow Window;
    public CapabilityNode Root, First, Second;
    public string Mode, Expected = "";
    public int NextId = 1, Changes, ValueReads, FocusCalls, LimitMessages, SetterCalls;
    public long SetterStarted, SetterEnded;
    public bool EnumerationExitArmed;
    public bool DisableAfterSet;
    public CapabilityNode LogicalFocus;
    public CapabilityNode Field(string name, string id) {
        return new CapabilityNode(this, ControlType.Edit.Id, name, id, true);
    }
    public void Rebuild() {
        CapabilityNode parent = First.Parent;
        int index = parent.Children.IndexOf(First);
        CapabilityNode old = First;
        int[] oldRuntime = old.GetRuntimeId();
        old.Alive = false; old.Value = "";
        First = Field(old.Name, old.Id); First.Parent = parent;
        parent.Children[index] = First;
        AutomationInteropProvider.RaiseStructureChangedEvent(Root,
            new StructureChangedEventArgs(StructureChangeType.ChildRemoved, oldRuntime));
    }
}
[ComVisible(true), ClassInterface(ClassInterfaceType.None)]
public sealed class CapabilityNode : IRawElementProviderSimple, IRawElementProviderFragment,
        IRawElementProviderFragmentRoot, IValueProvider {
    public readonly CapabilityState State;
    public readonly int Type, Runtime;
    public string Name, Id, Value = "";
    public bool IsField, Alive = true, Enabled = true, ReadOnly, Deny, NoValue;
    public CapabilityNode Parent;
    public readonly List<CapabilityNode> Children = new List<CapabilityNode>();
    public CapabilityNode(CapabilityState state, int type, string name, string id, bool field) {
        State = state; Type = type; Name = name; Id = id; IsField = field; Runtime = state.NextId++;
    }
    void Available() { if (!Alive) throw new ElementNotAvailableException(); }
    public ProviderOptions ProviderOptions { get { return ProviderOptions.ServerSideProvider; } }
    public IRawElementProviderSimple HostRawElementProvider {
        get { return Parent == null ? AutomationInteropProvider.HostProviderFromHandle(State.Window.Handle) : null; }
    }
    public object GetPatternProvider(int id) {
        lock(State.Gate) {
            Available();
            if (IsField && id == ValuePatternIdentifiers.Pattern.Id) {
                if (Deny) throw new COMException("Synthetic access denied", unchecked((int)0x80070005));
                return NoValue ? null : this;
            }
            return null;
        }
    }
    public object GetPropertyValue(int property) {
        lock(State.Gate) {
            Available();
            if (property == AutomationElementIdentifiers.ControlTypeProperty.Id) return Type;
            if (property == AutomationElementIdentifiers.NameProperty.Id) return Name;
            if (property == AutomationElementIdentifiers.AutomationIdProperty.Id) return Id;
            if (property == AutomationElementIdentifiers.ClassNameProperty.Id)
                return Type == ControlType.Document.Id ? State.Mode == "unknown-web-target" ? "ForeignDocumentContainer" : "WebViewSynthetic" : IsField ? "CapabilitySecretField" : "CapabilityNativeRoot";
            if (property == AutomationElementIdentifiers.FrameworkIdProperty.Id)
                return Type == ControlType.Document.Id ? State.Mode == "unknown-web-target" ? "UnregisteredProvider" : "Chrome" : "ChiyoCustomNative";
            if (property == AutomationElementIdentifiers.ProcessIdProperty.Id) return Process.GetCurrentProcess().Id;
            if (property == AutomationElementIdentifiers.IsPasswordProperty.Id) return IsField && State.Mode != "plain-text";
            if (property == AutomationElementIdentifiers.IsEnabledProperty.Id) return Enabled;
            if (property == AutomationElementIdentifiers.IsControlElementProperty.Id ||
                property == AutomationElementIdentifiers.IsContentElementProperty.Id) return true;
            if (property == AutomationElementIdentifiers.IsKeyboardFocusableProperty.Id) return IsField;
            if (property == AutomationElementIdentifiers.HasKeyboardFocusProperty.Id) return State.LogicalFocus == this;
            if (property == AutomationElementIdentifiers.IsOffscreenProperty.Id) return State.Window.WindowState == F.FormWindowState.Minimized;
            if (property == AutomationElementIdentifiers.NativeWindowHandleProperty.Id)
                return Parent == null ? State.Window.Handle.ToInt32() : 0;
            if (property == AutomationElementIdentifiers.IsValuePatternAvailableProperty.Id) return IsField && !NoValue;
            return null;
        }
    }
    public IRawElementProviderFragment Navigate(NavigateDirection direction) {
        lock(State.Gate) {
            Available();
            if (State.Mode == "enum-error" && State.EnumerationExitArmed && Parent == null)
                Environment.Exit(0); // Lose the provider while the client enumerates.
            if (direction == NavigateDirection.Parent) return Parent;
            if (direction == NavigateDirection.FirstChild) return Children.Count == 0 ? null : Children[0];
            if (direction == NavigateDirection.LastChild) return Children.Count == 0 ? null : Children[Children.Count - 1];
            if (Parent == null) return null;
            int index = Parent.Children.IndexOf(this);
            if (direction == NavigateDirection.NextSibling && index + 1 < Parent.Children.Count) return Parent.Children[index + 1];
            if (direction == NavigateDirection.PreviousSibling && index > 0) return Parent.Children[index - 1];
            return null;
        }
    }
    public int[] GetRuntimeId() {
        Available();
        return Parent == null ? null : new int[] { AutomationInteropProvider.AppendRuntimeId, Runtime };
    }
    public System.Windows.Rect BoundingRectangle {
        get {
            Rectangle r = State.Window.Bounds;
            return new System.Windows.Rect(r.Left + 15, r.Top + 40 + Runtime * 15, 420, 30);
        }
    }
    public IRawElementProviderSimple[] GetEmbeddedFragmentRoots() { return null; }
    public IRawElementProviderFragmentRoot FragmentRoot { get { return State.Root; } }
    public void SetFocus() { State.FocusCalls++; throw new InvalidOperationException("No focus setter in this fixture"); }
    public IRawElementProviderFragment ElementProviderFromPoint(double x, double y) { return State.Root; }
    public IRawElementProviderFragment GetFocus() { return State.LogicalFocus; }
    public bool IsReadOnly {
        get {
            lock(State.Gate) {
                Available();
                if (Deny) throw new COMException("Synthetic access denied", unchecked((int)0x80070005));
                return ReadOnly;
            }
        }
    }
    string IValueProvider.Value {
        get { State.ValueReads++; throw new UnauthorizedAccessException("Password values are not readable"); }
    }
    public void SetValue(string value) {
        lock(State.Gate) {
            Available();
            if (!IsField || !Enabled || ReadOnly || Deny || NoValue) throw new InvalidOperationException("Synthetic refusal");
            State.SetterStarted = Stopwatch.GetTimestamp(); State.SetterCalls++;
            Value = value; State.Changes++;
            if (State.DisableAfterSet) { State.DisableAfterSet=false; Enabled=false; }
            State.SetterEnded = Stopwatch.GetTimestamp();
        }
    }
}
public sealed class CapabilityWindow : F.Form {
    public readonly CapabilityState State;
    protected override bool ShowWithoutActivation { get { return true; } }
    public CapabilityWindow(CapabilityState state) {
        State = state; state.Window = this;
        Text = "Synthetic custom native UIA passwords"; Width = 540; Height = 320;
        StartPosition = F.FormStartPosition.Manual; Left = 150; Top = 160;
    }
    protected override void WndProc(ref F.Message message) {
        if (message.Msg == 0x003d && message.LParam.ToInt64() == AutomationInteropProvider.RootObjectId && State.Root != null) {
            message.Result = AutomationInteropProvider.ReturnRawElementProvider(Handle, message.WParam, message.LParam, State.Root);
            return;
        }
        if (message.Msg == 0x00d5) { State.LimitMessages++; message.Result = IntPtr.Zero; return; }
        base.WndProc(ref message);
    }
    protected override void OnPaint(F.PaintEventArgs e) {
        base.OnPaint(e);
        e.Graphics.DrawString("Self-drawn native password providers. No network.", Font, Brushes.Black, 15, 15);
        e.Graphics.DrawRectangle(Pens.Gray, 15, 55, 470, 45);
        e.Graphics.DrawRectangle(Pens.Gray, 15, 125, 470, 45);
    }
}
public static class CapabilityFixture {
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int kind);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool PeekNamedPipe(IntPtr handle, IntPtr buffer, int size, IntPtr read, out int available, IntPtr left);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadFile(IntPtr handle, byte[] buffer, int size, out int read, IntPtr overlapped);
    static string ReadCommand() {
        // Dart supplies an overlapped named pipe; Console.ReadLine can block
        // despite available bytes. Read only bytes reported ready by the pipe.
        var bytes = new List<byte>(); var one = new byte[1];
        IntPtr handle = GetStdHandle(-10);
        while(true) {
            int available, read;
            if(!PeekNamedPipe(handle,IntPtr.Zero,0,IntPtr.Zero,out available,IntPtr.Zero)) return null;
            if(available==0) { Thread.Sleep(2); continue; }
            if(!ReadFile(handle,one,1,out read,IntPtr.Zero) || read!=1) return null;
            if(one[0]==10) return System.Text.Encoding.UTF8.GetString(bytes.ToArray()).TrimEnd('\r');
            bytes.Add(one[0]);
            if(bytes.Count>65536) throw new InvalidOperationException();
        }
    }
    static void Reply(string text) { Console.WriteLine(text); Console.Out.Flush(); }
    static CapabilityNode Add(CapabilityNode parent, CapabilityNode child) {
        child.Parent = parent; parent.Children.Add(child); return child;
    }
    static string Command(CapabilityState state, string command) {
        lock(state.Gate) {
            if (command.StartsWith("expect ")) {
                string hex = command.Substring(7); char[] chars = new char[hex.Length/4];
                for(int i=0;i<chars.Length;i++) chars[i]=(char)Convert.ToInt32(hex.Substring(i*4,4),16);
                state.Expected = new string(chars); Array.Clear(chars,0,chars.Length); return "ok";
            }
            if(command=="verify") return "match="+(state.First.Value==state.Expected?"1":"0")+
                " empty="+(state.First.Value.Length==0?"1":"0")+" others="+(state.Second.Value.Length==0?"1":"0")+
                " changes="+state.Changes+" valueReads="+state.ValueReads+" focusCalls="+state.FocusCalls+
                " limitMessages="+state.LimitMessages+" setterCalls="+state.SetterCalls+
                " setterStarted="+state.SetterStarted+" setterEnded="+state.SetterEnded;
            if(command=="arm-enumeration-exit") { state.EnumerationExitArmed=true; return "ok"; }
            if(command=="reset") {
                state.First.Value=""; state.Second.Value=""; state.First.Enabled=true;
                state.First.ReadOnly=false; state.First.Deny=false; state.Changes=0;
                state.DisableAfterSet=false; return "ok";
            }
            if(command=="seed") { state.First.Value="old synthetic value"; state.Changes=0; return "ok"; }
            if(command=="focusB") { state.LogicalFocus=state.Second; return "ok"; }
            if(command=="enable") { state.First.Enabled=true; return "ok"; }
            if(command=="disable-after-set") { state.DisableAfterSet=true; return "ok"; }
            if(command.StartsWith("title ")) { state.Window.Text=command.Substring(6); state.Root.Name=state.Window.Text; return "ok"; }
            if(command=="submit") {
                // A separate receiver-side operation consumes its own field to
                // unlock a fixed synthetic payload. Setter success alone does
                // not claim this business action succeeded.
                if(state.Expected.Length==0 || state.First.Value!=state.Expected) return "accepted=0";
                byte[] content=System.Text.Encoding.UTF8.GetBytes("Synthetic custom native UIA protected payload.\n");
                using(var hash=System.Security.Cryptography.SHA256.Create()) {
                    string digest=BitConverter.ToString(hash.ComputeHash(content)).Replace("-", "").ToLowerInvariant();
                    return "accepted=1 payloadSha256="+digest;
                }
            }
            if(command=="recreate") { state.Rebuild(); return "ok"; }
            if(command=="readonly") { state.First.ReadOnly=true; return "ok"; }
            if(command=="disable") { state.First.Enabled=false; return "ok"; }
            if(command=="deny") { state.First.Deny=true; return "ok"; }
            if(command=="retitle") { state.Window.Text="Changed custom native window"; state.Root.Name=state.Window.Text; return "ok"; }
            if(command=="minimize") { state.Window.WindowState=F.FormWindowState.Minimized; return "ok"; }
            if(command=="hide") { state.Window.Hide(); return "ok"; }
            return "unsupported";
        }
    }
    [STAThread] public static void Main(string[] args) {
        F.Application.EnableVisualStyles();
        var state = new CapabilityState { Mode=args.Length==0?"normal":args[0] };
        var form = new CapabilityWindow(state);
        bool nativeRoot=state.Mode=="native-hwnd";
        state.Root = new CapabilityNode(state,nativeRoot?ControlType.Edit.Id:ControlType.Window.Id,
            form.Text,nativeRoot?"101":"",nativeRoot);
        CapabilityNode parent=state.Root;
        if(state.Mode=="web-target" || state.Mode=="unknown-web-target") parent=Add(state.Root,new CapabilityNode(state,ControlType.Document.Id,"Embedded page","web",false));
        bool missing=state.Mode=="missing-id" || state.Mode=="ambiguous";
        state.First=nativeRoot?state.Root:Add(parent,state.Field(state.Mode=="ambiguous"?"Password":"Archive password",missing?"":"101"));
        state.Second=Add(parent,state.Field(state.Mode=="ambiguous"?"Password":"Confirmation password",missing?"":"102"));
        if(state.Mode=="web-sibling") {
            var web=Add(state.Root,new CapabilityNode(state,ControlType.Document.Id,"Unrelated page","web",false));
            Add(web,state.Field("Web password","web-password"));
        }
        state.First.ReadOnly=state.Mode=="readonly";
        state.First.Enabled=state.Mode!="disabled";
        state.First.NoValue=state.Mode=="no-value";
        state.First.Deny=state.Mode=="deny-pattern";
        state.Second.ReadOnly=state.First.ReadOnly;
        state.Second.Enabled=state.First.Enabled;
        state.Second.NoValue=state.First.NoValue;
        state.Second.Deny=state.First.Deny;
        form.Shown += delegate {
            Reply("ready "+form.Handle.ToInt64());
            var thread = new Thread(delegate() {
                try {
                    string command;
                    while((command=ReadCommand())!=null && command!="close") {
                        string result=null;
                        form.Invoke((Action)delegate { result=Command(state,command); });
                        Reply(result);
                    }
                } catch { }
                try { form.BeginInvoke((Action)delegate { form.Close(); }); } catch { }
            });
            thread.IsBackground=true; thread.Start();
        };
        F.Application.Run(form);
    }
}
