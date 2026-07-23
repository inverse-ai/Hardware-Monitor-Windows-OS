'use strict';

/* ================= settings ================= */

const DEFAULTS = {
  selectedTile: 'cpu',            // which tile's detail is shown below
  theme: 'dark',
  stats: { cpu: true, ram: true, gpu: true, vram: true, net: true, disk: true },
  interval: 1000,                 // ms between /api/stats polls
  history: 60,                    // samples shown in charts/sparklines
  netUnits: 'bytes',              // 'bits' (Mbps) | 'bytes' (MB/s)
  netAdapter: 'all',
  sparklines: true,
  perCore: false,
  compact: false,
  procGroup: true,
};

// each selectable tile maps to one detail section shown below the tiles
const TILE_TO_DETAIL = { cpu: 'cpu', ram: 'mem', gpu: 'gpu', vram: 'gpu', net: 'net', disk: 'disk' };

function loadSettings() {
  try {
    const raw = JSON.parse(localStorage.getItem('hwmon-settings') || '{}');
    return { ...DEFAULTS, ...raw, stats: { ...DEFAULTS.stats, ...(raw.stats || {}) } };
  } catch { return { ...DEFAULTS, stats: { ...DEFAULTS.stats } }; }
}
function saveSettings() { localStorage.setItem('hwmon-settings', JSON.stringify(S)); }

let S = loadSettings();

/* ================= state ================= */

const HIST_MAX = 240;
const hist = {
  t: [], cpu: [], mem: [], commit: [], gpu: [], vram: [], down: [], up: [], disk: [],
  gpuPow: [], gpuTemp: [], gpuFan: [], gpuClock: [],
};
const coreHist = [];   // per-core % history (array of arrays)
const diskHist = {};   // per-physical-disk active% history, keyed by name
let last = null;          // last /api/stats payload
let lastDetail = null;    // last /api/detail payload
let online = null;
let statTimer = null, detailTimer = null;
let procShowAll = false;
let procSort = { key: 'cpu', dir: -1 };
let netSort = { key: 'est', dir: -1 };

/* ================= helpers ================= */

const $ = (id) => document.getElementById(id);
function el(tag, cls, text) {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}
function hexToRgb(hex) {
  const h = hex.replace('#', '');
  return [parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16)];
}
function rgba(hex, a) { const [r, g, b] = hexToRgb(hex); return `rgba(${r},${g},${b},${a})`; }

function fmtBytes(b, dp = 1) {
  if (b == null || isNaN(b)) return '—';
  const u = ['B', 'KB', 'MB', 'GB', 'TB'];
  let i = 0, v = Math.abs(b);
  while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
  return (b < 0 ? '-' : '') + v.toFixed(v >= 100 || i === 0 ? 0 : dp) + ' ' + u[i];
}
function fmtBits(bits, dp = 1) {
  if (bits == null || isNaN(bits)) return '—';
  const u = ['bps', 'Kbps', 'Mbps', 'Gbps'];
  let i = 0, v = Math.abs(bits);
  while (v >= 1000 && i < u.length - 1) { v /= 1000; i++; }
  return v.toFixed(v >= 100 || i === 0 ? 0 : dp) + ' ' + u[i];
}
function fmtRate(bps) { return S.netUnits === 'bits' ? fmtBits(bps * 8) : fmtBytes(bps) + '/s'; }
function fmtUptime(sec) {
  if (!sec) return '';
  const d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60);
  return d > 0 ? `${d}d ${h}h` : h > 0 ? `${h}h ${m}m` : `${m}m`;
}
function niceCeil(v) {
  if (v <= 0) return 1;
  const p = Math.pow(10, Math.floor(Math.log10(v)));
  for (const m of [1, 2, 5, 10]) { if (m * p >= v) return m * p; }
  return 10 * p;
}
function clampPct(v) { return Math.max(0, Math.min(100, v || 0)); }

async function fetchT(url, timeout) {
  const c = new AbortController();
  const t = setTimeout(() => c.abort(), timeout);
  try {
    const r = await fetch(url, { signal: c.signal, cache: 'no-store' });
    if (!r.ok) throw new Error('HTTP ' + r.status);
    return await r.json();
  } finally { clearTimeout(t); }
}

/* ================= data plumbing ================= */

function netRates(stats) {
  let down = 0, up = 0;
  const ads = (stats.net && stats.net.adapters) || [];
  for (const a of ads) {
    if (S.netAdapter !== 'all' && a.name !== S.netAdapter) continue;
    down += a.downBps || 0; up += a.upBps || 0;
  }
  return { down, up };
}

function pushHistory(stats) {
  const g = (stats.gpus && stats.gpus[0]) || null;
  const { down, up } = netRates(stats);
  hist.t.push(stats.ts);
  hist.cpu.push(clampPct(stats.cpu && stats.cpu.total));
  hist.mem.push(stats.mem ? clampPct(stats.mem.usedB / stats.mem.totalB * 100) : 0);
  hist.commit.push(stats.mem && stats.mem.commitLimitB ? clampPct(stats.mem.commitB / stats.mem.commitLimitB * 100) : 0);
  hist.gpu.push(g ? clampPct(g.util) : 0);
  hist.vram.push(g && g.vramTotalMB ? clampPct(g.vramUsedMB / g.vramTotalMB * 100) : 0);
  hist.down.push(down);
  hist.up.push(up);
  hist.disk.push(stats.disk ? clampPct(stats.disk.activePct) : 0);
  hist.gpuPow.push(g && g.powerW != null ? g.powerW : 0);
  hist.gpuTemp.push(g && g.tempC != null ? g.tempC : 0);
  hist.gpuFan.push(g && g.fanPct != null ? g.fanPct : 0);
  hist.gpuClock.push(g && g.clockMHz != null ? g.clockMHz : 0);
  for (const k of Object.keys(hist)) { if (hist[k].length > HIST_MAX) hist[k].shift(); }
  const cs = (stats.cpu && stats.cpu.cores) || [];
  for (let i = 0; i < cs.length; i++) {
    (coreHist[i] = coreHist[i] || []).push(cs[i]);
    if (coreHist[i].length > HIST_MAX) coreHist[i].shift();
  }
  for (const dk of stats.disks || []) {
    const a = diskHist[dk.name] = diskHist[dk.name] || [];
    a.push(clampPct(dk.activePct));
    if (a.length > HIST_MAX) a.shift();
  }
}
const lastGpu = () => (last && last.gpus && last.gpus[0]) || null;

function setOnline(v) {
  if (online === v) return;
  online = v;
  document.body.classList.toggle('offline', !v);
  const conn = $('conn');
  conn.classList.toggle('is-on', v);
  conn.classList.toggle('is-off', !v);
  $('connText').textContent = v ? 'Live' : 'Offline — retrying…';
}

async function pollStats() {
  clearTimeout(statTimer);
  try {
    const data = await fetchT('/api/stats', Math.max(2000, S.interval * 2));
    last = data;
    pushHistory(data);
    setOnline(true);
    renderWidget();
    renderDetailLive();
    maybeRefreshAdapters(data);
  } catch { setOnline(false); }
  const delay = document.hidden ? Math.max(S.interval, 3000) : S.interval;
  statTimer = setTimeout(pollStats, delay);
}

async function pollDetail() {
  clearTimeout(detailTimer);
  try {
    lastDetail = await fetchT('/api/detail', 8000);
    renderProcTable();
    renderNetTables();
    renderGpuDetail();
  } catch { /* conn indicator handled by stats poll */ }
  detailTimer = setTimeout(pollDetail, Math.max(2000, S.interval * 2));
}

/* ================= widget tiles ================= */

