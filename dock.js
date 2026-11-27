// Isle Dock: pinned apps, open apps (dot under the icon), Downloads and Recycle Bin.
// Icons grow under the mouse like on a Mac. Click: open / switch to (or minimize) the app.
// Right-click: menu. Drag a pinned icon to move it; drag it up out of the Dock to remove it;
// drag an open app onto the pinned ones to keep it.
const api = window.isle;
const dockEl = document.getElementById('dock');
const bar = document.getElementById('bar');
const label = document.getElementById('label');

let S = {};
let running = [];            // open apps, from the helper (front-most first)
const seenOrder = [];        // open-but-not-pinned apps, in the order they appeared (stable)
let hovering = false;
let mouseX = null;
let drag = null;
let raf = 0;

const lc = (s) => String(s || '').toLowerCase();
const pinKey = (p) => lc(p.aumid || p.exe || p.lnk);
const size = () => Math.max(28, Math.min(96, Number(S.dockSize) || 40));
const amount = () => (S.dockMagnify === false ? 1 : Math.max(1, Math.min(2.5, Number(S.dockMagnifyAmount) || 1.6)));
// A pinned app and an open one are the same app when their app IDs match, else their programs.
function same(p, r) {
  if (p.aumid && r.aumid) return lc(p.aumid) === lc(r.aumid);
  if (p.exe && r.exe) return lc(p.exe) === lc(r.exe);
  return false;
}
const appsFolder = (aumid) => (aumid ? 'shell:AppsFolder\\' + aumid : '');

/* ---------------------------------------------------------------- icons (kept between starts) */
const icons = new Map();
try { for (const [k, v] of Object.entries(JSON.parse(localStorage.getItem('dock-icons') || '{}'))) icons.set(k, v); } catch { /* none yet */ }
let saveT = 0;
function saveIcons() {
  clearTimeout(saveT);
  saveT = setTimeout(() => {
    const keep = [...icons.entries()].slice(-80);
    try { localStorage.setItem('dock-icons', JSON.stringify(Object.fromEntries(keep))); } catch { /* full */ }
  }, 1500);
}
function setIcon(el, url) {
  let img = el.querySelector('img');
  if (!img) { img = document.createElement('img'); img.alt = ''; el.insertBefore(img, el.firstChild); }
  img.src = url;
}
// One request per icon at a time; if the helper is busy (e.g. right at start) and it fails,
// it's asked again a little later. Every icon in the Dock with that key gets it.
const iconWaiting = new Set();
function loadIcon(el, it, attempt = 0) {
  const paths = it.iconPaths.filter(Boolean);
  const key = paths.join('|');
  el._iconKey = key;
  if (!key) return;
  if (icons.has(key)) { setIcon(el, icons.get(key)); return; }
  if (iconWaiting.has(key)) return;
  iconWaiting.add(key);
  api.dockIcon(paths).then((url) => {
    iconWaiting.delete(key);
    if (url) {
      icons.set(key, url);
      saveIcons();
      for (const x of bar.children) if (x._iconKey === key) setIcon(x, url);
    } else if (attempt < 4) {
      setTimeout(() => { const x = [...bar.children].find((c) => c._iconKey === key); if (x) loadIcon(x, it, attempt + 1); }, 1500 * (attempt + 1));
    }
  });
}

