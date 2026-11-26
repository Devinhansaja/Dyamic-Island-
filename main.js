const {
  app, BrowserWindow, ipcMain, screen, Menu, Tray, nativeImage, nativeTheme, clipboard, desktopCapturer,
} = require('electron');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawn } = require('child_process');

const APP_NAME = 'Isle';
const W = 780;   // transparent canvas; the notch animates inside it
const H = 380;
const ASSETS = path.join(__dirname, 'assets');

const DEFAULTS = {
  theme: 'black',             // 'black' | 'white' | 'glass'
  glassAmount: 50,            // Liquid Glass: 0 = frosted (more blur/tint), 100 = clear (more see-through)
  accent: '#5e8bff',
  idleStyle: 'thin',          // 'thin' | 'small' | 'hidden'
  notchWidth: 240,            // small notch width in px (180–340); idle / timer sizes follow it
  hideFullscreen: true,       // full-screen video
  gameMode: 'stats',          // during games: 'stats' | 'hide' | 'normal'
  gameShowNet: true,
  expandOnHover: true,
  hoverDelay: 0.5,            // seconds the mouse must rest on the notch before it opens
  launchAtLogin: false,
  trayIcon: true,
  settingsInNotch: true,
  liveActivity: true,
  compactArt: true,
  trackAlert: true,
  volumeHud: true,
  brightnessHud: true,
  hudStyle: 'segmented',      // 'segmented' | 'bar'
  scrollVolume: true,
  hideWindowsVolume: true,    // hide Windows' own volume / brightness pop-up while Isle runs
  notifEnabled: true,
  notifPreview: true,         // show message text, not just the app name
  islandDnd: false,           // collect notifications silently (badge only)
  hideWindowsNotifs: true,    // turn on Windows "Do not disturb" while Isle runs (restored on quit)
  downloadDir: '',            // '' = Downloads\Isle
  suggestDownloads: true,     // offer to download when a video link is copied
  dlCookies: '',              // '' | 'firefox' | 'edge' | 'chrome' | 'brave': use that browser's sign-in
  chargingAlert: true,
  btAlert: true,              // pop-up when a Bluetooth device connects / disconnects
  lowBatteryAlert: true,
  lowThreshold: 20,
  clipboardEnabled: true,
  clipLimit: 30,
  focusMinutes: 25,
  focusColor: '#ff9f0a',      // focus timer colour (turns red in the last minute)
  eyeBreak: true,             // 20-20-20 eye breaks in the notch
  eyeMinutes: 20,             // minutes of screen time between eye breaks
  autoUpdate: true,           // look for a new version on GitHub (at start and every 6 hours)
  weatherAuto: true,          // use Windows Location; weatherCity is the fallback / override
  weatherCity: '',
  weatherUnit: 'c',           // 'c' | 'f'
  clock24: false,
  clockSeconds: true,
};

// Electron's dev-only security-warning check throws on some resource URLs; the
// page has a strict CSP already, so skip that check.
process.env.ELECTRON_DISABLE_SECURITY_WARNINGS = 'true';

// Windows can wrongly mark a transparent always-on-top window as "occluded",
// after which Chromium stops repainting it and the notch looks frozen.
// SpareRendererForSitePerProcess: don't keep an extra idle page process around (saves memory).
app.commandLine.appendSwitch('disable-features', 'CalculateNativeWinOcclusion,SpareRendererForSitePerProcess');
app.commandLine.appendSwitch('disable-renderer-backgrounding');
app.commandLine.appendSwitch('disable-backgrounding-occluded-windows');

// Note: Isle is left on whichever GPU drives the screen (Windows' default). Forcing the
// integrated GPU made every frame get copied to the NVIDIA GPU on screens it drives, which
// made animations less smooth.

if (!app.requestSingleInstanceLock()) {
  app.quit();
  process.exit(0);
}
app.setName(APP_NAME);

let win = null;
let settingsWin = null;
let tray = null;
let helper = null;
let quitting = false;
let fullscreenApp = false;
let fullscreenProc = '';
let mode = 'normal';          // 'normal' | 'game' | 'video'
let eyeShowing = false;       // an eye break is on screen (see "eye breaks")

// Full-screen apps that are browsers or players count as "video", everything else as a game.
const VIDEO_APPS = new Set([
  'chrome', 'msedge', 'brave', 'firefox', 'opera', 'opera_gx', 'vivaldi', 'arc', 'iexplore',
  'vlc', 'mpc-hc', 'mpc-hc64', 'mpc-be', 'mpc-be64', 'potplayer', 'potplayermini', 'potplayermini64',
  'wmplayer', 'video.ui', 'microsoft.media.player', 'applicationframehost', 'mpv', 'kmplayer', 'gom',
  'plex', 'stremio', 'netflix', 'spotify', 'powerpnt', 'acrord32', 'acrobat', 'photos', 'microsoft.photos',
]);

/* ------------------------------------------------------------------ settings */

const settingsFile = () => path.join(app.getPath('userData'), 'settings.json');
let settings = { ...DEFAULTS };

function loadSettings() {
  try {
    const saved = JSON.parse(fs.readFileSync(settingsFile(), 'utf8'));
    settings = { ...DEFAULTS };
    for (const k of Object.keys(DEFAULTS)) if (k in saved) settings[k] = saved[k];
  } catch {
    settings = { ...DEFAULTS };
  }
}

function saveSettings() {
  try {
    fs.mkdirSync(path.dirname(settingsFile()), { recursive: true });
    fs.writeFileSync(settingsFile(), JSON.stringify(settings, null, 2));
  } catch { /* ignore */ }
}

const loginOpts = () => (app.isPackaged ? {} : { path: process.execPath, args: [path.resolve(__dirname)] });

// Windows only starts a startup entry that is approved in its "Startup apps" list (Task Manager >
// Startup apps / Settings > Apps > Startup). A new entry has no record there and was skipped.
// Mark Isle's entry as enabled: when it has no record yet, or when the user just switched
// "Launch at login" on in Isle (force). A record the user turned off in Task Manager is
// otherwise left alone.
function approveStartup(force = false) {
  if (process.platform !== 'win32') return;
  const { execFile } = require('child_process');
  const key = 'HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\StartupApproved\\Run';
  const items = (app.getLoginItemSettings(loginOpts()).launchItems || []).map((i) => i.name).filter(Boolean);
  const names = items.length ? items : [`electron.app.${APP_NAME}`];
  for (const name of names) {
    const add = () => execFile('reg', ['add', key, '/v', name, '/t', 'REG_BINARY', '/d', '020000000000000000000000', '/f'], { windowsHide: true }, () => {});
    if (force) add();
    else execFile('reg', ['query', key, '/v', name], { windowsHide: true }, (err) => { if (err) add(); });
  }
}

function broadcast(channel, data) {
  for (const w of BrowserWindow.getAllWindows()) {
    if (!w.isDestroyed()) w.webContents.send(channel, data);
  }
}

