# tooltip-above.ps1 — 把鼠标悬浮信息框移到光标右上角(不闪)
#
# 目标位置(默认 -Mode 0): 提示框的【左下角】贴在光标的【右上角】
#   -Mode 1 = 左上角     -Mode 2 = 正上方     -Gap 2 = 与光标的间距(像素)
#
# 不闪的原理:
#   独立的高优先级消息泵线程用 MsgWaitForMultipleObjects 阻塞等待(不轮询、不 sleep),
#   窗口一 SHOW 事件就立刻把提示框挪到目标位置 —— 赶在它被绘制之前,
#   所以用户只看到它出现在右上角, 不会先在右下角闪一下。
#
# 另有两层保险:
#   快路径: 每轮精确查 tooltips_class32(原生/Chromium 提示框)
#   兜底: 定期全量扫描, 覆盖自绘弹层
# 定位后持续强制回位, 应用自己抢回去也会被拉回来
#
# 启动: pwsh -NoProfile -File tooltip-above.ps1
# 停止: pwsh -NoProfile -File stop-tooltip-above.ps1
param(
    [int]$IntervalMs = 14,
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

public class TipMover2 {
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    public delegate void WinEventProc(IntPtr hWin, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);

    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int x; public int y; }

    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr parent, IntPtr after, string cls, string win);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr hmod, WinEventProc cb, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr h);
    [DllImport("user32.dll")] static extern bool PeekMessage(out MSG msg, IntPtr h, uint min, uint max, uint remove);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern uint MsgWaitForMultipleObjects(uint n, IntPtr[] handles, bool all, uint timeout, uint flags);
    [DllImport("kernel32.dll")] static extern IntPtr CreateEvent(IntPtr attrs, bool manual, bool initial, IntPtr name);
    [DllImport("kernel32.dll")] static extern bool SetEvent(IntPtr h);

    const uint SWP = 0x0001 | 0x0004 | 0x0010 | 0x0040; // NOSIZE|NOZORDER|NOACTIVATE|NOOWNERZORDER
    const uint EVENT_OBJECT_CREATE = 0x8000, EVENT_OBJECT_SHOW = 0x8002;
    const uint WINEVENT_OUTOFCONTEXT = 0x0000, WINEVENT_SKIPOWNPROCESS = 0x0002;
    const uint PM_REMOVE = 0x0001;
    const uint QS_ALLINPUT = 0x04FF0004;
    const uint WAIT_OBJECT_0 = 0x00000000;

    static int Gap = 2, Mode = 0;
    static string LogPath = null;

    // 委托必须持有静态引用, 否则会被 GC 回收导致钩子静默失效
    static readonly WinEventProc HookCb;
    static TipMover2() { HookCb = OnWinEvent; }

    static readonly ConcurrentDictionary<IntPtr, byte> Watching = new ConcurrentDictionary<IntPtr, byte>();
    static readonly ConcurrentDictionary<IntPtr, byte> Known    = new ConcurrentDictionary<IntPtr, byte>();
    static readonly object LogLock = new object();

    // 排除菜单/输入类窗口, 免得把右键菜单顶飞
    static readonly string[] SkipCls = { "#32768", "Popup", "Menu", "IME", "MSCTFIME UI" };

    static void Log(string s) {
        if (string.IsNullOrEmpty(LogPath)) return;
        try { lock (LogLock) File.AppendAllText(LogPath, s + Environment.NewLine); } catch { }
    }

    static bool IsSkip(string cls) { foreach (var s in SkipCls) if (cls == s) return true; return false; }

    static string ClassOf(IntPtr h) {
        var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString();
    }

    // 是不是"跟着光标弹出来的悬浮信息框"
    static bool LooksLikeTip(IntPtr h, int cx, int cy, RECT r, bool loose) {
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (w < 10 || ht < 8) return false;
        if (w > 1400 || ht > 800) return false;
        string cls = ClassOf(h);
        if (cls.Length == 0 || IsSkip(cls)) return false;
        if (h == GetForegroundWindow()) return false;
        if (Math.Abs(r.Left - cx) > (loose ? 260 : 80)) return false;
        if (Math.Abs(r.Top - cy) > (loose ? 260 : 170)) return false;
        if (!loose) {
            // 严格模式: 必须正好贴在光标右下角(顶边在光标下方)
            if (r.Top < cy + 6 || r.Top > cy + 160) return false;
        } else {
            // 宽松模式(用于 SHOW 事件): 原生提示框类, 附近即可接管
            if (cls.IndexOf("ooltip", StringComparison.OrdinalIgnoreCase) < 0) return false;
        }
        return true;
    }

    static void Target(int cx, int cy, RECT r, int gap, int mode, out int left, out int top) {
        int w = r.Right - r.Left, ht = r.Bottom - r.Top;
        if (mode == 1) {                 // 左上角
            left = (cx - gap) - w; top = (cy - gap) - ht;
        } else if (mode == 2) {          // 正上方
            left = r.Left; top = cy - ht - gap;
        } else {                         // 右上角(默认)
            left = cx + gap; top = cy - ht - gap;
        }
        if (left < 0) left = 0;
        if (top < 0) top = 0;
    }

    static bool Place(IntPtr h, int cx, int cy, RECT r, int gap, int mode) {
        int left, top;
        Target(cx, cy, r, gap, mode, out left, out top);
        if (Math.Abs(r.Left - left) > 1 || Math.Abs(r.Top - top) > 1) {
            SetWindowPos(h, IntPtr.Zero, left, top, 0, 0, SWP);
            return true;
        }
        return false;
    }

    // WinEvent 回调: 窗口"即将显示"的瞬间就摆好, 来不及在右下角闪一下
    static void OnWinEvent(IntPtr hWin, uint eventType, IntPtr hwnd, int idObject, int idChild, uint t, uint tm) {
        try {
            if (eventType == EVENT_OBJECT_CREATE) {
                string c0 = ClassOf(hWin);
                // 只把"提示框类"窗口放进观察表, 避免把系统所有窗口都拖进来(省 CPU)
                if (c0.Length > 0 && c0.IndexOf("ooltip", StringComparison.OrdinalIgnoreCase) >= 0)
                    Watching.TryAdd(hWin, (byte)0);
                return;
            }
            if (eventType != EVENT_OBJECT_SHOW) return;
            POINT p; GetCursorPos(out p);
            RECT r;
            if (!GetWindowRect(hWin, out r)) return;
            int w = r.Right - r.Left, ht = r.Bottom - r.Top;
            if (w <= 0 || ht <= 0) return;
            if (!LooksLikeTip(hWin, p.X, p.Y, r, true)) return;
            if (Place(hWin, p.X, p.Y, r, Gap, Mode)) Log("HOOK moved " + ClassOf(hWin));
            Known.TryAdd(hWin, (byte)0);
        } catch (Exception ex) { Log("HOOK ERR " + ex.Message); }
    }

    // 专门的消息泵线程: 用 MsgWaitForMultipleObjects 阻塞等待,
    // 消息一到立刻处理, 没有任何 sleep 轮询延迟 -> 能在第一帧绘制前完成定位
    static void HookPump(IntPtr stopEvt) {
        IntPtr hook = SetWinEventHook(EVENT_OBJECT_CREATE, EVENT_OBJECT_SHOW, IntPtr.Zero, HookCb, 0, 0,
                                      WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS);
        Log("hook=" + (hook != IntPtr.Zero));
        MSG msg;
        IntPtr[] handles = new IntPtr[] { stopEvt };
        while (true) {
            uint r = MsgWaitForMultipleObjects(1, handles, false, 200, QS_ALLINPUT);
            if (r == WAIT_OBJECT_0) break;                       // 停止信号
            if (r == WAIT_OBJECT_0 + 1) {                        // 有消息
                while (PeekMessage(out msg, IntPtr.Zero, 0, 0, PM_REMOVE)) {
                    TranslateMessage(ref msg);
                    DispatchMessage(ref msg);
                }
            }
        }
        if (hook != IntPtr.Zero) UnhookWinEvent(hook);
    }

    static List<IntPtr> Scan(int cx, int cy) {
        var list = new List<IntPtr>();
        EnumWindows((h, p) => {
            if (!IsWindowVisible(h)) return true;
            RECT r;
            if (GetWindowRect(h, out r) && LooksLikeTip(h, cx, cy, r, false)) list.Add(h);
            return true;
        }, IntPtr.Zero);
        return list;
    }

    public static string Run(int intervalMs, int gap, int mode, string stopFile, string logPath) {
        Gap = gap; Mode = mode; LogPath = logPath;

        IntPtr stopEvt = CreateEvent(IntPtr.Zero, true, false, IntPtr.Zero);
        var pump = new Thread(() => HookPump(stopEvt));
        pump.IsBackground = true;
        pump.Priority = ThreadPriority.Highest;
        pump.Start();

        try {
            int tick = 0;
            while (!File.Exists(stopFile)) {
                POINT p; GetCursorPos(out p);
                int cx = p.X, cy = p.Y;
                tick++;

                // 零成本快路径: 精确类名查找原生/Chromium 提示框
                IntPtr h = FindWindowEx(IntPtr.Zero, IntPtr.Zero, "tooltips_class32", null);
                while (h != IntPtr.Zero) {
                    RECT r;
                    if (IsWindowVisible(h) && GetWindowRect(h, out r) && LooksLikeTip(h, cx, cy, r, false)) {
                        if (Place(h, cx, cy, r, Gap, Mode)) Log("FAST moved");
                        Known.TryAdd(h, (byte)0);
                    }
                    h = FindWindowEx(IntPtr.Zero, h, "tooltips_class32", null);
                }

                // 观察列表: 钩子报过的新窗口, 逐个廉价检查
                foreach (var kv in Watching) {
                    IntPtr wh = kv.Key;
                    RECT r;
                    if (!IsWindowVisible(wh) || !GetWindowRect(wh, out r) || (r.Right - r.Left) <= 0) continue;
                    if (LooksLikeTip(wh, cx, cy, r, true)) {
                        if (Place(wh, cx, cy, r, Gap, Mode)) Log("WATCH moved");
                        Known.TryAdd(wh, (byte)0);
                    }
                }
                if (Watching.Count > 400) {
                    var victims = new List<IntPtr>(Watching.Keys);
                    foreach (var v in victims) {
                        RECT r;
                        if (!IsWindowVisible(v) || !GetWindowRect(v, out r) || (r.Right - r.Left) <= 0) Watching.TryRemove(v, out _);
                    }
                }

                // 已定位的窗口: 定期强制回位(应用抢回去也拉回来)
                if (tick % 2 == 0) {
                    foreach (var kv in Known) {
                        IntPtr kh = kv.Key;
                        RECT r;
                        if (!IsWindowVisible(kh) || !GetWindowRect(kh, out r) || (r.Right - r.Left) <= 0) { Known.TryRemove(kh, out _); continue; }
                        Place(kh, cx, cy, r, Gap, Mode);
                    }
                }

                // 兜底全量扫描(自绘弹层 / 钩子漏掉的)
                if (tick % 4 == 0) {
                    foreach (var sh in Scan(cx, cy)) Known.TryAdd(sh, (byte)0);
                }

                Thread.Sleep(Math.Max(2, intervalMs / 2));
            }
        }
        finally {
            if (stopEvt != IntPtr.Zero) SetEvent(stopEvt);
            pump.Join(1500);
        }
        return "stopped";
    }
}
'@

Set-Content -Path $pidFile -Value $PID -Encoding ascii
try {
    [TipMover2]::Run($IntervalMs, $Gap, $Mode, $stopFile, $logFile)
}
finally {
    if (Test-Path $pidFile) { Remove-Item $pidFile -Force -ErrorAction SilentlyContinue }
    if (Test-Path $stopFile) { Remove-Item $stopFile -Force -ErrorAction SilentlyContinue }
}