/* ---------------------------------------------------------------- what's in the Dock */
function model() {
  const pins = Array.isArray(S.dockPins) ? S.dockPins : [];
  const used = new Set();
  const out = [];
  for (const p of pins) {
    const r = running.find((x) => !used.has(x.key) && same(p, x));
    if (r) used.add(r.key);
    out.push({
      kind: 'pin', key: pinKey(p), name: p.name || (r && r.name) || 'App',
      lnk: p.lnk || '', exe: p.exe || (r && r.exe) || '', aumid: p.aumid || (r && r.aumid) || '',
      runKey: r ? r.key : '', active: !!(r && r.active),
      iconPaths: [p.lnk, p.exe, appsFolder(p.aumid)],
    });
  }
  if (S.dockShowRunning !== false) {
    const rest = running.filter((r) => !used.has(r.key));
    for (const r of rest) if (!seenOrder.includes(r.key)) seenOrder.push(r.key);
    for (let i = seenOrder.length - 1; i >= 0; i--) if (!rest.some((r) => r.key === seenOrder[i])) seenOrder.splice(i, 1);
    const extra = seenOrder.map((k) => rest.find((r) => r.key === k)).filter(Boolean);
    if (extra.length) {
      out.push({ kind: 'sep', key: 'sep-open' });
      for (const r of extra) {
        out.push({
          kind: 'run', key: r.key, name: r.name, lnk: '', exe: r.exe || '', aumid: r.aumid || '',
          runKey: r.key, active: !!r.active,
          // Store apps: the package's icon first (their program file has only a blank one)
          iconPaths: /\\WindowsApps\\/i.test(r.exe || '') ? [appsFolder(r.aumid), r.exe] : [r.exe, appsFolder(r.aumid)],
        });
      }
    }
  }
  if (S.dockExtras !== false) {
    out.push({ kind: 'sep', key: 'sep-end' });
    out.push({ kind: 'special', special: 'downloads', key: '::downloads', name: 'Downloads', iconPaths: ['shell:Downloads'] });
    out.push({ kind: 'special', special: 'trash', key: '::trash', name: 'Recycle Bin', iconPaths: ['shell:RecycleBinFolder'] });
  }
  return out;
}

const anim = () => S.macAnimations !== false;

// Keyed update: icons that stay keep their element; new ones pop in, removed ones shrink away
// (Mac-style). Without animations the change is immediate.
let leaving = 0;
function render() {
  const next = model();
  const sig = next.map((i) => i.kind + ':' + i.key).join('|');
  if (sig !== bar.dataset.sig) {
    bar.dataset.sig = sig;
    const keep = new Map();
    for (const el of [...bar.children]) if (!el.classList.contains('leave') && !el.classList.contains('gap')) keep.set(el._key, el);
    const wanted = new Set(next.map((i) => i.kind + ':' + i.key));
    // shrink away the ones that are gone, then drop them
    for (const [k, el] of keep) {
      if (wanted.has(k)) continue;
      keep.delete(k);
      if (anim()) {
        el.classList.add('leave');
        el.style.width = '0px';
        leaving++;
        setTimeout(() => { el.remove(); leaving--; if (!leaving) { measure(); magnify(); } }, 260);
      } else el.remove();
    }
    let prev = null;
    for (const it of next) {
      const k = it.kind + ':' + it.key;
      let el = keep.get(k);
      if (!el) {
        el = document.createElement('div');
        el._key = k;
        if (it.kind === 'sep') el.className = 'sep';
        else { el.className = 'item'; el.innerHTML = '<i class="ph"></i><i class="dot"></i>'; loadIcon(el, it); el.style.width = el.style.height = size() + 'px'; el._w = size(); }
        if (anim() && bar.dataset.ready) { el.classList.add('enter'); setTimeout(() => el.classList.remove('enter'), 420); }
      }
      // place it right after the previous one (leaving icons stay where they were)
      const want = prev ? prev.nextSibling : bar.firstChild;
      if (want !== el) bar.insertBefore(el, want);
      prev = el;
    }
    bar.dataset.ready = '1';
    if (!leaving) measure();
    if (anim()) setTimeout(() => { if (!leaving) { measure(); magnify(); } }, 430);
  }
  for (const it of next) {
    const el = [...bar.children].find((c) => c._key === it.kind + ':' + it.key);
    if (!el) continue;
    el._item = it;
    if (it.kind === 'sep') continue;
    el.classList.toggle('running', !!it.runKey);
    el.classList.toggle('active', !!it.active);
    if (it.runKey) el.classList.remove('bounce');
  }
  dockEl.classList.toggle('empty', !next.length);
  magnify();
}

