<#
  Hardware Widget - always-on-top desktop widget + system-tray monitor.
  Pure Windows PowerShell 5.1 / .NET Framework. No installs.

  Launch hidden via "Hardware Widget.vbs" (recommended) or:
    powershell -NoProfile -ExecutionPolicy Bypass -STA -File widget.ps1

  Right-click the widget (or the tray icon) for options.
  Run with -SelfTest for a headless sanity check.
#>
param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $Root 'widget-config.json'
$LogPath = Join-Path $Root 'widget-error.log'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ---- native helpers (hide console, free icon handles, DWM rounded corners) ----
if (-not ('Native.Win' -as [type])) {
  Add-Type -Namespace Native -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool DestroyIcon(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
'@
}

# Ask DWM (Windows 11) to round a window's corners - smooth & anti-aliased,
# unlike a GraphicsPath Region which produces jagged corners.
function Set-DwmCorners($hwnd, [int]$pref = 2) {
  # DWMWA_WINDOW_CORNER_PREFERENCE = 33; DWMWCP_ROUND = 2, DWMWCP_ROUNDSMALL = 3
  try { $p = $pref; [void][Native.Win]::DwmSetWindowAttribute($hwnd, 33, [ref]$p, 4) } catch {}
}

# ---------- static system facts ----------
$cpuChip = Get-CimInstance Win32_Processor | Select-Object -First 1
$BaseMHz = [int]$cpuChip.MaxClockSpeed
$CpuName = (($cpuChip.Name) -replace '\s+', ' ').Trim()
$HasNvidia = [bool](Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue)

# ---------- palette (dark) ----------
$Pal = @{
  bg     = [System.Drawing.Color]::FromArgb(240, 22, 22, 21)
  card   = [System.Drawing.Color]::FromArgb(255, 26, 26, 25)
  ink    = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
  ink2   = [System.Drawing.Color]::FromArgb(255, 195, 194, 183)
  muted  = [System.Drawing.Color]::FromArgb(255, 137, 135, 129)
  grid   = [System.Drawing.Color]::FromArgb(255, 44, 44, 42)
  cpu    = [System.Drawing.Color]::FromArgb(255, 57, 135, 229)
  ram    = [System.Drawing.Color]::FromArgb(255, 25, 158, 112)
  gpu    = [System.Drawing.Color]::FromArgb(255, 201, 133, 0)
  vram   = [System.Drawing.Color]::FromArgb(255, 0, 131, 0)
  down   = [System.Drawing.Color]::FromArgb(255, 144, 133, 233)
  up     = [System.Drawing.Color]::FromArgb(255, 230, 103, 103)
  warn   = [System.Drawing.Color]::FromArgb(255, 250, 178, 25)
  crit   = [System.Drawing.Color]::FromArgb(255, 208, 59, 59)
}

# ---------- formatting ----------
function Format-Bytes($b, [int]$dp = 1) {
  if ($null -eq $b) { return '--' }   # $b left untyped so a missing value stays $null (a [double] param would coerce it to 0)
  $u = 'B', 'KB', 'MB', 'GB', 'TB'; $i = 0; $v = [math]::Abs([double]$b)
  while ($v -ge 1024 -and $i -lt 4) { $v /= 1024; $i++ }
  $d = if ($v -ge 100 -or $i -eq 0) { 0 } else { $dp }
  return ('{0:N' + $d + '} {1}') -f $v, $u[$i]
}
function Format-Rate([double]$bps) {
  if ($null -eq $Cfg -or $Cfg.netUnits -ne 'bits') {
    # bytes per second (default): KB/s, MB/s, ...
    return (Format-Bytes $bps) + '/s'
  }
  $bits = $bps * 8; $u = 'bps', 'Kbps', 'Mbps', 'Gbps'; $i = 0; $v = $bits
  while ($v -ge 1000 -and $i -lt 3) { $v /= 1000; $i++ }
  $d = if ($v -ge 100 -or $i -eq 0) { 0 } else { 1 }
  return ('{0:N' + $d + '} {1}') -f $v, $u[$i]
}

# ---------- one-shot sampler (used by SelfTest) ----------
function Get-QuickStats {
  $o = @{}
  try {
    $t = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
    $u = [double]$t.PercentProcessorUtility
    if ($u -le 0) { $u = [double]$t.PercentProcessorTime }
    $o.cpu = [math]::Round([math]::Max(0, [math]::Min(100, $u)), 1)
    if ([double]$t.PercentProcessorPerformance -gt 0) { $o.cpuGHz = [math]::Round($BaseMHz * [double]$t.PercentProcessorPerformance / 100000, 2) }
  } catch { $o.cpu = 0 }
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $o.memTotalB = [double]$os.TotalVisibleMemorySize * 1024
    $o.memUsedB = $o.memTotalB - [double]$pm.AvailableBytes
    $o.memPct = [math]::Round($o.memUsedB / $o.memTotalB * 100, 1)
  } catch {}
  try {
    $down = 0.0; $up = 0.0
    foreach ($n in @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface)) {
      if ($n.Name -match 'isatap|Loopback|Teredo') { continue }
      $down += [double]$n.BytesReceivedPersec; $up += [double]$n.BytesSentPersec
    }
    $o.netDown = $down; $o.netUp = $up
  } catch {}
  if ($HasNvidia) {
    try {
      $l = & nvidia-smi.exe '--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1
      $f = $l -split ',\s*'
      $o.gpuUtil = [double]$f[0]; $o.vramUsedB = [double]$f[1] * 1MB; $o.vramTotalB = [double]$f[2] * 1MB
      $o.vramPct = [math]::Round($o.vramUsedB / $o.vramTotalB * 100, 1)
      $o.gpuTempC = [double]$f[3]; $o.gpuPowerW = [double]$f[4]
    } catch {}
  }
  return $o
}

