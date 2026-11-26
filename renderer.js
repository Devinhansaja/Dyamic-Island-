const api = window.isle;
const $ = (id) => document.getElementById(id);
const notch = $('notch');
const panel = $('panel');
const root = document.documentElement;

const icon = (id) => `<svg viewBox="0 0 24 24"><use href="#${id}"/></svg>`;
const clamp = (v, a = 0, b = 1) => Math.max(a, Math.min(b, v));

let S = {};
const ui = { state: 'idle', tab: 'home', hovering: false, mode: 'normal', toastKind: null };
const appIcons = {};     // media app id -> icon data URL
let devices = [];
let weatherNow = null;
const T = {};

let media = { has: false };
let mediaAt = 0;
let art = { key: '', url: null };
let firstMedia = true;
let vol = null;          // { v: 0-100, m: bool }
let bright = null;       // 0-100
let battery = { level: 1, charging: true, present: false };
let clips = [];
let clipFilter = 'all';

/* ================================================================ state machine */

function setState(s) {
  // An eye break comes before everything; whatever else wants the notch waits until it ends.
  if (ui.eyes && s !== 'eyes') return;
  if (ui.state === s) return;
  ui.state = s;
  notch.dataset.state = s;
  if (s === 'expanded') renderExpanded();
  glassRate();
  requestAnimationFrame(reportRect);
}

// What the notch shows when nothing temporary (hover / HUD / toast) is going on.
function restingState() {
  if (ui.mode === 'game' && S.gameMode === 'stats') return 'game';
  if (call.ring) return 'ring';
  if (call.proc) return 'call';
  const timerLive = focus.active;
  const musicLive = media.has && media.playing && S.liveActivity;
  // Only music playing, "Line" look: the notch keeps its resting size with a progress line.
  const line = musicLive && !timerLive && !dlActive() && S.liveStyle !== 'full';
  if (line !== notch.classList.contains('live-line')) {
    notch.classList.toggle('live-line', line);
    if (line) renderRing();
  }
  if (dlActive()) return 'live';
  notch.classList.toggle('live-timer', timerLive && !musicLive && !dlActive());
  // Music and the focus timer at the same time: split into a pill plus a separate timer bubble.
  notch.classList.toggle('dual', timerLive && (musicLive || dlActive()));
  return musicLive || timerLive ? 'live' : 'idle';
}

function settle() {
  if (ui.hovering && ui.mode !== 'game' && ui.state === 'timer') return;
  if (ui.hovering && ui.mode !== 'game' && (S.expandOnHover || ui.state === 'expanded')) return setState('expanded');
  setState(restingState());
}

function expand(tab) {
  if (ui.mode === 'game' || ui.eyes) return;
  if (tab) setTab(tab);
  clearTimeout(T.toast);
  if (ui.state === 'hud') return; // the HUD settles into expanded when it ends
  // Only the focus timer is showing: open the timer card instead of the full panel.
  if (!tab && ui.state === 'live' && focus.active && notch.classList.contains('live-timer')) return setState('timer');
  setState('expanded');
}

/* Hit area reported to the main process (it toggles click-through). */
function reportRect() {
  const r = panel.getBoundingClientRect();
  const resting = ui.state === 'idle' || ui.state === 'live';
  const padX = resting ? 40 : 6;
  const h = resting ? Math.max(r.bottom + 6, 16) : r.bottom + 6;
  let left = r.left - padX;
  let right = r.right + padX;
  // The split timer bubble is part of the hover / click area too.
  if (notch.classList.contains('dual') && ui.state === 'live') right = Math.max(right, $('bubble').getBoundingClientRect().right + 8);
  api.hitRect({ x: Math.round(left), y: 0, w: Math.round(right - left), h: Math.round(h) });
}
new ResizeObserver(reportRect).observe(panel);
window.addEventListener('resize', reportRect);

api.onHover((h) => {
  ui.hovering = h;
  clearTimeout(T.enter);
  clearTimeout(T.leave);
  // While it rings, the pill stays put so Answer / Decline are easy to hit. (On a call the notch
  // opens as usual; the open panel has the call's mute / end buttons in its top bar.)
  if (ui.state === 'ring' || ui.eyes) return;
  // The volume / brightness HUD stays while the mouse is on it (to drag its bars), then goes.
  if (ui.state === 'hud') {
    clearTimeout(T.hud);
    if (!h && !ui.dragging) T.hud = setTimeout(endHud, 1200);
    return;
  }
  if (h) {
    if (S.expandOnHover && ui.state !== 'expanded') {
      T.enter = setTimeout(() => expand(), Math.max(0, (S.hoverDelay ?? 0.2) * 1000));
    }
  } else {
    T.leave = setTimeout(() => {
      if (document.activeElement && document.activeElement.id === 'dlUrl') return; // typing a link
      if (ui.state === 'expanded' || ui.state === 'timer') setState(restingState());
    }, 260);
  }
});

api.onMode(({ mode }) => {
  ui.mode = mode;
  glassUpdate();
  if (mode === 'game') { clearTimeout(T.hud); clearTimeout(T.toast); }
  if (ui.state !== 'hud' && ui.state !== 'toast') setState(restingState());
});

panel.addEventListener('click', () => {
  if (ui.eyes) return;
  // "Update available" pop-up: a click downloads and installs it.
  if (ui.state === 'toast' && ui.toastKind === 'update') { api.installUpdate(); return; }
  if (ui.state === 'toast' && ui.toastKind === 'dl-suggest' && ui.pendingUrl) {
    const url = ui.pendingUrl;
    ui.pendingUrl = null;
    clearTimeout(T.toast);
    setTab('downloads');
    setState('expanded');
    dlFetch(url);
    return;
  }
  if (ui.state === 'idle' || ui.state === 'live' || ui.state === 'call') expand();
  // Timer card: a click outside its buttons opens the full panel.
  else if (ui.state === 'timer') { setTab('widgets'); setState('expanded'); }
});
panel.addEventListener('contextmenu', (e) => {
  e.preventDefault();
  api.menu();
});

/* ================================================================ tabs */

function setTab(t) {
  if (t === 'clips' && !S.clipboardEnabled) t = 'home';
  ui.tab = t;
  notch.classList.toggle('tab-widgets', t === 'widgets');
  notch.classList.toggle('tab-clips', t === 'clips');
  notch.classList.toggle('tab-notifs', t === 'notifs');
  notch.classList.toggle('tab-downloads', t === 'downloads');
  if (t === 'notifs') { notifUnread = 0; renderBadge(); }
  if (t === 'home' && ui.state === 'expanded') api.refreshDevices();
  document.querySelectorAll('.tab[data-tab]').forEach((b) => b.classList.toggle('active', b.dataset.tab === t));
  document.querySelectorAll('.page').forEach((p) => p.classList.toggle('active', p.dataset.page === t));
  if (t === 'widgets') { renderClock(); renderCalendar(); }
}
document.querySelectorAll('.tab[data-tab]').forEach((b) => b.addEventListener('click', () => setTab(b.dataset.tab)));
$('gear').addEventListener('click', () => api.openSettings());

/* ================================================================ HUD */

const SEGMENTS = 30;
for (let i = 0; i < SEGMENTS; i++) $('hudSegs').appendChild(document.createElement('i'));

function volumeIcon(v, muted) {
  let s = icon('i-spk');
  if (muted || v === 0) s += icon('i-x');
  else {
    s += icon('i-w1');
    if (v >= 50) s += icon('i-w2');
  }
  return s;
}

// Displays whose brightness Isle can set (laptop panel and DDC/CI monitors), from the helper.
let monitors = [];
const brightDisplays = () => monitors.filter((m) => typeof m.v === 'number' && m.v >= 0);

// Draws the single bar (segments or plain bar) for a value.
function paintBar(value) {
  const on = Math.round((value / 100) * SEGMENTS);
  [...$('hudSegs').children].forEach((el, i) => {
    el.classList.toggle('on', i < on - 1 || (i === on - 1 && on === SEGMENTS));
    el.classList.toggle('edge', i === on - 1 && on !== SEGMENTS);
  });
  $('hudFill').style.width = value + '%';
}

// One row per display: icon, name, draggable bar, percent.
function renderHudRows(list) {
  const box = $('hudRows');
  if (box.childElementCount !== list.length || [...box.children].some((r, i) => r.dataset.id !== list[i].id)) {
    box.innerHTML = '';
    for (const m of list) {
      const row = document.createElement('div');
      row.className = 'hud-row';
      row.dataset.id = m.id;
      row.innerHTML = `<span class="hr-icon">${m.kind === 'laptop' ? devIcon('laptop') : icon('d-monitor')}</span>
        <span class="hr-name"></span><div class="hr-track"><div class="hr-bar"><b></b></div></div><span class="hr-pct"></span>`;
      row.querySelector('.hr-name').textContent = m.name;
      row.title = m.name;
      makeDraggable(row.querySelector('.hr-track'), (v) => setDisplay(m.id, v));
      box.appendChild(row);
    }
  }
  list.forEach((m, i) => {
    const row = box.children[i];
    row.querySelector('.hr-bar b').style.width = m.v + '%';
    row.querySelector('.hr-pct').textContent = m.v + '%';
  });
}

// Each display is set on its own. Commands go out at most ~16 a second (the newest value
// last), and for a moment after the mouse sets a display its bar ignores the helper's
// reports, so a late echo can't snap it back.
const dispSend = {};   // id -> { t, timer, v }
const dispTouched = {}; // id -> time the mouse last set it
function setDisplay(id, v) {
  const m = monitors.find((x) => x.id === id);
  if (m) m.v = v;
  dispTouched[id] = Date.now();
  const s = dispSend[id] || (dispSend[id] = { t: 0, timer: 0, v });
  s.v = v;
  const send = () => { s.timer = 0; s.t = Date.now(); api.cmd(`mbright ${id} ${s.v}`); };
  const wait = 60 - (Date.now() - s.t);
  if (wait <= 0) send();
  else if (!s.timer) s.timer = setTimeout(send, wait);
  showHud('brightness');
}

