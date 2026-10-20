using System;
using System.Runtime.InteropServices;
public static class NotificationReadinessProbe {
  [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
}
