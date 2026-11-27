// Isle menu bar: Start and the app in front on the left; background (tray) apps, Wi-Fi, sound,
// battery and the date / time on the right. Clicks open small Mac-style menus drawn here.
const api = window.isle;
const $ = (id) => document.getElementById(id);
const pop = $('pop');

let S = {};
let power = null;       // { ac, charging, pct, battery }
let vol = null;         // { v, m }
let outputs = [];       // sound outputs [{ id, name, def }]
let wifi = { kind: 'none' };
let tray = [];
let openFor = null;     // the bar item whose menu is open
let closeT = 0;

/* ---------------------------------------------------------------- icons */
function wifiIcon(w) {
  if (w.kind === 'cable') return '<svg viewBox="0 0 16 16"><path d="M5 2h6v3h2v4h-2v5H5V9H3V5h2zm1.5 1.5v3h-2v1h2V12.5h3V7.5h2v-1h-2v-3z"/></svg>';
  const lvl = w.kind === 'wifi' ? (w.signal >= 70 ? 3 : w.signal >= 40 ? 2 : 1) : 0;
  const arc = (d, on) => `<path d="${d}" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" opacity="${on ? 1 : .3}"/>`;
  let s = '<svg viewBox="0 0 16 16">';
  s += arc('M1.6 6.1a9.2 9.2 0 0 1 12.8 0', lvl >= 3);
  s += arc('M3.9 8.5a5.9 5.9 0 0 1 8.2 0', lvl >= 2);
  s += arc('M6.1 10.8a2.7 2.7 0 0 1 3.8 0', lvl >= 1);
  s += `<circle cx="8" cy="13" r="1.25" opacity="${lvl ? 1 : .3}"/>`;
  if (!lvl) s += '<path d="M2.5 2.5l11 11" stroke="currentColor" stroke-width="1.6" stroke-linecap="round"/>';
  return s + '</svg>';
}
function volIcon(v) {
  let s = '<svg viewBox="0 0 16 16"><path d="M2 6h2.6L8 3v10L4.6 10H2z"/>';
  if (!v || v.m || v.v === 0) s += '<path d="M10.5 6l4 4m0-4l-4 4" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>';
  else {
    s += '<path d="M10.2 6a2.6 2.6 0 0 1 0 4" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>';
    if (v.v >= 34) s += '<path d="M11.9 4.3a5 5 0 0 1 0 7.4" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>';
    if (v.v >= 67) s += '<path d="M13.5 2.8a7.2 7.2 0 0 1 0 10.4" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/>';
  }
  return s + '</svg>';
}
function batIcon(p) {
  const pct = Math.max(0, Math.min(100, p.pct));
  const low = pct <= 20 && !p.ac;
  const fill = p.ac ? '#30d158' : low ? '#ff453a' : 'currentColor';
  const w = Math.max(1.5, 17 * pct / 100);
  let s = '<svg viewBox="0 0 25 13">';
  s += '<rect x=".75" y=".75" width="20.5" height="11.5" rx="3.2" fill="none" stroke="currentColor" stroke-width="1.2" opacity=".55"/>';
  s += '<path d="M22.6 4.3v4.4a1.9 1.9 0 0 0 0-4.4z" opacity=".55"/>';
  s += `<rect x="2.5" y="2.5" width="${w.toFixed(1)}" height="8" rx="1.8" fill="${fill}"/>`;
  if (p.charging || p.ac) s += '<path d="M12.3 1.6L8.2 7.1h2.6l-1.1 4.3 4.1-5.5h-2.6z" fill="#fff" stroke="rgba(0,0,0,.45)" stroke-width=".6"/>';
  return s + '</svg>';
}

/* ---------------------------------------------------------------- bar */
function renderClock() {
  const d = new Date();
  const day = d.toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short' });
  const time = d.toLocaleTimeString(S.clock24 ? 'en-GB' : 'en-US', { hour: 'numeric', minute: '2-digit', hour12: !S.clock24 });
  $('clock').textContent = `${day}  ${time}`;
}
function tick() { renderClock(); setTimeout(tick, 60000 - (Date.now() % 60000) + 30); }