function showHud(kind) {
  if (ui.mode === 'game' || ui.eyes) return;
  const isVol = kind === 'volume';
  ui.hudKind = kind;
  const displays = isVol ? [] : brightDisplays();
  const multi = displays.length > 1;
  notch.classList.toggle('hud-multi', multi);
  if (multi) {
    // Several displays on: name + bar for each.
    notch.style.setProperty('--hud-rows', displays.length);
    $('hudIcon').innerHTML = icon('i-sun');
    renderHudRows(displays);
  } else {
    const value = isVol ? (vol.m ? 0 : vol.v) : displays.length ? displays[0].v : bright;
    $('hudIcon').innerHTML = isVol ? volumeIcon(vol.v, vol.m) : icon('i-sun');
    $('hudPct').textContent = isVol && vol.m ? 'Muted' : value + '%';
    $('hudTrack').title = !isVol && displays.length ? displays[0].name : '';
    paintBar(value);
  }
  setState('hud');
  clearTimeout(T.hud);
  // While the mouse is on the HUD it stays, so it can be adjusted.
  if (!ui.hovering && !ui.dragging) T.hud = setTimeout(endHud, 1500);
}
function endHud() { ui.state = 'hud-done'; if (!nextNotif()) settle(); }

// Click or drag along a bar; onValue gets 0-100 (at most once per frame).
function makeDraggable(track, onValue) {
  let raf = 0; let next = null;
  const valueAt = (e) => { const r = track.getBoundingClientRect(); return Math.round(clamp((e.clientX - r.left) / r.width) * 100); };
  const push = (v) => { next = v; if (!raf) raf = requestAnimationFrame(() => { raf = 0; onValue(next); }); };
  track.addEventListener('pointerdown', (e) => {
    e.stopPropagation();
    track.setPointerCapture(e.pointerId);
    ui.dragging = true;
    clearTimeout(T.hud);
    push(valueAt(e));
  });
  track.addEventListener('pointermove', (e) => { if (track.hasPointerCapture(e.pointerId)) push(valueAt(e)); });
  const up = (e) => {
    if (!ui.dragging) return;
    ui.dragging = false;
    if (track.hasPointerCapture(e.pointerId)) track.releasePointerCapture(e.pointerId);
    if (!ui.hovering && ui.state === 'hud') { clearTimeout(T.hud); T.hud = setTimeout(endHud, 1200); }
  };
  track.addEventListener('pointerup', up);
  track.addEventListener('pointercancel', up);
  track.addEventListener('click', (e) => e.stopPropagation());
}

makeDraggable($('hudTrack'), (v) => {
  if (ui.hudKind === 'brightness') {
    const d = brightDisplays();
    if (d.length === 1) { setDisplay(d[0].id, v); return; }
    bright = v; api.cmd('bright ' + v);
  } else { vol = { v, m: false }; api.cmd('vol ' + v); }
  showHud(ui.hudKind);
});

function onMonitors(d) {
  const old = monitors;
  monitors = Array.isArray(d.list) ? d.list : [];
  for (const m of monitors) {
    const mine = old.find((x) => x.id === m.id);
    if (mine && (ui.dragging || Date.now() - (dispTouched[m.id] || 0) < 2000)) m.v = mine.v;
  }
  if (d.show && S.brightnessHud && ui.state !== 'expanded') showHud('brightness');
  else if (ui.state === 'hud' && ui.hudKind === 'brightness' && !ui.dragging) showHud('brightness');
}
$('hudIcon').addEventListener('click', () => {
  if (ui.hudKind === 'volume' && vol) { vol = { ...vol, m: !vol.m }; api.cmd('mute'); showHud('volume'); }
});

// Scroll on the notch changes the volume.
panel.addEventListener('wheel', (e) => {
  const list = e.target.closest('.h-list');
  if (list && list.scrollWidth > list.clientWidth) { list.scrollLeft += e.deltaY; return; }
  if (!S.scrollVolume || !vol || vol.v < 0) return;
  e.preventDefault();
  const v = clamp(vol.v + (e.deltaY < 0 ? 2 : -2), 0, 100);
  vol = { v, m: false };
  api.cmd('vol ' + v);
  if (ui.state === 'expanded') renderVolume();
  else if (S.volumeHud) showHud('volume');
}, { passive: false });

/* ================================================================ toast */

function showToast({ kind = null, icon: ic, iconColor = '', iconBg = '', artKey = null, logo = null, avatar = null, image = null, app = '', title, sub = '', right = '', rightClass = '', ms = 3200 }) {
  if (ui.state === 'expanded' || ui.eyes) return false;
  if (ui.mode === 'game' && kind !== 'battery') return false; // don't interrupt games
  ui.toastKind = kind;
  ui.toastArtKey = artKey;
  notch.classList.toggle('toast-notif', kind === 'notif');
  const el = $('tIcon');
  el.className = 't-icon';
  el.style.background = iconBg;
  el.style.backgroundImage = '';
  el.style.color = iconColor;
  el.innerHTML = ic || '';
  if (artKey) {
    el.className = 't-icon art';
    paintArt(el, artKey);
  } else if (kind === 'notif') {
    // Sender photo when the app gives one (WhatsApp, Discord, ...), with the app logo as a badge.
    el.className = avatar ? 't-icon avatar' : 't-icon logo';
    el.style.background = '';
    if (avatar) {
      el.style.backgroundImage = `url("${avatar}")`;
      if (logo) el.innerHTML = `<i class="t-badge" style="background-image:url('${logo}')"></i>`;
    } else if (logo) el.style.backgroundImage = `url("${logo}")`;
    else el.innerHTML = icon('i-bell');
  }
  $('tApp').textContent = app;
  $('tTitle').textContent = title;
  $('tSub').textContent = sub;
  const rightEl = $('tRight');
  rightEl.className = 't-right ' + rightClass;
  rightEl.style.backgroundImage = '';
  if (image) {
    // Sticker / photo preview
    rightEl.textContent = '';
    rightEl.className = 't-right t-thumb';
    rightEl.style.backgroundImage = `url("${image}")`;
  } else {
    rightEl.textContent = right;
  }
  notch.classList.toggle('toast-image', !!image);
  setState('toast');
  clearTimeout(T.toast);
  T.toast = setTimeout(() => {
    ui.state = 'toast-done';
    if (!nextNotif()) settle();
  }, ms);
  return true;
}

/* ================================================================ notifications */

let notifList = [];
let notifUnread = 0;
const notifQueue = [];

