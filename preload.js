const { contextBridge, ipcRenderer, webUtils } = require('electron');

const on = (channel) => (fn) => ipcRenderer.on(channel, (_e, data) => fn(data));

contextBridge.exposeInMainWorld('isle', {
  // settings
  getSettings: () => ipcRenderer.invoke('settings:get'),
  set: (key, value) => ipcRenderer.send('settings:set', key, value),
  onSettings: on('settings'),
  info: () => ipcRenderer.invoke('app:info'),
  onSection: on('section'),

  // island <-> main
  hitRect: (r) => ipcRenderer.send('hit-rect', r),
  onHover: on('hover'),
  onPrivHover: on('privhover'),
  onSys: on('sys'),
  onStats: on('stats'),
  onPerf: on('perf'),
  onMode: on('mode'),
  cmd: (line) => ipcRenderer.send('cmd', line),
  menu: () => ipcRenderer.send('menu'),
  openSettings: (section) => ipcRenderer.send('open-settings', section),
  action: (a) => ipcRenderer.send('action', a),
  onEyes: on('eyes'),
  onWelcome: on('welcome'),
  // menu bar
  onMbSys: on('mb:sys'),
  onMbTray: on('mb:tray'),
  onMbWifi: on('mb:wifi'),
  onMbHover: on('mb:hover'),
  mbHit: (rects) => ipcRenderer.send('mb:hit', rects),
  mbDo: (what, arg) => ipcRenderer.send('mb:do', what, arg),
  mbTall: (tall) => ipcRenderer.send('mb:tall', tall),
  // dock
  onDockApps: on('dock:apps'),
  onDockHover: on('dock:hover'),
  onDockReveal: on('dock:reveal'),
  dockHit: (r) => ipcRenderer.send('dock:hit', r),
  dockIcon: (paths) => ipcRenderer.invoke('dock:icon', paths),
  dockClick: (item) => ipcRenderer.send('dock:click', item),
  dockLaunch: (item) => ipcRenderer.send('dock:launch', item),
  dockReveal: (item) => ipcRenderer.send('dock:reveal', item),
  dockQuit: (runKey) => ipcRenderer.send('dock:quit', runKey),
  dockReorder: (keys) => ipcRenderer.send('dock:reorder', keys),
  dockUnpin: (key) => ipcRenderer.send('dock:unpin', key),
  dockPin: (item) => ipcRenderer.send('dock:pin', item),
  // files dropped on the Dock (shortcuts, programs, folders): their paths, then pin them
  pathForFile: (file) => { try { return webUtils.getPathForFile(file); } catch { return ''; } },
  dockDropFiles: (paths, at) => ipcRenderer.send('dock:drop', paths, at),
  // updates
  getUpdate: () => ipcRenderer.invoke('update:get'),
  onUpdate: on('update'),
  checkUpdate: () => ipcRenderer.send('update:check'),
  installUpdate: () => ipcRenderer.send('update:install'),
  eyesDone: () => ipcRenderer.send('eyes:done'),

  // widgets
  getWeather: () => ipcRenderer.invoke('weather:get'),
  onWeather: on('weather'),
  refreshWeather: () => ipcRenderer.send('weather:refresh'),
  glassSource: () => ipcRenderer.invoke('glass:source'),  getDevices: () => ipcRenderer.invoke('devices:get'),
  onDevices: on('devices'),
  refreshDevices: () => ipcRenderer.send('devices:refresh'),
  onAppIcon: on('appicon'),
  // video downloads
  dlInfo: (url) => ipcRenderer.invoke('dl:info', url),
  dlStart: (opts) => ipcRenderer.invoke('dl:start', opts),
  dlList: () => ipcRenderer.invoke('dl:list'),
  dlClipboard: () => ipcRenderer.invoke('dl:clipboard'),
  dlDir: () => ipcRenderer.invoke('dl:dir'),
  dlPickDir: () => ipcRenderer.invoke('dl:pick-dir'),
  dl: (action, id) => ipcRenderer.send('dl:' + action, id),
  onDownloads: on('downloads'),
  onDownloadDone: on('download-done'),
  onVideoLink: on('video-link'),

  getNotifs: () => ipcRenderer.invoke('notifs:get'),
  onNotifs: on('notifs'),
  onNotif: on('notif'),
  onNotifAccess: on('notifaccess'),
  notifs: (action, arg) => ipcRenderer.send('notifs:' + action, arg),
  openNotifSettings: (which) => ipcRenderer.send('open-notif-settings', which),

  // clipboard history
  getClips: () => ipcRenderer.invoke('clips:get'),
  onClips: on('clips'),
  clips: (action, arg) => ipcRenderer.send('clips:' + action, arg),
});