function setSetting(key, value) {
  if (!(key in DEFAULTS)) return;
  settings[key] = value;
  saveSettings();
  if (key === 'launchAtLogin' && app.isPackaged) {
    app.setLoginItemSettings({ ...loginOpts(), openAtLogin: !!value });
    if (value) approveStartup(true);
  }
  if (key === 'trayIcon') updateTray();
  if (key === 'hideFullscreen') updateVisibility();
  if (key === 'gameMode') {
    if (mode === 'game' && value === 'stats') startPerf(); else stopPerf();
    updateVisibility();
  }
  if (key === 'clipLimit') trimClips();
  if (key === 'theme') applyTheme();
  if (['hideWindowsVolume', 'volumeHud', 'brightnessHud', 'notifEnabled', 'hideWindowsNotifs'].includes(key)) syncHelper();
  if (key === 'weatherCity' || key === 'weatherUnit' || key === 'weatherAuto') fetchWeather();
  broadcast('settings', settings);
}

// Liquid glass draws a live copy of the screen behind the notch, so the notch
// itself must be left out of screen captures (otherwise it would see itself).
function applyTheme() {
  if (!win || win.isDestroyed()) return;
  const on = settings.theme === 'glass';
  // Toggle off first so Windows re-applies the display affinity reliably.
  if (on) win.setContentProtection(false);
  win.setContentProtection(on);
}

/* ------------------------------------------------------------------ island window */

// The notch always sits at the top centre of the main (primary) monitor.
function notchBounds() {
  const { bounds } = screen.getPrimaryDisplay();
  return { x: Math.round(bounds.x + (bounds.width - W) / 2), y: bounds.y, width: W, height: H };
}
function positionWindow() {
  if (!win || win.isDestroyed()) return;
  const want = notchBounds();
  const b = win.getBounds();
  if (b.x === want.x && b.y === want.y && b.width === want.width && b.height === want.height) return;
  win.setBounds(want);
  // Moving between monitors with different scaling can land at the wrong size; set it again.
  const b2 = win.getBounds();
  if (b2.width !== want.width || b2.height !== want.height || b2.x !== want.x || b2.y !== want.y) win.setBounds(want);
}
// Windows rearranges windows a moment after a monitor change, so check again a bit later too.
function positionSoon() {
  positionWindow();
  setTimeout(positionWindow, 600);
  setTimeout(positionWindow, 2000);
}

function createIsland() {
  win = new BrowserWindow({
    width: W,
    height: H,
    frame: false,
    transparent: true,
    resizable: false,
    movable: false,
    minimizable: false,
    maximizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    hasShadow: false,
    alwaysOnTop: true,
    show: false,
    backgroundColor: '#00000000',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      backgroundThrottling: false,
      spellcheck: false, // no text fields that need it; saves loading dictionaries
    },
  });
  positionWindow();
  applyTheme();
  win.setAlwaysOnTop(true, 'screen-saver');
  win.setIgnoreMouseEvents(true, { forward: true });
  win.loadFile('index.html');
  win.once('ready-to-show', updateVisibility);
  win.webContents.on('did-finish-load', () => {
    setTimeout(replayState, 300);
    win.webContents.send('mode', { mode, app: fullscreenProc });
  });

  screen.on('display-metrics-changed', positionSoon);
  screen.on('display-added', positionSoon);
  screen.on('display-removed', positionSoon);
  const { powerMonitor } = require('electron');
  powerMonitor.on('resume', positionSoon);
  powerMonitor.on('unlock-screen', positionSoon);

  setInterval(() => {
    if (win && !win.isDestroyed() && win.isVisible() && !hovering) {
      positionWindow(); // back onto the main monitor if Windows moved it
      win.setAlwaysOnTop(true, 'screen-saver');
      win.moveTop();
    }
  }, 3000);
}

// Windows' own full-screen surfaces (lock screen, Start, search, snipping overlay) are neither.
const SYSTEM_APPS = new Set([
  'lockapp', 'logonui', 'searchhost', 'searchapp', 'startmenuexperiencehost', 'shellexperiencehost',
  'textinputhost', 'screenclippinghost', 'snippingtool', 'explorer', 'electron', 'dwm',
]);

function currentMode() {
  if (!fullscreenApp || SYSTEM_APPS.has(fullscreenProc.toLowerCase())) return 'normal';
  return VIDEO_APPS.has(fullscreenProc.toLowerCase()) ? 'video' : 'game';
}

function updateVisibility() {
  if (!win || win.isDestroyed()) return;
  const m = currentMode();
  if (m !== mode) {
    mode = m;
    if (mode === 'game' && settings.gameMode === 'stats') startPerf();
    else stopPerf();
    // Never stay clickable while a game is in front.
    if (mode === 'game') { hovering = false; win.setIgnoreMouseEvents(true, { forward: true }); }
    win.webContents.send('mode', { mode, app: fullscreenProc });
    syncHelper();
  }
  // (An eye break is always shown, even when the notch is set to hide for games / video.)
  const hide = !eyeShowing && ((mode === 'video' && settings.hideFullscreen) || (mode === 'game' && settings.gameMode === 'hide'));
  if (hide && win.isVisible()) win.hide();
  if (!hide && !win.isVisible()) {
    win.showInactive();
    win.setAlwaysOnTop(true, 'screen-saver');
    win.moveTop();
    // Capture exclusion only sticks once the window is actually on screen.
    applyTheme();
  }
}

/* Hover: the window is click-through; we watch the cursor and only make it
   clickable while it is over the notch's reported hit area. */
let hitRect = null;
let hovering = false;
let privHover = false;
const inRect = (r, x, y) => !!r && x >= r.x && x <= r.x + r.w && y >= r.y && y <= r.y + r.h;
setInterval(() => {
  if (!win || win.isDestroyed() || !hitRect || !win.isVisible()) return;
  const p = screen.getCursorScreenPoint();
  const b = win.getBounds();
  const x = p.x - b.x;
  const y = p.y - b.y;
  // Hovering the mic / camera dots only shows a label; the window stays click-through.
  const ph = inRect(hitRect.priv, x, y);
  if (ph !== privHover) { privHover = ph; win.webContents.send('privhover', ph); }
  if (mode === 'game' && settings.gameMode === 'stats') return; // stats strip is click-through
  const inside = x >= hitRect.x && x <= hitRect.x + hitRect.w && y >= hitRect.y && y <= hitRect.y + hitRect.h;
  if (inside !== hovering) {
    hovering = inside;
    if (inside) win.setIgnoreMouseEvents(false);
    else win.setIgnoreMouseEvents(true, { forward: true });
    win.webContents.send('hover', inside);
  }
}, 40);

/* ------------------------------------------------------------------ eye breaks (20-20-20)
   After `eyeMinutes` of screen time the notch shows a 20-second eye break, on top of
   everything (games and full-screen video too). Only time at the screen counts: 5 minutes
   with no keyboard / mouse (and nothing full-screen or playing, since a game pad or a film
   doesn't count as input) or a locked / sleeping PC means the eyes got their rest. */
const EYE_SECONDS = 20;
let eyeUsed = 0;              // seconds of screen time since the last break
let eyeLocked = false;
let eyeTimer = null;
const EYE_TICK = 10;
setInterval(() => {
  if (!settings.eyeBreak || eyeShowing || eyeLocked) return;
  const { powerMonitor } = require('electron');
  const away = powerMonitor.getSystemIdleTime() >= 300 && mode === 'normal' && !(lastSys.media && lastSys.media.playing);
  if (away) { eyeUsed = 0; return; }
  eyeUsed += EYE_TICK;
  if (eyeUsed >= Math.max(1, Number(settings.eyeMinutes) || 20) * 60) startEyeBreak();
}, EYE_TICK * 1000);
app.whenReady().then(() => {
  const { powerMonitor } = require('electron');
  const rest = () => { eyeUsed = 0; };
  powerMonitor.on('lock-screen', () => { eyeLocked = true; rest(); });
  powerMonitor.on('unlock-screen', () => { eyeLocked = false; rest(); });
  powerMonitor.on('suspend', rest);
  powerMonitor.on('resume', rest);
});