function ago2(t) {
  const s = Math.round((Date.now() - t) / 1000);
  if (s < 45) return 'now';
  if (s < 3600) return Math.round(s / 60) + 'm';
  if (s < 86400) return Math.round(s / 3600) + 'h';
  return new Date(t).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

function notifToast(n) {
  return showToast({
    kind: 'notif',
    logo: n.logo,
    avatar: S.notifPreview ? n.avatar : null,
    image: S.notifPreview ? n.image : null,
    app: n.app,
    title: n.title || n.app,
    sub: S.notifPreview ? (n.body || (n.image ? 'Photo / sticker' : '')) : 'New notification',
    right: 'now',
    ms: n.image ? 5500 : 4500,
  });
}

// Show the next queued notification; returns true if one was shown.
function nextNotif() {
  while (notifQueue.length) {
    const n = notifQueue.shift();
    if (notifToast(n)) return true;
  }
  return false;
}

api.onNotif((n) => {
  if (!S.notifEnabled) return;
  if (n.incoming && ui.mode !== 'game') { startRing(n); return; } // incoming call: ring in the notch
  if (!(ui.state === 'expanded' && ui.tab === 'notifs')) notifUnread++;
  renderBadge();
  if (S.islandDnd) return; // do not disturb: keep it in the list, no pop-up
  if (ui.state === 'toast' && ui.toastKind === 'notif') { notifQueue.push(n); return; }
  if (ui.state === 'hud' || ui.eyes) { notifQueue.push(n); return; }   // shown after the HUD / eye break
  notifToast(n);
});

function renderBadge() {
  const b = $('notifBadge');
  b.textContent = notifUnread > 9 ? '9+' : String(notifUnread);
  b.classList.toggle('on', notifUnread > 0);
}

function renderNotifs(access) {
  const list = $('notifList');
  list.innerHTML = '';
  const page = document.querySelector('.p-notifs');
  page.classList.toggle('empty', !notifList.length);
  $('notifLabel').textContent = notifList.length ? `Notifications · ${notifList.length}` : 'Notifications';
  if (access && access !== 'Allowed') {
    $('notifEmptyTitle').textContent = 'Notification access is off';
    $('notifEmptyText').textContent = 'Allow it in Windows Settings → Privacy → Notifications.';
  }
  for (const n of notifList) {
    const el = document.createElement('div');
    el.className = 'n-item';
    el.innerHTML = '<div class="n-logo"></div><div class="n-text"><div class="n-title"></div><div class="n-body"></div></div><div class="n-meta"></div><button class="x-btn" title="Dismiss">×</button>';
    const logo = el.querySelector('.n-logo');
    const preview = S.notifPreview;
    if (preview && n.avatar) {
      logo.classList.add('avatar');
      logo.style.backgroundImage = `url("${n.avatar}")`;
      if (n.logo) logo.innerHTML = `<i class="t-badge" style="background-image:url('${n.logo}')"></i>`;
    } else if (n.logo) logo.style.backgroundImage = `url("${n.logo}")`;
    else logo.innerHTML = icon('i-bell');
    el.querySelector('.n-title').textContent = n.title || n.app;
    el.querySelector('.n-body').textContent = preview ? (n.body || (n.image ? 'Photo / sticker' : n.app)) : n.app;
    if (preview && n.image) {
      const th = document.createElement('div');
      th.className = 'n-thumb';
      th.style.backgroundImage = `url("${n.image}")`;
      el.insertBefore(th, el.querySelector('.n-meta'));
      el.classList.add('has-thumb');
    }
    el.querySelector('.n-meta').textContent = `${n.app} · ${ago2(n.at)}`;
    el.querySelector('.x-btn').addEventListener('click', () => api.notifs('remove', n.id));
    list.appendChild(el);
  }
}
let notifAccessState = null;
api.onNotifs((l) => { notifList = l || []; renderNotifs(notifAccessState); });
api.onNotifAccess((a) => { notifAccessState = a; renderNotifs(a); });
$('notifClear').addEventListener('click', () => api.notifs('clear'));

/* ================================================================ media */

function prettyApp(id = '') {
  if (!id) return '';
  let s = id.split('!').pop().replace(/\.exe$/i, '');
  s = s.split('.').pop();
  const known = { chrome: 'Chrome', msedge: 'Edge', spotify: 'Spotify', zunemusic: 'Media Player', firefox: 'Firefox', vlc: 'VLC', brave: 'Brave' };
  if (known[s.toLowerCase()]) return known[s.toLowerCase()];
  if (/^[0-9A-F]{16}$/i.test(s)) return 'Firefox';
  return s.charAt(0).toUpperCase() + s.slice(1);
}

function hueFor(text = '') {
  let h = 0;
  for (const ch of text) h = (h * 31 + ch.codePointAt(0)) % 360;
  return h;
}

function paintArt(el, key) {
  const url = art.key === key ? art.url : null;
  el.style.setProperty('--h', hueFor(key));
  el.classList.toggle('has-img', !!url);
  el.style.backgroundImage = url ? `url("${url}")` : '';
  if (!el.querySelector('svg')) el.innerHTML = icon('i-note');
}

function curPos() {
  if (!media.has) return 0;
  let p = media.pos || 0;
  if (media.playing) p += (Date.now() - mediaAt) * (media.rate || 1);
  return Math.min(p, media.dur || p);
}

function fmt(ms) {
  const s = Math.max(0, Math.floor(ms / 1000));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}

function renderProgress() {
  const dur = media.dur || 0;
  const ok = media.has && dur > 1000;
  $('musicPage').classList.toggle('no-timeline', !ok);
  if (!ok) return;
  const p = curPos();
  $('sFill').style.width = clamp(p / dur) * 100 + '%';
  $('mPos').textContent = fmt(p);
  $('mRem').textContent = '-' + fmt(dur - p);
}

function renderVolume() { /* volume lives in the HUD and on scroll */ }

// Song name in the small notch. If it doesn't fit, it scrolls from right to left
// (two copies side by side, so the loop is seamless), at a steady reading speed.
let liveTitleText = '';
let liveTitleWidth = 0;
function renderLiveTitle(force = false) {
  const box = $('lTitleBox');
  const text = media.has ? [media.title, media.artist].filter(Boolean).join(' · ') : '';
  const width = box.clientWidth;
  if (!force && text === liveTitleText && width === liveTitleWidth) return;
  liveTitleText = text;
  liveTitleWidth = width;
  box.classList.remove('scroll');
  box.innerHTML = '<span class="one"></span>';
  const one = box.firstChild;
  one.textContent = text;
  if (!text || !width || one.scrollWidth <= width) return;
  box.classList.add('scroll');
  box.innerHTML = '<div class="track"><span></span><span></span></div>';
  const [a, b] = box.querySelectorAll('span');
  a.textContent = text;
  b.textContent = text;
  const shift = a.offsetWidth + 36; // text + gap = one full loop
  const track = box.firstChild;
  track.style.setProperty('--shift', `-${shift}px`);
  track.style.setProperty('--dur', `${(shift / 32).toFixed(1)}s`); // ~32 px/s while moving
  // Scroll one full loop, rest 3.5 s (nothing is redrawn while resting), then go again.
  const run = () => { if (track.isConnected) track.classList.add('run'); };
  track.addEventListener('animationend', () => {
    track.classList.remove('run');
    clearTimeout(T.ticker);
    T.ticker = setTimeout(run, 3500);
  });
  clearTimeout(T.ticker);
  T.ticker = setTimeout(run, 1500);
}
new ResizeObserver(() => renderLiveTitle()).observe($('lTitleBox'));

// The player's own logo (Spotify, Brave, ...) sits on the corner of the album art.
function renderLogo() {
  const url = media.has ? appIcons[media.app] : null;
  const el = $('mLogo');
  el.classList.toggle('on', !!url);
  el.style.backgroundImage = url ? `url("${url}")` : '';
  el.title = media.has ? prettyApp(media.app) : '';
}
api.onAppIcon(({ app, url }) => { appIcons[app] = url; renderLogo(); });

function renderMedia() {
  const has = !!media.has;
  notch.classList.toggle('playing', has && !!media.playing);
  $('musicPage').classList.toggle('empty', !has);
  if (has) {
    $('mTitle').textContent = media.title || 'Unknown';
    $('mArtist').textContent = media.artist || media.album || '';
    paintArt($('mArt'), media.key);
    paintArt($('lArt'), media.key);
  }
  renderLogo();
  renderLiveTitle();
  renderProgress();
  renderRing();
  if (ui.state === 'idle' || ui.state === 'live' || ui.state === 'game') setState(restingState());
  else restingState();
}

function onMedia(m) {
  const prev = media;
  media = m;
  mediaAt = Date.now();
  const changedTrack = m.has && m.key !== prev.key;
  renderMedia();
  if (changedTrack && !firstMedia && m.playing && S.trackAlert) {
    showToast({ kind: 'track', artKey: m.key, title: m.title, sub: m.artist || prettyApp(m.app), ms: 3000 });
  }
  firstMedia = false;
}

function onArt(a) {
  art = { key: a.key, url: a.url };
  if (media.key === a.key) {
    paintArt($('mArt'), a.key);
    paintArt($('lArt'), a.key);
  }
  if (ui.state === 'toast' && ui.toastArtKey === a.key) paintArt($('tIcon'), a.key);
}

document.querySelectorAll('.mp-buttons button').forEach((b) => {
  b.addEventListener('click', () => {
    const cmd = b.dataset.cmd;
    api.cmd(cmd);
    if (cmd === 'play' && media.has) {
      media.pos = curPos();
      mediaAt = Date.now();
      media.playing = !media.playing;
      notch.classList.toggle('playing', media.playing);
    }
  });
});

$('scrub').addEventListener('click', (e) => {
  if (!media.dur) return;
  const r = $('scrub').getBoundingClientRect();
  const ms = clamp((e.clientX - r.left) / r.width) * media.dur;
  media.pos = ms;
  mediaAt = Date.now();
  renderProgress();
  api.cmd('seek ' + Math.round(ms / 1000));
});

// Progress ring in the small notch: fills as the song / video plays.
const RING_LEN = 47.12; // 2πr for r = 7.5
function renderRing() {
  const ring = $('mRing');
  const dur = media.dur || 0;
  const known = media.has && dur > 1000;
  ring.classList.toggle('indeterminate', !known);
  if (known) $('mRingFg').style.strokeDashoffset = RING_LEN * (1 - clamp(curPos() / dur));
  renderLine(known ? clamp(curPos() / dur) : null);
}

// "Line" look: a thin progress line inside the resting-size notch. It glides (2 s linear
// transition, the same as the update step), and jumps without gliding when a song starts over.
let lineAt = 0;
function renderLine(f) {
  const track = $('lnTrack');
  const fill = $('lnFill');
  track.classList.toggle('indeterminate', f === null);
  if (f === null) return;
  if (f < lineAt - 0.02) {
    fill.style.transition = 'none';
    fill.style.transform = `scaleX(${f})`;
    void fill.offsetWidth;
    fill.style.transition = '';
  } else fill.style.transform = `scaleX(${f})`;
  lineAt = f;
}

setInterval(() => {
  if (ui.state === 'expanded' && ui.tab === 'home') renderProgress();
}, 250);
// The small ring moves well under a pixel a second, so a step every 2 s looks the same and
// lets the notch sit still (no redraws) in between.
setInterval(() => { if (ui.state === 'live' && !dlActive()) renderRing(); }, 2000);

/* ================================================================ updates */

// A new version on GitHub: a pop-up you can click to install; then its download progress.
api.onUpdate((u) => {
  if (!u) return;
  const base = { kind: 'update', icon: icon('i-download'), iconColor: '#0a84ff', iconBg: 'rgba(10,132,255,.18)' };
  if (u.state === 'available' && u.announce) {
    showToast({ ...base, title: `Isle ${u.version} is available`, sub: 'Click to update · settings are kept', ms: 9000 });
  } else if (u.state === 'available' && u.failed) {
    showToast({ ...base, title: 'Update could not be downloaded', sub: 'Click to try again', iconColor: '#ff9f0a', ms: 6000 });
  } else if (u.state === 'downloading') {
    if (ui.state === 'toast' && ui.toastKind === 'update') {
      $('tTitle').textContent = `Updating to Isle ${u.version}`;
      $('tSub').textContent = u.pct >= 100 ? 'Installing… Isle will restart' : `Downloading… ${u.pct || 0}%`;
      clearTimeout(T.toast);
      T.toast = setTimeout(() => { ui.state = 'toast-done'; if (!nextNotif()) settle(); }, 15000);
    } else if (!u.pct) {
      showToast({ ...base, title: `Updating to Isle ${u.version}`, sub: 'Downloading…', ms: 15000 });
    }
  }
});

/* ================================================================ eye break (20-20-20) */

// Typed one after another, a few seconds each.
const EYE_TIPS = [
  'Look away from your screen.',
  'Focus on something 20 feet away.',
  'Blink slowly and relax your eyes.',
];
const eyeT = { tick: 0, type: 0, end: 0, total: 0 };

// Types `text` a letter at a time.
function eyeType(text) {
  clearTimeout(eyeT.type);
  const el = $('eType');
  let i = 0;
  const step = () => {
    el.textContent = text.slice(0, ++i);
    if (i < text.length) eyeT.type = setTimeout(step, 38);
  };
  el.textContent = '';
  eyeT.type = setTimeout(step, 120);
}

function startEyeBreak(seconds = 20) {
  if (ui.eyes) return;
  // Whatever the notch was doing stops: open panel, HUD, pop-ups (queued notifications come after).
  for (const k of ['hud', 'toast', 'enter', 'leave']) clearTimeout(T[k]);
  ui.eyes = true;
  setState('eyes');
  eyeT.total = seconds * 1000;
  eyeT.end = Date.now() + eyeT.total;
  const v = $('eVideo');
  try { v.currentTime = 0; v.play().catch(() => {}); } catch {}
  const tipEvery = eyeT.total / EYE_TIPS.length;
  let shown = -1;
  const tick = () => {
    const left = Math.max(0, eyeT.end - Date.now());
    $('eLeft').textContent = Math.ceil(left / 1000) + 's';
    $('eBar').style.width = (left / eyeT.total) * 100 + '%';
    const tip = Math.min(EYE_TIPS.length - 1, Math.floor((eyeT.total - left) / tipEvery));
    if (tip !== shown) { shown = tip; eyeType(EYE_TIPS[tip]); }
    if (left <= 0) endEyeBreak();
  };
  clearInterval(eyeT.tick);
  eyeT.tick = setInterval(tick, 250);
  tick();
}

function endEyeBreak() {
  if (!ui.eyes) return;
  clearInterval(eyeT.tick);
  clearTimeout(eyeT.type);
  $('eVideo').pause();
  ui.eyes = false;
  ui.state = 'eyes-done';
  api.eyesDone();
  // Back to normal: anything that waited (notifications, a call, the game strip) shows now.
  if (!nextNotif()) settle();
}
api.onEyes((d) => startEyeBreak((d && d.seconds) || 20));

/* ================================================================ device batteries */

const DEV_ICON = {
  earbuds: 'd-earbuds', headphones: 'd-headphones', gamepad: 'd-gamepad', mouse: 'd-mouse', keyboard: 'd-keyboard',
  watch: 'd-watch', phone: 'd-phone', tablet: 'd-tablet', speaker: 'd-speaker',
};
// Order of the battery rings: laptop first, then earbuds / controller / phone / TV / tablet.
const DEV_ORDER = ['earbuds', 'headphones', 'gamepad', 'phone', 'tv', 'tablet', 'watch', 'mouse', 'keyboard', 'speaker'];
const DEV_C = 125.66; // ring circumference (r = 20)
// Picture icons (assets/devices/*.png, used as a mask so they take the theme's colour).
const DEV_IMG = new Set(['earbuds', 'gamepad', 'laptop', 'tv', 'phone']);
function devIcon(kind) {
  if (DEV_IMG.has(kind)) return `<i class="dico" style="-webkit-mask-image:url('assets/devices/${kind}.png')"></i>`;
  return icon(DEV_ICON[kind] || 'd-earbuds');
}

// One battery ring: the coloured arc is the charge; hovering shows the percentage.
// wired: a USB / receiver controller that doesn't tell the PC its battery level (full grey ring).
function devRing(kind, name, pct, charging, wired) {
  const el = document.createElement('div');
  el.className = 'dev-ring';
  const known = typeof pct === 'number';
  const low = known && pct <= 20 && !charging;
  el.classList.toggle('low', low);
  el.classList.toggle('charging', !!charging);
  el.classList.toggle('na', !known && !wired);
  el.classList.toggle('wired', !known && !!wired);
  el.innerHTML = `<svg class="dr-arc" viewBox="0 0 48 48"><circle class="bg" cx="24" cy="24" r="20"/><circle class="fg" cx="24" cy="24" r="20"/></svg>
    <span class="dr-icon">${devIcon(kind)}</span><span class="dr-pct">${known ? pct + '%' : wired ? 'USB' : '—'}</span>${charging ? `<span class="dr-bolt">${icon('i-bolt')}</span>` : ''}`;
  el.querySelector('.fg').style.strokeDashoffset = DEV_C * (1 - (known ? clamp(pct, 0, 100) : wired ? 100 : 0) / 100);
  el.title = known ? `${name} · ${pct}%${charging ? ' · charging' : ''}`
    : wired ? `${name} · connected (this controller doesn't report its battery)` : `${name} · battery not reported`;
  return el;
}

function renderDevices() {
  const list = $('devList');
  list.innerHTML = '';
  if (battery.present) {
    list.appendChild(devRing('laptop', 'This PC', Math.round(battery.level * 100), battery.charging));
  }
  const sorted = [...devices].sort((a, b) => DEV_ORDER.indexOf(a.kind) - DEV_ORDER.indexOf(b.kind));
  for (const d of sorted.slice(0, battery.present ? 3 : 4)) {
    list.appendChild(devRing(d.kind, d.name, d.battery, !!d.charging, !!d.wired));
  }
  list.dataset.count = list.children.length;
  if (!list.children.length) list.innerHTML = '<div class="dev-none">No Bluetooth devices connected</div>';
}
let kindCache = {};         // device name → type, remembered between runs
try { kindCache = JSON.parse(localStorage.getItem('isle-dev-kinds') || '{}') || {}; } catch {}
let phoneLinkSeen = null;   // name of the phone last seen through Phone Link
let devicesFirst = true;    // the first list at start-up only sets the baseline
api.onDevices((d) => {
  devices = Array.isArray(d) ? d : [];
  renderDevices();
  // A phone that comes or goes through Phone Link (not Bluetooth) gets its own pop-up.
  const pl = devices.find((x) => x.via === 'phonelink');
  const plName = pl ? pl.name : null;
  if (!devicesFirst && plName !== phoneLinkSeen) {
    if (plName) onBluetooth({ added: [plName], removed: [] });
    else onBluetooth({ added: [], removed: [phoneLinkSeen] });
  }
  devicesFirst = false;
  phoneLinkSeen = plName;
  // A "connected" pop-up still showing: add the battery level once Windows reports it.
  // Remember each device's type, so its next pop-up has the right icon straight away.
  for (const x of devices) if (x.name && x.kind) kindCache[x.name] = x.kind;
  try { localStorage.setItem('isle-dev-kinds', JSON.stringify(kindCache)); } catch {}
  if (ui.state === 'toast' && ui.toastKind === 'bt' && ui.btName) {
    const dev = devices.find((x) => x.name === ui.btName);
    if (dev) $('tIcon').innerHTML = devIcon(dev.kind);
    if (dev && typeof dev.battery === 'number') {
      $('tRight').textContent = dev.battery + '%';
      $('tRight').className = 't-right ' + (dev.battery <= 20 ? 'red' : 'green');
    }
  }
});

// Guess the device type from its name (same rules as devices.ps1), for the icon.
function devKind(name) {
  const known = devices.find((x) => x.name === name);
  if (known) return known.kind;
  if (kindCache[name]) return kindCache[name];
  const n = (name || '').toLowerCase();
  if (/controller|gamepad|xbox|dualsense|dualshock|joy-con|8bitdo/.test(n)) return 'gamepad';
  if (/\btv\b|television|bravia|fire ?tv|chromecast|roku|webos|tizen|smart ?view/.test(n)) return 'tv';
  if (/ipad|\btab\b|tablet|galaxy tab|mediapad|matepad|\bpad\b/.test(n)) return 'tablet';
  if (/phone|galaxy [asmz]\d|iphone|pixel|redmi|oneplus|xiaomi|oppo|vivo|realme|huawei|honor|nokia/.test(n)) return 'phone';
  if (/mouse|mx master|trackpad/.test(n)) return 'mouse';
  if (/keyboard|keys/.test(n)) return 'keyboard';
  if (/watch|band|fit/.test(n)) return 'watch';
  if (/speaker|soundlink|jbl flip|charge|boom/.test(n)) return 'speaker';
  if (/headphone|headset|wh-1000|airpods max|\bq\d{2}\b|space one|life q/.test(n)) return 'headphones';
  return 'earbuds';
}

// Bluetooth device connected / disconnected → pop-up in the notch.
function onBluetooth(d) {
  if (!S.btAlert) return;
  const added = d.added || [];
  const removed = d.removed || [];
  const on = added.length > 0;
  const name = on ? added[0] : removed[0];
  if (!name) return;
  const more = added.length + removed.length - 1;
  const dev = devices.find((x) => x.name === name);
  const pct = on && dev && typeof dev.battery === 'number' ? dev.battery : null;
  const shown = showToast({
    kind: 'bt',
    icon: devIcon(devKind(name)),
    iconColor: on ? '#0a84ff' : 'var(--muted)',
    iconBg: on ? 'rgba(10,132,255,.18)' : 'var(--card-2)',
    title: name,
    sub: (on ? 'Connected' : 'Disconnected') + (more > 0 ? ` · +${more} more` : ''),
    right: pct !== null ? pct + '%' : '',
    rightClass: pct !== null ? (pct <= 20 ? 'red' : 'green') : '',
    ms: 3000,
  });
  if (shown !== false) ui.btName = on ? name : null;
}

/* ================================================================ video downloads */

let dlItems = [];
let dlInfoData = null;
let dlBusy = false;

const dlActive = () => dlItems.some((d) => d.status === 'downloading' || d.status === 'processing');

function fmtDur(s) {
  s = Math.round(s || 0);
  const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), ss = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}