const TILE_DEFS = [
  { key: 'cpu',  label: 'CPU',    color: '--cpu' },
  { key: 'ram',  label: 'Memory', color: '--ram' },
  { key: 'gpu',  label: 'GPU',    color: '--gpu' },
  { key: 'vram', label: 'VRAM',   color: '--vram' },
  { key: 'net',  label: 'Network' },
  { key: 'disk', label: 'Disk',   color: '--disk' },
];
let tileRefs = {};

function buildTiles() {
  const wrap = $('tiles');
  wrap.textContent = '';
  wrap.classList.toggle('compact', S.compact);
  tileRefs = {};
  let any = false;
  for (const def of TILE_DEFS) {
    if (!S.stats[def.key]) continue;
    any = true;
    const root = el('div', 'tile');
    root.id = 'tile-' + def.key;
    root.setAttribute('role', 'tab');
    root.tabIndex = 0;
    root.title = 'Show ' + def.label + ' details';
    root.addEventListener('click', () => selectTile(def.key));
    root.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); selectTile(def.key); } });
    const head = el('div', 'tile-head');
    const keyCls = def.key === 'net' ? 'key-down' : 'key-' + def.key;
    head.appendChild(el('span', 'key ' + keyCls));
    head.appendChild(el('span', 'tile-label', def.label));
    const note = el('span', 'meter-note');
    note.appendChild(el('span', '', '⚠'));
    const noteText = el('span', '', '');
    note.appendChild(noteText);
    head.appendChild(el('span', '', '')).style.flex = '1';
    head.appendChild(note);
    root.appendChild(head);

    const ref = { root, noteText };

    if (def.key === 'net') {
      const rows = el('div', 'tile-rows');
      for (const [dir, cls] of [['down', 'key-down'], ['up', 'key-up']]) {
        const r = el('div', 'tile-row');
        r.appendChild(el('span', 'key ' + cls));
        const v = el('span', 'v', '—');
        r.appendChild(v);
        r.appendChild(el('span', 'u', dir === 'down' ? 'down' : 'up'));
        rows.appendChild(r);
        ref[dir] = v;
      }
      root.appendChild(rows);
    } else {
      ref.value = el('div', 'tile-value', '—');
      root.appendChild(ref.value);
    }
    ref.sub = el('div', 'tile-sub', '');
    root.appendChild(ref.sub);

    if (def.key === 'ram' || def.key === 'vram') {
      const m = el('div', 'meter');
      ref.track = el('div', 'meter-track');
      ref.fill = el('div', 'meter-fill');
      m.appendChild(ref.track); m.appendChild(ref.fill);
      root.appendChild(m);
    }
    if (def.key === 'cpu' && S.perCore) {
      ref.cores = el('div', 'cores');
      root.appendChild(ref.cores);
    }
    if (S.sparklines) {
      ref.spark = el('canvas', 'spark');
      root.appendChild(ref.spark);
    }
    wrap.appendChild(root);
    tileRefs[def.key] = ref;
  }
  $('widgetEmpty').classList.toggle('hidden', any);
  applySelection();
  if (last) renderWidget();
}

/* ---- stat selection (tiles act as tabs for the detail below) ---- */
function enabledTiles() { return TILE_DEFS.filter(d => S.stats[d.key]).map(d => d.key); }

function selectTile(key) {
  if (!S.stats[key]) return;
  S.selectedTile = key;
  saveSettings();
  applySelection();
  renderDetailLive();
}

function applySelection() {
  const enabled = enabledTiles();
  if (!enabled.length) {
    document.querySelectorAll('.stat-detail').forEach(d => d.classList.add('hidden'));
    return;
  }
  if (!enabled.includes(S.selectedTile)) S.selectedTile = enabled[0];
  const detailKey = TILE_TO_DETAIL[S.selectedTile];
  document.querySelectorAll('.stat-detail').forEach(d => {
    d.classList.toggle('hidden', d.dataset.detail !== detailKey);
  });
  document.querySelectorAll('.tiles-select .tile').forEach(t => {
    const on = t.id === 'tile-' + S.selectedTile;
    t.classList.toggle('selected', on);
    t.setAttribute('aria-selected', on ? 'true' : 'false');
  });
}

function setMeter(ref, pct, colorVar) {
  const warn = pct >= 80, crit = pct >= 90;
  const color = crit ? cssVar('--crit') : warn ? cssVar('--warn') : cssVar(colorVar);
  ref.fill.style.width = clampPct(pct) + '%';
  ref.fill.style.background = color;
  ref.track.style.background = cssVar(colorVar);
  ref.root.classList.toggle('is-warn', warn && !crit);
  ref.root.classList.toggle('is-crit', crit);
  ref.noteText.textContent = crit ? 'Critical' : warn ? 'High' : '';
}

function bigValue(elm, text, unit) {
  elm.textContent = '';
  elm.appendChild(document.createTextNode(text));
  if (unit) elm.appendChild(el('small', '', ' ' + unit));
}

function renderWidget() {
  if (!last) return;
  const st = last, g = (st.gpus && st.gpus[0]) || null;
  const N = S.history;

  const r = tileRefs;
  if (r.cpu) {
    bigValue(r.cpu.value, String(Math.round(st.cpu.total)), '%');
    const ghz = st.cpu.curMHz ? (st.cpu.curMHz / 1000).toFixed(2) + ' GHz · ' : '';
    const pr = st.counts ? st.counts.processes + ' processes' : '';
    r.cpu.sub.textContent = ghz + pr;
    if (r.cpu.spark) drawSpark(r.cpu.spark, [{ data: hist.cpu.slice(-N), color: cssVar('--cpu') }], { max: 100 });
    if (r.cpu.cores) renderCoreBars(r.cpu.cores, st.cpu.cores || []);
  }
  if (r.ram && st.mem) {
    const pct = st.mem.usedB / st.mem.totalB * 100;
    bigValue(r.ram.value, fmtBytes(st.mem.usedB), '');
    r.ram.sub.textContent = `of ${fmtBytes(st.mem.totalB)} · ${Math.round(pct)}% · commit ${fmtBytes(st.mem.commitB)}`;
    setMeter(r.ram, pct, '--ram');
    if (r.ram.spark) drawSpark(r.ram.spark, [{ data: hist.mem.slice(-N), color: cssVar('--ram') }], { max: 100 });
  }
  if (r.gpu) {
    if (g) {
      bigValue(r.gpu.value, String(Math.round(g.util || 0)), '%');
      const bits = [];
      if (g.tempC != null) bits.push(Math.round(g.tempC) + ' °C');
      if (g.clockMHz != null) bits.push((g.clockMHz / 1000).toFixed(2) + ' GHz');
      if (g.powerW != null) bits.push(Math.round(g.powerW) + ' W');
      r.gpu.sub.textContent = bits.join(' · ');
    } else {
      r.gpu.value.textContent = '—';
      r.gpu.sub.textContent = 'No NVIDIA GPU detected';
    }
    if (r.gpu.spark) drawSpark(r.gpu.spark, [{ data: hist.gpu.slice(-N), color: cssVar('--gpu') }], { max: 100 });
  }
  if (r.vram) {
    if (g && g.vramTotalMB) {
      const usedB = g.vramUsedMB * 1048576, totB = g.vramTotalMB * 1048576;
      const pct = g.vramUsedMB / g.vramTotalMB * 100;
      bigValue(r.vram.value, fmtBytes(usedB), '');
      r.vram.sub.textContent = `of ${fmtBytes(totB)} · ${Math.round(pct)}%`;
      setMeter(r.vram, pct, '--vram');
    } else {
      r.vram.value.textContent = '—';
      r.vram.sub.textContent = 'No NVIDIA GPU detected';
    }
    if (r.vram.spark) drawSpark(r.vram.spark, [{ data: hist.vram.slice(-N), color: cssVar('--vram') }], { max: 100 });
  }
  if (r.net) {
    const { down, up } = netRates(st);
    r.net.down.textContent = fmtRate(down);
    r.net.up.textContent = fmtRate(up);
    r.net.sub.textContent = S.netAdapter === 'all' ? 'All adapters' : S.netAdapter;
    if (r.net.spark) {
      drawSpark(r.net.spark, [
        { data: hist.down.slice(-N), color: cssVar('--down') },
        { data: hist.up.slice(-N), color: cssVar('--up') },
      ], {});
    }
  }
  if (r.disk) {
    if (st.disk) {
      bigValue(r.disk.value, String(Math.round(st.disk.activePct)), '%');
      r.disk.sub.textContent = `R ${fmtBytes(st.disk.readBps)}/s · W ${fmtBytes(st.disk.writeBps)}/s`;
    } else { r.disk.value.textContent = '—'; }
    if (r.disk.spark) drawSpark(r.disk.spark, [{ data: hist.disk.slice(-N), color: cssVar('--disk') }], { max: 100 });
  }

  const sys = st.sys || {};
  $('sysline').textContent =
    `${sys.host || ''} · ${sys.cpuName || ''} · ${sys.coresPhysical}C/${sys.coresLogical}T · up ${fmtUptime(sys.uptimeSec)}`;
}