function startEyeBreak() {
  if (!win || win.isDestroyed() || eyeShowing) return;
  eyeShowing = true;
  eyeUsed = 0;
  // Shown even when the notch hides for games / video, and kept on top of the game.
  if (!win.isVisible()) win.showInactive();
  win.setAlwaysOnTop(true, 'screen-saver');
  win.moveTop();
  win.webContents.send('eyes', { seconds: EYE_SECONDS });
  clearTimeout(eyeTimer);
  eyeTimer = setTimeout(endEyeBreak, (EYE_SECONDS + 4) * 1000);   // in case the notch never says it's done
}
function endEyeBreak() {
  if (!eyeShowing) return;
  eyeShowing = false;
  eyeUsed = 0;
  clearTimeout(eyeTimer);
  updateVisibility();   // hide again if a game / video wants the notch hidden
}

/* ------------------------------------------------------------------ system helper */

function startHelper() {
  // (If Isle is force-closed, Windows kills this helper with it; the helper's small guard
  // program then puts Windows' volume / brightness bar back. See IsleGuard in helper.ps1.)
  helper = spawn(
    'powershell.exe',
    ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(__dirname, 'helper.ps1'), String(process.pid)],
    { windowsHide: true, stdio: ['pipe', 'pipe', 'ignore'] }
  );
  let buf = '';
  helper.stdout.setEncoding('utf8');
  helper.stdout.on('data', (chunk) => {
    buf += chunk;
    let i;
    while ((i = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, i).replace(/^\uFEFF/, '').trim();
      buf = buf.slice(i + 1);
      if (!line) continue;
      let msg;
      try { msg = JSON.parse(line); } catch { continue; }
      onHelperMessage(msg);
    }
  });
  helper.stdin.on('error', () => {});
  helper.on('exit', () => {
    helper = null;
    if (!quitting) setTimeout(startHelper, 3000);
  });
  if (perfOn) setTimeout(() => helperCmd(`perf 1 ${nvidiaOk ? 0 : 1}`), 4000);
  syncHelper();
}

function helperCmd(line) {
  if (helper && helper.stdin.writable) helper.stdin.write(line + '\n');
}

// Tell the helper which optional features are on.
function syncHelper() {
  // Hide Windows' volume / brightness pop-up only while the notch's own HUD can show
  // (not in games or full-screen video, where the notch stays out of the way).
  const osd = settings.hideWindowsVolume && (settings.volumeHud || settings.brightnessHud) && mode === 'normal';
  helperCmd(`osd ${osd ? 1 : 0}`);
  helperCmd(`mode ${mode}`);
  helperCmd(`notif ${settings.notifEnabled ? 1 : 0}`);
  // Windows "Do not disturb" keeps its banners away; notifications still reach Isle.
  helperCmd(`windnd ${settings.hideWindowsNotifs && settings.notifEnabled ? 1 : 0}`);
}

function onHelperMessage(msg) {
  if (msg.t === 'fs') {
    fullscreenApp = !!msg.v;
    fullscreenProc = msg.app || '';
    updateVisibility();
    return;
  }
  if (msg.t === 'perf') {
    perf.down = msg.down;
    perf.up = msg.up;
    if (typeof msg.gpu === 'number' && msg.gpu >= 0 && !nvidiaOk) perf.gpu = msg.gpu;
    sendPerf();
    return;
  }
  if (msg.t === 'clip') {
    readClipboard();
    return;
  }
  if (msg.t === 'notifaccess') {
    notifAccess = msg.v;
    broadcast('notifaccess', notifAccess);
    return;
  }
  if (msg.t === 'notif') {
    onNotification(msg);
    return;
  }
  if (msg.t === 'pads') {
    // USB / wireless-receiver controllers (from the helper; devices.ps1 only sees Bluetooth).
    pads = Array.isArray(msg.list) ? msg.list : [];
    broadcast('devices', allDevices());
    return;
  }
  if (msg.t === 'bt') {
    // A device connected / disconnected: re-read batteries (a new device reports its level a bit later).
    setTimeout(refreshDevices, 1200);
    if (msg.added && msg.added.length) setTimeout(refreshDevices, 7000);
  }
  if (msg.t === 'media') { lastSys.media = msg; if (msg.appPath) sendAppIcon(msg.app, msg.appPath); }
  if (msg.t === 'art') lastSys.art = msg;
  if (msg.t === 'privacy') lastSys.privacy = msg;
  if (msg.t === 'power') lastSys.power = msg;
  if (msg.t === 'bright') lastSys.bright = msg;
  if (msg.t === 'vol') lastSys.vol = msg;
  if (msg.t === 'monitors') lastSys.monitors = { ...msg, show: false }; // replayed without popping the HUD
  if (win && !win.isDestroyed()) win.webContents.send('sys', msg);
}

// Recent notifications, kept in memory only (never written to disk).
let notifs = [];
let notifAccess = null;
const notifLogos = new Map();

/* Toast images (sender photo, stickers, pictures) come as https / file / ms-appdata
   links; turn them into data URLs the notch can show. Cached per link, in memory. */