function dlMsg(text, cls = '') {
  const el = $('dlMsg');
  el.textContent = text;
  el.className = 'dl-msg ' + cls;
}

async function dlFetch(url) {
  url = (url || '').trim();
  if (!url) return;
  $('dlUrl').value = url;
  dlBusy = true;
  $('dlGo').disabled = true;
  $('dlInfo').classList.remove('on');
  dlMsg('Reading the link…', 'busy');
  const info = await api.dlInfo(url);
  dlBusy = false;
  $('dlGo').disabled = false;
  if (!info || !info.ok) { dlMsg((info && info.error) || 'Could not read this link', 'err'); return; }
  dlMsg('');
  dlInfoData = info;
  $('dlThumb').style.backgroundImage = info.thumb ? `url("${info.thumb}")` : '';
  $('dlTitle').textContent = info.title;
  $('dlSub').textContent = [info.site, info.uploader, info.duration ? fmtDur(info.duration) : ''].filter(Boolean).join(' · ');
  const opts = $('dlOpts');
  opts.innerHTML = '';
  const mb = (b) => (b ? (b >= 1073741824 ? (b / 1073741824).toFixed(1) + ' GB' : Math.max(1, Math.round(b / 1048576)) + ' MB') : '');
  const name = (h) => (h >= 2160 ? '4K' : h >= 1440 ? '2K' : `${h}p`);
  const add = (label, sub, o, main = false) => {
    const b = document.createElement('button');
    b.className = 'dl-opt' + (main ? ' main' : '');
    b.innerHTML = '<span class="q"></span><small></small>';
    b.querySelector('.q').textContent = label;
    b.querySelector('small').textContent = sub;
    b.title = 'Download ' + label;
    b.addEventListener('click', () => dlGo(o));
    opts.appendChild(b);
  };
  // Every quality the video offers (highest first), with its approximate size.
  const qs = (info.qualities || []).filter((q) => q.height >= 144);
  if (!qs.length) add('MP4', 'best', { kind: 'video' }, true);
  qs.forEach((q, i) => add(name(q.height) + (q.fps >= 50 ? q.fps : ''), mb(q.bytes) || 'MP4', { kind: 'video', height: q.height }, i === 0));
  add('MP3', mb(info.audioBytes) || 'audio', { kind: 'audio' });
  $('dlInfo').classList.add('on');
}