function renderCoreBars(wrap, cores) {
  if (wrap.childElementCount !== cores.length) {
    wrap.textContent = '';
    wrap.style.gridTemplateColumns = `repeat(${Math.min(16, Math.max(cores.length, 1))}, 1fr)`;
    for (let i = 0; i < cores.length; i++) {
      const c = el('div', 'core');
      wrap.appendChild(c);
    }
  }
  const kids = wrap.children;
  for (let i = 0; i < cores.length; i++) {
    kids[i].style.height = Math.max(4, cores[i]) + '%';
    kids[i].title = `Core ${i} — ${Math.round(cores[i])}%`;
  }
}

/* ================= sparklines ================= */

function prepCanvas(canvas) {
  const dpr = window.devicePixelRatio || 1;
  const w = canvas.clientWidth, h = canvas.clientHeight;
  if (!w || !h) return null;
  if (canvas.width !== Math.round(w * dpr) || canvas.height !== Math.round(h * dpr)) {
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
  }
  const ctx = canvas.getContext('2d');
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, w, h);
  return { ctx, w, h };
}

function drawSpark(canvas, series, opts) {
  const p = prepCanvas(canvas);
  if (!p) return;
  const { ctx, w, h } = p;
  const pad = 5;
  let max = opts.max;
  if (max == null) {
    max = 0;
    for (const s of series) for (const v of s.data) if (v > max) max = v;
    max = Math.max(max * 1.15, 1);
  }
  const surface = cssVar('--surface');
  // baseline
  ctx.strokeStyle = cssVar('--grid');
  ctx.lineWidth = 1;
  ctx.beginPath(); ctx.moveTo(0, h - 0.5); ctx.lineTo(w, h - 0.5); ctx.stroke();

  for (const s of series) {
    const d = s.data;
    if (d.length < 2) continue;
    const n = d.length;
    const x = (i) => pad + (w - pad * 2) * i / (n - 1);
    const y = (v) => h - pad - (h - pad * 2) * Math.min(v, max) / max;
    // area wash
    ctx.beginPath();
    ctx.moveTo(x(0), h - 1);
    for (let i = 0; i < n; i++) ctx.lineTo(x(i), y(d[i]));
    ctx.lineTo(x(n - 1), h - 1);
    ctx.closePath();
    ctx.fillStyle = rgba(s.color, 0.10);
    ctx.fill();
    // line
    ctx.beginPath();
    for (let i = 0; i < n; i++) { i ? ctx.lineTo(x(i), y(d[i])) : ctx.moveTo(x(i), y(d[i])); }
    ctx.strokeStyle = s.color;
    ctx.lineWidth = 2;
    ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    ctx.stroke();
    // end dot with surface ring
    const ex = x(n - 1), ey = y(d[n - 1]);
    ctx.beginPath(); ctx.arc(ex, ey, 4, 0, Math.PI * 2);
    ctx.fillStyle = s.color; ctx.fill();
    ctx.lineWidth = 2; ctx.strokeStyle = surface; ctx.stroke();
  }
}

/* ================= detail charts ================= */

const chartInstances = [];

const CHART_DEFS = [
  {
    key: 'cpu', enabled: () => S.stats.cpu, title: 'CPU utilization', pct: true,
    series: [{ label: 'Total', color: '--cpu', data: () => hist.cpu, fmt: v => Math.round(v) + '%' }],
  },
  {
    key: 'mem', enabled: () => S.stats.ram, title: 'Memory', pct: true,
    series: [
      { label: 'In use', color: '--ram', data: () => hist.mem, fmt: v => Math.round(v) + '%', live: () => last && last.mem ? `${fmtBytes(last.mem.usedB)} (${Math.round(last.mem.usedB / last.mem.totalB * 100)}%)` : '—' },
      { label: 'Committed', color: '--commit', data: () => hist.commit, fmt: v => Math.round(v) + '%', live: () => last && last.mem ? `${fmtBytes(last.mem.commitB)} (${Math.round(last.mem.commitB / last.mem.commitLimitB * 100)}%)` : '—' },
    ],
  },
  {
    key: 'gpu', enabled: () => S.stats.gpu || S.stats.vram, title: 'GPU', pct: true,
    series: [
      { label: 'Utilization', color: '--gpu', data: () => hist.gpu, fmt: v => Math.round(v) + '%' },
      { label: 'VRAM', color: '--vram', data: () => hist.vram, fmt: v => Math.round(v) + '%', live: () => { const g = last && last.gpus && last.gpus[0]; return g && g.vramTotalMB ? `${fmtBytes(g.vramUsedMB * 1048576)} (${Math.round(g.vramUsedMB / g.vramTotalMB * 100)}%)` : '—'; } },
    ],
  },
  {
    key: 'net', enabled: () => S.stats.net, title: 'Network throughput', pct: false, area: true,
    series: [
      { label: 'Download', color: '--down', data: () => hist.down, fmt: v => fmtRate(v) },
      { label: 'Upload', color: '--up', data: () => hist.up, fmt: v => fmtRate(v) },
    ],
  },
  {
    key: 'disk', enabled: () => S.stats.disk, title: 'Disk active time', pct: true,
    series: [{ label: 'Active', color: '--disk', data: () => hist.disk, fmt: v => Math.round(v) + '%', live: () => last && last.disk ? `${Math.round(last.disk.activePct)}% · R ${fmtBytes(last.disk.readBps)}/s · W ${fmtBytes(last.disk.writeBps)}/s` : '—' }],
  },
];

function makeChart(def, container) {
  const card = el('div', 'chart-card');
  const head = el('div', 'chart-head');
  head.appendChild(el('h3', '', def.title));
  const legend = el('div', 'legend');
  const legendVals = [];
  for (const s of def.series) {
    const item = el('span', 'legend-item');
    const sw = el('span', 'legend-swatch');
    sw.style.borderTopColor = cssVar(s.color);
    item.appendChild(sw);
    item.appendChild(el('span', '', s.label));
    const b = el('b', '', '—');
    item.appendChild(b);
    legendVals.push(b);
    legend.appendChild(item);
  }
  head.appendChild(legend);
  card.appendChild(head);
  const canvas = el('canvas', 'chart-canvas');
  canvas.tabIndex = 0;
  canvas.setAttribute('role', 'img');
  canvas.setAttribute('aria-label', def.title + ' history chart');
  card.appendChild(canvas);
  let strip = null;
  if (def.coreStrip) { strip = el('div', 'corestrip'); card.appendChild(strip); }
  container.appendChild(card);

  const inst = { def, canvas, legendVals, strip, hover: null };
  wireChartEvents(inst);
  chartInstances.push(inst);
  return inst;
}