function renderStatus() {
  $('wifi').innerHTML = wifiIcon(wifi);
  $('wifi').title = wifi.kind === 'wifi' ? `Wi-Fi: ${wifi.ssid} (${wifi.signal}%)` : wifi.kind === 'cable' ? 'Ethernet' : 'Not connected';
  $('vol').innerHTML = volIcon(vol);
  const bat = $('bat');
  bat.classList.toggle('hidden', !power || !power.battery || !(power.pct >= 0));
  if (power && power.battery) {
    $('batIcon').innerHTML = batIcon(power);
    $('batPct').textContent = S.menuBarBattery === false ? '' : `${Math.round(power.pct)}%`;
  }
  if (openFor && openFor.id !== 'trayitem') refreshPop();
}

const icons = new Map();
function trayName(a) {
  let n = (a.name || '').replace(/\.Root$/i, '');
  if (/^(python|pythonw|java|javaw|node)$/i.test(n) && a.tip) n = a.tip.split(/[–\-:|]/)[0].trim();
  return n || a.tip || 'App';
}
function renderTray() {
  const box = $('tray');
  box.innerHTML = '';
  if (S.menuBarTray === false) return;
  for (const a of tray) {
    const b = document.createElement('button');
    b.className = 'it';
    b.title = trayName(a) + (a.tip && a.tip !== a.name ? ' — ' + a.tip : '');
    b._app = a;
    const url = icons.get(a.exe);   // (keyed by program; two WhatsApps have two programs)
    b.innerHTML = url ? `<img src="${url}" alt="">` : '<i class="ph"></i>';
    // Store apps (WhatsApp...): the package's icon; the program file only has a blank one
    if (!url) api.dockIcon(a.aumid ? ['shell:AppsFolder\\' + a.aumid, a.exe] : [a.exe]).then((u) => { if (u) { icons.set(a.exe, u); const img = document.createElement('img'); img.src = u; img.alt = ''; if (b.isConnected) b.replaceChildren(img); } });
    b.addEventListener('click', () => { closePop(); api.mbDo('trayopen', a.exe); });
    b.addEventListener('contextmenu', (e) => { e.preventDefault(); openPop(b, trayMenu(a)); });
    box.appendChild(b);
  }
  reportHit();
}

/* ---------------------------------------------------------------- menus */
function row(label, run, opts = {}) { return { label, run, ...opts }; }
function trayMenu(a) {
  return () => [
    { title: trayName(a) },
    row('Open', () => api.mbDo('trayopen', a.exe)),
    row('Force quit', () => api.mbDo('trayquit', a.exe), { danger: true }),
    '-',
    row('Show the Windows tray…', () => api.mbDo('tray'), { sub: 'for its own menu' }),
  ];
}
function wifiMenu() {
  return [
    { title: 'Wi-Fi', right: wifi.kind === 'wifi' ? 'On' : wifi.kind === 'cable' ? 'Ethernet' : 'Off' },
    wifi.kind === 'wifi' ? row(wifi.ssid, null, { info: true, sub: `${wifi.signal}%` }) : row(wifi.kind === 'cable' ? 'Connected by cable' : 'Not connected', null, { info: true }),
    '-',
    row('Quick settings', () => api.mbDo('quick'), { sub: 'Win+A' }),
    row('Network settings…', () => api.mbDo('uri', 'ms-settings:network-wifi')),
  ];
}
// "Headphones (soundcore R60i NC)" → the device's name, with its kind on the right.
function outName(o) {
  const m = /^(.*?) \((.*)\)$/.exec(o.name || '');
  return m ? { label: m[2], sub: m[1] } : { label: o.name || 'Output', sub: '' };
}
function volMenu() {
  const rows = [
    { title: 'Sound', right: vol ? (vol.m ? 'Muted' : `${vol.v}%`) : '' },
    { slider: true },
    row(vol && vol.m ? 'Unmute' : 'Mute', () => { api.mbDo('mute'); if (vol) vol = { ...vol, m: !vol.m }; renderStatus(); }, { keep: true }),
  ];
  // Output: every speaker / headphones / monitor sound; click one to switch to it (like a Mac).
  if (outputs.length) {
    rows.push('-', { title: 'Output' });
    for (const o of outputs) {
      const n = outName(o);
      rows.push(row(n.label, () => {
        if (o.def) return;
        outputs = outputs.map((x) => ({ ...x, def: x.id === o.id }));   // shows at once; the helper confirms
        api.mbDo('output', o.id);
      }, { keep: true, check: !!o.def, sub: n.sub }));
    }
  }
  rows.push('-', row('Sound settings…', () => api.mbDo('uri', 'ms-settings:sound')));
  return rows;
}
function batMenu() {
  if (!power) return [];
  const state = power.charging ? 'Charging' : power.ac ? 'Plugged in' : 'On battery';
  return [
    { title: 'Battery', right: `${Math.round(power.pct)}%` },
    row(`Power source: ${power.ac ? 'Power adapter' : 'Battery'}`, null, { info: true }),
    row(state, null, { info: true }),
    '-',
    row('Battery settings…', () => api.mbDo('uri', 'ms-settings:batterysaver')),
  ];
}
function startMenu() {
  return [
    { title: 'Isle' },
    row('Start', () => api.mbDo('start'), { sub: 'Win' }),
    row('Notifications & calendar', () => api.mbDo('notifs'), { sub: 'Win+N' }),
    '-',
    row('Show the Windows taskbar…', () => api.mbDo('tray'), { sub: '12 s' }),
    row('Dock & menu bar settings…', () => api.mbDo('settings', 'dock')),
    row('Turn menu bar off', () => api.set('menuBar', false)),
  ];
}