async function dlGo(o) {
  if (!dlInfoData) return;
  await api.dlStart({ url: dlInfoData.url, title: dlInfoData.title, thumb: dlInfoData.thumb, ...o });
  $('dlInfo').classList.remove('on');
  $('dlUrl').value = '';
  dlInfoData = null;
  dlMsg('Downloading… you can close the notch, it keeps going.');
  setTimeout(() => { if ($('dlMsg').textContent.startsWith('Downloading')) dlMsg(''); }, 4000);
}

function renderDownloads() {
  const list = $('dlList');
  list.innerHTML = '';
  if (!dlItems.length) list.innerHTML = '<div class="dl-empty">Nothing downloaded yet.</div>';
  for (const d of dlItems) {
    const el = document.createElement('div');
    el.className = 'dl-item';
    el.innerHTML = `<div class="dl-ithumb"><b></b></div><div class="dl-itext"><div class="dl-ititle"></div><div class="dl-istatus"></div><div class="dl-ibar"><b></b></div></div><div class="dl-iact"></div>`;
    if (d.thumb) el.querySelector('.dl-ithumb').style.backgroundImage = `url("${d.thumb}")`;
    el.querySelector('.dl-ithumb b').textContent = d.label;
    el.querySelector('.dl-ititle').textContent = d.title;
    const st = el.querySelector('.dl-istatus');
    const bar = el.querySelector('.dl-ibar');
    const act = el.querySelector('.dl-iact');
    const btn = (html, title, fn) => { const b = document.createElement('button'); b.innerHTML = html; b.title = title; b.addEventListener('click', fn); act.appendChild(b); };
    if (d.status === 'downloading') {
      st.innerHTML = `<b class="dl-pct">${Math.round(d.percent)}%</b>`;
      st.append([d.speed, d.eta ? `${d.eta} left` : ''].filter(Boolean).map((x) => ' · ' + x).join(''));
      bar.querySelector('b').style.width = d.percent + '%';
      btn('×', 'Cancel', () => api.dl('cancel', d.id));
    } else if (d.status === 'processing') {
      st.textContent = d.kind === 'audio' ? 'Converting to MP3…' : 'Joining video and audio…';
      bar.querySelector('b').style.width = '100%';
      btn('×', 'Cancel', () => api.dl('cancel', d.id));
    } else {
      bar.style.display = 'none';
      if (d.status === 'done') {
        st.textContent = 'Downloaded';
        st.classList.add('ok');
        btn(icon('i-play'), 'Open', () => api.dl('open', d.id));
        btn(icon('i-folder2'), 'Show in folder', () => api.dl('reveal', d.id));
      } else {
        st.textContent = d.status === 'cancelled' ? 'Cancelled' : (d.error || 'Failed');
        st.classList.add('err');
        btn('×', 'Remove', () => api.dl('remove', d.id));
      }
    }
    list.appendChild(el);
  }
  const active = dlItems.filter((d) => d.status === 'downloading' || d.status === 'processing');
  const badge = $('dlBadge');
  // One download: show its percent on the tab; several: how many are running.
  badge.textContent = active.length === 1 ? Math.round(active[0].percent) + '%' : active.length ? String(active.length) : '';
  badge.classList.toggle('on', active.length > 0);
  renderDlLive();
}

// While something downloads, the small notch shows the arrow, the percent and a filling ring.
function renderDlLive() {
  const active = dlItems.filter((d) => d.status === 'downloading' || d.status === 'processing');
  notch.classList.toggle('live-dl', active.length > 0);
  if (active.length) {
    const pct = active.reduce((a, d) => a + (d.percent || 0), 0) / active.length;
    $('lDlPct').textContent = Math.round(pct) + '%';
    $('mRing').classList.remove('indeterminate');
    $('mRingFg').style.strokeDashoffset = RING_LEN * (1 - clamp(pct / 100));
  }
  if (ui.state === 'idle' || ui.state === 'live') setState(restingState());
}

api.onDownloads((list) => { dlItems = list || []; renderDownloads(); });
api.onDownloadDone((d) => {
  showToast({
    icon: icon('i-check'), iconColor: '#30d158', iconBg: 'rgba(48,209,88,.16)',
    title: d.kind === 'audio' ? 'Audio downloaded' : 'Video downloaded',
    sub: d.title, ms: 4000,
  });
});

// A video link was copied anywhere: offer to download it.
api.onVideoLink((url) => {
  if (ui.state === 'expanded' && ui.tab === 'downloads') { if (!$('dlUrl').value) dlFetch(url); return; }
  ui.pendingUrl = url;
  showToast({ kind: 'dl-suggest', icon: icon('i-download'), iconColor: '#fff', iconBg: 'var(--accent)', title: 'Video link copied', sub: 'Click to download it', ms: 6000 });
});

$('dlForm').addEventListener('submit', (e) => { e.preventDefault(); if (!dlBusy) dlFetch($('dlUrl').value); });
$('dlPaste').addEventListener('click', async () => { const t = await api.dlClipboard(); if (t) dlFetch(t); });
$('dlFolder').addEventListener('click', () => api.dl('reveal', -1));
$('dlClear').addEventListener('click', () => api.dl('clear'));
// Keep the notch open while typing a link.
$('dlUrl').addEventListener('blur', () => { if (!ui.hovering) setTimeout(() => { if (!ui.hovering && document.activeElement !== $('dlUrl') && ui.state === 'expanded') setState(restingState()); }, 300); });

/* ================================================================ calls */
/* Incoming call (from the app's call notification) and on-a-call (a calling app has the mic
   open). Answer / Decline / End press that app's own buttons through the helper; if a button
   can't be found, the app's window is brought to the front instead. Mute mutes the PC's mic. */

const CALL_NAMES = {
  whatsapp: 'WhatsApp', 'whatsapp.root': 'WhatsApp', 'ms-teams': 'Teams', teams: 'Teams', phoneexperiencehost: 'Phone Link',
  discord: 'Discord', zoom: 'Zoom', telegram: 'Telegram', messenger: 'Messenger', signal: 'Signal', skype: 'Skype',
  viber: 'Viber', slack: 'Slack', webex: 'Webex', ciscocollabhost: 'Webex', lync: 'Skype',
};
const CALL_PROCS = {
  WhatsApp: 'WhatsApp|WhatsApp.Root', Teams: 'ms-teams|Teams', 'Phone Link': 'PhoneExperienceHost', Discord: 'Discord',
  Zoom: 'Zoom', Telegram: 'Telegram', Messenger: 'Messenger', Signal: 'Signal', Skype: 'Skype', Viber: 'Viber',
  Slack: 'slack', Webex: 'webex|CiscoCollabHost',
};
const call = { proc: '', since: 0, muted: false, ring: null, ringTimer: null, lastTarget: '' };

const callName = (proc) => CALL_NAMES[(proc || '').toLowerCase()] || proc || 'Call';
function procsFor(appName) {
  const k = Object.keys(CALL_PROCS).find((x) => (appName || '').toLowerCase().includes(x.toLowerCase()));
  return k ? CALL_PROCS[k] : String(appName || '').replace(/\s+/g, '');
}
function logoFor(appName) {
  const n = notifList.find((x) => x.logo && (x.app || '').toLowerCase().includes((appName || '').toLowerCase()));
  return n ? n.logo : null;
}

function callPress(procs, kind) {
  call.lastTarget = procs;
  api.cmd(`callbtn ${procs} ${kind}`);
}

function renderCall() {
  const name = callName(call.proc);
  $('cApp').textContent = name;
  const s = call.since ? Math.floor((Date.now() - call.since) / 1000) : 0;
  const time = `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
  $('cTime').textContent = time;
  $('qCallTime').textContent = time;
  $('qCall').title = `${name} call`;
  notch.classList.toggle('call-on', !!call.proc);
  const logo = logoFor(name);
  const ic = $('cIcon');
  ic.classList.toggle('logo', !!logo);
  ic.style.backgroundImage = logo ? `url("${logo}")` : '';
  notch.classList.toggle('mic-muted', call.muted);
}
setInterval(() => { if (ui.state === 'call' || (ui.state === 'expanded' && call.proc)) renderCall(); }, 1000);

function callRefresh() {
  if (ui.state !== 'expanded' && ui.state !== 'hud') setState(restingState());
}

function startRing(n) {
  clearTimeout(call.ringTimer);
  call.ring = { name: n.title || n.app, app: n.app, avatar: n.avatar, logo: n.logo, procs: procsFor(n.app) };
  const av = $('rAvatar');
  const pic = n.avatar || n.logo;
  av.style.backgroundImage = pic ? `url("${pic}")` : '';
  av.innerHTML = pic ? '' : icon('i-phone');
  $('rName').textContent = call.ring.name;
  $('rSub').textContent = `Incoming call · ${n.app}`;
  call.ringTimer = setTimeout(endRing, 45000); // stop ringing if nothing happens
  setState('ring');
}
function endRing() {
  clearTimeout(call.ringTimer);
  call.ring = null;
  callRefresh();
}

$('rAnswer').addEventListener('click', (e) => {
  e.stopPropagation();
  if (!call.ring) return;
  callPress(call.ring.procs, 'answer');
  $('rSub').textContent = 'Answering…';
  call.ringTimer = setTimeout(endRing, 4000);
});
$('rDecline').addEventListener('click', (e) => {
  e.stopPropagation();
  if (!call.ring) return;
  callPress(call.ring.procs, 'decline');
  endRing();
});
function toggleCallMute(e) {
  e.stopPropagation();
  call.muted = !call.muted; // the helper confirms right after
  renderCall();
  api.cmd('micmute');
}
function endCall(e) {
  e.stopPropagation();
  callPress(procsFor(callName(call.proc)) || call.proc, 'end');
}
$('cMute').addEventListener('click', toggleCallMute);
$('cEnd').addEventListener('click', endCall);
$('qCallMute').addEventListener('click', toggleCallMute);
$('qCallEnd').addEventListener('click', endCall);

function onCall(d) {
  const was = call.proc;
  call.proc = d.app || '';
  call.muted = !!d.muted;
  if (call.proc && !was) { call.since = Date.now(); if (call.ring) { clearTimeout(call.ringTimer); call.ring = null; } }
  if (!call.proc) call.since = 0;
  renderCall();
  callRefresh();
}

// Incoming call shown in the app's own pop-up window (WhatsApp does this instead of a notification).
function onRingWindow(d) {
  if (!d.app) {
    if (call.ring && call.ring.fromWin) endRing();
    return;
  }
  if (call.proc || ui.mode === 'game' || !S.notifEnabled) return;
  if (call.ring && !call.ring.fromWin) return; // already ringing from the notification
  const app = callName(d.app);
  const raw = String(d.title || '').trim();
  // Window titles are usually "Name", "Voice call - Name" or just the app's name.
  let who = raw.replace(/\b(incoming|voice|video|audio|group)?\s*call(ing)?\b/gi, '').replace(/whatsapp( business| beta)?/gi, '')
    .replace(/^[\s\-–—|:·]+|[\s\-–—|:·]+$/g, '').trim();
  if (d.name) who = d.name;
  if (!who) who = app;
  startRing({ title: who, app, logo: logoFor(app) });
  call.ring.fromWin = true;
  const kind = /video/i.test(raw) ? 'Video call' : /voice|audio/i.test(raw) ? 'Voice call' : 'Incoming call';
  $('rSub').textContent = `${kind} · ${app}`;
  clearTimeout(call.ringTimer); // stays until the window goes away
}

// The app's button couldn't be found: open the app so the user can tap it there.
function onCallButton(d) {
  if (d.ok) return;
  if (call.lastTarget) api.cmd(`focusapp ${call.lastTarget}`);
  const what = d.kind === 'answer' ? 'answer' : d.kind === 'decline' ? 'decline' : 'end the call';
  showToast({ kind: 'battery', icon: icon('i-phone'), iconColor: '#fff', iconBg: 'var(--card-2)', title: `Couldn't ${what} from here`, sub: 'Opened the app so you can do it there', ms: 3500 });
}