// each stat detail hosts one overview chart, keyed by the detail's data-chart
const CHART_BY_DETAIL = { cpu: 'cpu', mem: 'mem', gpu: 'gpu', net: 'net', disk: 'disk' };

function buildCharts() {
  for (const def of CHART_DEFS) {
    const host = document.querySelector('.chart-host[data-chart="' + def.key + '"]');
    if (!host) continue;
    host.textContent = '';
    if (def.enabled()) makeChart(def, host);
  }
}

function renderCharts() {
  for (const inst of chartInstances) {
    drawChart(inst);
    // legend live values
    inst.def.series.forEach((s, i) => {
      const d = s.data();
      const cur = d.length ? d[d.length - 1] : null;
      inst.legendVals[i].textContent = cur == null ? '—' : (s.live ? s.live() : s.fmt(cur));
    });
    if (inst.strip && last && last.cpu) renderCoreStrip(inst.strip, last.cpu.cores || []);
  }
}

function renderCoreStrip(strip, cores) {
  if (strip.childElementCount !== cores.length) {
    strip.textContent = '';
    strip.style.gridTemplateColumns = `repeat(${Math.max(cores.length, 1)}, 1fr)`;
    for (let i = 0; i < cores.length; i++) strip.appendChild(el('div', 'cell'));
  }
  const base = cssVar('--cpu');
  for (let i = 0; i < cores.length; i++) {
    const c = strip.children[i];
    c.style.background = rgba(base, 0.12 + 0.88 * cores[i] / 100);
    c.title = `Core ${i} — ${Math.round(cores[i])}%`;
  }
}

function chartWindow(inst) {
  const N = S.history;
  const data = inst.def.series.map(s => s.data().slice(-N));
  const times = hist.t.slice(-N);
  return { data, times };
}

function drawChart(inst) {
  const p = prepCanvas(inst.canvas);
  if (!p) return;
  const { ctx, w, h } = p;
  const { data, times } = chartWindow(inst);
  const n = Math.max(...data.map(d => d.length));
  const padL = 44, padR = 12, padT = 8, padB = 20;
  const pw = w - padL - padR, ph = h - padT - padB;

  let max = 100;
  if (!inst.def.pct) {
    max = 0;
    for (const d of data) for (const v of d) if (v > max) max = v;
    max = niceCeil(Math.max(max * 1.1, inst.def.minMax || 1024)); // floor so idle isn't noise
  }

  const gridCol = cssVar('--grid'), axisCol = cssVar('--axis'), mutedCol = cssVar('--muted');
  const surface = cssVar('--surface');

  // y gridlines + ticks
  ctx.font = '10px system-ui, sans-serif';
  ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
  const ticks = 4;
  for (let i = 0; i <= ticks; i++) {
    const v = max * i / ticks;
    const y = padT + ph - ph * i / ticks;
    ctx.strokeStyle = i === 0 ? axisCol : gridCol;
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(padL, Math.round(y) + 0.5); ctx.lineTo(w - padR, Math.round(y) + 0.5); ctx.stroke();
    ctx.fillStyle = mutedCol;
    const label = inst.def.fmtTick ? inst.def.fmtTick(v)
      : inst.def.pct ? Math.round(v) + '%'
      : (S.netUnits === 'bits' ? fmtBits(v * 8, 0) : fmtBytes(v, 0) + '/s');
    ctx.fillText(label, padL - 6, y);
  }

  // x labels
  if (times.length >= 2) {
    const span = Math.round((times[times.length - 1] - times[0]) / 1000);
    ctx.textAlign = 'left'; ctx.textBaseline = 'top';
    ctx.fillText('-' + span + 's', padL, padT + ph + 5);
    ctx.textAlign = 'right';
    ctx.fillText('now', w - padR, padT + ph + 5);
  }

  if (n < 2) return;
  const x = (i) => padL + pw * i / (n - 1);
  const y = (v) => padT + ph - ph * Math.min(v, max) / max;

  // crosshair (under the series lines)
  if (inst.hover != null && inst.hover >= 0 && inst.hover < n) {
    ctx.strokeStyle = mutedCol;
    ctx.lineWidth = 1;
    const hx = Math.round(x(inst.hover)) + 0.5;
    ctx.beginPath(); ctx.moveTo(hx, padT); ctx.lineTo(hx, padT + ph); ctx.stroke();
  }

  inst.def.series.forEach((s, si) => {
    const d = data[si];
    if (d.length < 2) return;
    const off = n - d.length;
    const color = cssVar(s.color);
    if (inst.def.area || inst.def.pct) {
      ctx.beginPath();
      ctx.moveTo(x(off), padT + ph);
      for (let i = 0; i < d.length; i++) ctx.lineTo(x(off + i), y(d[i]));
      ctx.lineTo(x(n - 1), padT + ph);
      ctx.closePath();
      ctx.fillStyle = rgba(color, 0.10);
      ctx.fill();
    }
    ctx.beginPath();
    for (let i = 0; i < d.length; i++) { i ? ctx.lineTo(x(off + i), y(d[i])) : ctx.moveTo(x(off + i), y(d[i])); }
    ctx.strokeStyle = color;
    ctx.lineWidth = 2; ctx.lineJoin = 'round'; ctx.lineCap = 'round';
    ctx.stroke();
    // hover / end markers
    const mi = inst.hover != null ? inst.hover - off : d.length - 1;
    if (mi >= 0 && mi < d.length) {
      ctx.beginPath(); ctx.arc(x(off + mi), y(d[mi]), 4, 0, Math.PI * 2);
      ctx.fillStyle = color; ctx.fill();
      ctx.lineWidth = 2; ctx.strokeStyle = surface; ctx.stroke();
    }
  });
}

function wireChartEvents(inst) {
  const canvas = inst.canvas;
  const idxFromEvent = (ev) => {
    const rect = canvas.getBoundingClientRect();
    const { data } = chartWindow(inst);
    const n = Math.max(...data.map(d => d.length));
    if (n < 2) return null;
    const padL = 44, padR = 12;
    const rel = (ev.clientX - rect.left - padL) / (rect.width - padL - padR);
    return Math.max(0, Math.min(n - 1, Math.round(rel * (n - 1))));
  };
  canvas.addEventListener('pointermove', (ev) => {
    inst.hover = idxFromEvent(ev);
    drawChart(inst);
    showChartTooltip(inst, ev.clientX, ev.clientY);
  });
  canvas.addEventListener('pointerleave', () => {
    inst.hover = null;
    drawChart(inst);
    hideTooltip();
  });
  canvas.addEventListener('keydown', (ev) => {
    const { data } = chartWindow(inst);
    const n = Math.max(...data.map(d => d.length));
    if (!n) return;
    if (ev.key === 'ArrowLeft' || ev.key === 'ArrowRight') {
      ev.preventDefault();
      if (inst.hover == null) inst.hover = n - 1;
      inst.hover = Math.max(0, Math.min(n - 1, inst.hover + (ev.key === 'ArrowRight' ? 1 : -1)));
      drawChart(inst);
      const rect = canvas.getBoundingClientRect();
      const padL = 44, padR = 12;
      const px = rect.left + padL + (rect.width - padL - padR) * inst.hover / (n - 1);
      showChartTooltip(inst, px, rect.top + 40);
    } else if (ev.key === 'Escape') {
      inst.hover = null; drawChart(inst); hideTooltip();
    }
  });
  canvas.addEventListener('blur', () => { inst.hover = null; drawChart(inst); hideTooltip(); });
}