if ($SelfTest) {
  $ok = $true
  try {
    $s = Get-QuickStats
    Write-Host ("SelfTest sample: CPU {0}% RAM {1}% GPU {2}% VRAM {3}% down {4} up {5}" -f `
      $s.cpu, $s.memPct, $s.gpuUtil, $s.vramPct, (Format-Rate $s.netDown), (Format-Rate $s.netUp))
    $null = [System.Windows.Forms.Form]; $null = [System.Drawing.Bitmap]
    Write-Host "SelfTest: WinForms/Drawing types load OK"
  } catch { $ok = $false; Write-Host "SelfTest FAILED: $($_.Exception.Message)" }
  if ($ok) { Write-Host 'SelfTest: PASS' } else { exit 1 }
  return
}

# hide the launching console window (belt-and-suspenders; VBS also launches hidden)
[void][Native.Win]::ShowWindow([Native.Win]::GetConsoleWindow(), 0)

# ---------- config ----------
$DefaultCfg = @{
  corner = 'bottom-right'; opacity = 88; interval = 1000; width = 248; dockEdge = 'top'; netUnits = 'bytes'
  stats = @{ cpu = $true; ram = $true; gpu = $true; vram = $true; net = $true }
}
function Load-Cfg {
  try {
    if (Test-Path $ConfigPath) {
      $j = Get-Content $ConfigPath -Raw | ConvertFrom-Json
      return @{
        corner  = if ($j.corner) { $j.corner } else { $DefaultCfg.corner }
        opacity = if ($j.opacity) { [int]$j.opacity } else { $DefaultCfg.opacity }
        interval = if ($j.interval) { [int]$j.interval } else { $DefaultCfg.interval }
        width   = if ($j.width) { [int]$j.width } else { $DefaultCfg.width }
        dockEdge = if ($j.dockEdge) { [string]$j.dockEdge } else { $DefaultCfg.dockEdge }
        netUnits = if ($j.netUnits) { [string]$j.netUnits } else { $DefaultCfg.netUnits }
        stats = @{
          cpu  = [bool]$j.stats.cpu;  ram  = [bool]$j.stats.ram
          gpu  = [bool]$j.stats.gpu;  vram = [bool]$j.stats.vram; net = [bool]$j.stats.net
        }
      }
    }
  } catch {}
  # deep copy so mutating $Cfg.stats never touches $DefaultCfg.stats (Clone() is shallow)
  return @{
    corner = $DefaultCfg.corner; opacity = $DefaultCfg.opacity; interval = $DefaultCfg.interval
    width = $DefaultCfg.width; dockEdge = $DefaultCfg.dockEdge; netUnits = $DefaultCfg.netUnits
    stats = @{ cpu = $true; ram = $true; gpu = $true; vram = $true; net = $true }
  }
}
$Cfg = Load-Cfg
function Save-Cfg {
  try { $Cfg | ConvertTo-Json -Depth 4 | Set-Content -Path $ConfigPath -Encoding UTF8 } catch {}
}

# Start the local stats server (if not already up) and open the dashboard.
# If a dashboard app window is already open, do nothing (avoids stacking windows on repeated clicks).
function Open-Dashboard {
  try {
    $existing = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -like '*--app=http://localhost:8787*' })
    if ($existing.Count -gt 0) { return }
    $srv = Join-Path $Root 'server.ps1'
    Start-Process powershell -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$srv`"" -WindowStyle Hidden
    Start-Sleep -Milliseconds 700
    try { Start-Process 'msedge.exe' -ArgumentList '--app=http://localhost:8787/' -ErrorAction Stop }
    catch { Start-Process 'http://localhost:8787/' }
  } catch {}
}

# ---------- shared state + background sampler ----------
$Sync = [hashtable]::Synchronized(@{ run = $true; interval = $Cfg.interval; ready = $false })

$samplerScript = {
  param($Sync, $BaseMHz, $HasNvidia)
  $HN = 60
  $h = @{ cpu = @(); ram = @(); gpu = @(); vram = @(); down = @(); up = @() }
  function Push-H($k, $v) {
    $script:h[$k] += , ([double]$v)
    if ($script:h[$k].Count -gt $HN) { $script:h[$k] = $script:h[$k][($script:h[$k].Count - $HN)..($script:h[$k].Count - 1)] }
  }
  while ($Sync.run) {
    $d = @{}
    try {
      $t = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'"
      $u = [double]$t.PercentProcessorUtility
      if ($u -le 0) { $u = [double]$t.PercentProcessorTime }
      $d.cpu = [math]::Round([math]::Max(0, [math]::Min(100, $u)), 1)
      if ([double]$t.PercentProcessorPerformance -gt 0) { $d.cpuGHz = [math]::Round($BaseMHz * [double]$t.PercentProcessorPerformance / 100000, 2) }
    } catch { $d.cpu = 0 }
    try {
      $os = Get-CimInstance Win32_OperatingSystem
      $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
      $d.memTotalB = [double]$os.TotalVisibleMemorySize * 1024
      $d.memUsedB = $d.memTotalB - [double]$pm.AvailableBytes
      $d.memPct = [math]::Round($d.memUsedB / $d.memTotalB * 100, 1)
    } catch {}
    try {
      $down = 0.0; $up = 0.0
      foreach ($n in @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface)) {
        if ($n.Name -match 'isatap|Loopback|Teredo') { continue }
        $down += [double]$n.BytesReceivedPersec; $up += [double]$n.BytesSentPersec
      }
      $d.netDown = $down; $d.netUp = $up
    } catch { $d.netDown = 0; $d.netUp = 0 }
    if ($HasNvidia) {
      try {
        $l = & nvidia-smi.exe '--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw' '--format=csv,noheader,nounits' 2>$null | Select-Object -First 1
        $f = $l -split ',\s*'
        $d.gpuUtil = [double]$f[0]; $d.vramUsedB = [double]$f[1] * 1MB; $d.vramTotalB = [double]$f[2] * 1MB
        $d.vramPct = [math]::Round($d.vramUsedB / $d.vramTotalB * 100, 1)
        $d.gpuTempC = [double]$f[3]; $d.gpuPowerW = [double]$f[4]; $d.hasGpu = $true
      } catch { $d.hasGpu = $false }
    } else { $d.hasGpu = $false }

    Push-H cpu  $d.cpu
    Push-H ram  ($(if ($d.memPct) { $d.memPct } else { 0 }))
    Push-H gpu  ($(if ($d.hasGpu) { $d.gpuUtil } else { 0 }))
    Push-H vram ($(if ($d.hasGpu) { $d.vramPct } else { 0 }))
    Push-H down ($(if ($d.netDown) { $d.netDown } else { 0 }))
    Push-H up   ($(if ($d.netUp) { $d.netUp } else { 0 }))
    $d.histCpu = @($h.cpu); $d.histRam = @($h.ram); $d.histGpu = @($h.gpu)
    $d.histVram = @($h.vram); $d.histDown = @($h.down); $d.histUp = @($h.up)

    $Sync.data = $d
    $Sync.ready = $true
    Start-Sleep -Milliseconds $Sync.interval
  }
}

$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'MTA'
$rs.Open()
$psCmd = [powershell]::Create()
$psCmd.Runspace = $rs
[void]$psCmd.AddScript($samplerScript).AddArgument($Sync).AddArgument($BaseMHz).AddArgument($HasNvidia)
$asyncHandle = $psCmd.BeginInvoke()

# ---------- form (double-buffered, tool window, no taskbar) ----------
if (-not ('HWidget.Panel' -as [type])) {
  Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System;
using System.Windows.Forms;
namespace HWidget {
  public class Panel : Form {
    public Panel() {
      this.DoubleBuffered = true;
      this.SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
    }
    protected override CreateParams CreateParams {
      get { var cp = base.CreateParams; cp.ExStyle |= 0x00000080; return cp; } // WS_EX_TOOLWINDOW
    }
  }
}
'@
}

$STAT_META = @(
  @{ key = 'cpu';  label = 'CPU';     color = $Pal.cpu;  hist = 'histCpu' }
  @{ key = 'ram';  label = 'Memory';  color = $Pal.ram;  hist = 'histRam' }
  @{ key = 'gpu';  label = 'GPU';     color = $Pal.gpu;  hist = 'histGpu' }
  @{ key = 'vram'; label = 'VRAM';    color = $Pal.vram; hist = 'histVram' }
  @{ key = 'net';  label = 'Network'; color = $Pal.down; hist = 'histDown' }
)
# Width tiers control how much detail each row shows:
#   full    (>= 208): icon + label + value + sub-line + sparkline
#   compact (150-207): icon + label + value + sub-line (no sparkline)
#   mini    (< 150):   icon + value only
$MIN_W = 104; $MAX_W = 460
function Get-Tier {
  if ($Cfg.width -lt 150) { return 'mini' }
  if ($Cfg.width -lt 208) { return 'compact' }
  return 'full'
}
function Get-RowH { switch (Get-Tier) { 'mini' { 24 } 'compact' { 32 } default { 46 } } }
function Get-HeaderH { if ((Get-Tier) -eq 'mini') { 14 } else { 16 } }

