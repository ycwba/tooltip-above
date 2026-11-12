# test-tooltip-above.ps1 — 自检: 造一个真实系统提示框, 验证是否被移到光标左上角、是否会被抢回
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class T3 {
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  public static int[] CursorXY(){ POINT p; GetCursorPos(out p); return new int[]{p.X,p.Y}; }
  public static int[] RectOf(IntPtr h){ RECT r; if(!GetWindowRect(h,out r)) return null; return new int[]{r.Left,r.Top,r.Right,r.Bottom}; }
  public static List<IntPtr> Tips(){
    var l=new List<IntPtr>();
    EnumWindows((h,p)=>{
      if(!IsWindowVisible(h)) return true;
      var sb=new StringBuilder(256); GetClassName(h,sb,256);
      var c=sb.ToString();
      if(c.IndexOf("ooltip",StringComparison.OrdinalIgnoreCase)>=0) l.Add(h);
      return true;
    }, IntPtr.Zero);
    return l;
  }
}
'@

$c0 = [T3]::CursorXY()
$form = New-Object System.Windows.Forms.Form
$form.Text='tooltip-above 自检'; $form.FormBorderStyle='FixedToolWindow'; $form.StartPosition='Manual'
$form.TopMost=$true
$form.Location=New-Object System.Drawing.Point(400,400)
$form.ClientSize=New-Object System.Drawing.Size(260,160)
$btn=New-Object System.Windows.Forms.Button
$btn.Text='HOVER'; $btn.Size=New-Object System.Drawing.Size(120,40); $btn.Location=New-Object System.Drawing.Point(70,60)
$form.Controls.Add($btn)
$tt=New-Object System.Windows.Forms.ToolTip
$tt.SetToolTip($btn,'TEST-TOOLTIP-ABC')
$form.Show(); $form.Activate(); $form.BringToFront()
[System.Windows.Forms.Application]::DoEvents()
Start-Sleep -Milliseconds 500

[void][T3]::SetCursorPos(20, 20)
Start-Sleep -Milliseconds 250
$sp=$btn.PointToScreen((New-Object System.Drawing.Point([int]($btn.Width/2),[int]($btn.Height/2))))
[void][T3]::SetCursorPos($sp.X,$sp.Y)

$tip=[IntPtr]::Zero; $rect=$null
$end=(Get-Date).AddSeconds(4)
while((Get-Date) -lt $end){
  [System.Windows.Forms.Application]::DoEvents()
  foreach($h in [T3]::Tips()){
    $r=[T3]::RectOf($h)
    if($null -ne $r -and ($r[3]-$r[1]) -gt 5){ $tip=$h; $rect=$r; break }
  }
  if($tip -ne [IntPtr]::Zero){ break }
  Start-Sleep -Milliseconds 80
}
if($tip -ne [IntPtr]::Zero){
  $c=[T3]::CursorXY()
  "T+0.0s  提示框=$($rect[0]),$($rect[1])..$($rect[2]),$($rect[3])  光标=($($c[0]),$($c[1]))  $(if($rect[3] -le $c[1] -and $rect[2] -le $c[0]){'已在光标左上角 ✓'}else{'仍在光标右下角 ✗'})"
  Start-Sleep -Milliseconds 2500
  $rect2=[T3]::RectOf($tip); $c2=[T3]::CursorXY()
  "T+2.5s  提示框=$($rect2[0]),$($rect2[1])..$($rect2[2]),$($rect2[3])  光标=($($c2[0]),$($c2[1]))  $(if($rect2[3] -le $c2[1] -and $rect2[2] -le $c2[0]){'仍在左上角(未被应用抢回) ✓'}else{'被应用抢回 ✗'})"
}else{ 'RESULT=NO_TOOLTIP' }
$form.Close()
[void][T3]::SetCursorPos($c0[0],$c0[1])