function showChartTooltip(inst, cx, cy) {
  if (inst.hover == null) { hideTooltip(); return; }
  const { data, times } = chartWindow(inst);
  const n = Math.max(...data.map(d => d.length));
  const tip = $('tooltip');
  tip.textContent = '';
  const ago = times.length === n ? Math.round((times[n - 1] - times[inst.hover]) / 1000) : null;
  tip.appendChild(el('div', 'tt-time', ago === 0 ? 'now' : ago != null ? ago + 's ago' : ''));
  inst.def.series.forEach((s, si) => {
    const d = data[si];
    const off = n - d.length;
    const i = inst.hover - off;
    if (i < 0 || i >= d.length) return;
    const row = el('div', 'tt-row');
    const key = el('span', 'tt-key');
    key.style.borderTopColor = cssVar(s.color);
    row.appendChild(key);
    row.appendChild(el('span', 'tt-val', s.fmt(d[i])));
    row.appendChild(el('span', 'tt-label', s.label));
    tip.appendChild(row);
  });
  tip.classList.remove('hidden');
  const r = tip.getBoundingClientRect();
  let xx = cx + 14, yy = cy + 14;
  if (xx + r.width > innerWidth - 8) xx = cx - r.width - 14;
  if (yy + r.height > innerHeight - 8) yy = cy - r.height - 14;
  tip.style.left = xx + 'px';
  tip.style.top = yy + 'px';
}
function hideTooltip() { $('tooltip').classList.add('hidden'); }

/* ================= detail panels (CPU cores / GPU / memory / disks) ================= */

const GPU_CHART_DEFS = [
  {
    key: 'gpupow', title: 'Power draw', pct: false, area: true, minMax: 50,
    fmtTick: v => Math.round(v) + ' W',
    series: [{
      label: 'Power', color: '--gpu', data: () => hist.gpuPow, fmt: v => Math.round(v) + ' W',
      live: () => { const g = lastGpu(); return g && g.powerW != null ? `${Math.round(g.powerW)} W of ${Math.round(g.powerCapW || 0)} W` : '—'; },
    }],
  },
  {
    key: 'gputemp', title: 'Temperature', pct: true,
    fmtTick: v => Math.round(v) + '°',
    series: [{ label: 'GPU temp', color: '--up', data: () => hist.gpuTemp, fmt: v => Math.round(v) + ' °C' }],
  },
  {
    key: 'gpuclock', title: 'Core clock', pct: false, area: true, minMax: 500,
    fmtTick: v => Math.round(v),
    series: [{
      label: 'Clock MHz', color: '--down', data: () => hist.gpuClock, fmt: v => Math.round(v) + ' MHz',
      live: () => { const g = lastGpu(); return g && g.clockMHz != null ? `${Math.round(g.clockMHz)} MHz` : '—'; },
    }],
  },
];

/* ---- CPU cores ---- */
let coreCells = [];

function buildCpuPanel() {
  const grid = $('coreGrid');
  grid.textContent = '';
  coreCells = [];
  const n = ((last && last.cpu && last.cpu.cores) || coreHist).length;
  for (let i = 0; i < n; i++) {
    const cell = el('div', 'core-cell');
    const head = el('div', 'core-head');
    head.appendChild(el('span', 'cid', 'C' + i));
    const b = el('b', '', '—');
    head.appendChild(b);
    cell.appendChild(head);
    const cv = el('canvas');
    cell.appendChild(cv);
    const mhz = el('div', 'core-mhz', '');
    cell.appendChild(mhz);
    grid.appendChild(cell);
    coreCells.push({ b, cv, mhz });
  }
}

function renderCpuPanel() {
  if (!last || !last.cpu) return;
  const cores = last.cpu.cores || [];
  if (coreCells.length !== cores.length) buildCpuPanel();
  const N = S.history;
  const color = cssVar('--cpu');
  for (let i = 0; i < cores.length; i++) {
    const c = coreCells[i];
    c.b.textContent = Math.round(cores[i]) + '%';
    const mhz = last.cpu.coreMHz && last.cpu.coreMHz[i];
    c.mhz.textContent = mhz ? (mhz / 1000).toFixed(2) + ' GHz' : '';
    drawSpark(c.cv, [{ data: (coreHist[i] || []).slice(-N), color }], { max: 100 });
  }
  const sys = last.sys || {};
  const avg = last.cpu.curMHz ? ` · ${(last.cpu.curMHz / 1000).toFixed(2)} GHz avg` : '';
  $('cpuMeta').textContent = `${sys.cpuName || ''} · ${sys.coresPhysical}C/${sys.coresLogical}T${avg}`;
  const r = last.sysRates, counts = last.counts || {};
  $('sysRatesLine').textContent = r
    ? `${counts.processes || 0} processes · ${(counts.threads || 0).toLocaleString()} threads · ` +
      `${(r.ctxSwitches || 0).toLocaleString()} context switches/s · ${(r.sysCalls || 0).toLocaleString()} system calls/s · run queue ${r.procQueue}`
    : '';
}

/* ---- GPU panel ---- */
let gpuFactRefs = null;
let gpuProcShowAll = false;

function setFact(ref, main, small) {
  ref.v.textContent = '';
  ref.v.appendChild(document.createTextNode(main));
  if (small) ref.v.appendChild(el('small', '', ' ' + small));
}
function factMeter(ref, pct, colorVar) {
  const color = pct >= 90 ? cssVar('--crit') : pct >= 80 ? cssVar('--warn') : cssVar(colorVar);
  ref.fill.style.width = clampPct(pct) + '%';
  ref.fill.style.background = color;
  ref.track.style.background = cssVar(colorVar);
}

function buildGpuPanel() {
  const facts = $('gpuFacts');
  facts.textContent = '';
  gpuFactRefs = {};
  const defs = [
    ['util', 'Utilization', 'spark'],
    ['vram', 'VRAM', 'meter'],
    ['temp', 'Temperature', 'spark'],
    ['fan', 'Fan', 'spark'],
    ['power', 'Power', 'spark'],
    ['clock', 'Clocks (core / mem)', null],
    ['bus', 'PCIe link', null],
    ['pstate', 'Performance state', null],
  ];
  for (const [k, label, extra] of defs) {
    const f = el('div', 'fact');
    f.appendChild(el('div', 'f-label', label));
    const v = el('div', 'f-value', '—');
    f.appendChild(v);
    const ref = { v };
    if (extra === 'spark') { ref.cv = el('canvas'); f.appendChild(ref.cv); }
    if (extra === 'meter') {
      const m = el('div', 'meter');
      ref.track = el('div', 'meter-track');
      ref.fill = el('div', 'meter-fill');
      m.appendChild(ref.track); m.appendChild(ref.fill);
      f.appendChild(m);
    }
    facts.appendChild(f);
    gpuFactRefs[k] = ref;
  }
  const chartsWrap = $('gpuCharts');
  chartsWrap.textContent = '';
  for (const def of GPU_CHART_DEFS) makeChart(def, chartsWrap);
}

