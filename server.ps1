<#
  Hardware Monitor - local stats server
  Pure Windows PowerShell 5.1, no dependencies to install.

  Serves the web UI from .\ui and live JSON from:
    GET /api/stats   - summary (CPU, memory, GPU, network, disk)
    GET /api/detail  - per-process detail (CPU, memory, I/O, TCP connections)

  Run:
    powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1 [-Port 8787]
#>
param([int]$Port = 8787)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web.Extensions

$root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$uiDir = [IO.Path]::GetFullPath((Join-Path $root 'ui'))
$ser   = New-Object System.Web.Script.Serialization.JavaScriptSerializer
$ser.MaxJsonLength = 67108864

# ---------- static system facts (queried once) ----------
$cpuChips = @(Get-CimInstance Win32_Processor)
$sysInfo = @{
  host          = $env:COMPUTERNAME
  cpuName       = (($cpuChips[0].Name) -replace '\s+', ' ').Trim()
  coresPhysical = [int](($cpuChips | Measure-Object NumberOfCores -Sum).Sum)
  coresLogical  = [int][Environment]::ProcessorCount
  baseMHz       = [int]$cpuChips[0].MaxClockSpeed
}
$hasNvidia = [bool](Get-Command nvidia-smi.exe -ErrorAction SilentlyContinue)

function ToNum([string]$s) {
  $d = 0.0
  if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
  return $null
}
function Clamp([double]$v, [double]$lo, [double]$hi) { return [math]::Max($lo, [math]::Min($hi, $v)) }

# ---------- GPU (nvidia-smi, cached ~1s) ----------
$script:gpuAt = [datetime]::MinValue
$script:gpu   = @()
function Get-Gpu {
  if (-not $hasNvidia) { return @() }
  if (((Get-Date) - $script:gpuAt).TotalMilliseconds -lt 900) { return $script:gpu }
  try {
    $q = 'name,driver_version,pstate,utilization.gpu,utilization.memory,memory.used,memory.total,temperature.gpu,fan.speed,power.draw,power.limit,clocks.gr,clocks.mem,pcie.link.gen.current,pcie.link.width.current'
    $lines = & nvidia-smi.exe "--query-gpu=$q" '--format=csv,noheader,nounits' 2>$null
    $out = @()
    foreach ($ln in @($lines)) {
      if ([string]::IsNullOrWhiteSpace($ln)) { continue }
      $f = $ln -split ',\s*'
      if ($f.Count -lt 15) { continue }
      $out += @{
        name        = [string]$f[0]
        driver      = [string]$f[1]
        pstate      = [string]$f[2]
        util        = ToNum $f[3]
        memUtil     = ToNum $f[4]
        vramUsedMB  = ToNum $f[5]
        vramTotalMB = ToNum $f[6]
        tempC       = ToNum $f[7]
        fanPct      = ToNum $f[8]
        powerW      = ToNum $f[9]
        powerCapW   = ToNum $f[10]
        clockMHz    = ToNum $f[11]
        memClockMHz = ToNum $f[12]
        pcieGen     = ToNum $f[13]
        pcieWidth   = ToNum $f[14]
      }
    }
    $script:gpu = $out
    $script:gpuAt = Get-Date
  } catch { $script:gpu = @() }
  return $script:gpu
}

