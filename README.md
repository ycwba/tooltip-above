# tooltip-above

把 Windows 的**鼠标悬浮信息框(tooltip)**从光标右下角挪到光标**右上角**,不再被鼠标箭头挡住。

Windows 本身没有这个开关(注册表里跟提示相关的只有 `ShowInfoTip` / `EnableBalloonTips` / `MouseHoverTime`,全是"显不显示/等多久",没有"位置"),所以这个脚本自己接管提示框的定位。

## 效果

| | 提示框位置 |
|---|---|
| 系统默认 | 光标右下角(箭头压住左上角) |
| 脚本接管后 | 光标右上角(提示框左下角贴光标右上角) |

## 用法

```powershell
# 启动(后台隐藏运行)
pwsh -NoProfile -File tooltip-above.ps1

# 停止
pwsh -NoProfile -File stop-tooltip-above.ps1

# 双击启动(可选参数: 0=右上角 1=左上角 2=正上方)
start-tooltip-above.bat
```

参数:

| 参数 | 说明 |
|---|---|
| `-Mode 0` | 光标**右上角**(默认) |
| `-Mode 1` | 光标左上角 |
| `-Mode 2` | 光标正上方(左边缘不变,整体上移) |
| `-Gap 2` | 与光标的间距(像素) |
| `-Debug` | 把每次定位写进 `tooltip-above.log`,排查用 |

## 开机自启

写注册表 Run 键,登录后隐藏运行:

```powershell
$pwsh = (Get-Command pwsh).Source
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$cmd = '"' + $pwsh + '" -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$env:USERPROFILE\Scripts\tooltip-above\tooltip-above.ps1"'
New-ItemProperty -Path $runKey -Name 'TooltipAbove' -Value $cmd -PropertyType String -Force
```

## 实现原理

三路并行,谁快用谁:

1. **WinEvent 钩子(主力)** —— 独立的高优先级消息泵线程用 `MsgWaitForMultipleObjects` 阻塞等待消息(不 sleep、不轮询)。窗口一触发 `EVENT_OBJECT_SHOW` 就立刻把提示框挪到目标位置,赶在它被绘制之前,所以不会"先在右下角闪一下再跳过去"。
2. **零成本快路径** —— 每轮用 `FindWindowEx` 精确查 `tooltips_class32`(原生提示框、Chromium 链接提示),单次约 0.01ms。
3. **兜底全量扫描** —— 定期扫一遍所有顶层窗口,覆盖应用自绘的弹层。

定位之后仍会持续强制回位,应用自己把位置抢回去也会被立刻拉回来。

实现上踩过的坑,记录在代码注释里:

- 传给 `SetWinEventHook` 的委托必须用**静态字段**持有,否则会被 GC 回收,钩子静默失效。
- `RegisterClassEx` 的 P/Invoke 必须标 `CharSet.Unicode`,否则类名会按 ANSI 解释,注册成乱码。
- 提示框类名常被加前缀(如 `WindowsForms10.tooltips_class32....`),匹配要按**子串**而不是全等。

## 作用范围

**能接管**:原生 Win32 提示框(`tooltips_class32`)、Chromium/Electron 的独立弹出窗口。

**接管不了**:在应用自己的窗口内部用 HTML/CSS 绘制的提示(没有独立窗口),这种只能在应用自己的设置里改。

菜单类窗口(`#32768` 等,顶边正好等于光标 y 的)会被排除,不会把右键菜单顶飞。

## 资源占用

常驻约 **1% 单核** CPU、约 165MB 内存(PowerShell 自身开销)。