/* ---------------------------------------------------------------- growing icons */
// Each icon's centre with every icon at normal size (the growth is worked out from these, so
// it doesn't wobble as the icons themselves move).
function measure() {
  const s = size();
  const live = [...bar.children].filter((el) => !el.classList.contains('leave'));
  const saved = live.map((el) => el.style.width);
  for (const el of live) if (el.classList.contains('item')) { el.style.width = el.style.height = s + 'px'; }
  for (const el of live) { const r = el.getBoundingClientRect(); el._c = r.left + r.width / 2; }
  live.forEach((el, i) => { if (el.classList.contains('item')) el.style.width = el.style.height = saved[i] || s + 'px'; });
}
// Target size of each icon; with animations the icons ease towards it (smooth, like a Mac),
// otherwise they jump straight to it.
function targets() {
  const base = size();
  const amt = amount();
  const R = base * 3;
  const t = new Map();
  for (const el of bar.children) {
    if (!el.classList.contains('item') || el.classList.contains('leave')) continue;
    let w = base;
    if (mouseX !== null && amt > 1 && !(drag && drag.started) && !menuFor) {
      const d = Math.abs(mouseX - el._c);
      if (d < R) w = base * (1 + (amt - 1) * (1 + Math.cos(Math.PI * d / R)) / 2);
    }
    t.set(el, w);
  }
  return t;
}
let easing = 0;
function magnify() {
  const t = targets();
  let moving = false;
  for (const [el, w] of t) {
    let cur = typeof el._w === 'number' ? el._w : w;
    if (anim()) { cur += (w - cur) * 0.32; if (Math.abs(w - cur) < 0.25) cur = w; else moving = true; } else cur = w;
    el._w = cur;
    el.style.width = el.style.height = cur.toFixed(2) + 'px';
  }
  showLabel();
  reportHit();
  if (moving && !easing) easing = requestAnimationFrame(() => { easing = 0; magnify(); });
}
function frame() { if (!raf) raf = requestAnimationFrame(() => { raf = 0; magnify(); }); }

document.addEventListener('mousemove', (e) => {
  if (!hovering && !drag) return;
  mouseX = e.clientX;
  frame();
});
api.onDockHover((h) => {
  hovering = h;
  if (!h && !drag) { mouseX = null; magnify(); }   // eases back to normal size
  autoHideUpdate();
});

/* ---------------------------------------------------------------- show / hide (Mac-style) */
// Slides up when it appears; with "hide automatically" it slides down out of sight and comes
// back when the mouse touches the bottom edge of the screen.
let revealed = false;
let hideT = 0;
function autoHideUpdate() {
  clearTimeout(hideT);
  const busy = hovering || (drag && drag.started) || menuFor;
  if (S.dockAutoHide && !busy && revealed) hideT = setTimeout(() => { revealed = false; autoHideUpdate(); }, 650);
  dockEl.classList.toggle('away', !!S.dockAutoHide && !revealed && !busy);
  reportHit();
}
api.onDockReveal(() => { revealed = true; autoHideUpdate(); });

/* ---------------------------------------------------------------- name label */
function itemAt(x) {
  for (const el of bar.children) {
    if (!el.classList.contains('item')) continue;
    const r = el.getBoundingClientRect();
    if (x >= r.left - 3 && x <= r.right + 3) return el;
  }
  return null;
}
function showLabel() {
  const el = mouseX !== null && !(drag && drag.started) && !menuFor ? itemAt(mouseX) : null;
  if (!el || !el._item) { label.classList.remove('on'); return; }
  const r = el.getBoundingClientRect();
  label.textContent = el._item.name;
  label.style.left = (r.left + r.width / 2) + 'px';
  label.style.bottom = (window.innerHeight - r.top + 10) + 'px';
  label.classList.add('on');
}

/* ---------------------------------------------------------------- where the window takes the mouse */
let lastHit = '';
function reportHit() {
  const r = bar.getBoundingClientRect();
  let hit;
  if (dockEl.classList.contains('away')) hit = { x: 0, y: 0, w: 0, h: 0 };   // slid out of sight: let everything through
  else if (drag && drag.started) hit = { x: 0, y: 0, w: window.innerWidth, h: window.innerHeight };
  else if (menuFor) {
    // the Dock plus the open menu above it
    const m = menu.getBoundingClientRect();
    const left = Math.min(r.left, m.left) - 4, right = Math.max(r.right, m.right) + 4, top = Math.max(0, m.top - 6);
    hit = { x: Math.round(left), y: Math.round(top), w: Math.round(right - left), h: Math.round(window.innerHeight - top) };
  } else {
    const grow = hovering ? size() * (amount() - 1) + 40 : 0;   // room for grown icons + the label
    const top = Math.max(0, r.top - grow - 4);
    hit = { x: Math.round(r.left - 4), y: Math.round(top), w: Math.round(r.width + 8), h: Math.round(window.innerHeight - top) };
  }
  const k = JSON.stringify(hit);
  if (k !== lastHit) { lastHit = k; api.dockHit(hit); }
}

/* ---------------------------------------------------------------- click, menu, drag */
const payload = (it) => ({ name: it.name, lnk: it.lnk || '', exe: it.exe || '', aumid: it.aumid || '', runKey: it.runKey || '', special: it.special || '' });