function Get-VisibleStats { return @($STAT_META | Where-Object { $Cfg.stats[$_.key] }) }
function Measure-Height {
  $n = (Get-VisibleStats).Count
  if ($n -eq 0) { $n = 1 }
  $pad = if ((Get-Tier) -eq 'mini') { 8 } else { 12 }
  return (Get-HeaderH) + $n * (Get-RowH) + $pad
}

$form = New-Object HWidget.Panel
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar = $false
$form.TopMost = $true
$form.StartPosition = 'Manual'
$form.BackColor = $Pal.card
$form.Width = $Cfg.width
$form.Height = Measure-Height
$form.Opacity = $Cfg.opacity / 100

function Set-Rounded {
  # DWM rounds the actual window corners smoothly (anti-aliased); no jagged Region clip.
  $form.Region = $null
  Set-DwmCorners $form.Handle 2
}

# The monitor a window currently sits on (multi-monitor aware).
function Screen-Of($f) { return [System.Windows.Forms.Screen]::FromRectangle($f.Bounds) }

function Place-Corner {
  $wa = (Screen-Of $form).WorkingArea
  $m = 16
  switch ($Cfg.corner) {
    'top-left'     { $x = $wa.Left + $m;  $y = $wa.Top + $m }
    'top-right'    { $x = $wa.Right - $form.Width - $m; $y = $wa.Top + $m }
    'bottom-left'  { $x = $wa.Left + $m;  $y = $wa.Bottom - $form.Height - $m }
    default        { $x = $wa.Right - $form.Width - $m; $y = $wa.Bottom - $form.Height - $m }
  }
  $form.Location = New-Object System.Drawing.Point([int]$x, [int]$y)
}

function Clamp-OnScreen {
  $wa = (Screen-Of $form).WorkingArea
  $x = [math]::Min([math]::Max($form.Left, $wa.Left), $wa.Right - $form.Width)
  $y = [math]::Min([math]::Max($form.Top, $wa.Top), $wa.Bottom - $form.Height)
  $form.Location = New-Object System.Drawing.Point([int]$x, [int]$y)
}

# Which screen edge the widget is currently closest to (drives the collapse button
# arrow + where clicking it docks). Follows the widget as it's dragged around.
function Nearest-Edge {
  $wa = (Screen-Of $form).WorkingArea
  $dT = $form.Top - $wa.Top
  $dB = $wa.Bottom - $form.Bottom
  $dL = $form.Left - $wa.Left
  $dR = $wa.Right - $form.Right
  $min = [math]::Min([math]::Min($dT, $dB), [math]::Min($dL, $dR))
  if ($min -eq $dT) { return 'top' }
  if ($min -eq $dB) { return 'bottom' }
  if ($min -eq $dL) { return 'left' }
  return 'right'
}

# ---------- drawing ----------
$fontLabel = New-Object System.Drawing.Font 'Segoe UI', 9, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Point)
$fontValue = New-Object System.Drawing.Font 'Segoe UI Semibold', 11, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Point)
$fontSmall = New-Object System.Drawing.Font 'Segoe UI', 8, ([System.Drawing.FontStyle]::Regular), ([System.Drawing.GraphicsUnit]::Point)
$fontBtn = New-Object System.Drawing.Font 'Segoe UI', 12, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Point)
$fontArrow = New-Object System.Drawing.Font 'Segoe UI', 16, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Point)
$sfRight = New-Object System.Drawing.StringFormat; $sfRight.Alignment = 'Far'
$sfLeft = New-Object System.Drawing.StringFormat; $sfLeft.Alignment = 'Near'
$sfCenter = New-Object System.Drawing.StringFormat; $sfCenter.Alignment = 'Center'; $sfCenter.LineAlignment = 'Center'

function Draw-Spark($g, $rect, $data, $color, $max) {
  if (-not $data -or $data.Count -lt 2) { return }
  $n = $data.Count
  $mx = $max
  if ($null -eq $mx) { $mx = 1; foreach ($v in $data) { if ($v -gt $mx) { $mx = $v } }; $mx *= 1.15 }
  if ($mx -le 0) { $mx = 1 }
  $pts = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
  for ($i = 0; $i -lt $n; $i++) {
    $x = $rect.X + $rect.Width * $i / ($n - 1)
    $y = $rect.Y + $rect.Height - $rect.Height * [math]::Min($data[$i], $mx) / $mx
    $pts.Add((New-Object System.Drawing.PointF([single]$x, [single]$y)))
  }
  # area
  $poly = New-Object 'System.Collections.Generic.List[System.Drawing.PointF]'
  $poly.Add((New-Object System.Drawing.PointF([single]$rect.X, [single]($rect.Y + $rect.Height))))
  $poly.AddRange($pts)
  $poly.Add((New-Object System.Drawing.PointF([single]($rect.X + $rect.Width), [single]($rect.Y + $rect.Height))))
  $fill = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(28, $color.R, $color.G, $color.B))
  $g.FillPolygon($fill, $poly.ToArray()); $fill.Dispose()
  # line
  $pen = New-Object System.Drawing.Pen $color, 2
  $pen.LineJoin = 'Round'; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
  $g.DrawLines($pen, $pts.ToArray()); $pen.Dispose()
  # end dot
  $last = $pts[$pts.Count - 1]
  $db = New-Object System.Drawing.SolidBrush $color
  $g.FillEllipse($db, $last.X - 3, $last.Y - 3, 6, 6); $db.Dispose()
}

function Format-RateShort([double]$bps) {
  if ($null -eq $Cfg -or $Cfg.netUnits -ne 'bits') {
    # bytes per second (default), compact: 774KB, 1.2MB
    $u = 'B', 'KB', 'MB', 'GB'; $i = 0; $v = [math]::Abs($bps)
    while ($v -ge 1024 -and $i -lt 3) { $v /= 1024; $i++ }
    $dp = if ($v -ge 100 -or $i -eq 0) { 0 } else { 1 }
    return ('{0:N' + $dp + '}{1}') -f $v, $u[$i]
  }
  $bits = $bps * 8; $u = 'b', 'K', 'M', 'G'; $i = 0; $v = $bits
  while ($v -ge 1000 -and $i -lt 3) { $v /= 1000; $i++ }
  $dp = if ($v -ge 100 -or $i -eq 0) { 0 } else { 1 }
  return ('{0:N' + $dp + '}{1}') -f $v, $u[$i]
}

function Hide-Button-Rect {
  # top-right corner hit zone for the collapse button
  return New-Object System.Drawing.Rectangle (($Cfg.width - 20), 0, 20, 16)
}