const imageCache = new Map();
async function imageData(src, aumid) {
  if (!src) return null;
  if (imageCache.has(src)) return imageCache.get(src);
  let url = null;
  try {
    if (/^https?:\/\//i.test(src)) {
      const ctrl = new AbortController();
      const timer = setTimeout(() => ctrl.abort(), 6000);
      const r = await fetch(src, { signal: ctrl.signal });
      clearTimeout(timer);
      const type = (r.headers.get('content-type') || '').split(';')[0];
      const buf = Buffer.from(await r.arrayBuffer());
      if (r.ok && buf.length < 4 * 1024 * 1024) url = `data:${type.startsWith('image/') ? type : 'image/png'};base64,${buf.toString('base64')}`;
    } else {
      let file = null;
      if (/^file:/i.test(src)) file = decodeURIComponent(new URL(src).pathname).replace(/^\/([A-Za-z]:)/, '$1');
      else if (/^ms-appdata:\/\/\/local\//i.test(src) && aumid && aumid.includes('!')) {
        const family = aumid.split('!')[0];
        file = path.join(process.env.LOCALAPPDATA || '', 'Packages', family, 'LocalState', decodeURIComponent(src.replace(/^ms-appdata:\/\/\/local\//i, '')));
      } else if (/^[A-Za-z]:\\/.test(src)) file = src;
      if (file && fs.existsSync(file) && fs.statSync(file).size < 4 * 1024 * 1024) {
        const ext = path.extname(file).slice(1).toLowerCase();
        const type = { jpg: 'image/jpeg', jpeg: 'image/jpeg', gif: 'image/gif', webp: 'image/webp', bmp: 'image/bmp' }[ext] || 'image/png';
        url = `data:${type};base64,${fs.readFileSync(file).toString('base64')}`;
      }
    }
  } catch { url = null; }
  imageCache.set(src, url);
  if (imageCache.size > 200) imageCache.delete(imageCache.keys().next().value);
  return url;
}

async function onNotification(msg) {
  if (msg.logo) notifLogos.set(msg.app, msg.logo);
  const [avatar, image] = await Promise.all([imageData(msg.avatar, msg.aumid), imageData(msg.image, msg.aumid)]);
  const item = {
    id: msg.id, app: msg.app, title: msg.title, body: msg.body, at: msg.at || Date.now(),
    logo: notifLogos.get(msg.app) || null, avatar, image,
    incoming: !!msg.incoming,
  };
  notifs = [item, ...notifs.filter((n) => n.id !== item.id)].slice(0, 30);
  broadcast('notifs', notifs);
  if (win && !win.isDestroyed()) win.webContents.send('notif', item);
}

// Last known media / art / volume, replayed whenever the island page (re)loads.
const lastSys = {};
function replayState() {
  if (!win || win.isDestroyed()) return;
  for (const k of ['vol', 'bright', 'monitors', 'privacy', 'power', 'media', 'art']) if (lastSys[k]) win.webContents.send('sys', lastSys[k]);
  for (const [app, url] of appIconByApp) win.webContents.send('appicon', { app, url });
}

/* The media player's own icon, taken from its .exe. */
const appIcons = new Map();      // exe -> data URL (null while loading / none)
const appIconByApp = new Map();  // media app id -> data URL
async function sendAppIcon(app, exe) {
  if (appIcons.has(exe)) {
    const url = appIcons.get(exe);
    if (url && !appIconByApp.has(app)) {
      appIconByApp.set(app, url);
      if (win && !win.isDestroyed()) win.webContents.send('appicon', { app, url });
    }
    return;
  }
  appIcons.set(exe, null);
  try {
    const img = await app_.getFileIcon(exe, { size: 'large' });
    if (!img.isEmpty()) appIcons.set(exe, img.toDataURL());
  } catch { /* no icon */ }
  const url = appIcons.get(exe);
  if (!url) return;
  appIconByApp.set(app, url);
  if (win && !win.isDestroyed()) win.webContents.send('appicon', { app, url });
}
const app_ = app;

/* ------------------------------------------------------------------ one-shot PowerShell scripts */

function runScript(file, timeoutMs = 20000) {
  return new Promise((resolve) => {
    let out = '';
    const p = spawn('powershell.exe', ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', path.join(__dirname, file)], { windowsHide: true });
    const timer = setTimeout(() => p.kill(), timeoutMs);
    p.stdout.setEncoding('utf8');
    p.stdout.on('data', (d) => { out += d; });
    p.on('error', () => { clearTimeout(timer); resolve(null); });
    p.on('exit', () => {
      clearTimeout(timer);
      const line = out.split(/\r?\n/).map((s) => s.replace(/^﻿/, '').trim()).filter(Boolean).pop();
      try { resolve(line ? JSON.parse(line) : null); } catch { resolve(null); }
    });
  });
}

/* ------------------------------------------------------------------ Bluetooth device batteries */

let devices = [];
let pads = [];
let devicesBusy = false;
let devicesAt = 0;
const allDevices = () => [...devices, ...pads];

async function refreshDevices() {
  if (devicesBusy) return;
  devicesBusy = true;
  const list = await runScript('devices.ps1');
  devicesBusy = false;
  devicesAt = Date.now();
  if (Array.isArray(list)) devices = list;
  broadcast('devices', allDevices());
}
/* Memory: only the background helper (PowerShell, draws nothing) is trimmed. The notch's own
   processes keep their memory, so opening and animating the notch never has to wait for it. */
setInterval(() => helperCmd('trim'), 2 * 60 * 1000);

// Batteries change slowly, and connects / disconnects are reported right away by the helper.
setInterval(() => { if (mode !== 'game') refreshDevices(); }, 3 * 60 * 1000);

/* ------------------------------------------------------------------ clipboard history */

let clips = [];          // { id, kind, text?, thumb?, at }
const clipImages = new Map();
let clipId = 0;
let firstClipRead = true;

function trimClips() {
  const limit = Math.max(5, Number(settings.clipLimit) || 30);
  while (clips.length > limit) {
    const old = clips.pop();
    clipImages.delete(old.id);
  }
}

function pushClips() {
  broadcast('clips', clips);
}

function readClipboard() {
  // Skip whatever was already on the clipboard when Isle started.
  if (firstClipRead) { firstClipRead = false; return; }
  if (!settings.clipboardEnabled) return;
  const formats = clipboard.availableFormats();
  let item = null;

  const text = clipboard.readText();
  if (text && text.trim()) {
    const t = text.length > 5000 ? text.slice(0, 5000) : text;
    const kind = /^https?:\/\/\S+$/i.test(t.trim()) ? 'link' : 'text';
    item = { kind, text: t, sig: 't:' + t };
  } else if (formats.some((f) => f.startsWith('image/'))) {
    const img = clipboard.readImage();
    if (!img.isEmpty()) {
      const size = img.getSize();
      const thumb = img.resize({ width: Math.min(size.width, 320) });
      const thumbUrl = thumb.toDataURL();
      item = { kind: 'image', thumb: thumbUrl, w: size.width, h: size.height, sig: 'i:' + size.width + 'x' + size.height + thumbUrl.slice(-120) };
      item._img = img;
    }
  }
  if (!item) return;

  // A video link was copied: offer to download it.
  if (item.kind === 'link' && settings.suggestDownloads && isVideoLink(item.text) && win && !win.isDestroyed()) {
    win.webContents.send('video-link', item.text.trim());
  }

  const existing = clips.findIndex((c) => c.sig === item.sig);
  if (existing >= 0) {
    const [c] = clips.splice(existing, 1);
    c.at = Date.now();
    clips.unshift(c);
  } else {
    const id = ++clipId;
    if (item._img) clipImages.set(id, item._img);
    delete item._img;
    clips.unshift({ id, ...item, at: Date.now() });
    trimClips();
  }
  pushClips();
}

/* ------------------------------------------------------------------ video downloads (yt-dlp) */

const YTDLP = path.join(__dirname, 'bin', 'yt-dlp.exe');
// Sites whose copied links trigger the "download this?" pop-up. Pasting works for any of the
// 1,800+ sites yt-dlp supports, not only these.
const VIDEO_HOST = new RegExp('(^|\\.)(' + [
  'youtube\\.com', 'youtu\\.be', 'facebook\\.com', 'fb\\.watch', 'fb\\.com', 'instagram\\.com', 'threads\\.net', 'threads\\.com',
  'tiktok\\.com', 'twitter\\.com', 'x\\.com', 'reddit\\.com', 'redd\\.it', 'pinterest\\.com', 'pin\\.it', 'linkedin\\.com',
  'snapchat\\.com', 'tumblr\\.com', 'vimeo\\.com', 'dailymotion\\.com', 'dai\\.ly', 'twitch\\.tv', 'kick\\.com',
  'rumble\\.com', 'bilibili\\.com', 'b23\\.tv', 'vk\\.com', 'vkvideo\\.ru', 'ok\\.ru', 'likee\\.video', 'kwai\\.com',
  'soundcloud\\.com', 'bandcamp\\.com', 'mixcloud\\.com', 'streamable\\.com', 'imgur\\.com', '9gag\\.com',
  'bitchute\\.com', 'odysee\\.com', 'ted\\.com', 'bsky\\.app', 'weibo\\.com', 'douyin\\.com', 'nicovideo\\.jp',
].join('|') + ')$', 'i');

function isVideoLink(text) {
  try {
    const u = new URL(String(text).trim());
    return /^https?:$/.test(u.protocol) && VIDEO_HOST.test(u.hostname);
  } catch { return false; }
}

function downloadDir() {
  return settings.downloadDir || path.join(app.getPath('downloads'), 'Isle');
}

let ffmpegPath = null;
function findFfmpeg() {
  try {
    const out = require('child_process').execFileSync('where.exe', ['ffmpeg'], { encoding: 'utf8', windowsHide: true });
    ffmpegPath = out.split(/\r?\n/).find((l) => l.trim().toLowerCase().endsWith('.exe')) || null;
  } catch { ffmpegPath = null; }
}

function ytdlp(args) {
  // Optional: reuse a browser's sign-in for posts that need login (Instagram, Facebook, private videos).
  const cookies = settings.dlCookies ? ['--cookies-from-browser', settings.dlCookies] : [];
  return spawn(YTDLP, ['--encoding', 'utf-8', '--no-colors', ...cookies, ...(ffmpegPath ? ['--ffmpeg-location', ffmpegPath] : []), ...args], {
    windowsHide: true,
    env: { ...process.env, PYTHONIOENCODING: 'utf-8' },
  });
}

// Title, thumbnail and available qualities for a link.
function videoInfo(url) {
  return new Promise((resolve) => {
    if (!fs.existsSync(YTDLP)) return resolve({ ok: false, error: 'yt-dlp is missing from the bin folder' });
    let out = '';
    let err = '';
    const p = ytdlp(['-J', '--no-playlist', '--no-warnings', url]);
    const timer = setTimeout(() => p.kill(), 45000);
    p.stdout.setEncoding('utf8');
    p.stderr.setEncoding('utf8');
    p.stdout.on('data', (d) => { out += d; });
    p.stderr.on('data', (d) => { err += d; });
    p.on('exit', () => {
      clearTimeout(timer);
      try {
        const j = JSON.parse(out);
        const formats = j.formats || [];
        const size = (f) => f.filesize || f.filesize_approx || 0;
        // Best audio track size (added to each video-only quality).
        const audio = formats.filter((f) => f.acodec && f.acodec !== 'none' && (!f.vcodec || f.vcodec === 'none'));
        const audioSize = audio.reduce((m, f) => Math.max(m, size(f)), 0);
        const heights = [...new Set(formats
          .filter((f) => f.vcodec && f.vcodec !== 'none' && f.height)
          .map((f) => f.height))].sort((a, b) => b - a);
        // One entry per quality with an estimated download size.
        const qualities = heights.map((h) => {
          const vids = formats.filter((f) => f.height === h && f.vcodec && f.vcodec !== 'none');
          const best = vids.reduce((m, f) => Math.max(m, size(f)), 0);
          const hasAudio = vids.some((f) => f.acodec && f.acodec !== 'none');
          const fps = vids.reduce((m, f) => Math.max(m, f.fps || 0), 0);
          return { height: h, fps: Math.round(fps), bytes: best ? best + (hasAudio ? 0 : audioSize) : 0 };
        });
        resolve({
          qualities,
          audioBytes: audioSize,
          ok: true,
          url,
          title: j.title || 'Video',
          uploader: j.uploader || j.channel || '',
          site: j.extractor_key || '',
          duration: j.duration || 0,
          thumb: j.thumbnail || null,
          heights,
        });
      } catch {
        let line = (err.split(/\r?\n/).find((l) => l.startsWith('ERROR')) || 'Could not read this link').replace(/^ERROR:\s*/, '');
        if (/unsupported url/i.test(line)) line = 'This site or link type is not supported';
        else if (/log ?in|sign ?in|cookies|private|rate-limit|authentication/i.test(line) && !settings.dlCookies) {
          line = 'This post needs you to be signed in. Pick your browser in Settings → Clipboard & Downloads, then try again.';
        } else if (/could not copy .*cookie|cookie database|failed to decrypt/i.test(line)) {
          line = 'Could not read your browser sign-in. Close that browser and try again, or choose Firefox.';
        }
        resolve({ ok: false, error: line.slice(0, 220) });
      }
    });
  });
}

let downloads = [];      // { id, url, title, thumb, kind, label, percent, speed, eta, status, file, error }
let dlSeq = 0;
const dlProcs = new Map();
let dlPushTimer = null;

function pushDownloads(now = false) {
  const send = () => { dlPushTimer = null; broadcast('downloads', downloads.map(({ proc, ...d }) => d)); };
  if (now) { clearTimeout(dlPushTimer); send(); return; }
  if (!dlPushTimer) dlPushTimer = setTimeout(send, 200);
}

function startDownload({ url, kind, height, title, thumb }) {
  const dir = downloadDir();
  fs.mkdirSync(dir, { recursive: true });
  const id = ++dlSeq;
  const label = kind === 'audio' ? 'MP3' : height ? `${height}p` : 'Best';
  const item = { id, url, title: title || url, thumb: thumb || null, kind, label, percent: 0, speed: '', eta: '', status: 'downloading', file: null, error: null };
  downloads.unshift(item);
  downloads = downloads.slice(0, 20);

  const fmt = kind === 'audio'
    ? ['-f', 'ba/b', '-x', '--audio-format', 'mp3', '--audio-quality', '0']
    // Keep the chosen resolution, but prefer H.264 video + AAC audio so the MP4 plays everywhere
    // (falls back to VP9/AV1 only for qualities that exist in nothing else, e.g. 4K on YouTube).
    : ['-f', 'bv*+ba/b', '-S', `res${height ? ':' + height : ''},vcodec:h264,acodec:m4a`, '--merge-output-format', 'mp4'];
  const p = ytdlp([
    // --print would switch yt-dlp to quiet mode and hide the progress; keep both on.
    '--no-playlist', '--newline', '--windows-filenames', '--no-mtime', '--no-quiet', '--progress',
    '--progress-template', 'download:[isle] %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s',
    '--print', 'after_move:[isledone] %(filepath)s',
    '-o', path.join(dir, '%(title).150B [%(id)s].%(ext)s'),
    ...fmt, url,
  ]);
  dlProcs.set(id, p);
  let errText = '';
  // Video and audio download one after the other (two 0-100% runs); combine them into one
  // overall percentage. The video track is most of the size, so it gets most of the bar.
  let parts = 1;
  let part = -1;
  const weights = () => (parts >= 2 ? [0.85, 0.15] : [1]);
  const onLine = (line) => {
    const s = line.trim();
    const fm = /Downloading \d+ format\(s\): (\S+)/.exec(s);
    if (fm) { parts = fm[1].split('+').length; return; }
    if (s.startsWith('[download] Destination:')) { part = Math.min(part + 1, parts - 1); return; }
    if (s.startsWith('[isle]')) {
      const [pct, speed, eta] = s.slice(6).split('|').map((x) => x.trim());
      const n = parseFloat(pct);
      if (!Number.isNaN(n)) {
        const w = weights();
        const idx = Math.max(0, part);
        const done = w.slice(0, idx).reduce((a, b) => a + b, 0);
        const overall = (done + (w[idx] || 0) * (n / 100)) * 100;
        item.percent = Math.max(item.percent, Math.min(99.5, overall)); // never jumps backwards
      }
      item.speed = speed === 'NA' || speed === 'Unknown' ? '' : speed;
      item.eta = eta === 'NA' || eta === 'Unknown' ? '' : eta;
      item.status = 'downloading';
      pushDownloads();
    } else if (s.startsWith('[isledone]')) {
      item.file = s.slice(10).trim();
    } else if (/^\[(Merger|ExtractAudio|VideoConvertor|FixupM3u8|FixupM4a)\]/.test(s)) {
      item.status = 'processing';
      item.percent = 100;
      pushDownloads();
    } else if (s.startsWith('ERROR')) {
      errText = s.replace(/^ERROR:\s*/, '');
    }
  };
  let buf = '';
  const feed = (d) => { buf += d; let i; while ((i = buf.indexOf('\n')) >= 0) { onLine(buf.slice(0, i)); buf = buf.slice(i + 1); } };
  p.stdout.setEncoding('utf8');
  p.stderr.setEncoding('utf8');
  p.stdout.on('data', feed);
  p.stderr.on('data', feed);
  p.on('exit', (code) => {
    dlProcs.delete(id);
    if (item.status === 'cancelled') { pushDownloads(true); return; }
    if (code === 0 && item.file) {
      item.status = 'done';
      item.percent = 100;
      if (win && !win.isDestroyed()) win.webContents.send('download-done', { id, title: item.title, thumb: item.thumb, kind: item.kind });
    } else {
      item.status = 'error';
      item.error = errText || 'Download failed';
    }
    pushDownloads(true);
  });
  pushDownloads(true);
  return id;
}

function cancelDownload(id) {
  const p = dlProcs.get(id);
  const item = downloads.find((d) => d.id === id);
  if (item) item.status = 'cancelled';
  if (p) {
    // yt-dlp may have an ffmpeg child; end the whole tree.
    spawn('taskkill', ['/PID', String(p.pid), '/T', '/F'], { windowsHide: true });
  }
  pushDownloads(true);
}

/* ------------------------------------------------------------------ weather (Open-Meteo, no API key) */

let weather = { state: 'unset' };
let geo = null;
let here = null;        // { lat, lon, name, at } from Windows Location
let locDenied = false;

// Windows Location gives coordinates; they're rounded to ~1 km before any lookup.
async function locateHere() {
  if (here && Date.now() - here.at < 60 * 60 * 1000) return here;
  const r = await runScript('location.ps1', 20000);
  if (!r || !r.ok) { locDenied = !!(r && String(r.why).startsWith('denied')); return here; }
  locDenied = false;
  const lat = Math.round(r.lat * 100) / 100;
  const lon = Math.round(r.lon * 100) / 100;
  let name = '';
  try {
    const g = await (await fetch(`https://api.bigdatacloud.net/data/reverse-geocode-client?latitude=${lat}&longitude=${lon}&localityLanguage=en`)).json();
    name = g.city || g.locality || g.principalSubdivision || '';
  } catch { /* name stays empty */ }
  here = { lat, lon, name: name || 'Current location', at: Date.now() };
  return here;
}

async function fetchWeather() {
  const city = String(settings.weatherCity || '').trim();
  if (weather.state !== 'ok') broadcast('weather', (weather = { state: 'loading', city }));

  if (settings.weatherAuto) {
    const loc = await locateHere();
    if (loc) {
      geo = { q: '@here', name: loc.name, lat: loc.lat, lon: loc.lon };
    } else if (!city) {
      weather = { state: locDenied ? 'nolocation' : 'error' };
      broadcast('weather', weather);
      return;
    }
  }
  if (!settings.weatherAuto || !here) {
    if (!city) {
      weather = { state: 'unset' };
      broadcast('weather', weather);
      return;
    }
  }
  try {
    if ((!settings.weatherAuto || !here) && (!geo || geo.q !== city.toLowerCase())) {
      const r = await fetch(`https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(city)}&count=1&language=en&format=json`);
      const j = await r.json();
      if (!j.results || !j.results.length) {
        weather = { state: 'notfound', city };
        broadcast('weather', weather);
        return;
      }
      const g = j.results[0];
      geo = { q: city.toLowerCase(), name: g.name, lat: g.latitude, lon: g.longitude };
    }
    const unit = settings.weatherUnit === 'f' ? '&temperature_unit=fahrenheit' : '';
    const r = await fetch(
      `https://api.open-meteo.com/v1/forecast?latitude=${geo.lat}&longitude=${geo.lon}` +
      '&current=temperature_2m,apparent_temperature,weather_code,is_day,relative_humidity_2m' +
      `&daily=temperature_2m_max,temperature_2m_min&forecast_days=1&timezone=auto${unit}`
    );
    const w = await r.json();
    weather = {
      state: 'ok',
      city: geo.name,
      temp: Math.round(w.current.temperature_2m),
      feels: Math.round(w.current.apparent_temperature),
      code: w.current.weather_code,
      day: !!w.current.is_day,
      humidity: Math.round(w.current.relative_humidity_2m),
      hi: Math.round(w.daily.temperature_2m_max[0]),
      lo: Math.round(w.daily.temperature_2m_min[0]),
      at: Date.now(),
    };
  } catch {
    if (weather.state !== 'ok') weather = { state: 'error', city };
  }
  broadcast('weather', weather);
}
setInterval(fetchWeather, 20 * 60 * 1000);

/* ------------------------------------------------------------------ in-game performance */

const perf = { cpu: 0, ram: 0, gpu: null, temp: null, vram: null, vramTotal: null, down: 0, up: 0 };
let perfOn = false;
let smi = null;
let nvidiaOk = false;
let nvidiaMissing = false;

function sendPerf() {
  if (perfOn && win && !win.isDestroyed()) win.webContents.send('perf', perf);
}

function startPerf() {
  if (perfOn) return;
  perfOn = true;
  helperCmd(`perf 1 ${nvidiaOk ? 0 : 1}`);
  if (nvidiaMissing || smi) return;
  // nvidia-smi in loop mode prints one CSV line per second.
  smi = spawn('nvidia-smi', [
    '--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total',
    '--format=csv,noheader,nounits', '-lms', '1000',
  ], { windowsHide: true });
  smi.on('error', () => { nvidiaMissing = true; nvidiaOk = false; smi = null; if (perfOn) helperCmd('perf 1 1'); });
  smi.stdout.setEncoding('utf8');
  smi.stdout.on('data', (chunk) => {
    const lines = chunk.trim().split(/\r?\n/);
    const f = lines[lines.length - 1].split(',').map((s) => Number(s.trim()));
    if (f.length < 4 || f.some(Number.isNaN)) return;
    if (!nvidiaOk) { nvidiaOk = true; helperCmd('perf 1 0'); }
    [perf.gpu, perf.temp, perf.vram, perf.vramTotal] = f;
    sendPerf();
  });
  smi.on('exit', () => { smi = null; });
}

function stopPerf() {
  if (!perfOn) return;
  perfOn = false;
  helperCmd('perf 0 0');
  if (smi) { smi.kill(); smi = null; }
}

/* ------------------------------------------------------------------ system stats */

function diskInfo() {
  try {
    const s = fs.statfsSync(process.env.SystemDrive ? process.env.SystemDrive + '\\' : 'C:\\');
    const total = s.blocks * s.bsize;
    const free = s.bavail * s.bsize;
    return { disk: Math.round(((total - free) / total) * 100), diskFree: free };
  } catch {
    return { disk: null, diskFree: null };
  }
}

let lastCpu = os.cpus();
let tickCount = 0;
let disk = diskInfo();
setInterval(() => {
  const now = os.cpus();
  let idle = 0;
  let total = 0;
  now.forEach((c, i) => {
    const prev = lastCpu[i] ? lastCpu[i].times : { user: 0, nice: 0, sys: 0, idle: 0, irq: 0 };
    const t = c.times;
    total += (t.user - prev.user) + (t.nice - prev.nice) + (t.sys - prev.sys) + (t.idle - prev.idle) + (t.irq - prev.irq);
    idle += t.idle - prev.idle;
  });
  lastCpu = now;
  const cpu = total > 0 ? Math.round(100 * (1 - idle / total)) : 0;
  const totalMem = os.totalmem();
  const usedMem = totalMem - os.freemem();
  perf.cpu = cpu;
  perf.ram = Math.round((usedMem / totalMem) * 100);
  if (perfOn) { sendPerf(); return; }
  if (++tickCount % 30 === 0) disk = diskInfo();
  if (win && !win.isDestroyed()) {
    win.webContents.send('stats', {
      cpu,
      ram: perf.ram,
      ramUsed: usedMem,
      ramTotal: totalMem,
      uptime: os.uptime(),
      ...disk,
    });
  }
}, 1000);

/* ------------------------------------------------------------------ settings window */

function overlayColors() {
  return nativeTheme.shouldUseDarkColors
    ? { color: '#1c1c1e', symbolColor: '#f2f2f7', height: 38 }
    : { color: '#f5f5f7', symbolColor: '#1c1c1e', height: 38 };
}

function openSettings(section) {
  if (settingsWin && !settingsWin.isDestroyed()) {
    settingsWin.show();
    settingsWin.focus();
    if (section) settingsWin.webContents.send('section', section);
    return;
  }
  settingsWin = new BrowserWindow({
    width: 720,
    height: 660,
    resizable: false,
    maximizable: false,
    fullscreenable: false,
    title: `${APP_NAME} Settings`,
    icon: path.join(ASSETS, 'icon.png'),
    backgroundColor: nativeTheme.shouldUseDarkColors ? '#1c1c1e' : '#f5f5f7',
    titleBarStyle: 'hidden',
    titleBarOverlay: overlayColors(),
    show: false,
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
    },
  });
  settingsWin.loadFile('settings.html', section ? { hash: section } : undefined);
  settingsWin.once('ready-to-show', () => settingsWin.show());
  settingsWin.on('closed', () => { settingsWin = null; });
}

nativeTheme.on('updated', () => {
  if (settingsWin && !settingsWin.isDestroyed()) settingsWin.setTitleBarOverlay(overlayColors());
});

/* ------------------------------------------------------------------ tray & menu */

function buildMenu() {
  const themeItem = (label, value) => ({
    label, type: 'radio', checked: settings.theme === value, click: () => setSetting('theme', value),
  });
  return Menu.buildFromTemplate([
    { label: `${APP_NAME}`, enabled: false },
    { type: 'separator' },
    { label: 'Theme', submenu: [themeItem('Black', 'black'), themeItem('White', 'white'), themeItem('Liquid Glass', 'glass')] },
    { label: 'Settings…', click: () => openSettings() },
    { label: 'Reload island', click: () => win && win.reload() },
    { type: 'separator' },
    { label: `Quit ${APP_NAME}`, click: () => app.quit() },
  ]);
}

function updateTray() {
  if (settings.trayIcon && !tray) {
    tray = new Tray(nativeImage.createFromPath(path.join(ASSETS, 'tray.png')));
    tray.setToolTip(APP_NAME);
    tray.on('click', () => openSettings());
    tray.on('right-click', () => tray.popUpContextMenu(buildMenu()));
  } else if (!settings.trayIcon && tray) {
    tray.destroy();
    tray = null;
  }
}

/* ------------------------------------------------------------------ IPC */

/* ------------------------------------------------------------------ updates (GitHub Releases)
   New versions are published as releases of the GitHub repo, each with "Isle-Setup.exe".
   Isle compares the newest release with its own version; when it is newer, the notch offers
   it, and on a click the setup is downloaded and run silently (it closes this Isle, installs
   over it, keeps the settings and starts the new one). Only GitHub's public release list is
   read; nothing about this PC is sent. */
const UPDATE_REPO = 'Devinhansaja/Dyamic-Island-';
let update = { state: 'idle' };   // idle | checking | none | available | downloading | error

function isNewer(a, b) {
  const pa = String(a).split('.').map((n) => parseInt(n, 10) || 0);
  const pb = String(b).split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) if ((pa[i] || 0) !== (pb[i] || 0)) return (pa[i] || 0) > (pb[i] || 0);
  return false;
}
function sendUpdate(extra = {}) { broadcast('update', { ...update, current: app.getVersion(), ...extra }); }

async function checkUpdate(manual = false) {
  if (update.state === 'downloading' || update.state === 'checking') return;
  const was = update;
  update = { ...update, state: 'checking' };
  sendUpdate();
  try {
    const { net } = require('electron');
    const r = await net.fetch(`https://api.github.com/repos/${UPDATE_REPO}/releases/latest`, {
      headers: { 'User-Agent': 'Isle-updater', Accept: 'application/vnd.github+json' },
    });
    if (r.status === 404) { update = { state: 'none' }; sendUpdate(); return; }   // no release yet
    if (!r.ok) throw new Error('HTTP ' + r.status);
    const j = await r.json();
    const version = String(j.tag_name || '').replace(/^v/i, '');
    const asset = (j.assets || []).find((a) => /setup.*\.exe$/i.test(a.name));
    if (version && asset && isNewer(version, app.getVersion())) {
      update = { state: 'available', version, url: asset.browser_download_url, size: asset.size };
      // The pop-up is shown once per new version (and when asked from Settings).
      sendUpdate({ announce: manual || was.version !== version });
    } else {
      update = { state: 'none' };
      sendUpdate();
    }
  } catch {
    update = { ...was, state: was.state === 'available' ? 'available' : 'error' };
    sendUpdate();
  }
}

async function installUpdate() {
  if (update.state !== 'available') return;
  const { net } = require('electron');
  const file = path.join(app.getPath('temp'), `Isle-Setup-${update.version}.exe`);
  update = { ...update, state: 'downloading', pct: 0 };
  sendUpdate();
  try {
    const r = await net.fetch(update.url, { headers: { 'User-Agent': 'Isle-updater' } });
    if (!r.ok || !r.body) throw new Error('HTTP ' + r.status);
    const total = Number(r.headers.get('content-length')) || update.size || 0;
    const out = fs.createWriteStream(file);
    const reader = r.body.getReader();
    let got = 0, lastPct = -1;
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      got += value.length;
      if (!out.write(Buffer.from(value))) await new Promise((res) => out.once('drain', res));
      const pct = total ? Math.floor((got / total) * 100) : 0;
      if (pct !== lastPct) { lastPct = pct; update.pct = pct; sendUpdate(); }
    }
    await new Promise((res, rej) => out.end((e) => (e ? rej(e) : res())));
    if (total && got < total) throw new Error('download cut short');
    // Runs on its own (not tied to Isle), closes this Isle, installs, starts the new version.
    spawn(file, ['/S'], { detached: true, stdio: 'ignore', windowsHide: true }).unref();
  } catch {
    update = { ...update, state: 'available', failed: true };
    sendUpdate();
  }
}

setInterval(() => { if (settings.autoUpdate && app.isPackaged) checkUpdate(); }, 6 * 60 * 60 * 1000);
ipcMain.handle('update:get', () => ({ ...update, current: app.getVersion() }));
ipcMain.on('update:check', () => checkUpdate(true));
ipcMain.on('update:install', () => installUpdate());

ipcMain.handle('settings:get', () => settings);
ipcMain.on('settings:set', (_e, key, value) => setSetting(key, value));
ipcMain.handle('app:info', () => ({
  name: APP_NAME,
  version: app.getVersion(),
  electron: process.versions.electron,
  chrome: process.versions.chrome,
}));

ipcMain.on('hit-rect', (_e, r) => { hitRect = r; });
ipcMain.on('cmd', (_e, line) => helperCmd(String(line)));
ipcMain.on('menu', () => buildMenu().popup({ window: win }));
ipcMain.on('open-settings', (_e, section) => openSettings(section));
ipcMain.on('action', (_e, a) => {
  if (a === 'reload' && win) win.reload();
  if (a === 'quit') app.quit();
  if (a === 'eye-break') startEyeBreak();
});
ipcMain.on('eyes:done', () => endEyeBreak());

ipcMain.handle('dl:info', (_e, url) => videoInfo(String(url || '').trim()));
ipcMain.handle('dl:start', (_e, opts) => startDownload(opts || {}));
ipcMain.handle('dl:list', () => downloads);
ipcMain.handle('dl:clipboard', () => clipboard.readText());
ipcMain.handle('dl:dir', () => downloadDir());
ipcMain.on('dl:cancel', (_e, id) => cancelDownload(id));
ipcMain.on('dl:open', (_e, id) => { const d = downloads.find((x) => x.id === id); if (d && d.file) require('electron').shell.openPath(d.file); });
ipcMain.on('dl:reveal', (_e, id) => {
  const d = downloads.find((x) => x.id === id);
  if (d && d.file) require('electron').shell.showItemInFolder(d.file);
  else require('electron').shell.openPath(downloadDir());
});
ipcMain.on('dl:remove', (_e, id) => { downloads = downloads.filter((d) => d.id !== id || dlProcs.has(id)); pushDownloads(true); });
ipcMain.on('dl:clear', () => { downloads = downloads.filter((d) => dlProcs.has(d.id)); pushDownloads(true); });
ipcMain.handle('dl:pick-dir', async () => {
  const r = await require('electron').dialog.showOpenDialog(settingsWin || win, { properties: ['openDirectory', 'createDirectory'], defaultPath: downloadDir() });
  if (r.canceled || !r.filePaths[0]) return null;
  setSetting('downloadDir', r.filePaths[0]);
  return r.filePaths[0];
});
ipcMain.handle('weather:get', () => weather);
ipcMain.on('weather:refresh', () => fetchWeather());
ipcMain.handle('notifs:get', () => ({ list: notifs, access: notifAccess }));
ipcMain.on('notifs:remove', (_e, id) => { notifs = notifs.filter((n) => n.id !== id); broadcast('notifs', notifs); });
ipcMain.on('notifs:clear', () => { notifs = []; broadcast('notifs', notifs); });
ipcMain.on('open-notif-settings', (_e, which) => {
  const uri = which === 'dnd' ? 'ms-settings:notifications' : 'ms-settings:privacy-notifications';
  require('electron').shell.openExternal(uri);
});
ipcMain.handle('devices:get', () => allDevices());
ipcMain.on('devices:refresh', () => { if (Date.now() - devicesAt > 15000) refreshDevices(); });

// Screen source for the liquid glass backdrop (primary display only).
ipcMain.handle('glass:source', async () => {
  try {
    const display = screen.getPrimaryDisplay();
    const sources = await desktopCapturer.getSources({ types: ['screen'], thumbnailSize: { width: 0, height: 0 } });
    const src = sources.find((s) => String(s.display_id) === String(display.id)) || sources[0];
    if (!src || !win) return null;
    const b = win.getBounds();
    return {
      id: src.id,
      width: display.bounds.width,
      height: display.bounds.height,
      scale: display.scaleFactor,
      winX: b.x - display.bounds.x,
      winY: b.y - display.bounds.y,
    };
  } catch {
    return null;
  }
});

ipcMain.handle('clips:get', () => clips);
ipcMain.on('clips:copy', (_e, id) => {
  const c = clips.find((x) => x.id === id);
  if (!c) return;
  if (c.kind === 'image') {
    const img = clipImages.get(id);
    if (img) clipboard.writeImage(img);
  } else {
    clipboard.writeText(c.text);
  }
});
ipcMain.on('clips:remove', (_e, id) => {
  clips = clips.filter((c) => c.id !== id);
  clipImages.delete(id);
  pushClips();
});
ipcMain.on('clips:clear', () => {
  clips = [];
  clipImages.clear();
  pushClips();
});

/* ------------------------------------------------------------------ lifecycle */

app.on('second-instance', () => openSettings());

app.whenReady().then(() => {
  loadSettings();
  // "Launch at login" follows Windows; but if it was on and this copy of Isle isn't registered
  // yet (e.g. after moving to Isle.exe), register this copy. Only the built Isle.exe does this:
  // a development copy must never add itself to Windows' startup apps.
  if (app.isPackaged) {
    const registered = app.getLoginItemSettings(loginOpts()).openAtLogin;
    if (settings.launchAtLogin && !registered) app.setLoginItemSettings({ ...loginOpts(), openAtLogin: true });
    else settings.launchAtLogin = registered;
    if (settings.launchAtLogin) approveStartup();
  }
  createIsland();
  updateTray();
  startHelper();
  fetchWeather();
  refreshDevices();
  findFfmpeg();
  // First update check a minute after start (not while Windows is still starting everything).
  setTimeout(() => { if (settings.autoUpdate && app.isPackaged) checkUpdate(); }, 60 * 1000);
});

// On quit, let the helper put Windows "Do not disturb" back the way it was before killing it.
let quitReady = false;
app.on('before-quit', (e) => {
  quitting = true;
  if (smi) smi.kill();
  for (const id of [...dlProcs.keys()]) cancelDownload(id);
  if (!quitReady && helper && helper.stdin.writable) {
    e.preventDefault();
    quitReady = true;
    helperCmd('windnd 0');
    helperCmd('osd 0');           // Windows' own volume / brightness bar back to normal
    helper.stdin.end();           // the helper also restores and exits when stdin closes
    const h = helper;
    const done = () => app.quit();
    h.once('exit', done);
    setTimeout(() => { try { h.kill(); } catch { /* gone */ } done(); }, 1500);
    return;
  }
  if (helper) helper.kill();
});

// Closing the settings window must not quit the app.
app.on('window-all-closed', () => {});