/* ================================================================ quick toggles + privacy */

let privacy = { mic: [], cam: [] };

function renderQuick() {
  $('qDnd').classList.toggle('on', !!S.islandDnd);
  $('qSilent').classList.toggle('on', !!(vol && vol.m));
}
$('qDnd').addEventListener('click', () => api.set('islandDnd', !S.islandDnd));
$('qSilent').addEventListener('click', () => {
  if (!vol) return;
  vol = { ...vol, m: !vol.m };
  api.cmd('mute');
  renderQuick();
});

function renderPrivacy() {
  const mic = privacy.mic || [];
  const cam = privacy.cam || [];
  notch.classList.toggle('mic-on', mic.length > 0);
  notch.classList.toggle('cam-on', cam.length > 0);
  notch.classList.toggle('priv-on', mic.length + cam.length > 0);
  const parts = [];
  if (cam.length) parts.push(`<span class="c">${icon('i-cam')}</span><span class="c"></span>`);
  if (mic.length) parts.push(`<span class="m">${icon('i-mic')}</span><span class="m"></span>`);
  const label = $('privLabel');
  label.innerHTML = parts.join('');
  const names = label.querySelectorAll('span:not(:has(svg))');
  let i = 0;
  if (cam.length) names[i++].textContent = cam.join(', ');
  if (mic.length) names[i++].textContent = mic.join(', ');
  label.classList.toggle('on', parts.length > 0);
  const tip = [cam.length ? `Camera: ${cam.join(', ')}` : '', mic.length ? `Microphone: ${mic.join(', ')}` : ''].filter(Boolean).join('\n');
  label.title = tip;
  requestAnimationFrame(reportRect);
}

/* ================================================================ system messages */

api.onSys((d) => {
  if (d.t === 'privacy') { privacy = { mic: d.mic || [], cam: d.cam || [] }; renderPrivacy(); return; }
  if (d.t === 'power') { onPower(d); return; }
  if (d.t === 'call') { onCall(d); return; }
  if (d.t === 'callbtn') { onCallButton(d); return; }
  if (d.t === 'ringwin') { onRingWindow(d); return; }
  if (d.t === 'bt') { onBluetooth(d); return; }
  if (d.t === 'media') onMedia(d);
  else if (d.t === 'art') onArt(d);
  else if (d.t === 'vol') {
    if (d.v < 0) return;
    const prev = vol;
    vol = { v: d.v, m: !!d.m };
    renderVolume();
    renderQuick();
    // Windows' own pop-up may be hidden, so show the HUD even over the open panel.
    if (prev && (prev.v !== vol.v || prev.m !== vol.m) && S.volumeHud) showHud('volume');
  } else if (d.t === 'bright') {
    const prev = bright;
    bright = d.v;
    // With the display list known, the helper's "monitors" message drives the HUD instead
    // (the laptop panel's own level can be off-screen / parked while a monitor is used).
    if (brightDisplays().length) return;
    if (prev !== null && prev !== bright && S.brightnessHud && ui.state !== 'expanded') showHud('brightness');
  } else if (d.t === 'monitors') {
    onMonitors(d);
  }
});

/* ================================================================ in-game performance strip */

function load(el, v, warn, hot) {
  el.classList.toggle('warn', v >= warn && v < hot);
  el.classList.toggle('hot', v >= hot);
}

function rate(bps) {
  if (bps < 1024) return Math.round(bps) + 'B';
  if (bps < 1048576) return Math.round(bps / 1024) + 'K';
  return (bps / 1048576).toFixed(1) + 'M';
}

api.onPerf((p) => {
  $('gCpu').textContent = p.cpu + '%';
  load($('gCpu'), p.cpu, 70, 90);
  $('gRam').textContent = p.ram + '%';
  load($('gRam'), p.ram, 80, 92);
  if (p.gpu != null) {
    $('gGpu').textContent = p.gpu + '%';
    load($('gGpu'), p.gpu, 85, 97);
  }
  $('gTemp').textContent = p.temp != null ? ` ${p.temp}°` : '';
  if (p.temp != null) load($('gTemp'), p.temp, 75, 85);
  notch.classList.toggle('no-vram', p.vram == null);
  if (p.vram != null) $('gVram').textContent = (p.vram / 1024).toFixed(1) + 'G';
  $('gDown').textContent = '↓' + rate(p.down || 0);
  $('gUp').textContent = '↑' + rate(p.up || 0);
});

/* ================================================================ battery */

function renderBattery() {
  const pct = Math.round(battery.level * 100);
  notch.classList.toggle('low', pct <= (S.lowThreshold || 20) && !battery.charging);
  $('batBar').style.width = pct + '%';
  $('batVal').textContent = battery.present ? pct + '%' : 'AC';
  $('topBatt').innerHTML = battery.present
    ? (battery.charging ? icon('i-bolt') : '') + `<span>${pct}%</span>`
    : '';
  renderDevices();
}

// Battery state comes from Windows through the helper ({t:'power'}): plugged in, charging, percent.
// The first reading only fills in the battery; later changes show the charger / low battery pop-ups.
let power = null;
function onPower(p) {
  const prev = power;
  power = p;
  battery = { level: Math.max(0, p.pct) / 100, charging: !!p.ac, present: !!p.battery && p.pct >= 0 };
  renderBattery();
  if (!prev || !battery.present) return;
  const pct = Math.round(battery.level * 100);
  if (p.ac !== prev.ac && S.chargingAlert) {
    if (p.ac) {
      showToast({ kind: 'battery', icon: icon('i-bolt'), iconColor: '#30d158', iconBg: 'rgba(48,209,88,.16)', title: 'Charging', sub: 'Power connected', right: pct + '%', rightClass: 'green', ms: 2800 });
    } else {
      showToast({ kind: 'battery', icon: icon('i-plug'), title: 'On battery', sub: 'Charger disconnected', right: pct + '%', ms: 2800 });
    }
  }
  const th = S.lowThreshold || 20;
  if (S.lowBatteryAlert && !p.ac && prev.pct > th && p.pct <= th) {
    showToast({ kind: 'battery', icon: icon('i-batlow'), iconColor: '#ff453a', iconBg: 'rgba(255,69,58,.16)', title: 'Low battery', sub: 'Plug in your charger soon', right: pct + '%', rightClass: 'red' });
  }
}

/* ================================================================ clock */

function renderClock() {
  const now = new Date();
  let h = now.getHours();
  const m = String(now.getMinutes()).padStart(2, '0');
  let ampm = '';
  if (!S.clock24) { ampm = h >= 12 ? 'PM' : 'AM'; h = h % 12 || 12; }
  else h = String(h).padStart(2, '0');
  $('clkTime').textContent = `${h}:${m}`;
  $('clkSec').textContent = S.clockSeconds ? String(now.getSeconds()).padStart(2, '0') : '';
  $('clkAmPm').textContent = ampm;
  $('clkDate').textContent = now.toLocaleDateString(undefined, { weekday: 'long', month: 'long', day: 'numeric' });
  const secs = now.getHours() * 3600 + now.getMinutes() * 60 + now.getSeconds();
  $('clkDay').style.width = (secs / 864) + '%';
  const tz = Intl.DateTimeFormat().resolvedOptions().timeZone || '';
  $('clkLabel').textContent = tz ? tz.split('/').pop().replace(/_/g, ' ') : 'Local time';
}
setInterval(() => { if (ui.state === 'expanded' && ui.tab === 'widgets') renderClock(); }, 1000);

/* ================================================================ calendar */

let lastDay = '';
function renderCalendar() {
  const now = new Date();
  const key = now.toDateString();
  if (key === lastDay) return;
  lastDay = key;
  $('calDay').textContent = now.getDate();
  $('calWd').textContent = now.toLocaleDateString(undefined, { weekday: 'short' });
  $('calMon').textContent = now.toLocaleDateString(undefined, { month: 'short' });
  const start = new Date(now.getFullYear(), 0, 1);
  const week = Math.ceil(((now - start) / 86400000 + start.getDay() + 1) / 7);
  $('calWeek').textContent = `W${week}`;

  const monday = new Date(now);
  monday.setDate(now.getDate() - ((now.getDay() + 6) % 7));
  const wk = $('week');
  wk.innerHTML = '';
  for (let i = 0; i < 7; i++) {
    const d = new Date(monday);
    d.setDate(monday.getDate() + i);
    const el = document.createElement('div');
    el.className = 'day' + (d.toDateString() === key ? ' today' : d < now ? ' past' : '');
    el.innerHTML = `<div class="wd">${d.toLocaleDateString(undefined, { weekday: 'narrow' })}</div><div class="dn">${d.getDate()}</div>`;
    wk.appendChild(el);
  }
}
setInterval(renderCalendar, 30000);