# Draw a small vector glyph for a stat, stroked in its colour, inside an s x s box at (x,y).
function Draw-Icon($g, $key, $x, $y, $s, $color) {
  $pen = New-Object System.Drawing.Pen $color, 1.4
  $pen.LineJoin = 'Round'; $pen.StartCap = 'Round'; $pen.EndCap = 'Round'
  $br = New-Object System.Drawing.SolidBrush $color
  $L = { param($a, $b, $c, $d) $g.DrawLine($pen, [single]$a, [single]$b, [single]$c, [single]$d) }
  $R = { param($a, $b, $c, $d) $g.DrawRectangle($pen, [single]$a, [single]$b, [single]$c, [single]$d) }
  $E = { param($a, $b, $c, $d) $g.DrawEllipse($pen, [single]$a, [single]$b, [single]$c, [single]$d) }
  $A = { param($a, $b, $c, $d, $st, $sw) $g.DrawArc($pen, [single]$a, [single]$b, [single]$c, [single]$d, [single]$st, [single]$sw) }
  switch ($key) {
    'cpu' {
      # processor chip: body + inner die + pins on all four sides
      $in = 3.0; $bx = $x + $in; $by = $y + $in; $bs = $s - 2 * $in
      & $R $bx $by $bs $bs
      & $R ($bx + 2) ($by + 2) ($bs - 4) ($bs - 4)
      foreach ($f in 0.3, 0.5, 0.7) {
        $px = $bx + $bs * $f; $py = $by + $bs * $f
        & $L $px ($by - $in + 1) $px $by
        & $L $px ($by + $bs) $px ($by + $bs + $in - 1)
        & $L ($bx - $in + 1) $py $bx $py
        & $L ($bx + $bs) $py ($bx + $bs + $in - 1) $py
      }
    }
    'ram' {
      # memory module: body + chip lines + two pins
      $rx = $x + 1.5; $ry = $y + 3; $rw = $s - 3; $rh = $s - 8
      & $R $rx $ry $rw $rh
      for ($i = 1; $i -le 3; $i++) { $lx = $rx + $rw * $i / 4; & $L $lx ($ry + 1.5) $lx ($ry + $rh - 1.5) }
      & $L ($rx + $rw * 0.32) ($ry + $rh) ($rx + $rw * 0.32) ($ry + $rh + 2)
      & $L ($rx + $rw * 0.68) ($ry + $rh) ($rx + $rw * 0.68) ($ry + $rh + 2)
    }
    'gpu' {
      # graphics card: board + fan + bracket
      $rx = $x + 1; $ry = $y + 3.5; $rw = $s - 2; $rh = $s - 7
      & $R $rx $ry $rw $rh
      $fd = $rh - 3; $fx = $rx + 1.5; $fy = $ry + 1.5
      & $E $fx $fy $fd $fd
      $g.FillEllipse($br, [single]($fx + $fd / 2 - 0.9), [single]($fy + $fd / 2 - 0.9), [single]1.8, [single]1.8)
      & $L ($rx + $rw) ($ry + 1) ($rx + $rw) ($ry + $rh - 1)
    }
    'vram' {
      # stacked memory layers
      $rx = $x + 1.5; $rw = $s - 3
      for ($i = 0; $i -lt 3; $i++) { $ry = $y + 3 + $i * 3.4; & $R $rx $ry $rw 2.0 }
    }
    'net' {
      # down + up arrows
      $c1 = $x + $s * 0.34; $c2 = $x + $s * 0.66; $top = $y + 3; $bot = $y + $s - 3
      & $L $c1 $top $c1 $bot
      & $L ($c1 - 2) ($bot - 2.5) $c1 $bot
      & $L ($c1 + 2) ($bot - 2.5) $c1 $bot
      & $L $c2 $top $c2 $bot
      & $L ($c2 - 2) ($top + 2.5) $c2 $top
      & $L ($c2 + 2) ($top + 2.5) $c2 $top
    }
    'disk' {
      # cylinder
      $rx = $x + 2; $rw = $s - 4; $ry = $y + 2.5; $eh = 3.5; $bh = $s - 6
      & $E $rx $ry $rw $eh
      & $A $rx ($ry + $bh - $eh) $rw $eh 0 180
      & $L $rx ($ry + $eh / 2) $rx ($ry + $bh - $eh / 2)
      & $L ($rx + $rw) ($ry + $eh / 2) ($rx + $rw) ($ry + $bh - $eh / 2)
    }
    default { & $R ($x + 3) ($y + 3) ($s - 6) ($s - 6) }
  }
  $pen.Dispose(); $br.Dispose()
}

