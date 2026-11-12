# tooltip-above.ps1 — 把鼠标悬浮信息框"接管"到光标右上角(不闪)
#
# 做法(和常见做法不同):
#   常见做法 = 等提示框显示出来再搬走 -> 用户会先看到它在右下角闪一下
#   本脚本   = 提示框显示前先把它藏起来(清空窗口区域), 它被显示到右下角时
#              用户什么都看不到; 随后挪到右上角并恢复显示 -> 右下角来不及出现
#
# 三路并行找提示框(都很快):
#   1) 精确类名 tooltips_class32      (原生提示框 / Chromium 链接提示)
#   2) 只扫前台应用自己的窗口          (Chromium/Electron 弹窗就在这进程里)
#   3) 已接管过的窗口                  (兜住换线程的情况)
# 另有每 ~200ms 一次的全量扫描兜底
#
# 位置(默认 -Mode 0): 提示框的【左下角】贴在光标的【右上角】
#   -Mode 1 = 左上角   -Mode 2 = 正上方   -Gap 2 = 与光标的间距(像素)
#
# 启动: pwsh -NoProfile -File tooltip-above.ps1
# 停止: pwsh -NoProfile -File stop-tooltip-above.ps1
param(
    [int]$IntervalMs = 2,
    [int]$Gap = 2,
    [int]$Mode = 0,
    [switch]$Debug
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$stopFile  = Join-Path $scriptDir 'tooltip-above.stop'
$pidFile   = Join-Path $scriptDir 'tooltip-above.pid'
$logFile   = Join-Path $scriptDir 'tooltip-above.log'
if (-not $Debug) { $logFile = $null }

Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Runtime.InteropServices;

public class TipTaker3 {
    public delegate bool EnumProc(IntPtr h, IntPtr p);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct THREADENTRY32 {
        public uint dwSize, cntUsage, th32ThreadID, th32OwnerProcessID, tpBasePri, tpDeltaPri, dwFlags;
    }

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumThreadWindows(uint tid, EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string win);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int idx);
    [DllImport("user32.dll")] static extern int SetWindowRgn(IntPtr h, IntPtr rgn, bool redraw);
    [DllImport("user32.dll")] static extern IntPtr GetWindowRgn(IntPtr h, IntPtr rgn);
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll")] static extern bool Thread32First(IntPtr snap, IntPtr lp);
    [DllImport("kernel32.dll")] static extern bool Thread32Next(IntPtr snap, IntPtr lp);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("gdi32.dll")] static extern IntPtr CreateRectRgn(int l, int t, int r, int b);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);

    const uint SWP = 0x0001 | 0x0004 | 0x0010 | 0x0040;
    const uint WS_POPUP = 0x80000000, WS_CHILD = 0x40000000;
    const int GWL_STYLE = -16;
    const uint TH32CS_SNAPTHREAD = 0x00000004;

    static int Gap = 2, Mode = 0;
    static string LogPath = null;
    static IntPtr EmptyRegion = IntPtr.Zero;

    class Win { public IntPtr Hwnd; public IntPtr OrigRegion; public bool Hidden; }
    static readonly ConcurrentDictionary<IntPtr, Win> Managed = new ConcurrentDictionary<IntPtr, Win>();
    static readonly object LogLock = new object();

    static readonly string[] SkipCls = { "#32768", "Popup", "Menu", "IME", "MSCTFIME UI" };

    // 当前前台应用(提示框所在进程)的线程列表, 缓存起来避免每次都做系统快照
    static readonly List<uint> Threads = new List<uint>();
    static uint cachedPid = 0;
    static long lastRefresh = 0;

    static void Log(string s) {
        if (string.IsNullOrEmpty(LogPath)) return;
        try { lock (LogLock) File.AppendAllText(LogPath, s + Environment.NewLine); } catch { }
    }

    static bool IsSkip(string cls) { foreach (var s in SkipCls) if (cls == s) return true; return false; }

    static string ClassOf(IntPtr h) {
        var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString();
    }

    static bool IsPopupStyle(IntPtr h) {
        int style = GetWindowLong(h, GWL_STYLE);
        return (style & WS_POPUP) != 0 && (style & WS_CHILD) == 0;
    }

    // 用非托管缓冲枚举指定进程的线程
    static List<uint> ThreadsOf(uint pid) {
        var list = new List<uint>();
        IntPtr snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if (snap == IntPtr.Zero || snap == new IntPtr(-1)) return list;
        IntPtr buf = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(THREADENTRY32)));
        try {
            var te = new THREADENTRY32();
            te.dwSize = (uint)Marshal.SizeOf(typeof(THREADENTRY32));
            Marshal.StructureToPtr(te, buf, false);
            if (Thread32First(snap, buf)) {
                do {
                    var cur = (THREADENTRY32)Marshal.PtrToStructure(buf, typeof(THREADENTRY32));
                    if (cur.th32OwnerProcessID == pid) list.Add(cur.th32ThreadID);
                } while (Thread32Next(snap, buf));
            }
        } catch { }
        finally { Marshal.FreeHGlobal(buf); CloseHandle(snap); }
        return list;
    }

    static Win Manage(IntPtr h) {
        Win w;
        if (Managed.TryGetValue(h, out w)) return w;
        w = new Win();
        w.Hwnd = h;
        IntPtr rgn = CreateRectRgn(0, 0, 0, 0);
        IntPtr copy = GetWindowRgn(h, rgn);
        if (copy != IntPtr.Zero) { w.OrigRegion = rgn; } else { DeleteObject(rgn); w.OrigRegion = IntPtr.Zero; }
        w.Hidden = false;
        Managed[h] = w;
        return w;
    }

    static void HideContent(Win w) {
        if (w.Hidden) return;
        SetWindowRgn(w.Hwnd, EmptyRegion, true);
        w.Hidden = true;
    }

    static void ShowContent(Win w) {
        if (!w.Hidden) return;
        if (w.OrigRegion != IntPtr.Zero) SetWindowRgn(w.Hwnd, w.OrigRegion, true);
        else SetWindowRgn(w.Hwnd, IntPtr.Zero, true);
        w.Hidden = false;
    }

    static void Target(int cx, int cy, RECT r, out int left, out int top) {
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (Mode == 1) { left = (cx - Gap) - w; top = (cy - Gap) - ht; }
        else if (Mode == 2) { left = r.Left; top = cy - ht - Gap; }
        else { left = cx + Gap; top = cy - ht - Gap; }
        if (left < 0) left = 0;
        if (top < 0) top = 0;
    }

    static bool IsAtTarget(RECT r, int cx, int cy) {
        int left, top;
        Target(cx, cy, r, out left, out top);
        return Math.Abs(r.Left - left) <= 2 && Math.Abs(r.Top - top) <= 2;
    }

    static bool MoveTo(IntPtr h, int cx, int cy, RECT r) {
        int left, top;
        Target(cx, cy, r, out left, out top);
        if (Math.Abs(r.Left - left) > 1 || Math.Abs(r.Top - top) > 1) {
            SetWindowPos(h, IntPtr.Zero, left, top, 0, 0, SWP);
            return true;
        }
        return false;
    }

    static bool LooksLikeTip(IntPtr h, int cx, int cy, RECT r) {
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w < 10 || ht < 8) return false;
        if (w > 1400 || ht > 800) return false;
        if (h == GetForegroundWindow()) return false;
        if (Math.Abs(r.Left - cx) > 80) return false;
        if (r.Top < cy + 4 || r.Top > cy + 170) return false;
        return true;
    }

    static void Handle(IntPtr h, int cx, int cy) {
        RECT r;
        if (!GetWindowRect(h, out r)) return;
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w <= 0 || ht <= 0) return;

        Win win = Manage(h);

        if (!IsWindowVisible(h)) {
            if (w <= 900 && ht <= 400) HideContent(win);   // 提前藏好, 显示时用户看不到
            return;
        }

        if (IsAtTarget(r, cx, cy)) { ShowContent(win); return; }

        // 已经显示出来了: 只做位移。
        // 不做"藏->移->显", 否则反而多一次闪烁。
        if (win.Hidden) ShowContent(win);
        if (MoveTo(h, cx, cy, r)) Log("TAKE cls=" + ClassOf(h) + " old=" + r.Left + "," + r.Top);
    }

    // 进程内的窗口: 只在提示框所在进程里找, 成本极低
    // 只扫指定线程的顶层窗口(成本极低)
    static void ScanThread(uint tid, int cx, int cy, List<IntPtr> found) {
        EnumThreadWindows(tid, (h, p) => {
            if (!IsWindowVisible(h)) return true;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            int w = r.Right - r.Left, ht = r.Bottom - r.Top;
            if (w <= 0 || ht <= 0) return true;
            if (Math.Abs(r.Left - cx) > 80) return true;
            if (r.Top < cy + 4 || r.Top > cy + 170) return true;
            string c = ClassOf(h);
            if (c.Length == 0 || IsSkip(c)) return true;
            found.Add(h);
            return true;
        }, IntPtr.Zero);
    }

    public static string Run(int intervalMs, int gap, int mode, string stopFile, string logPath) {
        Gap = gap; Mode = mode; LogPath = logPath;
        EmptyRegion = CreateRectRgn(0, 0, 0, 0);

        try {
            int tick = 0;
            var found = new List<IntPtr>();
            while (!File.Exists(stopFile)) {
                POINT p; GetCursorPos(out p);
                int cx = p.X, cy = p.Y;
                tick++;

                // 前台应用变了 -> 刷新线程列表(每秒最多一次)
                IntPtr fg = GetForegroundWindow();
                uint pid;
                GetWindowThreadProcessId(fg, out pid);
                long now = Environment.TickCount64;
                if (pid != cachedPid || now - lastRefresh > 1000) {
                    cachedPid = pid;
                    lastRefresh = now;
                    Threads.Clear();
                    Threads.AddRange(ThreadsOf(pid));
                }

                // 快路径 1: 原生提示框(精确类名, 每 10ms 一次即可)
                if (tick % 5 == 0) {
                    IntPtr h = FindWindowEx(IntPtr.Zero, IntPtr.Zero, "tooltips_class32", null);
                    while (h != IntPtr.Zero) {
                        Handle(h, cx, cy);
                        h = FindWindowEx(IntPtr.Zero, h, "tooltips_class32", null);
                    }
                }

                // 快路径 2: 前台应用自己的窗口(Chromium 弹窗就在这里)
                found.Clear();
                uint fpid; uint ftid = GetWindowThreadProcessId(fg, out fpid);
                ScanThread(ftid, cx, cy, found);
                if (tick % 25 == 0) {                       // 其余线程低频扫
                    foreach (var t in Threads) if (t != ftid) ScanThread(t, cx, cy, found);
                }
                foreach (var f in found) Handle(f, cx, cy);

                // 快路径 3: 已接管的窗口(兜住换了线程的情况)
                foreach (var kv in Managed) {
                    IntPtr mh = kv.Key;
                    if (!IsWindow(mh)) { Managed.TryRemove(mh, out _); continue; }
                    RECT r;
                    if (!GetWindowRect(mh, out r)) continue;
                    int w = r.Right - r.Left, ht = r.Bottom - r.Top;
                    if (w <= 0 || ht <= 0) continue;
                    if (!IsWindowVisible(mh)) {
                        string mc = ClassOf(mh);
                        bool tipCls = mc.IndexOf("ooltip", StringComparison.OrdinalIgnoreCase) >= 0;
                        if (tipCls) { if (w <= 900 && ht <= 400) HideContent(kv.Value); }
                        else Managed.TryRemove(mh, out _);   // 不是提示框类, 不再跟踪
                        continue;
                    }
                    if (LooksLikeTip(mh, cx, cy, r) || IsAtTarget(r, cx, cy)) Handle(mh, cx, cy);
                }

                // 观察表限流: 只保留还活着的
                if (Managed.Count > 60) {
                    var victims = new List<IntPtr>(Managed.Keys);
                    foreach (var v in victims) if (!IsWindow(v) || !IsWindowVisible(v)) Managed.TryRemove(v, out _);
                }

                // 兜底: 每 ~200ms 全量扫一次
                if (tick % 100 == 0) {
                    found.Clear();
                    EnumWindows((hh, pp) => {
                        if (!IsWindowVisible(hh)) return true;
                        RECT r;
                        if (!GetWindowRect(hh, out r)) return true;
                        if (Math.Abs(r.Left - cx) > 80 || r.Top < cy + 4 || r.Top > cy + 170) return true;
                        string c = ClassOf(hh);
                        if (c.Length == 0 || IsSkip(c)) return true;
                        if (hh == GetForegroundWindow()) return true;
                        found.Add(hh);
                        return true;
                    }, IntPtr.Zero);
                    foreach (var f in found) Handle(f, cx, cy);
                }

                Thread.Sleep(Math.Max(1, intervalMs));
            }
        }
        finally {
            foreach (var kv in Managed) { try { ShowContent(kv.Value); } catch { } }
            if (EmptyRegion != IntPtr.Zero) DeleteObject(EmptyRegion);
        }
        return "stopped";
    }
}
'@

Set-Content -Path $pidFile -Value $PID -Encoding ascii
try {
    [TipTaker3]::Run($IntervalMs, $Gap, $Mode, $stopFile, $logFile)
}
finally {
    # 只清理自己写的 PID 文件, 避免把新实例的 PID 误删
    if (Test-Path $pidFile) {
        $cur = (Get-Content $pidFile -Raw -ErrorAction SilentlyContinue).Trim()
        if ($cur -eq "$PID") { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path $stopFile) { Remove-Item $stopFile -Force -ErrorAction SilentlyContinue }
}