/* ================================================================ weather */

const WX = {
  sun: '<svg viewBox="0 0 36 36"><circle cx="18" cy="18" r="7" fill="#ffcc33"/><g stroke="#ffcc33" stroke-width="2.4" stroke-linecap="round"><path d="M18 3v4M18 29v4M3 18h4M29 18h4M7.4 7.4l2.8 2.8M25.8 25.8l2.8 2.8M7.4 28.6l2.8-2.8M25.8 10.2l2.8-2.8"/></g></svg>',
  moon: '<svg viewBox="0 0 36 36"><path d="M24 26.5A11 11 0 0 1 15.2 6.6 11.5 11.5 0 1 0 29.5 21a11 11 0 0 1-5.5 5.5z" fill="#c9d4ff"/></svg>',
  partly: '<svg viewBox="0 0 36 36"><circle cx="13" cy="13" r="6" fill="#ffcc33"/><g stroke="#ffcc33" stroke-width="2" stroke-linecap="round"><path d="M13 2.5v3M2.5 13h3M5.6 5.6l2 2M20.4 5.6l-2 2"/></g><path d="M12 30a6 6 0 0 1-.6-12 8 8 0 0 1 15.3 2.3A5 5 0 0 1 27 30z" fill="#e9edf5"/></svg>',
  cloud: '<svg viewBox="0 0 36 36"><path d="M10 29a7 7 0 0 1-.7-14 9 9 0 0 1 17.4 2.5A5.8 5.8 0 0 1 26.5 29z" fill="#d5dbe6"/></svg>',
  fog: '<svg viewBox="0 0 36 36"><path d="M10 22a6 6 0 0 1-.6-12 8 8 0 0 1 15.3 2.3A5 5 0 0 1 25 22z" fill="#cfd5df"/><g stroke="#aab3c2" stroke-width="2.4" stroke-linecap="round"><path d="M6 27h24M9 32h18"/></g></svg>',
  rain: '<svg viewBox="0 0 36 36"><path d="M10 22a6.5 6.5 0 0 1-.6-13 8.5 8.5 0 0 1 16.3 2.4A5.3 5.3 0 0 1 25.5 22z" fill="#cfd6e3"/><g stroke="#5eb0ff" stroke-width="2.4" stroke-linecap="round"><path d="M12 26l-2 5M19 26l-2 5M26 26l-2 5"/></g></svg>',
  snow: '<svg viewBox="0 0 36 36"><path d="M10 22a6.5 6.5 0 0 1-.6-13 8.5 8.5 0 0 1 16.3 2.4A5.3 5.3 0 0 1 25.5 22z" fill="#dfe5ee"/><g fill="#ffffff"><circle cx="11" cy="28" r="1.8"/><circle cx="18" cy="31" r="1.8"/><circle cx="25" cy="28" r="1.8"/></g></svg>',
  storm: '<svg viewBox="0 0 36 36"><path d="M10 21a6.5 6.5 0 0 1-.6-13 8.5 8.5 0 0 1 16.3 2.4A5.3 5.3 0 0 1 25.5 21z" fill="#b9c0cc"/><path d="M19 21l-5 7h4l-2 6 7-9h-4l2-4z" fill="#ffcc33"/></svg>',
};