# ---------- summary stats (cached ~350ms) ----------
$script:statsAt = [datetime]::MinValue
$script:stats   = $null
function Get-Stats {
  if ($script:stats -and ((Get-Date) - $script:statsAt).TotalMilliseconds -lt 350) { return $script:stats }

  # CPU (Processor Information counters: utility matches Task Manager)
  $cpuTotal = 0.0; $cores = @(); $coreMHz = @(); $curMHz = $null
  try {
    $pi  = @(Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation)
    $tot = $pi | Where-Object { $_.Name -eq '_Total' } | Select-Object -First 1
    if ($tot) {
      $u = [double]$tot.PercentProcessorUtility
      if ($u -le 0) { $u = [double]$tot.PercentProcessorTime }
      $cpuTotal = [math]::Round((Clamp $u 0 100), 1)
      if ([double]$tot.PercentProcessorPerformance -gt 0) {
        $curMHz = [int]($sysInfo.baseMHz * [double]$tot.PercentProcessorPerformance / 100)
      }
    }
    $coreInst = $pi | Where-Object { $_.Name -match '^\d+,\d+$' } |
      Sort-Object { $p = $_.Name -split ','; [int]$p[0] * 1024 + [int]$p[1] }
    foreach ($c in $coreInst) {
      $u = [double]$c.PercentProcessorUtility
      if ($u -le 0 -and [double]$c.PercentProcessorTime -gt 0) { $u = [double]$c.PercentProcessorTime }
      $cores += [math]::Round((Clamp $u 0 100), 1)
      $coreMHz += [int]($sysInfo.baseMHz * [double]$c.PercentProcessorPerformance / 100)
    }
  } catch {}

  # Memory
  $mem = $null
  try {
    $os = Get-CimInstance Win32_OperatingSystem
    $pm = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
    $totalB = [long]$os.TotalVisibleMemorySize * 1024
    $availB = [long]$pm.AvailableBytes
    $standbyB = [long]$pm.StandbyCacheReserveBytes + [long]$pm.StandbyCacheNormalPriorityBytes + [long]$pm.StandbyCacheCoreBytes
    $mem = @{
      totalB       = $totalB
      availB       = $availB
      usedB        = $totalB - $availB
      commitB      = [long]$pm.CommittedBytes
      commitLimitB = [long]$pm.CommitLimit
      cacheB       = [long]$pm.CacheBytes
      standbyB     = $standbyB
      freeB        = [long]$pm.FreeAndZeroPageListBytes
      modifiedB    = [long]$pm.ModifiedPageListBytes
      poolPagedB   = [long]$pm.PoolPagedBytes
      poolNonpagedB = [long]$pm.PoolNonpagedBytes
      pagesPersec  = [long]$pm.PagesPersec
    }
    $uptimeSec = [long]((Get-Date) - $os.LastBootUpTime).TotalSeconds
  } catch { $uptimeSec = 0 }

  # Page file
  $pagefile = $null
  try {
    $pfU = 0L; $pfA = 0L
    foreach ($pf in @(Get-CimInstance Win32_PageFileUsage)) {
      $pfA += [long]$pf.AllocatedBaseSize * 1MB
      $pfU += [long]$pf.CurrentUsage * 1MB
    }
    if ($pfA -gt 0) { $pagefile = @{ usedB = $pfU; totalB = $pfA } }
  } catch {}

  # Network (per adapter, bytes/sec)
  $adapters = @()
  try {
    foreach ($n in @(Get-CimInstance Win32_PerfFormattedData_Tcpip_NetworkInterface)) {
      if ($n.Name -match 'isatap|Loopback|Teredo') { continue }
      $adapters += @{
        name    = [string]$n.Name
        downBps = [long]$n.BytesReceivedPersec
        upBps   = [long]$n.BytesSentPersec
        linkBps = [long]$n.CurrentBandwidth
      }
    }
  } catch {}

  # Disk (physical total + per disk)
  $disk = $null
  $disks = @()
  try {
    foreach ($d in @(Get-CimInstance Win32_PerfFormattedData_PerfDisk_PhysicalDisk)) {
      $entry = @{
        name      = [string]$d.Name
        activePct = [math]::Round((Clamp (100 - [double]$d.PercentIdleTime) 0 100), 1)
        readBps   = [long]$d.DiskReadBytesPersec
        writeBps  = [long]$d.DiskWriteBytesPersec
        queue     = [double]$d.CurrentDiskQueueLength
      }
      if ($d.Name -eq '_Total') { $disk = $entry } else { $disks += $entry }
    }
  } catch {}

  # Object counts + system rates
  $counts = $null
  try {
    $o = Get-CimInstance Win32_PerfFormattedData_PerfOS_Objects
    $counts = @{ processes = [int]$o.Processes; threads = [int]$o.Threads }
  } catch {}
  $sysRates = $null
  try {
    $sr = Get-CimInstance Win32_PerfFormattedData_PerfOS_System
    $sysRates = @{
      ctxSwitches = [long]$sr.ContextSwitchesPersec
      sysCalls    = [long]$sr.SystemCallsPersec
      procQueue   = [int]$sr.ProcessorQueueLength
    }
  } catch {}

  $script:stats = @{
    ts     = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    cpu    = @{ total = $cpuTotal; cores = $cores; coreMHz = $coreMHz; curMHz = $curMHz }
    mem    = $mem
    pagefile = $pagefile
    gpus   = @(Get-Gpu)
    net    = @{ adapters = $adapters }
    disk   = $disk
    disks  = $disks
    counts = $counts
    sysRates = $sysRates
    sys    = @{
      host = $sysInfo.host; cpuName = $sysInfo.cpuName
      coresPhysical = $sysInfo.coresPhysical; coresLogical = $sysInfo.coresLogical
      baseMHz = $sysInfo.baseMHz; uptimeSec = $uptimeSec; hasNvidia = $hasNvidia
    }
  }
  $script:statsAt = Get-Date
  return $script:stats
}