function open(el) {
  const it = el._item;
  if (!it) return;
  if (!it.runKey && !it.special) {
    el.classList.add('bounce');                         // launching
    setTimeout(() => el.classList.remove('bounce'), 2600);
  }
  api.dockClick(payload(it));
}

/* right-click menu (Mac-style, drawn here) */
const menu = document.getElementById('menu');
let menuFor = null;
let menuCloseT = 0;
function closeMenu() {
  clearTimeout(menuCloseT);
  menu.classList.remove('on');
  menuFor = null;
  reportHit();
  autoHideUpdate();
}
function openMenu(el) {
  const it = el._item;
  const pins = Array.isArray(S.dockPins) ? S.dockPins : [];
  const pinned = it.kind === 'pin' || pins.some((p) => pinKey(p) === it.key);
  const rows = [{ title: it.name }, '-'];
  if (it.special) rows.push({ label: 'Open', run: () => api.dockClick(payload(it)) });
  else {
    rows.push({ label: it.runKey ? 'New window' : 'Open', run: () => api.dockLaunch(payload(it)) });
    rows.push({ label: 'Keep in Dock', check: pinned, run: () => (pinned ? api.dockUnpin(it.key) : api.dockPin(payload(it))) });
    if (it.exe || it.lnk) rows.push({ label: 'Show in folder', run: () => api.dockReveal(payload(it)) });
    if (it.runKey) rows.push('-', { label: 'Quit', danger: true, run: () => api.dockQuit(it.runKey) });
  }
  rows.push('-',
    { label: S.dockAutoHide ? 'Turn Hiding Off' : 'Turn Hiding On', run: () => api.set('dockAutoHide', !S.dockAutoHide) },
    { label: 'Turn Dock off', run: () => api.set('dockEnabled', false) },
    { label: 'Dock settings…', run: () => api.openSettings('dock') });
  menu.innerHTML = '';
  for (const r of rows) {
    const d = document.createElement('div');
    if (r === '-') { d.className = 'ms'; menu.appendChild(d); continue; }
    d.className = 'mi' + (r.title ? ' title' : '') + (r.danger ? ' danger' : '');
    d.innerHTML = '<span class="ck"></span><span class="tx"></span>';
    d.querySelector('.tx').textContent = r.title || r.label;
    if (r.check) d.querySelector('.ck').textContent = '✓';
    if (r.run) d.addEventListener('click', () => { closeMenu(); r.run(); });
    menu.appendChild(d);
  }
  const b = el.getBoundingClientRect();
  menu.classList.add('on');
  const w = menu.offsetWidth;
  const left = Math.max(6, Math.min(window.innerWidth - w - 6, b.left + b.width / 2 - w / 2));
  menu.style.left = left + 'px';
  menu.style.bottom = (window.innerHeight - b.top + 10) + 'px';
  menuFor = el;
  label.classList.remove('on');
  reportHit();
}
bar.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  const el = e.target.closest('.item');
  if (el && el._item) openMenu(el); else closeMenu();
});
// The menu closes once the mouse has left the Dock and the menu for a moment.
api.onDockHover((h) => {
  clearTimeout(menuCloseT);
  if (!h && menuFor) menuCloseT = setTimeout(closeMenu, 900);
});