function wxInfo(code, day) {
  if (code === 0) return [day ? WX.sun : WX.moon, 'Clear'];
  if (code === 1) return [day ? WX.sun : WX.moon, 'Mostly clear'];
  if (code === 2) return [WX.partly, 'Partly cloudy'];
  if (code === 3) return [WX.cloud, 'Cloudy'];
  if (code === 45 || code === 48) return [WX.fog, 'Fog'];
  if (code >= 51 && code <= 57) return [WX.rain, 'Drizzle'];
  if ((code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return [WX.rain, code >= 80 ? 'Showers' : 'Rain'];
  if ((code >= 71 && code <= 77) || code === 85 || code === 86) return [WX.snow, 'Snow'];
  if (code >= 95) return [WX.storm, 'Thunderstorm'];
  return [WX.cloud, '—'];
}

function renderWeather(w) {
  weatherNow = w;
  const ok = w && w.state === 'ok';
  $('weather').classList.toggle('empty', !ok);
  $('homeWeather').classList.toggle('empty', !ok);
  if (!ok) {
    const msg = !w || w.state === 'unset' ? 'Add your city to see the weather'
      : w.state === 'nolocation' ? 'Turn on Location in Windows, or set a city'
      : w.state === 'notfound' ? `Couldn't find "${w.city}"`
      : w.state === 'loading' ? 'Loading weather…'
      : 'Weather is offline right now';
    $('wxMsg').textContent = msg;
    $('hwMsg').textContent = msg;
    $('wxSet').style.display = w && w.state === 'loading' ? 'none' : '';
    return;
  }
  const [svg, text] = wxInfo(w.code, w.day);
  $('wxIcon').innerHTML = svg;
  $('wxTemp').textContent = `${w.temp}°`;
  $('wxCond').textContent = `${text} · feels ${w.feels}°`;
  $('wxCity').textContent = w.city;
  $('wxMeta').textContent = `H ${w.hi}°  L ${w.lo}°  ·  ${w.humidity}% humidity`;
  $('hwIcon').innerHTML = svg;
  $('hwTemp').textContent = `${w.temp}°`;
  $('hwCond').textContent = text;
  // Today's high / low, small, under the condition.
  $('hwHi').textContent = `↑ ${w.hi}°`;
  $('hwLo').textContent = `↓ ${w.lo}°`;
  $('hwCity').textContent = w.city;
}
$('wxSet').addEventListener('click', () => api.openSettings('widgets'));
$('hwMsg').addEventListener('click', () => api.openSettings('widgets'));
api.onWeather(renderWeather);

/* ================================================================ focus timer */

// active = a session has been started (running or paused); it ends when stopped or finished.
const focus = { total: 25 * 60, left: 25 * 60, running: false, active: false, endAt: 0 };
const RING = 175.9;
const MINI = 50.27;

function renderFocus() {
  const m = Math.floor(focus.left / 60);
  const s = String(Math.floor(focus.left % 60)).padStart(2, '0');
  const text = `${m}:${s}`;
  $('fTime').textContent = text;
  $('lTimer').textContent = text;
  $('bTime').textContent = text;
  $('tTime').textContent = text;
  const f = focus.total ? clamp(focus.left / focus.total, 0, 1) : 0;
  $('fRing').style.strokeDashoffset = RING * (1 - f);
  $('lRing').querySelector('.fg').style.strokeDashoffset = MINI * (1 - f);
  $('bRingFg').style.strokeDashoffset = MINI * (1 - f);
  // Timer card: the coloured line around the edge is the time left.
  $('tEdge').style.strokeDasharray = `${(f * 100).toFixed(2)} 100`;
  const end = new Date(Date.now() + focus.left * 1000);
  $('tEnd').textContent = focus.running
    ? end.toLocaleTimeString([], { hour: 'numeric', minute: '2-digit', hour12: !S.clock24 })
    : 'Paused';
  // Last minute: the timer turns red and pulses.
  notch.classList.toggle('focus-ending', focus.running && focus.left <= 60);
  notch.classList.toggle('focus-paused', focus.active && !focus.running);
  $('fSub').textContent = focus.running ? 'Stay focused…' : focus.active ? 'Paused' : `${Math.round(focus.total / 60)} min session`;
  $('focus').classList.toggle('running', focus.running);
  $('focus').classList.toggle('active', focus.active);
}

function focusStop() {
  focus.running = false;
  focus.active = false;
  focus.left = focus.total;
  renderFocus();
  if (ui.state === 'live' || ui.state === 'timer') setState(restingState());
  else restingState();
}

function focusTick() {
  if (!focus.running) return;
  focus.left = Math.max(0, Math.round((focus.endAt - Date.now()) / 1000));
  if (focus.left === 0) {
    focusStop();
    showToast({ icon: icon('i-check'), iconColor: '#30d158', iconBg: 'rgba(48,209,88,.16)', title: 'Focus session done', sub: 'Time for a short break', ms: 5000 });
    return;
  }
  renderFocus();
}
setInterval(focusTick, 1000);

function focusToggle() {
  focus.running = !focus.running;
  if (focus.running) { focus.active = true; focus.endAt = Date.now() + focus.left * 1000; }
  renderFocus();
  restingState();
}
$('fPlay').addEventListener('click', focusToggle);
$('tPlay').addEventListener('click', (e) => { e.stopPropagation(); focusToggle(); });
$('tStop').addEventListener('click', (e) => { e.stopPropagation(); focusStop(); });
$('fStop').addEventListener('click', focusStop);
// The split timer bubble opens the timer card.
$('bubble').addEventListener('click', () => setState('timer'));
function adjustFocus(delta) {
  const mins = clamp(Math.round(focus.total / 60) + delta, 5, 180);
  const diff = mins * 60 - focus.total;
  focus.total = mins * 60;
  focus.left = clamp(focus.left + diff, 0, focus.total);
  if (focus.running) focus.endAt = Date.now() + focus.left * 1000;
  api.set('focusMinutes', mins);
  renderFocus();
}
$('fMinus').addEventListener('click', () => adjustFocus(-5));
$('fPlus').addEventListener('click', () => adjustFocus(5));

/* ================================================================ system stats */

api.onStats((s) => {
  $('cpuBar').style.width = s.cpu + '%';
  $('cpuVal').textContent = s.cpu + '%';
  $('ramBar').style.width = s.ram + '%';
  $('ramVal').textContent = s.ram + '%';
  if (s.disk != null) {
    $('diskBar').style.width = s.disk + '%';
    $('diskVal').textContent = s.disk + '%';
  }
  const gb = (n) => (n / 1073741824).toFixed(1);
  const h = Math.floor(s.uptime / 3600);
  const free = s.diskFree != null ? ` · ${gb(s.diskFree)} GB free on C:` : '';
  $('sysFoot').textContent = `RAM ${gb(s.ramUsed)} / ${gb(s.ramTotal)} GB · up ${h}h ${Math.floor((s.uptime % 3600) / 60)}m${free}`;
});

/* ================================================================ clipboard */

function ago(t) {
  const s = Math.round((Date.now() - t) / 1000);
  if (s < 45) return 'now';
  if (s < 3600) return Math.round(s / 60) + 'm';
  if (s < 86400) return Math.round(s / 3600) + 'h';
  return Math.round(s / 86400) + 'd';
}

function renderClips() {
  const list = $('clipList');
  list.innerHTML = '';
  const shown = clips.filter((c) => clipFilter === 'all' || c.kind === clipFilter);
  document.querySelector('.p-clips').classList.toggle('empty', !shown.length);
  const labels = { text: ['i-text', 'Text'], link: ['i-link', 'Link'], image: ['i-image', 'Image'] };
  for (const c of shown) {
    const el = document.createElement('div');
    el.className = 'clip ' + c.kind;
    el.title = 'Click to copy';
    const [ic, label] = labels[c.kind];
    el.innerHTML = `<div class="c-head">${icon(ic)}<span>${label}</span><em>${ago(c.at)}</em></div><button class="x-btn" title="Remove">×</button>`;
    if (c.kind === 'image') {
      const img = new Image();
      img.src = c.thumb;
      el.appendChild(img);
      el.querySelector('.c-head span').textContent = `${c.w} × ${c.h}`;
    } else {
      const body = document.createElement('div');
      body.className = 'c-body';
      body.textContent = c.text;
      el.appendChild(body);
    }
    el.addEventListener('click', () => {
      api.clips('copy', c.id);
      el.classList.add('copied');
      setTimeout(() => el.classList.remove('copied'), 900);
    });
    el.querySelector('.x-btn').addEventListener('click', (e) => { e.stopPropagation(); api.clips('remove', c.id); });
    list.appendChild(el);
  }
}
document.querySelectorAll('#clipChips .chip').forEach((b) => b.addEventListener('click', () => {
  clipFilter = b.dataset.f;
  document.querySelectorAll('#clipChips .chip').forEach((x) => x.classList.toggle('on', x === b));
  renderClips();
}));
$('clipClear').addEventListener('click', () => api.clips('clear'));

/* ================================================================ liquid glass */

// Displacement map: red/green push pixels near the edges inward, like the rim of a lens.
(function buildRefractionMap() {
  const n = 128;
  const band = 0.2;
  const cv = document.createElement('canvas');
  cv.width = cv.height = n;
  const ctx = cv.getContext('2d');
  const img = ctx.createImageData(n, n);
  const edge = (t) => {
    if (t < band) return Math.pow(1 - t / band, 2);
    if (t > 1 - band) return -Math.pow(1 - (1 - t) / band, 2);
    return 0;
  };
  for (let y = 0; y < n; y++) {
    for (let x = 0; x < n; x++) {
      const i = (y * n + x) * 4;
      img.data[i] = 128 + edge(x / (n - 1)) * 127;
      img.data[i + 1] = 128 + edge(y / (n - 1)) * 127 * 0.6;
      img.data[i + 2] = 128;
      img.data[i + 3] = 255;
    }
  }
  ctx.putImageData(img, 0, 0);
  $('lgMap').setAttribute('href', cv.toDataURL());
})();

const glass = { stream: null, video: null, src: null, ctx: $('glassCanvas').getContext('2d'), starting: false };

function glassWanted() {
  return S.theme === 'glass' && ui.mode === 'normal' && !(ui.state === 'idle' && S.idleStyle === 'hidden');
}

async function startGlass() {
  if (glass.stream || glass.starting) return;
  glass.starting = true;
  try {
    const src = await api.glassSource();
    if (!src) return;
    glass.src = src;
    glass.stream = await navigator.mediaDevices.getUserMedia({
      audio: false,
      video: { mandatory: { chromeMediaSource: 'desktop', chromeMediaSourceId: src.id, maxFrameRate: 24, maxWidth: Math.round(src.width * src.scale), maxHeight: Math.round(src.height * src.scale) } },
    });
    const v = document.createElement('video');
    v.muted = true;
    v.srcObject = glass.stream;
    await v.play();
    glass.video = v;
    panel.classList.add('glass-live');
    glassRate();
    const loop = () => {
      if (!glass.video) return;
      drawGlass();
      glass.video.requestVideoFrameCallback(loop);
    };
    v.requestVideoFrameCallback(loop);
  } catch (e) {
    console.log('glass capture unavailable:', e && e.message);
    stopGlass();
  } finally {
    glass.starting = false;
  }
}

function stopGlass() {
  if (glass.stream) glass.stream.getTracks().forEach((t) => t.stop());
  glass.stream = null;
  glass.video = null;
  panel.classList.remove('glass-live');
  const c = $('glassCanvas');
  glass.ctx.clearRect(0, 0, c.width, c.height);
}

function glassUpdate() {
  if (glassWanted()) startGlass();
  else stopGlass();
}

// Lower the capture rate while the notch is small; it barely needs updates then.
function glassRate() {
  if (!glass.stream) return;
  const big = ui.state === 'expanded' || ui.state === 'hud' || ui.state === 'toast';
  const track = glass.stream.getVideoTracks()[0];
  if (track) track.applyConstraints({ frameRate: big ? 24 : 6 }).catch(() => {});
  if (S.idleStyle === 'hidden') glassUpdate();
}

function drawGlass() {
  const v = glass.video;
  if (!v || !v.videoWidth || !glass.src) return;
  const c = $('glassCanvas');
  const r = panel.getBoundingClientRect();
  const pad = 16;
  const w = Math.max(1, Math.round(r.width + pad * 2));
  const h = Math.max(1, Math.round(r.height + pad));
  if (c.width !== w || c.height !== h) { c.width = w; c.height = h; }
  const k = v.videoWidth / glass.src.width; // video pixels per screen DIP
  const sx = (glass.src.winX + r.left - pad) * k;
  const sy = (glass.src.winY + r.top) * k;
  glass.ctx.drawImage(v, sx, sy, w * k, h * k, 0, 0, w, h);
}

// Liquid Glass strength: 0 = frosted (darker tint, more blur), 100 = clear (see-through, stronger lens).
function applyGlassAmount(amount) {
  const a = clamp((Number.isFinite(+amount) ? +amount : 50) / 100);
  const tint = Math.max(0.05, 0.62 * Math.pow(1 - a, 1.6));                  // .62 → .20 (at 50) → .05
  root.style.setProperty('--glass-tint', tint.toFixed(3));
  root.style.setProperty('--glass-tint-solid', Math.min(0.9, tint + 0.35).toFixed(3)); // before the live backdrop arrives
  root.style.setProperty('--glass-blur', (12 - a * 10).toFixed(1) + 'px'); // 12px → 2px
  root.style.setProperty('--glass-clear', a.toFixed(2));
  const disp = document.querySelector('#lg-refract feDisplacementMap');
  if (disp) disp.setAttribute('scale', (0.02 + a * 0.1).toFixed(3));       // .02 → .12
}

/* ================================================================ settings */

// Keep the accent readable against the notch background.
function visibleAccent(hex, theme) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex || '');
  if (!m) return '#5e8bff';
  let [r, g, b] = [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16));
  const lum = () => (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
  if (theme === 'white') {
    while (lum() > 0.6) { r *= 0.85; g *= 0.85; b *= 0.85; }
  } else {
    while (lum() < 0.35) { r += (255 - r) * 0.2; g += (255 - g) * 0.2; b += (255 - b) * 0.2; }
  }
  return `rgb(${Math.round(r)}, ${Math.round(g)}, ${Math.round(b)})`;
}

function applySettings(s) {
  S = s;
  root.dataset.theme = s.theme || 'black';
  applyGlassAmount(s.glassAmount);
  root.style.setProperty('--pw', `${clamp(Number(s.notchWidth) || 240, 180, 340)}px`);
  root.style.setProperty('--focus', s.focusColor || '#ff9f0a');
  root.style.setProperty('--accent', visibleAccent(s.accent, s.theme));
  const c = notch.classList;
  c.toggle('idle-small', s.idleStyle === 'small');
  c.toggle('idle-hidden', s.idleStyle === 'hidden');
  c.toggle('no-compact-art', !s.compactArt);
  c.toggle('no-gear', !s.settingsInNotch);
  c.toggle('no-clips', !s.clipboardEnabled);
  c.toggle('hud-bar-style', s.hudStyle === 'bar');
  c.toggle('no-game-net', !s.gameShowNet);
  if (!focus.active && s.focusMinutes && s.focusMinutes * 60 !== focus.total) {
    focus.total = focus.left = s.focusMinutes * 60;
  }
  lastDay = '';
  renderQuick();
  setTab(ui.tab);
  renderFocus();
  renderBattery();
  renderClock();
  renderCalendar();
  glassUpdate();
  if (ui.state === 'idle' || ui.state === 'live' || ui.state === 'game') setState(restingState());
  requestAnimationFrame(reportRect);
}

function renderExpanded() {
  renderProgress();
  renderVolume();
  renderClips();
  renderCalendar();
  renderClock();
}

/* ================================================================ boot */

api.onSettings(applySettings);
api.onClips((c) => { clips = c || []; if (ui.state === 'expanded') renderClips(); });

api.dlList().then((l) => { dlItems = l || []; renderDownloads(); });

Promise.all([api.getSettings(), api.getClips(), api.getWeather(), api.getDevices(), api.getNotifs()]).then(([s, c, w, d, nf]) => {
  applySettings(s);
  clips = c || [];
  devices = Array.isArray(d) ? d : [];
  notifList = (nf && nf.list) || [];
  notifAccessState = nf && nf.access;
  renderNotifs(notifAccessState);
  renderClips();
  renderWeather(w);
  renderDevices();
  renderMedia();
  setTab('home');
  reportRect();
  setTimeout(prewarm, 2500);
});

/* Warm-up: Chromium prepares a view's images and text the first time it's drawn, which made
   the very first open stutter. Draw the panel's pages once, invisibly, right after start. */
async function prewarm() {
  if (ui.hovering || (ui.state !== 'idle' && ui.state !== 'live')) return;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const back = ui.tab;
  notch.classList.add('prewarm');
  // Real open → switch pages → close, with the normal animations, so everything (including
  // the blur used by the open animation) has been drawn once.
  for (const t of ['widgets', 'downloads', 'notifs', 'home']) {
    if (ui.hovering) break;
    setTab(t);
    setState('expanded');
    await sleep(t === 'home' ? 500 : 250);
  }
  setTab(back);
  if (!ui.hovering) setState(restingState());
  await sleep(700); // let the close animation finish before it becomes visible again
  notch.classList.remove('prewarm');
  if (ui.hovering) settle();
}