function renderGpuLive() {
  const g = lastGpu();
  $('gpuPanel').classList.toggle('hidden', !g);
  if (!g || !gpuFactRefs) return;
  const N = S.history;
  $('gpuMeta').textContent = `${g.name}${g.driver ? ' · driver ' + g.driver : ''}`;
  const R = gpuFactRefs;
  setFact(R.util, Math.round(g.util || 0) + '%', g.memUtil != null ? `mem bus ${Math.round(g.memUtil)}%` : '');
  drawSpark(R.util.cv, [{ data: hist.gpu.slice(-N), color: cssVar('--gpu') }], { max: 100 });
  const vramPct = g.vramTotalMB ? g.vramUsedMB / g.vramTotalMB * 100 : 0;
  setFact(R.vram, fmtBytes(g.vramUsedMB * 1048576), `of ${fmtBytes(g.vramTotalMB * 1048576)} (${Math.round(vramPct)}%)`);
  factMeter(R.vram, vramPct, '--vram');
  setFact(R.temp, g.tempC != null ? Math.round(g.tempC) + ' °C' : '—');
  drawSpark(R.temp.cv, [{ data: hist.gpuTemp.slice(-N), color: cssVar('--up') }], { max: 100 });
  setFact(R.fan, g.fanPct != null ? Math.round(g.fanPct) + '%' : '—');
  drawSpark(R.fan.cv, [{ data: hist.gpuFan.slice(-N), color: cssVar('--ram') }], { max: 100 });
  setFact(R.power, g.powerW != null ? Math.round(g.powerW) + ' W' : '—', g.powerCapW ? `of ${Math.round(g.powerCapW)} W` : '');
  drawSpark(R.power.cv, [{ data: hist.gpuPow.slice(-N), color: cssVar('--gpu') }], {});
  setFact(R.clock, g.clockMHz != null ? (g.clockMHz / 1000).toFixed(2) + ' GHz' : '—', g.memClockMHz != null ? `mem ${(g.memClockMHz / 1000).toFixed(2)} GHz` : '');
  setFact(R.bus, (g.pcieGen != null && g.pcieWidth != null) ? `Gen ${g.pcieGen} x${g.pcieWidth}` : '—');
  setFact(R.pstate, g.pstate || '—');
}

const ENGINE_BASELINE = ['3D', 'Copy', 'VideoDecode', 'VideoEncode'];

function renderGpuDetail() {
  if (!lastDetail || !lastDetail.gpu) return;
  // engines
  const eng = lastDetail.gpu.engines || {};
  const wrap = $('gpuEngines');
  wrap.textContent = '';
  const keys = [...new Set([...ENGINE_BASELINE, ...Object.keys(eng)])]
    .sort((a, b) => (eng[b] || 0) - (eng[a] || 0));
  const color = cssVar('--gpu');
  for (const k of keys) {
    const pct = eng[k] || 0;
    const row = el('div', 'engine-row');
    row.appendChild(el('span', 'e-name', k));
    const m = el('div', 'meter');
    const track = el('div', 'meter-track');
    track.style.background = color;
    const fill = el('div', 'meter-fill');
    fill.style.width = clampPct(pct) + '%';
    fill.style.background = color;
    m.appendChild(track); m.appendChild(fill);
    row.appendChild(m);
    row.appendChild(el('span', 'e-val', pct.toFixed(0) + '%'));
    wrap.appendChild(row);
  }
  // processes on GPU
  const rows = (lastDetail.gpu.procs || []).slice()
    .sort((a, b) => (b.dedB - a.dedB) || (b.util - a.util));
  const shown = gpuProcShowAll ? rows : rows.slice(0, 12);
  const tbody = $('gpuProcTable').tBodies[0];
  tbody.textContent = '';
  const washColor = cssVar('--gpu');
  for (const r of shown) {
    const tr = el('tr');
    tr.appendChild(el('td', 't-left', r.name));
    tr.appendChild(el('td', '', String(r.pid)));
    const utilTd = el('td', 'cpu-cell', r.util.toFixed(0) + '%');
    const pct = clampPct(r.util);
    utilTd.style.background = `linear-gradient(90deg, ${rgba(washColor, 0.16)} ${pct}%, transparent ${pct}%)`;
    tr.appendChild(utilTd);
    tr.appendChild(el('td', '', fmtBytes(r.dedB)));
    tr.appendChild(el('td', '', fmtBytes(r.sharedB)));
    tbody.appendChild(tr);
  }
  $('gpuProcCount').textContent = `${shown.length} of ${rows.length} shown`;
  $('gpuProcMore').textContent = gpuProcShowAll ? 'Show top 12' : `Show all (${rows.length})`;
}

/* ---- memory panel ---- */
let memRefs = null;

function buildMemPanel() {
  const segsDef = [
    ['inUse', 'In use', () => cssVar('--ram')],
    ['modified', 'Modified', () => cssVar('--disk')],
    ['standby', 'Standby (cache)', () => rgba(cssVar('--ram'), 0.38)],
    ['free', 'Free', () => cssVar('--grid')],
  ];
  const bar = $('memBar'); bar.textContent = '';
  const legend = $('memLegend'); legend.textContent = '';
  memRefs = { segs: {}, facts: {} };
  for (const [k, label] of segsDef) {
    const seg = el('div', 'mem-seg');
    bar.appendChild(seg);
    const li = el('span', 'legend-item');
    const sw = el('span', 'legend-swatch');
    li.appendChild(sw);
    li.appendChild(el('span', '', label));
    const b = el('b', '', '—');
    li.appendChild(b);
    legend.appendChild(li);
    memRefs.segs[k] = { seg, sw, b, colorFn: segsDef.find(s => s[0] === k)[2] };
  }
  const factsDef = [
    ['commit', 'Commit charge', 'meter'],
    ['pagefile', 'Page file', 'meter'],
    ['poolP', 'Pool paged', null],
    ['poolNP', 'Pool non-paged', null],
    ['cache', 'System cache', null],
    ['pages', 'Hard faults', null],
  ];
  const facts = $('memFacts'); facts.textContent = '';
  for (const [k, label, extra] of factsDef) {
    const f = el('div', 'fact');
    f.appendChild(el('div', 'f-label', label));
    const v = el('div', 'f-value', '—');
    f.appendChild(v);
    const ref = { v };
    if (extra === 'meter') {
      const m = el('div', 'meter');
      ref.track = el('div', 'meter-track');
      ref.fill = el('div', 'meter-fill');
      m.appendChild(ref.track); m.appendChild(ref.fill);
      f.appendChild(m);
    }
    facts.appendChild(f);
    memRefs.facts[k] = ref;
  }
}

function renderMemPanel() {
  const m = last && last.mem;
  if (!m || !memRefs) return;
  $('memMeta').textContent = `${fmtBytes(m.usedB)} of ${fmtBytes(m.totalB)} in use (${Math.round(m.usedB / m.totalB * 100)}%)`;
  const total = m.totalB || 1;
  const vals = { inUse: m.usedB, modified: m.modifiedB || 0, standby: m.standbyB || 0, free: m.freeB || 0 };
  for (const k of Object.keys(vals)) {
    const r = memRefs.segs[k];
    const color = r.colorFn();
    r.seg.style.width = Math.max(0, vals[k] / total * 100) + '%';
    r.seg.style.background = color;
    r.seg.title = fmtBytes(vals[k]);
    r.sw.style.borderTopColor = color;
    r.b.textContent = fmtBytes(vals[k]);
  }
  const F = memRefs.facts;
  const commitPct = m.commitLimitB ? m.commitB / m.commitLimitB * 100 : 0;
  setFact(F.commit, fmtBytes(m.commitB), `of ${fmtBytes(m.commitLimitB)} (${Math.round(commitPct)}%)`);
  factMeter(F.commit, commitPct, '--commit');
  const pf = last.pagefile;
  if (pf) {
    const pfPct = pf.totalB ? pf.usedB / pf.totalB * 100 : 0;
    setFact(F.pagefile, fmtBytes(pf.usedB), `of ${fmtBytes(pf.totalB)} (${Math.round(pfPct)}%)`);
    factMeter(F.pagefile, pfPct, '--commit');
  } else { setFact(F.pagefile, '—'); }
  setFact(F.poolP, fmtBytes(m.poolPagedB || 0));
  setFact(F.poolNP, fmtBytes(m.poolNonpagedB || 0));
  setFact(F.cache, fmtBytes(m.cacheB || 0));
  setFact(F.pages, (m.pagesPersec || 0).toLocaleString(), 'pages/s');
}