# ---------- per-process detail (cached ~1.2s) ----------
$script:detailAt = [datetime]::MinValue
$script:detail   = $null
function Get-Detail {
  if ($script:detail -and ((Get-Date) - $script:detailAt).TotalMilliseconds -lt 1200) { return $script:detail }

  # TCP connections grouped by owning process
  $tcp = @{}
  try {
    foreach ($c in @(Get-NetTCPConnection -ErrorAction Stop)) {
      $owner = [int]$c.OwningProcess
      if (-not $tcp.ContainsKey($owner)) { $tcp[$owner] = @{ total = 0; est = 0; remotes = @{} } }
      $e = $tcp[$owner]
      $e.total++
      if ("$($c.State)" -eq 'Established') {
        $e.est++
        $ra = [string]$c.RemoteAddress
        if ($ra -and $ra -ne '127.0.0.1' -and $ra -ne '::1' -and $ra -ne '0.0.0.0' -and $ra -ne '::') {
          $e.remotes[$ra] = $true
        }
      }
    }
  } catch {}

  $procs = New-Object System.Collections.ArrayList
  $nameByPid = @{}
  try {
    foreach ($p in @(Get-CimInstance Win32_PerfFormattedData_PerfProc_Process)) {
      if ($p.Name -eq '_Total' -or $p.Name -eq 'Idle') { continue }
      $procPid = [int]$p.IDProcess
      $nameByPid[$procPid] = [string]($p.Name -replace '#\d+$', '')
      $t = $null
      if ($tcp.ContainsKey($procPid)) { $t = $tcp[$procPid] }
      $remotes = @(); $remoteCount = 0
      if ($t) {
        $remoteCount = [int]$t.remotes.Count
        foreach ($ipK in (@($t.remotes.Keys) | Select-Object -First 3)) {
          $ipS = [string]$ipK
          # queue the IP for reverse-DNS (value $null = pending) and read any result so far
          [System.Threading.Monitor]::Enter($DnsCache.SyncRoot)
          try { if (-not $DnsCache.ContainsKey($ipS)) { $DnsCache[$ipS] = $null }; $hn = $DnsCache[$ipS] }
          finally { [System.Threading.Monitor]::Exit($DnsCache.SyncRoot) }
          $remotes += @{ ip = $ipS; host = [string]$(if ($hn) { $hn } else { '' }) }
        }
      }
      [void]$procs.Add(@{
        name        = [string]($p.Name -replace '#\d+$', '')
        pid         = $procPid
        cpu         = [math]::Round(([double]$p.PercentProcessorTime / $sysInfo.coresLogical), 1)
        memB        = [long]$p.WorkingSetPrivate
        ioR         = [long]$p.IOReadBytesPersec
        ioW         = [long]$p.IOWriteBytesPersec
        threads     = [int]$p.ThreadCount
        tcp         = $(if ($t) { [int]$t.total } else { 0 })
        est         = $(if ($t) { [int]$t.est } else { 0 })
        remotes     = @($remotes)
        remoteCount = $remoteCount
      })
    }
  } catch {}

  # GPU per-process (WDDM GPU performance counters - same source Task Manager uses;
  # nvidia-smi cannot see per-process VRAM under WDDM)
  $gpuAgg = @{}
  try {
    foreach ($gm in @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUProcessMemory)) {
      if ($gm.Name -notmatch '^pid_(\d+)_') { continue }
      $gp = [int]$Matches[1]
      if (-not $gpuAgg.ContainsKey($gp)) { $gpuAgg[$gp] = @{ ded = [long]0; sh = [long]0; util = 0.0 } }
      $gpuAgg[$gp].ded += [long]$gm.DedicatedUsage
      $gpuAgg[$gp].sh  += [long]$gm.SharedUsage
    }
  } catch {}
  $engTotals = @{}
  try {
    foreach ($ge in @(Get-CimInstance Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine)) {
      $u = [double]$ge.UtilizationPercentage
      if ($u -le 0) { continue }
      if ($ge.Name -notmatch '^pid_(\d+)_.*engtype_(.+)$') { continue }
      $gp = [int]$Matches[1]; $et = [string]$Matches[2]
      if (-not $gpuAgg.ContainsKey($gp)) { $gpuAgg[$gp] = @{ ded = [long]0; sh = [long]0; util = 0.0 } }
      $gpuAgg[$gp].util += $u
      if (-not $engTotals.ContainsKey($et)) { $engTotals[$et] = 0.0 }
      $engTotals[$et] += $u
    }
  } catch {}
  $gpuProcs = @()
  foreach ($gp in $gpuAgg.Keys) {
    $a = $gpuAgg[$gp]
    if ($a.ded -le 0 -and $a.util -le 0) { continue }
    $nm = if ($nameByPid.ContainsKey($gp)) { $nameByPid[$gp] } elseif ($gp -eq 0) { 'System' } else { "pid $gp" }
    $gpuProcs += @{
      pid   = $gp
      name  = [string]$nm
      dedB  = [long]$a.ded
      sharedB = [long]$a.sh
      util  = [math]::Round([math]::Min($a.util, 100), 1)
    }
  }
  $engines = @{}
  foreach ($et in $engTotals.Keys) { $engines[$et] = [math]::Round([math]::Min($engTotals[$et], 100), 1) }

  $script:detail = @{
    ts    = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    procs = $procs.ToArray()
    gpu   = @{ procs = $gpuProcs; engines = $engines }
  }
  $script:detailAt = Get-Date
  return $script:detail
}

