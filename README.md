# tooltip-above

把 Windows 的**鼠标悬浮信息框(tooltip)**挪到光标**右上角**,不再被鼠标箭头挡住。

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

先说结论:**不同应用用的提示框不是一类窗口,必须分开处理。**

- 原生 Win32 提示框(`tooltips_class32`):窗口是**复用**的,应用只是把它显示/隐藏。
- Chromium / Electron 应用(MCode、Chrome、Edge…):每次悬浮都会**新建**一个 `Chrome_WidgetWin_1` 弹窗窗口。

所以有三条路径并行:

1. **原生提示框**:用 `FindWindowEx` 精确查 `tooltips_class32`,单次约 0.01ms。窗口空闲时是隐藏的,脚本会**先清空它的窗口区域**(内容画不出来),等应用把它显示到右下角时用户什么都看不到,随后再挪到右上角并恢复显示 —— 右下角那个位置根本来不及出现。
2. **Chromium 弹窗**:只枚举**前台应用自己的线程窗口**(提示框和主窗口同进程),成本约 0.25ms,2ms 一轮,能在提示框出现后 ~2ms 内完成位移。
3. **兜底**:每 ~200ms 一次全量窗口扫描,覆盖换了线程或特殊实现的情况。

定位之后仍会持续强制回位,应用自己把位置抢回去也会被立刻拉回。

### 踩过的坑

- 传给 `SetWinEventHook` 的委托必须用**静态字段**持有,否则会被 GC 回收,钩子静默失效。
- `RegisterClassEx` 的 P/Invoke 必须标 `CharSet.Unicode`,否则类名会按 ANSI 解释,注册成乱码。
- 提示框类名常被加前缀(如 `WindowsForms10.tooltips_class32....`),匹配要按**子串**而不是全等。
- **`EnumWindows` 里不要先查窗口类名**:`GetClassName` 对其它进程的窗口是一次跨进程调用,445 个窗口下会让扫描从 0.39ms 变成 0.46ms,而且会把 CPU 拉高好几倍。先按几何位置过滤,只在候选窗口上查类名。
- WinEvent 钩子(OUTOFCONTEXT)在部分环境下不投递事件,不能依赖它做主路径。

## 作用范围

**能接管**:原生 Win32 提示框、Chromium/Electron 的独立弹出窗口。

**接管不了**:在应用自己的窗口内部用 HTML/CSS 绘制的提示(没有独立窗口),这种只能在应用自己的设置里改。

菜单类窗口(`#32768` 等,顶边正好等于光标 y 的)会被排除,不会把右键菜单顶飞。

## 资源占用

常驻约 **2~13% 单核** CPU(取决于前台应用线程数)、约 165MB 内存(PowerShell 自身开销)。