/* ---- disks panel ---- */
let diskCards = {};

function buildDiskPanel() {
  $('diskGrid').textContent = '';
  diskCards = {};
}

function renderDiskPanel() {
  const ds = (last && last.disks) || [];
  $('diskPanel').classList.toggle('hidden', ds.length === 0);
  const color = cssVar('--disk');
  for (const d of ds) {
    let c = diskCards[d.name];
    if (!c) {
      const card = el('div', 'disk-card');
      const head = el('div', 'd-head');
      head.appendChild(el('span', 'd-name', 'Disk ' + d.name));
      const b = el('b', '', '—');
      head.appendChild(b);
      card.appendChild(head);
      const m = el('div', 'meter');
      const track = el('div', 'meter-track');
      const fill = el('div', 'meter-fill');
      m.appendChild(track); m.appendChild(fill);
      card.appendChild(m);
      const cv = el('canvas');
      card.appendChild(cv);
      const sub = el('div', 'd-sub', '');
      card.appendChild(sub);
      $('diskGrid').appendChild(card);
      c = diskCards[d.name] = { b, fill, track, cv, sub };
    }
    c.b.textContent = Math.round(d.activePct) + '%';
    c.fill.style.width = clampPct(d.activePct) + '%';
    c.fill.style.background = color;
    c.track.style.background = color;
    drawSpark(c.cv, [{ data: (diskHist[d.name] || []).slice(-S.history), color }], { max: 100 });
    c.sub.textContent = `Read ${fmtBytes(d.readBps)}/s · Write ${fmtBytes(d.writeBps)}/s · queue ${d.queue}`;
  }
}

/* ---- detail composition ---- */
function buildDetail() {
  chartInstances.length = 0;   // makeChart() re-populates (overview + gpu sub-charts)
  buildCharts();
  buildCpuPanel();
  buildGpuPanel();
  buildMemPanel();
  buildDiskPanel();
  applySelection();
  renderDetailLive();
  renderProcTable();
  renderNetTables();
  renderGpuDetail();
}

// Update every panel each tick; hidden ones are cheap (canvases skip when 0-size).
function renderDetailLive() {
  renderCharts();
  renderCpuPanel();
  renderGpuLive();
  renderMemPanel();
  renderDiskPanel();
}

/* ================= processes table ================= */

function groupProcs(procs) {
  const map = new Map();
  for (const pr of procs) {
    let g = map.get(pr.name);
    if (!g) {
      g = { name: pr.name, pids: 0, cpu: 0, memB: 0, ioR: 0, ioW: 0, threads: 0, tcp: 0, est: 0, remotes: [], remoteCount: 0 };
      map.set(pr.name, g);
    }
    g.pids++;
    g.cpu += pr.cpu; g.memB += pr.memB; g.ioR += pr.ioR; g.ioW += pr.ioW;
    g.threads += pr.threads; g.tcp += pr.tcp; g.est += pr.est;
    g.remoteCount += pr.remoteCount;
    for (const rm of pr.remotes || []) { if (g.remotes.length < 3 && !g.remotes.some(x => x.ip === rm.ip)) g.remotes.push(rm); }
  }
  return [...map.values()];
}

function sortRows(rows, sort) {
  const { key, dir } = sort;
  rows.sort((a, b) => {
    if (key === 'name') return dir * a.name.localeCompare(b.name);
    return dir * ((a[key] || 0) - (b[key] || 0));
  });
}

function renderProcTable() {
  if (!lastDetail) return;
  let rows = lastDetail.procs.map(pr => ({ ...pr, pids: 1 }));
  if (S.procGroup) rows = groupProcs(lastDetail.procs);
  const q = $('procSearch').value.trim().toLowerCase();
  if (q) rows = rows.filter(r => r.name.toLowerCase().includes(q));
  sortRows(rows, procSort);
  const total = rows.length;
  const shown = procShowAll ? rows : rows.slice(0, 25);

  const tbody = $('procTable').tBodies[0];
  tbody.textContent = '';
  const cpuColor = cssVar('--cpu');
  for (const r of shown) {
    const tr = el('tr');
    tr.appendChild(el('td', 't-left', r.name));
    const pidTd = el('td', '', S.procGroup ? String(r.pids) : String(r.pid));
    tr.appendChild(pidTd);
    const cpuTd = el('td', 'cpu-cell', Math.min(r.cpu, 100).toFixed(1) + '%');
    const pct = Math.min(r.cpu, 100);
    cpuTd.style.background = `linear-gradient(90deg, ${rgba(cpuColor, 0.16)} ${pct}%, transparent ${pct}%)`;
    tr.appendChild(cpuTd);
    tr.appendChild(el('td', '', fmtBytes(r.memB)));
    tr.appendChild(el('td', '', r.ioR ? fmtBytes(r.ioR) + '/s' : '—'));
    tr.appendChild(el('td', '', r.ioW ? fmtBytes(r.ioW) + '/s' : '—'));
    tr.appendChild(el('td', '', String(r.threads)));
    tr.appendChild(el('td', '', r.tcp ? String(r.tcp) : '—'));
    tbody.appendChild(tr);
  }
  $('procCount').textContent = `${shown.length} of ${total} shown` + (S.procGroup ? ' (grouped by app)' : '');
  $('procMore').textContent = procShowAll ? 'Show top 25' : `Show all (${total})`;
}

/* ================= network tables ================= */

// Map a reverse-DNS hostname to a recognisable service name. Reverse DNS usually
// reveals the hosting network / CDN rather than the exact site, so this is a best
// effort — the full hostname + IP are always available in the cell's tooltip.
const SERVICE_MAP = [
  ['1e100.net','Google'],['googlevideo','YouTube'],['youtube','YouTube'],['ytimg','YouTube'],['gstatic','Google'],['ggpht','Google'],['doubleclick','Google Ads'],['googleusercontent','Google Cloud'],['google','Google'],
  ['fbcdn','Meta / Facebook'],['facebook','Facebook'],['instagram','Instagram'],['whatsapp','WhatsApp'],['fbsbx','Meta'],
  ['cloudfront','AWS CloudFront'],['amazonaws','AWS'],
  ['edgekey','Akamai CDN'],['edgesuite','Akamai CDN'],['akamai','Akamai CDN'],
  ['azureedge','Azure CDN'],['trafficmanager','Azure'],['azure','Azure'],['windowsupdate','Windows Update'],['msedge.net','Microsoft Edge'],['office','Microsoft 365'],['live.com','Microsoft'],['msn','MSN'],['skype','Skype'],['bing','Bing'],['microsoft','Microsoft'],['msft','Microsoft'],
  ['one.one.one.one','Cloudflare DNS'],['cloudflare','Cloudflare'],['fastly','Fastly CDN'],
  ['githubusercontent','GitHub'],['github','GitHub'],
  ['aaplimg','Apple'],['icloud','iCloud'],['apple','Apple'],
  ['nflxvideo','Netflix'],['nflxso','Netflix'],['netflix','Netflix'],
  ['byteoversea','TikTok'],['bytedance','TikTok'],['tiktok','TikTok'],['ttdns','TikTok'],
  ['twimg','X / Twitter'],['twitter','X / Twitter'],
  ['scdn.co','Spotify'],['spotify','Spotify'],['discord','Discord'],['steampowered','Steam'],['valve','Steam / Valve'],['steam','Steam'],['epicgames','Epic Games'],['riotgames','Riot Games'],
  ['openai','OpenAI'],['anthropic','Anthropic'],['claude','Anthropic'],
  ['redditmedia','Reddit'],['redd.it','Reddit'],['reddit','Reddit'],['telegram','Telegram'],
];
function friendlyHost(host, ip) {
  if (!host) return ip;
  const h = host.toLowerCase();
  for (const [needle, label] of SERVICE_MAP) { if (h.includes(needle)) return label; }
  const p = host.replace(/\.$/, '').split('.');   // else the registrable-ish domain
  return p.length >= 2 ? p.slice(-2).join('.') : host;
}