$form.Add_Paint({
  param($sender, $e)
  try {
  $g = $e.Graphics
  $g.SmoothingMode = 'AntiAlias'
  $g.TextRenderingHint = 'ClearTypeGridFit'
  $w = $Cfg.width
  $tier = Get-Tier
  $rowH = Get-RowH
  $headerH = Get-HeaderH
  $leftPad = if ($tier -eq 'mini') { 9 } else { 13 }
  $rightPad = if ($tier -eq 'mini') { 8 } else { 14 }
  $iconBox = if ($tier -eq 'mini') { 13 } else { 15 }
  $labelX = $leftPad + $iconBox + 5

  # background
  $bg = New-Object System.Drawing.SolidBrush $Pal.card
  $g.FillRectangle($bg, 0, 0, $form.Width, $form.Height); $bg.Dispose()

  $d = $Sync.data
  $vis = Get-VisibleStats
  $brInk = New-Object System.Drawing.SolidBrush $Pal.ink
  $brInk2 = New-Object System.Drawing.SolidBrush $Pal.ink2
  $brMuted = New-Object System.Drawing.SolidBrush $Pal.muted
  $brWarn = New-Object System.Drawing.SolidBrush $Pal.warn
  $brCrit = New-Object System.Drawing.SolidBrush $Pal.crit

  # collapse (hide-to-edge) button, top-right; glyph points toward the dock edge
  $hbGlyph = switch (Nearest-Edge) { 'left' { [char]0x00AB } 'right' { [char]0x00BB } 'bottom' { [char]0x25BE } default { [char]0x25B4 } }
  $hbRect = New-Object System.Drawing.RectangleF ($w - 27), 3, 22, 18
  $hbBg = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(34, 255, 255, 255))
  $g.FillRectangle($hbBg, $hbRect.X, $hbRect.Y, $hbRect.Width, $hbRect.Height); $hbBg.Dispose()
  $g.DrawString([string]$hbGlyph, $fontBtn, $brInk, $hbRect, $sfCenter)

  if (-not $Sync.ready -or $null -eq $d) {
    $g.DrawString('Starting...', $fontLabel, $brMuted, $leftPad, ($headerH + 2))
    $brInk.Dispose(); $brInk2.Dispose(); $brMuted.Dispose(); $brWarn.Dispose(); $brCrit.Dispose(); return
  }

  $y = $headerH
  foreach ($m in $vis) {
    # per-stat value / sub text / value color
    $valText = ''; $subText = ''; $valBrush = $brInk; $isNet = $false
    switch ($m.key) {
      'cpu'  { $valText = "$([math]::Round($d.cpu))%"; if ($d.cpuGHz) { $subText = "$($d.cpuGHz) GHz" } }
      'ram'  {
        $valText = Format-Bytes $d.memUsedB
        $subText = "$([math]::Round($d.memPct))% of $(Format-Bytes $d.memTotalB)"
        if ($d.memPct -ge 90) { $valBrush = $brCrit } elseif ($d.memPct -ge 80) { $valBrush = $brWarn }
      }
      'gpu'  {
        if ($d.hasGpu) { $valText = "$([math]::Round($d.gpuUtil))%"; $subText = "$([math]::Round($d.gpuTempC)) C - $([math]::Round($d.gpuPowerW)) W" }
        else { $valText = 'n/a'; $valBrush = $brMuted }
      }
      'vram' {
        if ($d.hasGpu) {
          $valText = Format-Bytes $d.vramUsedB
          $subText = "$([math]::Round($d.vramPct))% of $(Format-Bytes $d.vramTotalB)"
          if ($d.vramPct -ge 90) { $valBrush = $brCrit } elseif ($d.vramPct -ge 80) { $valBrush = $brWarn }
        } else { $valText = 'n/a'; $valBrush = $brMuted }
      }
      'net'  {
        $isNet = $true
        if ($tier -eq 'mini') { $valText = [string][char]0x2193 + (Format-RateShort $d.netDown) }
        else { $valText = [string][char]0x2193 + ' ' + (Format-Rate $d.netDown) }
        $subText = [string][char]0x2191 + ' ' + (Format-Rate $d.netUp)
      }
    }

    # icon glyph (shape + colour)
    $iconY = if ($tier -eq 'mini') { $y + [int](($rowH - $iconBox) / 2) } else { $y + 2 }
    Draw-Icon $g $m.key $leftPad $iconY $iconBox $m.color

    if ($tier -eq 'mini') {
      # icon + value only, single line
      $g.DrawString($valText, $fontValue, $valBrush, (New-Object System.Drawing.RectangleF $labelX, ($y + 2), ($w - $rightPad - $labelX), 20), $sfRight)
    }
    elseif ($tier -eq 'compact') {
      # line 1: label (left) + value (right); line 2: sub (left, small)
      $g.DrawString($m.label, $fontLabel, $brMuted, $labelX, ($y + 1))
      $g.DrawString($valText, $fontValue, $valBrush, (New-Object System.Drawing.RectangleF 0, ($y - 1), ($w - $rightPad), 20), $sfRight)
      if ($subText) { $g.DrawString($subText, $fontSmall, $brMuted, (New-Object System.Drawing.RectangleF $labelX, ($y + 17), ($w - $labelX - 4), 12), $sfLeft) }
    }
    else {
      # full: label + value (line 1), sub (line 2), sparkline (line 3) - kept vertically
      # separate so the graph never draws over the sub-line text
      $g.DrawString($m.label, $fontLabel, $brMuted, $labelX, ($y + 1))
      $g.DrawString($valText, $fontValue, $valBrush, (New-Object System.Drawing.RectangleF 0, ($y - 2), ($w - $rightPad), 20), $sfRight)
      if ($subText) {
        $subBrush = if ($isNet) { $brInk2 } else { $brMuted }
        $g.DrawString($subText, $fontSmall, $subBrush, (New-Object System.Drawing.RectangleF 0, ($y + 16), ($w - $rightPad), 13), $sfRight)
      }
      $sr = New-Object System.Drawing.RectangleF $labelX, ($y + 31), ($w - $labelX - 14), 12
      if ($isNet) {
        $max = 0.0
        foreach ($v in @($d.histDown) + @($d.histUp)) { if ($v -gt $max) { $max = $v } }
        if ($max -le 0) { $max = 1 }
        Draw-Spark $g $sr $d.histDown $Pal.down $max
        Draw-Spark $g $sr $d.histUp $Pal.up $max
      } else {
        $max = 100
        Draw-Spark $g $sr $d[$m.hist] $m.color $max
      }
    }
    $y += $rowH
  }
  $brInk.Dispose(); $brInk2.Dispose(); $brMuted.Dispose(); $brWarn.Dispose(); $brCrit.Dispose()
  } catch {
    "$([DateTime]::Now) PAINT: $($_.Exception.Message)`n$($_.ScriptStackTrace)" | Out-File -FilePath $LogPath -Append -Encoding UTF8
  }
})

# ---------- interaction: click-to-open, drag-move, edge-resize, collapse button ----------
$script:drag = $false; $script:dragOff = New-Object System.Drawing.Point 0, 0
$script:resizing = $null; $script:rsX = 0; $script:rsW = 0; $script:rsLeft = 0
$script:downScreen = New-Object System.Drawing.Point 0, 0; $script:moved = $false

$form.Add_MouseDown({ param($s, $e)
  if ($e.Button -ne 'Left') { return }
  $w = $Cfg.width
  if ($e.X -ge ($w - 28) -and $e.Y -le 22) { Hide-ToEdge (Nearest-Edge); return }   # collapse button -> dock to nearest edge
  if ($e.X -le 7) { $script:resizing = 'left'; $script:rsX = [System.Windows.Forms.Cursor]::Position.X; $script:rsW = $w; $script:rsLeft = $form.Left; return }
  if ($e.X -ge ($w - 7)) { $script:resizing = 'right'; $script:rsX = [System.Windows.Forms.Cursor]::Position.X; $script:rsW = $w; return }
  $script:drag = $true; $script:dragOff = $e.Location
  $script:downScreen = [System.Windows.Forms.Cursor]::Position; $script:moved = $false
})

$form.Add_MouseMove({ param($s, $e)
  if ($script:resizing) {
    $dx = [System.Windows.Forms.Cursor]::Position.X - $script:rsX
    $nw = if ($script:resizing -eq 'right') { $script:rsW + $dx } else { $script:rsW - $dx }
    $nw = [int][math]::Max($MIN_W, [math]::Min($MAX_W, $nw))
    if ($nw -ne $Cfg.width) {
      if ($script:resizing -eq 'left') { $form.Left = $script:rsLeft + ($script:rsW - $nw) }
      $Cfg.width = $nw
      $form.Width = $nw
      $form.Height = Measure-Height
      Set-Rounded
      $form.Invalidate()
    }
    return
  }
  if ($script:drag) {
    $cur = [System.Windows.Forms.Cursor]::Position
    if ([math]::Abs($cur.X - $script:downScreen.X) + [math]::Abs($cur.Y - $script:downScreen.Y) -gt 4) { $script:moved = $true }
    if ($script:moved) {
      $form.Location = New-Object System.Drawing.Point(($form.Left + $e.X - $script:dragOff.X), ($form.Top + $e.Y - $script:dragOff.Y))
      $form.Invalidate()   # refresh the collapse-button arrow to match the nearest edge
    }
    return
  }
  $w = $Cfg.width
  if ($e.X -ge ($w - 28) -and $e.Y -le 22) { $form.Cursor = [System.Windows.Forms.Cursors]::Hand }
  elseif ($e.X -le 7 -or $e.X -ge ($w - 7)) { $form.Cursor = [System.Windows.Forms.Cursors]::SizeWE }
  else { $form.Cursor = [System.Windows.Forms.Cursors]::Hand }
})