# ---------- HTTP server ----------
# The stats/detail sampling is expensive (CIM + nvidia-smi + per-process GPU/TCP),
# so it runs on this main thread in a loop and stores pre-serialized JSON in a shared
# cache. Worker runspaces serve HTTP from that cache, so requests never block on
# sampling and the browser never times out.
$mime = @{
  '.html' = 'text/html; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.js'   = 'application/javascript; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.svg'  = 'image/svg+xml'
  '.png'  = 'image/png'
  '.ico'  = 'image/x-icon'
  '.woff2'= 'font/woff2'
}

$Cache = [hashtable]::Synchronized(@{ statsBytes = $null; detailBytes = $null })
# Reverse-DNS cache: ip -> hostname. Filled by a background resolver runspace so the
# (blocking) lookups never slow down sampling. Get-Detail queues new IPs as $null.
$DnsCache = [hashtable]::Synchronized(@{})
function ToJsonBytes($obj) { return [Text.Encoding]::UTF8.GetBytes($ser.Serialize($obj)) }

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try {
  $listener.Start()
} catch {
  Write-Host "Could not bind http://localhost:$Port/ - is the monitor already running?" -ForegroundColor Red
  exit 1
}

# Prime the cache before serving so the first request already has data.
try { $Cache.statsBytes = ToJsonBytes (Get-Stats) } catch {}
try { $Cache.detailBytes = ToJsonBytes (Get-Detail) } catch {}