let popBuild = null;
let sliding = false;   // the volume slider is being dragged: don't rebuild the menu under the mouse
function refreshPop() { if (openFor && popBuild && !sliding) fillPop(typeof popBuild === 'function' ? popBuild() : popBuild); }
function fillPop(rows) {
  pop.innerHTML = '';
  for (const r of rows) {
    if (r === '-') { const d = document.createElement('div'); d.className = 'ps'; pop.appendChild(d); continue; }
    if (r.title) {
      const d = document.createElement('div'); d.className = 'ph-title';
      d.textContent = r.title;
      if (r.right) { const s = document.createElement('span'); s.textContent = r.right; d.appendChild(s); }
      pop.appendChild(d); continue;
    }
    if (r.slider) { pop.appendChild(makeSlider()); continue; }
    const d = document.createElement('div');
    d.className = 'pi' + (r.info ? ' info' : '') + (r.danger ? ' danger' : '') + ('check' in r ? ' choice' : '');
    if ('check' in r) { const c = document.createElement('i'); c.className = 'ck'; c.textContent = r.check ? '✓' : ''; d.appendChild(c); }
    const t = document.createElement('span'); t.textContent = r.label; d.appendChild(t);
    if (r.sub) { const s = document.createElement('span'); s.className = 'sub'; s.textContent = r.sub; d.appendChild(s); }
    if (r.run) d.addEventListener('click', () => { if (!r.keep) closePop(); r.run(); if (r.keep) refreshPop(); });
    pop.appendChild(d);
  }
}
function makeSlider() {
  const el = document.createElement('div');
  el.className = 'slider';
  el.innerHTML = '<b></b><i></i>';
  const paint = () => { el.querySelector('b').style.width = (vol ? (vol.m ? 0 : vol.v) : 0) + '%'; el.querySelector('i').innerHTML = volIcon(vol); };
  paint();
  let last = 0;
  const set = (e) => {
    const r = el.getBoundingClientRect();
    const v = Math.round(Math.max(0, Math.min(1, (e.clientX - r.left) / r.width)) * 100);
    vol = { v, m: false };
    paint();
    $('vol').innerHTML = volIcon(vol);
    if (Date.now() - last > 50) { last = Date.now(); api.mbDo('vol', v); }
  };
  el.addEventListener('pointerdown', (e) => { sliding = true; el.setPointerCapture(e.pointerId); set(e); });
  el.addEventListener('pointermove', (e) => { if (el.hasPointerCapture(e.pointerId)) set(e); });
  el.addEventListener('pointerup', (e) => { set(e); api.mbDo('vol', vol.v); sliding = false; });
  el.addEventListener('lostpointercapture', () => { sliding = false; });
  return el;
}
function openPop(btn, build) {
  if (openFor === btn) { closePop(); return; }
  document.querySelectorAll('.it.open').forEach((x) => x.classList.remove('open'));
  clearTimeout(shrinkT);
  api.mbTall(true);          // the window grows down to make room for the menu
  openFor = btn;
  popBuild = build;
  btn.classList.add('open');
  fillPop(typeof build === 'function' ? build() : build);
  pop.classList.add('on');
  const b = btn.getBoundingClientRect();
  const w = pop.offsetWidth;
  pop.style.left = Math.max(6, Math.min(window.innerWidth - w - 6, b.left + b.width / 2 - w / 2)) + 'px';
  reportHit();
}
let shrinkT = 0;
function closePop() {
  clearTimeout(closeT);
  clearTimeout(shrinkT);
  if (openFor) shrinkT = setTimeout(() => api.mbTall(false), 220);   // back to just the bar once the menu has faded
  pop.classList.remove('on');
  document.querySelectorAll('.it.open').forEach((x) => x.classList.remove('open'));
  openFor = null;
  popBuild = null;
  reportHit();
}
api.onMbHover((h) => { clearTimeout(closeT); if (!h && openFor) closeT = setTimeout(closePop, 900); });