$form.Add_MouseUp({ param($s, $e)
  if ($script:resizing) { $script:resizing = $null; Save-Cfg; Clamp-OnScreen; return }
  if ($script:drag) {
    $script:drag = $false
    if (-not $script:moved) { Open-Dashboard; return }   # a click (not a drag) opens the dashboard
    # If the pointer was pushed to a screen edge, auto-hide (dock) to that edge.
    $cur = [System.Windows.Forms.Cursor]::Position
    $sb = ([System.Windows.Forms.Screen]::FromPoint($cur)).Bounds
    $thr = 5
    $edge = $null
    if ($cur.Y -le $sb.Top + $thr) { $edge = 'top' }
    elseif ($cur.Y -ge $sb.Bottom - $thr) { $edge = 'bottom' }
    elseif ($cur.X -le $sb.Left + $thr) { $edge = 'left' }
    elseif ($cur.X -ge $sb.Right - $thr) { $edge = 'right' }
    if ($edge) { Hide-ToEdge $edge; return }
    # Otherwise it's a normal move: un-dock if it was docked, snap on-screen, remember corner.
    if ($script:docked) {
      $script:docked = $false; $script:peekShown = $false
      $dockTimer.Stop(); $peek.Hide(); Build-Menu
    }
    Clamp-OnScreen
    $wa = (Screen-Of $form).WorkingArea
    $cx = $form.Left + $form.Width / 2; $cy = $form.Top + $form.Height / 2
    $hh = if ($cx -lt ($wa.Left + $wa.Width / 2)) { 'left' } else { 'right' }
    $vv = if ($cy -lt ($wa.Top + $wa.Height / 2)) { 'top' } else { 'bottom' }
    $Cfg.corner = "$vv-$hh"; Save-Cfg
  }
})