# ---- HTTP worker (serves only from cache + static files; no sampling) ----
$httpWorker = {
  param($listener, $Cache, $uiDir, $mime)
  function SendB($res, [byte[]]$bytes, [string]$ctype, [int]$code = 200) {
    $res.StatusCode = $code; $res.ContentType = $ctype
    try { $res.Headers.Add('Cache-Control', 'no-store') } catch {}
    $res.ContentLength64 = $bytes.Length
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
  }
  $empty = [Text.Encoding]::UTF8.GetBytes('{}')
  while ($listener.IsListening) {
    $ctx = $null
    try { $ctx = $listener.GetContext() } catch { break }
    $res = $ctx.Response
    try {
      $path = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath)
      if ($path -eq '/api/stats') {
        $b = $Cache.statsBytes; if ($null -eq $b) { $b = $empty }
        SendB $res $b 'application/json; charset=utf-8'
      } elseif ($path -eq '/api/detail') {
        $b = $Cache.detailBytes; if ($null -eq $b) { $b = $empty }
        SendB $res $b 'application/json; charset=utf-8'
      } else {
        if ($path -eq '/') { $path = '/index.html' }
        $file = [IO.Path]::GetFullPath((Join-Path $uiDir ($path.TrimStart('/'))))
        $inRoot = $file.StartsWith($uiDir + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
        if ($inRoot -and (Test-Path -LiteralPath $file -PathType Leaf)) {
          $ext = [IO.Path]::GetExtension($file).ToLowerInvariant()
          $ct  = if ($mime.ContainsKey($ext)) { $mime[$ext] } else { 'application/octet-stream' }
          SendB $res ([IO.File]::ReadAllBytes($file)) $ct
        } else {
          SendB $res ([Text.Encoding]::UTF8.GetBytes('Not found')) 'text/plain; charset=utf-8' 404
        }
      }
    } catch {
      try { SendB $res ([Text.Encoding]::UTF8.GetBytes('Server error')) 'text/plain; charset=utf-8' 500 } catch {}
    } finally {
      try { $res.OutputStream.Close() } catch {}
    }
  }
}

$workers = @()
for ($i = 0; $i -lt 3; $i++) {
  $ps = [powershell]::Create()
  [void]$ps.AddScript($httpWorker).AddArgument($listener).AddArgument($Cache).AddArgument($uiDir).AddArgument($mime)
  [void]$ps.BeginInvoke()
  $workers += $ps
}

# ---- reverse-DNS resolver (background): fills $DnsCache without blocking sampling ----
$dnsWorker = {
  param($DnsCache)
  while ($true) {
    $pending = @()
    try {
      [System.Threading.Monitor]::Enter($DnsCache.SyncRoot)
      try { foreach ($k in @($DnsCache.Keys)) { if ($null -eq $DnsCache[$k]) { $pending += [string]$k } } }
      finally { [System.Threading.Monitor]::Exit($DnsCache.SyncRoot) }
    } catch {}
    if ($pending.Count -gt 0) {
      # fire the reverse lookups CONCURRENTLY, then collect - so a batch resolves in
      # about one timeout window instead of one-after-another
      $batch = @($pending | Select-Object -First 40)
      $tasks = @{}
      foreach ($ip in $batch) {
        try { $tasks[$ip] = [System.Net.Dns]::GetHostEntryAsync($ip) } catch { $DnsCache[$ip] = '' }
      }
      Start-Sleep -Milliseconds 1200   # the lookups run concurrently on the thread pool
      foreach ($ip in @($tasks.Keys)) {
        $tk = $tasks[$ip]
        if (-not $tk.IsCompleted) { continue }   # leave $null (pending) so it retries next pass
        $name = ''   # '' = resolved but no PTR (UI shows the IP); non-empty = hostname
        try { if (-not $tk.IsFaulted) { $h = [string]$tk.Result.HostName; if ($h -and $h -ne $ip) { $name = $h } } } catch {}
        $DnsCache[$ip] = $name
      }
    }
    Start-Sleep -Milliseconds 500
  }
}
$dnsPs = [powershell]::Create()
[void]$dnsPs.AddScript($dnsWorker).AddArgument($DnsCache)
[void]$dnsPs.BeginInvoke()

Write-Host ''
Write-Host "  Hardware Monitor  ->  http://localhost:$Port/" -ForegroundColor Green
Write-Host '  Close this window (or press Ctrl+C) to stop.'
Write-Host ''

# ---- sampling loop (main thread): refresh stats often, detail less often ----
$loop = 0
while ($listener.IsListening) {
  $loop++
  try { $Cache.statsBytes = ToJsonBytes (Get-Stats) } catch {}
  if ($loop % 4 -eq 0) { try { $Cache.detailBytes = ToJsonBytes (Get-Detail) } catch {} }
  Start-Sleep -Milliseconds 500
}
