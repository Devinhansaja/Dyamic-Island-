const api = window.isle;
const $ = (id) => document.getElementById(id);
const all = (sel) => [...document.querySelectorAll(sel)];

let S = {};
const TITLES = {
  general: 'General', dock: 'Dock & menu bar', media: 'Media', huds: 'HUDs', gaming: 'Gaming', widgets: 'Widgets',
  battery: 'Alerts', clipboard: 'Clipboard & Downloads', about: 'About',
};

function show(sec) {
  if (!TITLES[sec]) sec = 'general';
  all('.tb').forEach((b) => b.classList.toggle('on', b.dataset.sec === sec));
  all('main section').forEach((s) => s.classList.toggle('on', s.dataset.sec === sec));
  $('title').textContent = TITLES[sec];
  if (sec === 'widgets') setTimeout(() => $('cityInput').focus(), 50);
}
all('.tb').forEach((b) => b.addEventListener('click', () => show(b.dataset.sec)));
api.onSection(show);

// Same rule as the notch: lift near-black accents so switches stay visible.
function visibleAccent(hex) {
  const m = /^#?([0-9a-f]{6})$/i.exec(hex || '');
  if (!m) return '#5e8bff';
  let [r, g, b] = [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16));
  const lum = () => (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255;
  while (lum() < 0.35) {
    r += (255 - r) * 0.2; g += (255 - g) * 0.2; b += (255 - b) * 0.2;
  }
  return `rgb(${Math.round(r)}, ${Math.round(g)}, ${Math.round(b)})`;
}

function fmtRange(el) {
  const v = Number(el.value);
  const f = el.dataset.fmt;
  if (f === 's') return v.toFixed(2).replace(/0$/, '') + 's';
  if (f === '%') return v + '%';
  if (f === 'items') return v + ' items';
  if (f === 'px') return v + ' px';
  if (f === 'min') return v + ' min';
  if (f === 'x') return v.toFixed(1) + '×';
  return String(v);
}

function render() {
  document.documentElement.style.setProperty('--accent', visibleAccent(S.accent));

  all('input.switch[data-key]').forEach((el) => { el.checked = !!S[el.dataset.key]; });
  all('input[type=range][data-key]').forEach((el) => {
    el.value = S[el.dataset.key];
    const out = document.querySelector(`.range-val[data-for="${el.dataset.key}"]`);
    if (out) out.textContent = fmtRange(el);
  });
  all('.seg[data-key]').forEach((seg) => {
    seg.querySelectorAll('button').forEach((b) => b.classList.toggle('on', b.dataset.value === S[seg.dataset.key]));
  });
  all('.theme-card').forEach((b) => b.classList.toggle('on', b.dataset.value === (S.theme || 'black')));
  all('.swatch').forEach((b) => b.classList.toggle('on', b.dataset.value.toLowerCase() === String(S.accent).toLowerCase()));
  all('.cswatches[data-key]').forEach((g) => g.querySelectorAll('.cswatch').forEach((b) => {
    b.classList.toggle('on', b.dataset.value.toLowerCase() === String(S[g.dataset.key] || '').toLowerCase());
  }));
  $('customColor').value = /^#[0-9a-f]{6}$/i.test(S.accent) ? S.accent : '#5e8bff';
  if (document.activeElement !== $('cityInput')) $('cityInput').value = S.weatherCity || '';
  all('[data-needs]').forEach((row) => row.classList.toggle('disabled', !S[row.dataset.needs]));
  all('[data-needs-value]').forEach((row) => {
    const [k, v] = row.dataset.needsValue.split('=');
    row.classList.toggle('disabled', S[k] !== v);
  });
}

all('input.switch[data-key]').forEach((el) => el.addEventListener('change', () => api.set(el.dataset.key, el.checked)));
all('input[type=range][data-key]').forEach((el) => {
  let pending = null;
  el.addEventListener('input', () => {
    const out = document.querySelector(`.range-val[data-for="${el.dataset.key}"]`);
    if (out) out.textContent = fmtRange(el);
    // Live sliders (like Glass) update the notch while dragging, a few times a second.
    if (el.dataset.live && !pending) {
      pending = setTimeout(() => { pending = null; api.set(el.dataset.key, Number(el.value)); }, 80);
    }
  });
  el.addEventListener('change', () => api.set(el.dataset.key, Number(el.value)));
});
all('.seg[data-key]').forEach((seg) => {
  seg.querySelectorAll('button').forEach((b) => b.addEventListener('click', () => api.set(seg.dataset.key, b.dataset.value)));
});
all('.theme-card').forEach((b) => b.addEventListener('click', () => api.set('theme', b.dataset.value)));
all('.swatch').forEach((b) => b.addEventListener('click', () => api.set('accent', b.dataset.value)));
all('.cswatches[data-key]').forEach((g) => g.querySelectorAll('.cswatch').forEach((b) => {
  b.addEventListener('click', () => api.set(g.dataset.key, b.dataset.value));
}));
$('customColor').addEventListener('change', (e) => api.set('accent', e.target.value));

$('cityForm').addEventListener('submit', (e) => {
  e.preventDefault();
  api.set('weatherCity', $('cityInput').value.trim());
  $('cityInput').blur();
});

all('[data-action]').forEach((b) => b.addEventListener('click', () => {
  const a = b.dataset.action;
  if (a === 'clear-clips') api.clips('clear');
  else if (a === 'notif-settings') api.openNotifSettings('privacy');
  else if (a === 'win-dnd') api.openNotifSettings('dnd');
  else if (a === 'pick-dl-dir') api.dlPickDir().then(showDlDir);
  else api.action(a);
}));

function showDlDir() { api.dlDir().then((d) => { $('dlDirText').textContent = d; }); }
showDlDir();

api.onSettings((s) => { S = s; render(); showDlDir(); });

// Updates: status line + one button (check, or install when a new version is waiting).
function renderUpdate(u) {
  if (!u) return;
  const st = $('updStatus');
  const btn = $('updBtn');
  btn.disabled = u.state === 'checking' || u.state === 'downloading';
  btn.textContent = u.state === 'available' ? `Install ${u.version}` : 'Check for updates';
  st.textContent =
    u.state === 'checking' ? 'Checking…'
    : u.state === 'available' ? (u.failed ? 'Download failed, try again' : `Version ${u.version} is available (you have ${u.current})`)
    : u.state === 'downloading' ? `Downloading ${u.version}… ${u.pct || 0}%`
    : u.state === 'error' ? 'Could not reach GitHub'
    : u.state === 'none' ? `Isle ${u.current} is up to date`
    : `You have Isle ${u.current}`;
}
let upd = null;
api.onUpdate((u) => { upd = u; renderUpdate(u); });
api.getUpdate().then((u) => { upd = u; renderUpdate(u); });
$('updBtn').addEventListener('click', () => {
  if (upd && upd.state === 'available') api.installUpdate(); else api.checkUpdate();
});

Promise.all([api.getSettings(), api.info()]).then(([s, info]) => {
  S = s;
  render();
  $('ver').textContent = `Version ${info.version} · Electron ${info.electron}`;
  show(location.hash.slice(1) || 'general');
});