# ---------- context menu ----------
function Rebuild-Layout {
  $form.Width = $Cfg.width
  $form.Height = Measure-Height
  Set-Rounded
  if ($script:docked) {
    # keep the docked bar sized to the current stats (esp. the bottom readout width)
    Place-Peek $Cfg.dockEdge
    $peek.Invalidate()
    if ($script:peekShown) { Peek-Place }
  } else {
    Place-Corner
  }
  $form.Invalidate()
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.ShowImageMargin = $false

function Add-MenuItem($parent, $text, $checked, $action) {
  $mi = New-Object System.Windows.Forms.ToolStripMenuItem $text
  if ($null -ne $checked) { $mi.Checked = $checked }
  if ($action) { $mi.Add_Click($action) }
  [void]$parent.Items.Add($mi); return $mi
}

function Build-Menu {
  $menu.Items.Clear()
  # Show which stats
  $show = New-Object System.Windows.Forms.ToolStripMenuItem 'Show stats'
  foreach ($m in $STAT_META) {
    $k = $m.key
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $m.label
    $mi.Checked = [bool]$Cfg.stats[$k]
    $mi.Tag = $k
    $mi.Add_Click({ param($s, $e) $key = $s.Tag; $Cfg.stats[$key] = -not $Cfg.stats[$key]; Save-Cfg; Build-Menu; Rebuild-Layout }.GetNewClosure())
    [void]$show.DropDownItems.Add($mi)
  }
  [void]$menu.Items.Add($show)
  # Position
  $pos = New-Object System.Windows.Forms.ToolStripMenuItem 'Position'
  foreach ($c in @('top-left', 'top-right', 'bottom-left', 'bottom-right')) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem ($c -replace '-', ' ')
    $mi.Checked = ($Cfg.corner -eq $c); $mi.Tag = $c
    $mi.Add_Click({ param($s, $e) $Cfg.corner = $s.Tag; Save-Cfg; Build-Menu; Place-Corner }.GetNewClosure())
    [void]$pos.DropDownItems.Add($mi)
  }
  [void]$menu.Items.Add($pos)
  # Size (width tier)
  $sz = New-Object System.Windows.Forms.ToolStripMenuItem 'Size'
  foreach ($pair in @(@('Full (labels + graphs)', 248, 'full'), @('Compact (no graphs)', 176, 'compact'), @('Mini (icons + numbers)', 120, 'mini'))) {
    $lbl = $pair[0]; $wv = $pair[1]; $tv = $pair[2]
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $lbl
    $mi.Checked = ((Get-Tier) -eq $tv); $mi.Tag = $wv
    $mi.Add_Click({ param($s, $e) $Cfg.width = [int]$s.Tag; Save-Cfg; Build-Menu; Rebuild-Layout }.GetNewClosure())
    [void]$sz.DropDownItems.Add($mi)
  }
  [void]$menu.Items.Add($sz)
  # Opacity
  $op = New-Object System.Windows.Forms.ToolStripMenuItem 'Opacity'
  foreach ($o in @(100, 90, 80, 70, 60)) {
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem "$o%"
    $mi.Checked = ($Cfg.opacity -eq $o); $mi.Tag = $o
    $mi.Add_Click({ param($s, $e) $Cfg.opacity = [int]$s.Tag; $form.Opacity = $Cfg.opacity / 100; Save-Cfg; Build-Menu }.GetNewClosure())
    [void]$op.DropDownItems.Add($mi)
  }
  [void]$menu.Items.Add($op)
  # Refresh interval
  $iv = New-Object System.Windows.Forms.ToolStripMenuItem 'Refresh'
  foreach ($pair in @(@(500, '0.5 s'), @(1000, '1 s'), @(2000, '2 s'), @(5000, '5 s'))) {
    $ms = $pair[0]; $lbl = $pair[1]
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $lbl
    $mi.Checked = ($Cfg.interval -eq $ms); $mi.Tag = $ms
    $mi.Add_Click({ param($s, $e) $Cfg.interval = [int]$s.Tag; $Sync.interval = $Cfg.interval; Save-Cfg; Build-Menu }.GetNewClosure())
    [void]$iv.DropDownItems.Add($mi)
  }
  [void]$menu.Items.Add($iv)
  # Network units
  $nu = New-Object System.Windows.Forms.ToolStripMenuItem 'Network units'
  foreach ($pair in @(@('bytes', 'KB/s, MB/s (bytes)'), @('bits', 'Kbps, Mbps (bits)'))) {
    $uv = $pair[0]; $lbl = $pair[1]
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $lbl
    $mi.Checked = ($Cfg.netUnits -eq $uv); $mi.Tag = $uv
    $mi.Add_Click({ param($s, $e) $Cfg.netUnits = [string]$s.Tag; Save-Cfg; Build-Menu; $form.Invalidate() }.GetNewClosure())
    [void]$nu.DropDownItems.Add($mi)
  }
  [void]$menu.Items.Add($nu)
  # Hide to edge (collapse to a small restore tab)
  $hd = New-Object System.Windows.Forms.ToolStripMenuItem 'Hide to edge'
  foreach ($ed in @('top', 'left', 'right', 'bottom')) {
    $lbl = if ($ed -eq 'bottom') { 'Bottom (taskbar readout)' } else { $ed.Substring(0, 1).ToUpper() + $ed.Substring(1) }
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $lbl
    $mi.Checked = ($Cfg.dockEdge -eq $ed)
    $mi.Tag = $ed
    $mi.Add_Click({ param($s, $e) Hide-ToEdge $s.Tag }.GetNewClosure())
    [void]$hd.DropDownItems.Add($mi)
  }
  [void]$menu.Items.Add($hd)
  # Show values in the taskbar (dock to the bottom as an icon+value readout) - toggle
  $inTaskbar = ($script:docked -and $Cfg.dockEdge -eq 'bottom')
  Add-MenuItem $menu 'Show values in taskbar' $inTaskbar {
    if ($script:docked -and $Cfg.dockEdge -eq 'bottom') { Show-Widget } else { Hide-ToEdge 'bottom' }
  } | Out-Null
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  # Start with Windows
  $startupLnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Hardware Widget.lnk'
  Add-MenuItem $menu 'Start with Windows' (Test-Path $startupLnk) {
    $lnk = Join-Path ([Environment]::GetFolderPath('Startup')) 'Hardware Widget.lnk'
    if (Test-Path $lnk) { Remove-Item $lnk -Force -ErrorAction SilentlyContinue }
    else {
      try {
        $ws = New-Object -ComObject WScript.Shell
        $sc = $ws.CreateShortcut($lnk)
        $sc.TargetPath = Join-Path $Root 'Hardware Widget.vbs'
        $sc.WorkingDirectory = $Root
        $sc.Description = 'Hardware Widget'
        $sc.Save()
      } catch {}
    }
    Build-Menu
  } | Out-Null
  Add-MenuItem $menu 'Open full dashboard...' $null { Open-Dashboard } | Out-Null
  [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
  Add-MenuItem $menu 'Exit' $null { $form.Close() } | Out-Null
}
Build-Menu
$form.ContextMenuStrip = $menu

# ---------- collapse-to-edge auto-hide bar ----------
$peek = New-Object HWidget.Panel
$peek.FormBorderStyle = 'None'
$peek.ShowInTaskbar = $false
$peek.TopMost = $true
$peek.StartPosition = 'Manual'
$peek.BackColor = $Pal.card
$peek.Visible = $false
$peek.Cursor = [System.Windows.Forms.Cursors]::Hand

$script:docked = $false
$script:peekShown = $false
$script:lastHover = Get-Date

# Compact per-stat value for the bottom (taskbar) readout.
function Stat-ShortValue($key, $d) {
  switch ($key) {
    'cpu'  { return "$([math]::Round($d.cpu))%" }
    'ram'  { if ($null -ne $d.memPct) { return (Format-Bytes $d.memUsedB) } else { return '--' } }
    'gpu'  { if ($d.hasGpu) { return "$([math]::Round($d.gpuUtil))%" } else { return 'n/a' } }
    'vram' { if ($d.hasGpu) { return (Format-Bytes $d.vramUsedB) } else { return 'n/a' } }
    'net'  { return ([string][char]0x2193 + (Format-RateShort $d.netDown)) }
    default { return '--' }
  }
}

function Peek-Dims($edge) {
  if ($edge -eq 'top') { return @(140, 26) }
  if ($edge -eq 'bottom') {
    $n = (Get-VisibleStats).Count; if ($n -lt 1) { $n = 1 }
    return @(($n * 86 + 10), 30)    # horizontal readout: one cell per stat
  }
  return @(26, 140)                 # left / right vertical bar
}

function Set-PeekRounded {
  $peek.Region = $null
  Set-DwmCorners $peek.Handle 3
}

function Place-Peek($edge) {
  $scr = Screen-Of $form
  $wa = $scr.WorkingArea
  $sb = $scr.Bounds
  $dim = Peek-Dims $edge; $pw = $dim[0]; $ph = $dim[1]
  $peek.Width = $pw; $peek.Height = $ph
  switch ($edge) {
    'left'   { $x = $wa.Left; $y = $wa.Top + [int](($wa.Height - $ph) / 2) }
    'top'    { $x = $wa.Left + [int](($wa.Width - $pw) / 2); $y = $wa.Top }
    'bottom' {
      # sit in the taskbar band (if the taskbar is at the bottom), just left of the tray
      $tbH = $sb.Bottom - $wa.Bottom
      if ($tbH -gt 8) { $y = $wa.Bottom + [int](([math]::Max($tbH, $ph) - $ph) / 2) } else { $y = $wa.Bottom - $ph - 2 }
      $x = $sb.Right - $pw - 200
      if ($x -lt $wa.Left + 6) { $x = $wa.Left + 6 }
    }
    default  { $x = $wa.Right - $pw; $y = $wa.Top + [int](($wa.Height - $ph) / 2) }   # right
  }
  $peek.Location = New-Object System.Drawing.Point([int]$x, [int]$y)
  Set-PeekRounded
}

$peek.Add_Paint({ param($s, $e)
  try {
  $g = $e.Graphics
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'ClearTypeGridFit'
  $bg = New-Object System.Drawing.SolidBrush $Pal.card
  $g.FillRectangle($bg, 0, 0, $peek.Width, $peek.Height); $bg.Dispose()
  $d = $Sync.data
  $edge = $Cfg.dockEdge
  $tb = New-Object System.Drawing.SolidBrush $Pal.ink
  if ($edge -eq 'bottom') {
    # taskbar-style readout: each enabled stat as icon + value, left to right
    $vis = Get-VisibleStats
    $n = $vis.Count; if ($n -lt 1) { $n = 1 }
    $cellW = $peek.Width / $n
    $sfm = New-Object System.Drawing.StringFormat; $sfm.Alignment = 'Near'; $sfm.LineAlignment = 'Center'
    $ci = 0
    foreach ($m in $vis) {
      $cellX = $ci * $cellW
      Draw-Icon $g $m.key ($cellX + 8) 8 14 $m.color
      $val = if ($d) { Stat-ShortValue $m.key $d } else { '--' }
      $g.DrawString([string]$val, $fontLabel, $tb, (New-Object System.Drawing.RectangleF ($cellX + 26), 0, ($cellW - 28), $peek.Height), $sfm)
      $ci++
    }
    $sfm.Dispose()
  }
  else {
    $cpu = if ($d) { [math]::Round($d.cpu) } else { 0 }
    $mc = if ($cpu -ge 90) { $Pal.crit } elseif ($cpu -ge 70) { $Pal.warn } else { $Pal.cpu }
    if ($edge -eq 'top') {
      $mb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(50, $mc.R, $mc.G, $mc.B))
      $g.FillRectangle($mb, 0, 0, [int]($peek.Width * $cpu / 100), $peek.Height); $mb.Dispose()
      $g.DrawString([string][char]0x25BE, $fontArrow, $tb, (New-Object System.Drawing.RectangleF 0, -2, $peek.Width, $peek.Height), $sfCenter)
    } else {
      $fillH = [int]($peek.Height * $cpu / 100)
      $mb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(60, $mc.R, $mc.G, $mc.B))
      $g.FillRectangle($mb, 0, ($peek.Height - $fillH), $peek.Width, $fillH); $mb.Dispose()
      $arrow = if ($edge -eq 'left') { [char]0x00BB } else { [char]0x00AB }   # » expand right / « expand left
      $g.DrawString([string]$arrow, $fontArrow, $tb, (New-Object System.Drawing.RectangleF 0, 0, $peek.Width, $peek.Height), $sfCenter)
    }
  }
  $tb.Dispose()
  } catch {
    "$([DateTime]::Now) PEEK: $($_.Exception.Message)" | Out-File -FilePath $LogPath -Append -Encoding UTF8
  }
})
$peek.Add_MouseDown({ param($s, $e) Show-Widget })   # click the bar to bring the widget back for good

