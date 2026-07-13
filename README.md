# Hardware Monitor for Windows

A lightweight, good-looking hardware monitor for Windows — an always-on-top
**desktop widget** plus a full **web dashboard** — with **zero installs and zero
dependencies**. The whole thing is pure Windows PowerShell 5.1 and .NET Framework
(both already on every Windows 10/11 machine) with a plain HTML/CSS/JS front-end.
No Python, Node, admin rights, or background services required.

- 🖥️ **Desktop widget** — a small, rounded, always-on-top panel that shows CPU,
  Memory, GPU, VRAM and Network live, with per-stat glyph icons and sparklines.
  Resize it, drag it to any corner, or auto-hide it to a screen edge.
- 📊 **Web dashboard** — click the widget (or run one script) to open a full
  monitoring dashboard: per-core CPU graphs, an `nvidia-smi`-style GPU panel with
  per-process VRAM, a memory breakdown, per-disk activity, and process/network
  tables.
- 🪶 **No installs** — download, double-click, done. Nothing to `pip`/`npm`
  install, no runtime to keep updated, no service running in the background.

---

## Requirements

| | |
|---|---|
| **OS** | Windows 10 or Windows 11 |
| **Runtime** | Windows PowerShell 5.1 + .NET Framework (built in — nothing to install) |
| **GPU details** | NVIDIA GPU with `nvidia-smi` on `PATH` (bundled with the NVIDIA driver). Without it, GPU/VRAM simply show "n/a"; everything else still works. |
| **Browser** (dashboard only) | Any modern browser. Microsoft Edge gives the nicest "app window". |

Everything runs **unelevated** (no administrator rights).

---

## Quick start

1. **Download** this repository (green **Code → Download ZIP**, then extract) or
   `git clone https://github.com/inverse-ai/Hardware-Monitor-Windows-OS.git`.
2. **Desktop widget:** double-click **`Hardware Widget.vbs`**. A panel appears in
   the bottom-right corner and a CPU% icon appears in the system tray.
3. **Web dashboard:** click the widget, or double-click
   **`Start Hardware Monitor.cmd`**, then browse to `http://localhost:8787/`.

> **First run / "running scripts is disabled":** the launchers already pass
> `-ExecutionPolicy Bypass`, so no policy change is needed. If Windows
> SmartScreen prompts on the `.vbs`/`.cmd`, choose **More info → Run anyway**
> (these are plain text scripts you can read).

To have the widget **start automatically at login**, right-click it →
**Start with Windows**.

---

## The desktop widget

A borderless, rounded, always-on-top panel. Each row is a **drawn icon** (a
processor chip for CPU, a memory module for RAM, a graphics card for GPU, a
stacked-memory glyph for VRAM, up/down arrows for Network) tinted in the stat's
colour, its live value, a small sub-line, and a **sparkline** of recent history.
A matching **CPU% icon** sits in the system tray (on Windows 11 it may start in
the hidden `⌃` overflow — drag it onto the taskbar to pin it).

### Interactions

| Action | Result |
|---|---|
| **Click** the panel | Opens the full web dashboard |
| **Drag** the panel | Moves it; it remembers the nearest corner |
| **Drag it to a screen edge** | **Docks (auto-hides) to that edge** — top, left, right or bottom |
| **Drag the left/right edge** | Resizes the width (see sizes below) |
| **Click the `»` button** (top-right) | Collapses to the **nearest** screen edge — the button's arrow (`«` `»` `▴` `▾`) shows which, and follows the widget as you move it |
| **Hover the edge bar** (when collapsed) | The widget **peeks out**; it slides away again when the pointer leaves |
| **Click the edge bar** | Brings the widget back for good (un-docks) |
| **Right-click** the panel or tray icon | Opens the settings menu |
| **Double-click the tray icon** | Show / hide (or restore) the panel |

### Adaptive width

Drag the side to shrink it; the panel sheds detail automatically so it stays
readable at any size:

| Tier | Width | Shows |
|---|---|---|
| **Full** | ≥ 208 px | icon + label + value + sub-line + sparkline |
| **Compact** | 150–207 px | icon + label + value + sub-line (no sparkline) |
| **Mini** | < 150 px | just the icon + the number |

### Auto-hide to an edge

**Drag the widget to any screen edge** — top, left, right or bottom — and it docks
there, leaving a slim bar. (You can also click the `»` button, or use right-click →
**Hide to edge**.) **Hover the bar** and the widget peeks back into view; move the
pointer away and it hides again — like the Windows taskbar's auto-hide. **Click the
bar** to bring it back for good, or just **drag** the peeked widget away from the edge.

Each edge shows a fitting bar: a thin vertical/horizontal sliver with a live CPU
meter and an arrow. The **bottom edge is special** — docking there drops a
**taskbar-style readout** into the taskbar band showing every stat as an icon +
value (e.g. `▣ 34%  ▤ 21.8 GB  ▥ 100%  …`), so you can keep glancing at the
numbers while the full panel is tucked away. Hover it to peek the full widget out
above it.

### Right-click menu

- **Show stats** — pick which of CPU / Memory / GPU / VRAM / Network appear
- **Size** — Full / Compact / Mini presets (same as dragging the width)
- **Position** — snap to any of the four corners
- **Opacity** — 60–100 %
- **Refresh** — 0.5 / 1 / 2 / 5 s
- **Network units** — KB/s, MB/s (bytes, default) or Kbps, Mbps (bits)
- **Hide to edge** — collapse to the Top / Left / Right / Bottom edge
- **Show values in taskbar** — dock to the bottom as an icon+value readout (toggle)
- **Start with Windows** — add/remove a Startup shortcut
- **Open full dashboard** — launch the web view

All choices persist in `widget-config.json` next to the scripts.

Sampling runs on a **background thread**, so the panel never stutters even though
Windows' CPU-utilization counter takes ~300 ms to read.

---

## The web dashboard

Open it by clicking the widget, running `Start Hardware Monitor.cmd`, or starting
the server manually:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File server.ps1 [-Port 8787]
```

then browse to `http://localhost:8787/`.

The page is a **single dashboard**. The **stat tiles across the top are the
selector** — click a tile (CPU, Memory, GPU, VRAM, Network, Disk) and its full
detail opens below; the selected tile is highlighted. The tiles are always the
live glance *and* the navigation. The ⚙ button chooses which tiles appear,
refresh rate, history window, network units, and light/dark theme.

Each stat's detail leads with a **history chart** (hover crosshair + tooltips;
arrow keys work when the chart is focused), followed by:

- **CPU** — a card for **every logical core** with live utilization %, its
  current boost clock, and its own mini history graph; plus system rates (context
  switches/s, system calls/s, run queue, process & thread counts) and the full
  **process table** (CPU %, private memory, I/O read/write, threads, TCP count —
  sortable, filterable, group-by-app).
- **GPU** — an **`nvidia-smi`-style panel**: driver, performance state and PCIe
  link in the header; fact tiles with sparklines for utilization (+ memory-bus
  %), a VRAM meter, temperature, fan, power draw (vs. cap) and core/memory
  clocks; history charts for power, temperature and clock; **engine-utilization**
  meters (3D / Copy / VideoDecode / VideoEncode); and a **processes-on-GPU**
  table with each process's GPU % and dedicated/shared VRAM.
- **Memory** — a composition bar (in use / modified / standby cache / free) plus
  commit charge, page file, paged/non-paged pool, system cache and hard faults.
- **Network** — per-adapter link speed and throughput, plus a **by-app** table
  with exact TCP connection counts, established connections and remote endpoints.
- **Disk** — a card per physical disk with an active-time graph, read/write
  rates and queue depth.

---

## How it works