bar.addEventListener('pointerdown', (e) => {
  if (e.button !== 0) return;
  if (menuFor) closeMenu();
  const el = e.target.closest('.item');
  if (!el) return;
  drag = { el, x0: e.clientX, y0: e.clientY, started: false };
  el.setPointerCapture(e.pointerId);
});
bar.addEventListener('pointermove', (e) => {
  if (!drag) return;
  const dx = e.clientX - drag.x0, dy = e.clientY - drag.y0;
  const kind = drag.el._item && drag.el._item.kind;
  if (!drag.started && Math.hypot(dx, dy) > 6 && (kind === 'pin' || kind === 'run')) {
    drag.started = true;
    drag.el.classList.add('drag');
    mouseX = null;
    magnify();
  }
  if (drag.started) {
    drag.el.style.transform = `translate(${dx}px, ${Math.min(0, dy)}px)`;
    drag.el.classList.toggle('out', kind === 'pin' && dy < -70);
  }
});
function endDrag(e, cancelled) {
  if (!drag) return;
  const d = drag;
  drag = null;
  d.el.style.transform = '';
  d.el.classList.remove('drag', 'out');
  if (!d.started) { if (!cancelled) open(d.el); return; }
  const it = d.el._item;
  const dx = e.clientX - d.x0, dy = e.clientY - d.y0;
  const pins = [...bar.children].filter((el) => el._item && el._item.kind === 'pin');
  if (it.kind === 'pin' && dy < -70) { api.dockUnpin(it.key); return; }             // dragged out: remove
  const dropX = d.el._c + dx;
  const others = pins.filter((el) => el !== d.el);
  const at = others.filter((el) => el._c < dropX).length;
  if (it.kind === 'pin') {
    const keys = others.map((el) => el._item.key);
    keys.splice(at, 0, it.key);
    api.dockReorder(keys);
  } else if (it.kind === 'run') {
    const last = pins.length ? pins[pins.length - 1]._c + size() : -Infinity;
    if (dropX <= last) api.dockPin({ ...payload(it), at });                         // dropped among the pinned: keep it
  }
  if (!hovering) { mouseX = null; magnify(); }
  autoHideUpdate();
}
bar.addEventListener('pointerup', (e) => endDrag(e, false));
bar.addEventListener('pointercancel', (e) => endDrag(e, true));

/* ---------------------------------------------------------------- drop shortcuts onto the Dock */
// Drag a shortcut, a program or a folder from the desktop / File Explorer onto the Dock: the
// pinned icons move apart where it will go (like a Mac) and it's pinned there when dropped.
let gap = null;
let gapAt = -1;
const pinnedEls = () => [...bar.children].filter((el) => el._item && el._item.kind === 'pin' && !el.classList.contains('leave'));
function dropIndexAt(x) { return pinnedEls().filter((el) => el._c < x).length; }
function showGap(at) {
  if (at === gapAt && gap) return;
  gapAt = at;
  if (!gap) {
    gap = document.createElement('div');
    gap.className = 'item gap';
    gap._key = 'gap';
    gap.style.width = gap.style.height = size() + 'px';
  }
  const pins = pinnedEls();
  const before = pins[at] || (pins.length ? pins[pins.length - 1].nextSibling : bar.firstChild);
  if (gap.nextSibling !== before || !gap.isConnected) bar.insertBefore(gap, before);
  reportHit();
}
function hideGap() {
  if (gap) { gap.remove(); gap = null; }
  gapAt = -1;
  magnify();
}
const hasFiles = (e) => e.dataTransfer && [...(e.dataTransfer.types || [])].includes('Files');
document.addEventListener('dragover', (e) => {
  e.preventDefault();   // (also stops the window from opening a dropped file)
  if (!hasFiles(e)) return;
  e.dataTransfer.dropEffect = 'link';
  if (S.dockAutoHide) { revealed = true; autoHideUpdate(); }
  showGap(dropIndexAt(e.clientX));
});
document.addEventListener('dragleave', (e) => { if (!e.relatedTarget) hideGap(); });   // left the window
document.addEventListener('drop', (e) => {
  e.preventDefault();
  const at = gapAt >= 0 ? gapAt : dropIndexAt(e.clientX);
  hideGap();
  if (!hasFiles(e)) return;
  const paths = [...e.dataTransfer.files].map((f) => api.pathForFile(f)).filter(Boolean);
  if (paths.length) api.dockDropFiles(paths, at);
});

/* ---------------------------------------------------------------- settings + start */
let introDone = false;
function apply(s) {
  const oldSize = size();
  S = s || {};
  document.documentElement.classList.toggle('noanim', S.macAnimations === false);
  // first appearance: slide up from the bottom edge
  if (!introDone) { introDone = true; if (anim()) { dockEl.classList.add('intro'); requestAnimationFrame(() => requestAnimationFrame(() => dockEl.classList.remove('intro'))); } }
  document.documentElement.dataset.theme = S.theme === 'white' ? 'white' : 'black';
  document.documentElement.style.setProperty('--s', size() + 'px');
  render();                      // (rebuilds only if what's in the Dock changed)
  if (size() !== oldSize) { measure(); magnify(); }
  autoHideUpdate();
}
api.onSettings(apply);
api.onDockApps((a) => { running = Array.isArray(a) ? a : []; render(); });
window.addEventListener('resize', () => { measure(); magnify(); });
api.getSettings().then(apply);