function renderNetTables() {
  // adapters
  if (last && last.net) {
    const tbody = $('nicTable').tBodies[0];
    tbody.textContent = '';
    let ads = last.net.adapters.filter(a => a.linkBps > 0 || a.downBps > 0 || a.upBps > 0);
    if (!ads.length) ads = last.net.adapters;
    for (const a of ads) {
      const tr = el('tr');
      tr.appendChild(el('td', 't-left', a.name));
      tr.appendChild(el('td', '', a.linkBps ? fmtBits(a.linkBps, 0) : '—'));
      tr.appendChild(el('td', '', fmtRate(a.downBps)));
      tr.appendChild(el('td', '', fmtRate(a.upBps)));
      tbody.appendChild(tr);
    }
  }
  // by app
  if (lastDetail) {
    let rows = groupProcs(lastDetail.procs).filter(r => r.tcp > 0);
    for (const r of rows) r.io = r.ioR + r.ioW;
    sortRows(rows, netSort);
    const tbody = $('netAppTable').tBodies[0];
    tbody.textContent = '';
    for (const r of rows.slice(0, 20)) {
      const tr = el('tr');
      tr.appendChild(el('td', 't-left', r.name));
      tr.appendChild(el('td', '', String(r.tcp)));
      tr.appendChild(el('td', '', String(r.est)));
      tr.appendChild(el('td', '', r.io ? fmtBytes(r.io) + '/s' : '—'));
      const extra = r.remoteCount - r.remotes.length;
      const labels = r.remotes.map(rm => friendlyHost(rm.host, rm.ip));
      const remotes = labels.join(', ') + (extra > 0 ? `  +${extra}` : '');
      const rtd = el('td', 't-left remote-list', remotes || '—');
      rtd.title = r.remotes.map(rm => rm.host ? `${rm.host}  (${rm.ip})` : rm.ip).join('\n') || '';
      tr.appendChild(rtd);
      tbody.appendChild(tr);
    }
  }
}

/* ================= settings UI ================= */

function maybeRefreshAdapters(stats) {
  const sel = $('optAdapter');
  const names = [...new Set(((stats.net && stats.net.adapters) || []).map(a => a.name))];
  const existing = [...sel.options].slice(1).map(o => o.value);
  if (names.join('|') === existing.join('|')) return;
  const cur = S.netAdapter;
  sel.textContent = '';
  const all = el('option', '', 'All adapters');
  all.value = 'all';
  sel.appendChild(all);
  for (const nm of names) {
    const o = el('option', '', nm);
    o.value = nm;
    sel.appendChild(o);
  }
  sel.value = names.includes(cur) ? cur : 'all';
  if (sel.value !== cur) { S.netAdapter = sel.value; saveSettings(); }
}

function syncSettingsUI() {
  document.querySelectorAll('[data-stat]').forEach(cb => { cb.checked = !!S.stats[cb.dataset.stat]; });
  $('optInterval').value = String(S.interval);
  $('optHistory').value = String(S.history);
  $('optUnits').value = S.netUnits;
  $('optSpark').checked = S.sparklines;
  $('optCores').checked = S.perCore;
  $('optCompact').checked = S.compact;
  $('optGroup').checked = S.procGroup;
}

function applyAll() {
  buildTiles();
  buildDetail();
}

function wireSettings() {
  document.querySelectorAll('[data-stat]').forEach(cb => {
    cb.addEventListener('change', () => {
      S.stats[cb.dataset.stat] = cb.checked;
      saveSettings(); applyAll();
    });
  });
  $('optInterval').addEventListener('change', e => { S.interval = +e.target.value; saveSettings(); pollStats(); });
  $('optHistory').addEventListener('change', e => { S.history = +e.target.value; saveSettings(); renderWidget(); renderDetailLive(); });
  $('optUnits').addEventListener('change', e => { S.netUnits = e.target.value; saveSettings(); renderWidget(); renderDetailLive(); renderNetTables(); });
  $('optAdapter').addEventListener('change', e => { S.netAdapter = e.target.value; saveSettings(); renderWidget(); renderDetailLive(); });
  $('optSpark').addEventListener('change', e => { S.sparklines = e.target.checked; saveSettings(); buildTiles(); });
  $('optCores').addEventListener('change', e => { S.perCore = e.target.checked; saveSettings(); buildTiles(); });
  $('optCompact').addEventListener('change', e => { S.compact = e.target.checked; saveSettings(); buildTiles(); });
  $('optGroup').addEventListener('change', e => { S.procGroup = e.target.checked; saveSettings(); renderProcTable(); renderNetTables(); });
  $('btnReset').addEventListener('click', () => {
    S = JSON.parse(JSON.stringify(DEFAULTS));
    saveSettings(); syncSettingsUI(); applyTheme(); applyAll(); pollStats();
  });

  $('btnSettings').addEventListener('click', () => toggleDrawer(true));
  $('btnCloseSettings').addEventListener('click', () => toggleDrawer(false));
  $('backdrop').addEventListener('click', () => toggleDrawer(false));
  document.addEventListener('keydown', e => { if (e.key === 'Escape') toggleDrawer(false); });
}

function toggleDrawer(open) {
  $('drawer').classList.toggle('open', open);
  $('drawer').setAttribute('aria-hidden', String(!open));
  $('backdrop').classList.toggle('hidden', !open);
}

/* ================= theme ================= */

function applyTheme() {
  document.documentElement.dataset.theme = S.theme;
  renderWidget();
  buildDetail();
}

/* ================= table sorting ================= */

function wireTableSort(table, sortState, rerender) {
  table.tHead.addEventListener('click', (ev) => {
    const th = ev.target.closest('th');
    if (!th || !th.dataset.sort) return;
    const key = th.dataset.sort;
    if (sortState.key === key) sortState.dir *= -1;
    else { sortState.key = key; sortState.dir = key === 'name' ? 1 : -1; }
    table.tHead.querySelectorAll('th').forEach(h => h.classList.toggle('sorted', h === th));
    rerender();
  });
}

/* ================= boot ================= */

function boot() {
  syncSettingsUI();
  wireSettings();
  document.documentElement.dataset.theme = S.theme;
  buildTiles();
  buildDetail();

  $('btnTheme').addEventListener('click', () => {
    S.theme = S.theme === 'dark' ? 'light' : 'dark';
    saveSettings(); applyTheme();
  });
  $('procSearch').addEventListener('input', () => renderProcTable());
  $('procMore').addEventListener('click', () => { procShowAll = !procShowAll; renderProcTable(); });
  $('gpuProcMore').addEventListener('click', () => { gpuProcShowAll = !gpuProcShowAll; renderGpuDetail(); });
  wireTableSort($('procTable'), procSort, renderProcTable);
  wireTableSort($('netAppTable'), netSort, renderNetTables);

  let resizeRaf = null;
  addEventListener('resize', () => {
    cancelAnimationFrame(resizeRaf);
    resizeRaf = requestAnimationFrame(() => { renderWidget(); renderDetailLive(); });
  });
  document.addEventListener('visibilitychange', () => { if (!document.hidden) pollStats(); });

  pollStats();
  pollDetail();
}

boot();