# Position the widget just inside the bar so the bar stays visible and clickable.
function Peek-Place {
  $wa = (Screen-Of $peek).WorkingArea
  switch ($Cfg.dockEdge) {
    'left'   { $x = $peek.Right; $y = [int]($peek.Top + $peek.Height / 2 - $form.Height / 2) }
    'top'    { $x = [int]($peek.Left + $peek.Width / 2 - $form.Width / 2); $y = $peek.Bottom }
    'bottom' { $x = [int]($peek.Left + $peek.Width / 2 - $form.Width / 2); $y = $peek.Top - $form.Height }
    default  { $x = $peek.Left - $form.Width; $y = [int]($peek.Top + $peek.Height / 2 - $form.Height / 2) }
  }
  $x = [math]::Min([math]::Max($x, $wa.Left), $wa.Right - $form.Width)
  $y = [math]::Min([math]::Max($y, $wa.Top), $wa.Bottom - $form.Height)
  $form.Location = New-Object System.Drawing.Point([int]$x, [int]$y)
}
function Peek-Out {
  if ($script:peekShown) { return }
  $script:peekShown = $true
  Peek-Place
  $form.Show(); $form.TopMost = $true
  try { $form.BringToFront() } catch {}
  $form.Invalidate()
}
function Peek-In {
  if (-not $script:peekShown) { return }
  $script:peekShown = $false
  $form.Hide()
}

function Hide-ToEdge($edge) {
  $Cfg.dockEdge = $edge; Save-Cfg
  $script:docked = $true; $script:peekShown = $false
  Place-Peek $edge
  $form.Hide()
  $peek.Show(); $peek.TopMost = $true; $peek.Invalidate()
  $script:lastHover = Get-Date
  $dockTimer.Start()
  Build-Menu
}
function Show-Widget {
  $script:docked = $false; $script:peekShown = $false
  $dockTimer.Stop()
  $peek.Hide()
  $form.Show(); $form.TopMost = $true
  Rebuild-Layout
}

# Auto-hide watcher: while docked, peek the widget out when the pointer is over the
# bar (or the peeked widget) and slide it away shortly after the pointer leaves.
$dockTimer = New-Object System.Windows.Forms.Timer
$dockTimer.Interval = 110
$dockTimer.Add_Tick({
  if (-not $script:docked) { return }
  try {
    $cur = [System.Windows.Forms.Cursor]::Position
    $overBar = $peek.Bounds.Contains($cur)
    $overForm = $script:peekShown -and $form.Bounds.Contains($cur)
    if ($overBar -or $overForm) {
      $script:lastHover = Get-Date
      if (-not $script:peekShown) { Peek-Out }
    } elseif ($script:peekShown -and ((Get-Date) - $script:lastHover).TotalMilliseconds -gt 450) {
      Peek-In
    }
  } catch {}
})

# ---------- system tray ----------
$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Text = 'Hardware Widget'
$tray.Visible = $true
$script:trayHandle = [IntPtr]::Zero

function Update-Tray($d) {
  if ($null -eq $d) { return }
  try {
  $cpu = [math]::Round($d.cpu)
  $fg = if ($cpu -ge 90) { $Pal.crit } elseif ($cpu -ge 70) { $Pal.warn } else { $Pal.cpu }
  $bmp = New-Object System.Drawing.Bitmap 32, 32
  $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'
  $g.Clear([System.Drawing.Color]::Transparent)
  $bb = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(235, 26, 26, 25))
  $g.FillRectangle($bb, 0, 0, 32, 32); $bb.Dispose()
  $fs = if ($cpu -ge 100) { 13 } else { 17 }
  $f = New-Object System.Drawing.Font 'Segoe UI', $fs, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object System.Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $tb = New-Object System.Drawing.SolidBrush $fg
  $g.DrawString("$cpu", $f, $tb, (New-Object System.Drawing.RectangleF 0, 0, 32, 32), $sf)
  $tb.Dispose(); $f.Dispose(); $sf.Dispose(); $g.Dispose()
  $hicon = $bmp.GetHicon()
  $tray.Icon = [System.Drawing.Icon]::FromHandle($hicon)
  if ($script:trayHandle -ne [IntPtr]::Zero) { [void][Native.Win]::DestroyIcon($script:trayHandle) }
  $script:trayHandle = $hicon
  $bmp.Dispose()
  $gpuTxt = if ($d.hasGpu) { "  GPU $([math]::Round($d.gpuUtil))%" } else { '' }
  $tray.Text = "CPU $cpu%  RAM $([math]::Round($d.memPct))%$gpuTxt"
  } catch {
    "$([DateTime]::Now) TRAY: $($_.Exception.Message)" | Out-File -FilePath $LogPath -Append -Encoding UTF8
  }
}

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
Add-MenuItem $trayMenu 'Show / hide widget' $null {
  if ($peek.Visible) { Show-Widget }
  else { $form.Visible = -not $form.Visible; if ($form.Visible) { $form.TopMost = $true } }
} | Out-Null
Add-MenuItem $trayMenu 'Open full dashboard...' $null { Open-Dashboard } | Out-Null
[void]$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
Add-MenuItem $trayMenu 'Exit' $null { $form.Close() } | Out-Null
$tray.ContextMenuStrip = $trayMenu
$tray.Add_MouseDoubleClick({ param($s, $e)
  if ($e.Button -eq 'Left') {
    if ($peek.Visible) { Show-Widget }
    else { $form.Visible = -not $form.Visible; if ($form.Visible) { $form.TopMost = $true } }
  }
})

# ---------- UI refresh timer ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({
  if ($Sync.ready) {
    if ($form.Visible) { $form.Invalidate() }
    if ($peek.Visible) { $peek.Invalidate() }
    Update-Tray $Sync.data
  }
})
$timer.Start()

# ---------- lifecycle ----------
$form.Add_Shown({ Set-Rounded; Place-Corner })
$form.Add_FormClosing({
  $Sync.run = $false
  $timer.Stop()
  try { $dockTimer.Stop() } catch {}
  try { $peek.Hide(); $peek.Dispose() } catch {}
  try { $tray.Visible = $false; $tray.Dispose() } catch {}
  if ($script:trayHandle -ne [IntPtr]::Zero) { [void][Native.Win]::DestroyIcon($script:trayHandle) }
  try { $psCmd.Stop() } catch {}
  try { $rs.Close() } catch {}
})

[System.Windows.Forms.Application]::add_ThreadException({
  param($s, $e)
  "$([DateTime]::Now) THREAD: $($e.Exception.Message)`n$($e.Exception.StackTrace)" | Out-File -FilePath $LogPath -Append -Encoding UTF8
})
try { [System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException) } catch {}

try {
  [System.Windows.Forms.Application]::EnableVisualStyles()
  [System.Windows.Forms.Application]::Run($form)
} catch {
  "$([DateTime]::Now) $($_.Exception.Message)`n$($_.ScriptStackTrace)" | Out-File -FilePath $LogPath -Append -Encoding UTF8
}
