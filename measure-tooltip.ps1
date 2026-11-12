# measure-tooltip.ps1 — 精确测量悬浮提示框的"闪动时长"
# 造一个和原生提示框完全同构的窗口(左边缘对齐光标x, 顶边在光标下 19px),
# 显示它, 然后测量它被移到光标左上角所需毫秒数
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
public class Mz4 {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll", CharSet=CharSet.Unicode)]
  static extern IntPtr CreateWindowEx(uint ex, string cls, string title, uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr param);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("kernel32.dll")] static extern uint GetLastError();

  public static int[] CursorXY(){ POINT p; GetCursorPos(out p); return new int[]{p.X,p.Y}; }
  static int[] RectOf(IntPtr h){ RECT r; if(!GetWindowRect(h,out r)) return null; return new int[]{r.Left,r.Top,r.Right,r.Bottom}; }

  public static string Run(int timeoutMs) {
    int[] c = CursorXY();
    int x = c[0], y = c[1] + 19;   // 与原生提示框一致
    IntPtr hwnd = CreateWindowEx(0x00000008 /*WS_EX_TOPMOST*/, "STATIC", "tip", 0x80000000 /*WS_POPUP*/, x, y, 160, 40, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
    if (hwnd == IntPtr.Zero) return "CREATE_FAILED err=" + GetLastError();
    var sw = Stopwatch.StartNew();
    ShowWindow(hwnd, 5);

    long placed = -1; int[] fr = null; int[] fc = null;
    while (sw.ElapsedMilliseconds < timeoutMs) {
      int[] r = RectOf(hwnd);
      int[] cc = CursorXY();
      if (r != null && (r[2]-r[0]) > 5) {
        if (fr == null) { fr = r; fc = cc; }
        if (r[3] <= cc[1] && r[2] <= cc[0]) { placed = sw.ElapsedMilliseconds; break; }
      }
      Thread.Sleep(1);
    }
    DestroyWindow(hwnd);
    if (fr == null) return "NEVER_APPEARED";
    string firstPos = (fr[3] <= fc[1] && fr[2] <= fc[0]) ? "已在左上角(无闪动)" : "在右下角(会闪一下)";
    return string.Format("出现时位于 {0} | 落到左上角耗时 {1}ms", firstPos, placed < 0 ? -1 : placed);
  }
}
'@
"RESULT: " + [Mz4]::Run(3000)