/* ---------------------------------------------------------------- where the window takes the mouse */
let lastHit = '';
function reportHit() {
  const rects = [{ x: 0, y: 0, w: window.innerWidth, h: 26 }];
  if (openFor) { const r = pop.getBoundingClientRect(); rects.push({ x: Math.round(r.left - 4), y: 22, w: Math.round(r.width + 8), h: Math.round(r.bottom + 6 - 22) }); }
  const k = JSON.stringify(rects);
  if (k !== lastHit) { lastHit = k; api.mbHit(rects); }
}

/* ---------------------------------------------------------------- wiring */
$('start').addEventListener('click', () => { closePop(); api.mbDo('start'); });
$('start').addEventListener('contextmenu', (e) => { e.preventDefault(); openPop($('start'), startMenu); });
$('wifi').addEventListener('click', () => openPop($('wifi'), wifiMenu));
$('vol').addEventListener('click', () => openPop($('vol'), volMenu));
$('bat').addEventListener('click', () => openPop($('bat'), batMenu));
$('clock').addEventListener('click', () => { closePop(); api.mbDo('notifs'); });
document.addEventListener('contextmenu', (e) => e.preventDefault());

api.onMbSys((m) => {
  if (m.t === 'power') power = m;
  if (m.t === 'vol' && m.v >= 0 && !sliding) vol = { v: m.v, m: !!m.m };
  if (m.t === 'outputs') outputs = Array.isArray(m.list) ? m.list : [];
  renderStatus();
});
api.onMbWifi((w) => { wifi = w || { kind: 'none' }; renderStatus(); });
api.onMbTray((list) => { tray = Array.isArray(list) ? list : []; renderTray(); });
api.onDockApps((apps) => {
  const front = (apps || []).find((a) => a.active);
  $('app').textContent = front ? front.name : 'Desktop';
});
let introDone = false;
function apply(s) {
  S = s || {};
  document.documentElement.classList.toggle('noanim', S.macAnimations === false);
  if (!introDone) { introDone = true; if (S.macAnimations !== false) { const mb = document.getElementById('mb'); mb.classList.add('intro'); requestAnimationFrame(() => requestAnimationFrame(() => mb.classList.remove('intro'))); } }
  // Look: Dark / Light / Liquid glass (shared with the Dock)
  const look = S.barTheme === 'light' || S.barTheme === 'glass' ? S.barTheme : 'dark';
  document.documentElement.dataset.bar = look;
  document.documentElement.dataset.theme = look === 'light' ? 'white' : 'black';
  renderClock();
  renderStatus();
  renderTray();
}
api.onSettings(apply);
api.getSettings().then((s) => { apply(s); tick(); reportHit(); });
window.addEventListener('resize', reportHit);