The backend (`server.ps1`) reads Windows performance counters and `nvidia-smi`,
and serves the `ui/` front-end plus two JSON endpoints over `HttpListener` on
**localhost only**. A background thread samples continuously and stores a
pre-serialized snapshot, so HTTP requests return instantly and never block on the
(relatively slow) counter reads.

| Data | Source |
|---|---|
| CPU total / per-core / clocks | `Win32_PerfFormattedData_Counters_ProcessorInformation` |
| Memory / commit / pools / cache | `Win32_OperatingSystem` + `Win32_PerfFormattedData_PerfOS_Memory` + `Win32_PageFileUsage` |
| System rates | `Win32_PerfFormattedData_PerfOS_System` |
| GPU + VRAM + clocks / power / fan | `nvidia-smi` |
| Per-process GPU % / VRAM | `Win32_PerfFormattedData_GPUPerformanceCounters_GPUEngine` / `…_GPUProcessMemory` (WDDM — the same source Task Manager uses) |
| Network per adapter | `Win32_PerfFormattedData_Tcpip_NetworkInterface` |
| Disk (per physical disk) | `Win32_PerfFormattedData_PerfDisk_PhysicalDisk` |
| Per-process CPU / memory / I/O | `Win32_PerfFormattedData_PerfProc_Process` |
| Per-process TCP | `Get-NetTCPConnection` grouped by owning PID |

The desktop widget (`widget.ps1`) is a self-contained WinForms app that samples
the same counters directly in a background runspace — it does **not** need the
web server running.

### Two accuracy caveats (by design, on unelevated Windows)

- **Per-app network bandwidth.** Windows only exposes exact per-process network
  *throughput* to elevated ETW traces (what Task Manager's App-history uses).
  Running unelevated, the by-app table shows the process's **total I/O rate**
  (network + disk) as an upper bound, while connection counts and remote
  endpoints are **exact**.
- **Per-app GPU VRAM.** `nvidia-smi` cannot report per-process VRAM under the
  Windows WDDM driver model, so the dashboard reads the **WDDM GPU performance
  counters** instead (the same ones Task Manager uses) for exact per-process
  dedicated/shared VRAM and engine utilization. Wattage and fan are per-GPU
  (per-process power doesn't exist in hardware).

---

## Project layout

```
Hardware Widget.vbs         Launches the desktop widget hidden (no console)
widget.ps1                  The desktop widget (WinForms)
Start Hardware Monitor.cmd  Starts the web server + opens it in an Edge app window
server.ps1                  Stats server + static file host (HttpListener, :8787)
ui/                         Web dashboard front-end
  index.html  style.css  app.js
widget-config.json          Created at runtime — remembers the widget's settings
```

---

## Troubleshooting

- **GPU / VRAM show "n/a".** No NVIDIA GPU detected, or `nvidia-smi` isn't on
  `PATH`. Only NVIDIA GPUs are supported for GPU details.
- **Dashboard says "Offline — retrying".** The server isn't running. Click the
  widget, run `Start Hardware Monitor.cmd`, or start `server.ps1` manually.
- **Port 8787 is in use.** Start with a different port:
  `powershell -File server.ps1 -Port 9000` and open `http://localhost:9000/`.
- **The tray icon is missing.** On Windows 11 it starts in the hidden `⌃`
  overflow — drag it onto the taskbar to keep it visible.
- **Stop everything.** Close the "Hardware Monitor Server" console window (web
  server) and right-click the widget → **Exit** (widget/tray).

---

## Privacy

Everything is local. The server binds to `localhost` only and makes no outbound
connections. The "remote endpoints" column just reads your machine's own TCP
table (`Get-NetTCPConnection`); nothing is sent anywhere.

---

## Contributing

Issues and pull requests are welcome. The code is deliberately dependency-free
and readable — `server.ps1` and `widget.ps1` are standalone PowerShell scripts,
and the dashboard is vanilla HTML/CSS/JS in `ui/`. Please keep it install-free.

## License

Released under the **MIT License** — see [LICENSE](LICENSE). Free to use, modify
and share.
