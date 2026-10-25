// メインプロセス: ウィンドウ、ファイル操作、音声エンジン連携、ffmpeg 書き出し
const { app, BrowserWindow, ipcMain, dialog, shell, screen, protocol, net } = require('electron');
const { createMenu } = require('./menu');
const { pathToFileURL } = require('url');

// 素材は media:// で渡す(canvas の録画や音声の読み込みが file:// の制限に引っかからないように)
protocol.registerSchemesAsPrivileged([
  { scheme: 'media', privileges: { standard: true, secure: true, supportFetchAPI: true, corsEnabled: true, stream: true, bypassCSP: true } },
]);
const path = require('path');
const fs = require('fs');
const os = require('os');
const crypto = require('crypto');
const { spawn, execFileSync } = require('child_process');

const VOICE_DIR = () => {
  const d = path.join(app.getPath('userData'), 'voices');
  fs.mkdirSync(d, { recursive: true });
  return d;
};

// ウィンドウ位置を覚える(つないだ画面が変わっても、見える場所に戻す)
const BOUNDS_FILE = () => path.join(app.getPath('userData'), 'window.json');
function loadBounds() {
  try {
    const b = JSON.parse(fs.readFileSync(BOUNDS_FILE(), 'utf8'));
    const visible = screen.getAllDisplays().some((d) => {
      const a = d.workArea;
      return b.x >= a.x - 50 && b.y >= a.y - 50 && b.x < a.x + a.width && b.y < a.y + a.height;
    });
    return visible ? b : null;
  } catch { return null; }
}

// プレビューを出す画面: 内蔵以外で画素数が一番多いもの(4K を足せばそれが選ばれる)
function pickPreviewDisplay() {
  const all = screen.getAllDisplays();
  const ext = all.filter((d) => !d.internal);
  const pool = ext.length ? ext : all;
  return pool.sort((a, b) => b.size.width * b.scaleFactor * b.size.height * b.scaleFactor - a.size.width * a.scaleFactor * a.size.height * a.scaleFactor)[0];
}

// ---------- メニュー・ドキュメント状態 ----------
// レンダラーが知らせてくる、メニューの有効/チェックや窓の見た目に必要な状態
const ui = { width: 1920, height: 1080, codec: 'h264', bg: '#000000', hasSelection: false, dirty: false, projectPath: null };
let mainWin = null;
let allowClose = false; // 未保存の確認を済ませた(または確認いらない)ときだけ true
let guarding = false;
let saveWaiter = null;
let rendererReady = false;
const pendingOpen = []; // ダブルクリックで開かれたが、まだレンダラーが準備できていないファイル

const sendAction = (id, arg) => { if (mainWin && !mainWin.isDestroyed()) mainWin.webContents.send('menu-action', { id, arg }); };

// 最近使った項目(userData/recent.json に最大 10 件)
const RECENT_FILE = () => path.join(app.getPath('userData'), 'recent.json');
let recentList = null;
function loadRecent() {
  if (!recentList) {
    try { recentList = JSON.parse(fs.readFileSync(RECENT_FILE(), 'utf8')).filter((p) => typeof p === 'string'); } catch { recentList = []; }
  }
  return recentList;
}
const getRecent = () => loadRecent().filter((p) => fs.existsSync(p)).slice(0, 10);
function saveRecent() { try { fs.writeFileSync(RECENT_FILE(), JSON.stringify(recentList)); } catch { /* 書けなくても動作には影響しない */ } }
function addRecent(p) {
  recentList = [p, ...loadRecent().filter((x) => x !== p)].slice(0, 10);
  saveRecent();
  app.addRecentDocument(p);
  menuCtl.rebuild();
}
function clearRecent() {
  recentList = [];
  saveRecent();
  app.clearRecentDocuments();
  menuCtl.rebuild();
}

const menuCtl = createMenu({ send: sendAction, getUi: () => ui, getRecent, clearRecent });
const rebuildMenu = () => { if (app.isReady()) menuCtl.rebuild(); };

// 窓のタイトル・プロキシアイコン・編集済みの点
function applyWindowState() {
  const win = mainWin;
  if (!win || win.isDestroyed()) return;
  const name = ui.projectPath ? path.basename(ui.projectPath) : '名称未設定';
  win.setTitle(`${name} — ゆっくりエディタ`);
  win.setRepresentedFilename(ui.projectPath || '');
  win.setDocumentEdited(!!ui.dirty);
}

ipcMain.on('ui-state', (_e, s) => {
  const next = {
    width: Number(s?.width) || ui.width, height: Number(s?.height) || ui.height,
    codec: s?.codec === 'hevc' ? 'hevc' : 'h264', bg: typeof s?.bg === 'string' ? s.bg : ui.bg,
    hasSelection: !!s?.hasSelection, dirty: !!s?.dirty, projectPath: typeof s?.projectPath === 'string' ? s.projectPath : null,
  };
  const changed = JSON.stringify(next) !== JSON.stringify(ui);
  Object.assign(ui, next);
  if (changed) { applyWindowState(); rebuildMenu(); }
});

// 閉じる前の保存確認で「保存」を選んだとき: レンダラーに保存させ、終わった合図を待つ
function requestSave() {
  return new Promise((resolve) => { saveWaiter = resolve; sendAction('save'); });
}
ipcMain.on('saved', (_e, ok) => {
  if (!saveWaiter) return;
  const r = saveWaiter; saveWaiter = null; r(!!ok);
});

function openPathInApp(p) {
  if (rendererReady && mainWin) sendAction('open-path', p);
  else pendingOpen.push(p);
}
// ダブルクリックや Dock へのドロップで開く(ready より前に登録しておく)
app.on('open-file', (e, p) => { e.preventDefault(); openPathInApp(p); });
ipcMain.on('renderer-ready', () => {
  rendererReady = true;
  pendingOpen.splice(0).forEach((p) => sendAction('open-path', p));
});

// 書き出しの進み具合を Dock のアイコンに出す
ipcMain.on('export-progress', (_e, f) => { if (mainWin && !mainWin.isDestroyed()) mainWin.setProgressBar(typeof f === 'number' ? f : -1); });
ipcMain.on('export-finished', () => {
  if (!mainWin || mainWin.isDestroyed()) return;
  mainWin.setProgressBar(-1);
  if (!mainWin.isFocused()) app.dock?.bounce('informational');
});

function createWindow() {
  const saved = loadBounds();
  const win = new BrowserWindow({
    width: 1400,
    height: 900,
    minWidth: 1100,
    minHeight: 700,
    ...(saved ?? {}),
    title: 'ゆっくりエディタ',
    backgroundColor: '#1e1f24',
    webPreferences: { preload: path.join(__dirname, 'preload.js') },
  });
  mainWin = win;
  if (saved?.maximized) win.maximize();
  win.webContents.on('did-start-loading', () => { rendererReady = false; });
  win.on('page-title-updated', (e) => e.preventDefault()); // タイトルは applyWindowState が決める
  win.on('closed', () => { if (mainWin === win) mainWin = null; });
  // 未保存の変更があるときは、閉じる前にシート(保存 / 保存しない / キャンセル)で確かめる
  win.on('close', (e) => {
    if (allowClose || !ui.dirty || process.env.YE_SMOKE_OUT) return;
    e.preventDefault();
    if (guarding) return;
    guarding = true;
    dialog.showMessageBox(win, {
      type: 'warning', message: 'このプロジェクトには保存していない変更があります。', detail: '閉じる前に保存しますか?',
      buttons: ['保存', '保存しない', 'キャンセル'], defaultId: 0, cancelId: 2,
    }).then(async ({ response }) => {
      if (response === 0) { if (!(await requestSave())) return; } else if (response !== 1) return;
      allowClose = true;
      win.close();
    }).finally(() => { guarding = false; });
  });
  const remember = () => fs.writeFileSync(BOUNDS_FILE(), JSON.stringify({ ...win.getNormalBounds(), maximized: win.isMaximized() }));
  win.on('close', remember);
  win.webContents.setWindowOpenHandler(({ frameName }) => {
    if (frameName !== 'preview') return { action: 'deny' };
    const d = pickPreviewDisplay();
    return {
      action: 'allow',
      overrideBrowserWindowOptions: {
        x: d.bounds.x, y: d.bounds.y, width: d.bounds.width, height: d.bounds.height,
        fullscreen: !d.internal, backgroundColor: '#000', title: 'プレビュー', autoHideMenuBar: true,
      },
    };
  });
  win.loadFile('index.html');
}

ipcMain.handle('displays', () => screen.getAllDisplays().map((d) => ({ label: d.label, internal: d.internal, w: d.size.width * d.scaleFactor, h: d.size.height * d.scaleFactor })));

// VOICEVOX.app に同梱のエンジンを画面なしで起動する(入っていなければ起動しない)
const VV_ENGINE = '/Applications/VOICEVOX.app/Contents/Resources/vv-engine/run';
const VV_PORT = 50021;
// 推論スレッド数: 性能コア数(Apple Silicon)を優先し、取れなければ論理コア数の6割
function cpuThreads() {
  try {
    const n = parseInt(execFileSync('/usr/sbin/sysctl', ['-n', 'hw.perflevel0.logicalcpu'], { encoding: 'utf8', timeout: 2000 }).trim(), 10);
    if (n > 0) return n;
  } catch { /* 取れなければ下で代替 */ }
  const all = typeof os.availableParallelism === 'function' ? os.availableParallelism() : os.cpus().length;
  return Math.max(2, Math.round(all * 0.6));
}
let vvProc = null;
async function vvAlive() {
  try { return (await fetch(`http://127.0.0.1:${VV_PORT}/version`, { signal: AbortSignal.timeout(800) })).ok; } catch { return false; }
}
async function startVoicevox() {
  if (await vvAlive()) return true; // すでに VOICEVOX が動いていればそれを使う
  if (!fs.existsSync(VV_ENGINE)) return false;
  if (!vvProc) {
    vvProc = spawn(VV_ENGINE, ['--host', '127.0.0.1', '--port', String(VV_PORT), '--cpu_num_threads', String(cpuThreads())], { stdio: 'ignore' });
    vvProc.on('error', () => (vvProc = null));
    vvProc.on('exit', () => (vvProc = null));
  }
  for (let i = 0; i < 60; i++) {
    if (await vvAlive()) return true;
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
}

app.whenReady().then(() => {
  protocol.handle('media', async (req) => {
    const p = decodeURIComponent(new URL(req.url).pathname);
    const res = await net.fetch(pathToFileURL(p).toString(), { headers: req.headers });
    const headers = new Headers(res.headers);
    headers.set('Access-Control-Allow-Origin', '*');
    return new Response(res.body, { status: res.status, headers });
  });
  app.setAboutPanelOptions({
    applicationName: 'ゆっくりエディタ', applicationVersion: app.getVersion(),
    copyright: 'MIT License', credits: 'VOICEVOX / ゆっくり音声(AquesTalk)対応の動画編集ソフトです。',
  });
  createWindow();
  menuCtl.rebuild();
  if (process.platform === 'darwin') app.dock?.setMenu(menuCtl.dockMenu());
  startVoicevox();
});
app.on('window-all-closed', () => app.quit());
app.on('will-quit', () => vvProc?.kill());

// ---------- ファイル ----------
ipcMain.handle('open-media', async () => {
  const r = await dialog.showOpenDialog({
    properties: ['openFile', 'multiSelections'],
    filters: [
      { name: '素材', extensions: ['mp4', 'mov', 'webm', 'm4v', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'mp3', 'wav', 'm4a', 'aac', 'ogg'] },
    ],
  });
  return r.canceled ? [] : r.filePaths;
});

ipcMain.handle('open-image', async () => {
  const r = await dialog.showOpenDialog({
    properties: ['openFile'],
    filters: [{ name: '画像', extensions: ['png', 'jpg', 'jpeg', 'gif', 'webp'] }],
  });
  return r.canceled ? null : r.filePaths[0];
});

ipcMain.handle('save-project', async (_e, json, currentPath) => {
  let p = currentPath;
  if (!p) {
    const r = await dialog.showSaveDialog({ defaultPath: ui.projectPath || 'project.ymproj', filters: [{ name: 'プロジェクト', extensions: ['ymproj'] }] });
    if (r.canceled || !r.filePath) return null;
    p = r.filePath;
  }
  fs.writeFileSync(p, json);
  addRecent(p);
  return p;
});

ipcMain.handle('load-project', async () => {
  const r = await dialog.showOpenDialog({ properties: ['openFile'], filters: [{ name: 'プロジェクト', extensions: ['ymproj'] }] });
  if (r.canceled) return null;
  addRecent(r.filePaths[0]);
  return { path: r.filePaths[0], json: fs.readFileSync(r.filePaths[0], 'utf8') };
});

// パスを直接指定して読む(最近使った項目・ダブルクリック)。「開く…」と同じ形を返す
ipcMain.handle('load-project-path', async (_e, p) => {
  const json = fs.readFileSync(p, 'utf8'); // 読めなければ例外 → レンダラーが案内を出す
  addRecent(p);
  return { path: p, json };
});

// ---------- VOICEVOX ----------
// VOICEVOX 互換エンジン(COEIROINK, SHAREVOX なども同じ API)にも使える
ipcMain.handle('voicevox-speakers', async (_e, base) => {
  const res = await fetch(`${base}/speakers`);
  if (!res.ok) throw new Error(`speakers: ${res.status}`);
  return res.json();
});

ipcMain.handle('voicevox-launch', () => startVoicevox());

ipcMain.handle('voicevox-synth', async (_e, { base, text, speaker, speed, pitch, intonation, volume }) => {
  const key = crypto.createHash('sha1').update(JSON.stringify(['vv', base, text, speaker, speed, pitch, intonation, volume])).digest('hex');
  const out = path.join(VOICE_DIR(), `${key}.wav`);
  if (fs.existsSync(out)) return out;
  const q = await fetch(`${base}/audio_query?text=${encodeURIComponent(text)}&speaker=${speaker}`, { method: 'POST' });
  if (!q.ok) throw new Error(`audio_query: ${q.status}`);
  const query = await q.json();
  query.speedScale = speed ?? 1;
  query.pitchScale = pitch ?? 0;
  query.intonationScale = intonation ?? 1;
  query.volumeScale = volume ?? 1;
  const s = await fetch(`${base}/synthesis?speaker=${speaker}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(query),
  });
  if (!s.ok) throw new Error(`synthesis: ${s.status}`);
  fs.writeFileSync(out, Buffer.from(await s.arrayBuffer()));
  return out;
});

// ---------- ゆっくり(AquesTalk 系・外部コマンド) ----------
// コマンドの例は設定画面を参照。{text} {voice} {speed} {out} を置き換えて実行する
const shq = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;
ipcMain.handle('aquestalk-synth', async (_e, { command, text, voice, speed }) => {
  if (!command) throw new Error('設定でゆっくり音声のコマンドを指定してください');
  const key = crypto.createHash('sha1').update(JSON.stringify(['aq', command, text, voice, speed])).digest('hex');
  const out = path.join(VOICE_DIR(), `${key}.wav`);
  if (fs.existsSync(out)) return out;
  const cmd = command
    .replaceAll('{text}', shq(text))
    .replaceAll('{voice}', shq(voice ?? ''))
    .replaceAll('{speed}', shq(speed ?? 100))
    .replaceAll('{out}', shq(out));
  await new Promise((resolve, reject) => {
    const p = spawn('/bin/zsh', ['-lc', cmd]);
    let err = '';
    p.stderr.on('data', (d) => (err += d));
    p.on('close', (code) => (code === 0 && fs.existsSync(out) ? resolve() : reject(new Error(`コマンド失敗 (${code}): ${err.slice(-400)}`))));
  });
  return out;
});

// AquesTalkPlayer Mac版が入っているか、プリセット(れいむ・まりさ など)の一覧
const AQP_APP = '/Applications/AquesTalkPlayer.app/Contents/MacOS/AquesTalkPlayer';
// 標準で入っているプリセット(実機で -P を試して確認したもの)
const AQP_PRESETS = ['れいむ', 'まりさ', '中性', '機械', 'ロボット'];
// ---------- ffmpeg の場所を探す ----------
let ffmpegPath = null;
function findFfmpeg() {
  if (ffmpegPath && fs.existsSync(ffmpegPath)) return ffmpegPath;
  for (const p of ['/opt/homebrew/bin/ffmpeg', '/usr/local/bin/ffmpeg']) {
    if (fs.existsSync(p)) return (ffmpegPath = p);
  }
  try {
    // Finder から起動すると PATH が短いので、ログインシェル経由で探す
    const out = execFileSync('/bin/zsh', ['-lc', 'which ffmpeg'], { encoding: 'utf8', timeout: 5000 }).trim().split('\n').pop();
    if (out && fs.existsSync(out)) return (ffmpegPath = out);
  } catch { /* 見つからない */ }
  return null;
}
function requireFfmpeg() {
  const p = findFfmpeg();
  if (!p) throw new Error('ffmpeg が見つかりません。ターミナルで「brew install ffmpeg」を実行してから、もう一度書き出してください。');
  return p;
}

// 起動時の依存チェック(ある=true)
ipcMain.handle('deps-status', async () => ({
  voicevox: fs.existsSync(VV_ENGINE) || (await vvAlive()),
  aquestalkPlayer: fs.existsSync(AQP_APP),
  ffmpeg: !!findFfmpeg(),
}));

ipcMain.handle('aquestalk-info', () => ({ installed: fs.existsSync(AQP_APP), presets: AQP_PRESETS }));

// ---------- 書き出し ----------
ipcMain.handle('choose-export-path', async () => {
  const r = await dialog.showSaveDialog({ defaultPath: 'output.mp4', filters: [{ name: 'MP4', extensions: ['mp4'] }] });
  return r.canceled ? null : r.filePath;
});

// Apple Silicon のメディアエンジンで H.264 / HEVC を作り、音声は Apple の AAC エンコーダを使う
const VT_ARGS = {
  h264: ['-c:v', 'h264_videotoolbox', '-b:v', '16M', '-profile:v', 'high'],
  hevc: ['-c:v', 'hevc_videotoolbox', '-b:v', '12M', '-tag:v', 'hvc1'],
};
ipcMain.handle('finish-export', async (_e, webmBytes, outPath, fps, codec) => {
  const ffmpeg = requireFfmpeg(); // 先に確認(なければ一時ファイルも作らない)
  const tmp = path.join(os.tmpdir(), `yukkuri-export-${Date.now()}.webm`);
  fs.writeFileSync(tmp, Buffer.from(webmBytes));
  try {
  await new Promise((resolve, reject) => {
    const p = spawn(ffmpeg, ['-y', '-i', tmp, '-r', String(fps), ...(VT_ARGS[codec] ?? VT_ARGS.h264), '-pix_fmt', 'yuv420p', '-c:a', 'aac_at', '-b:a', '256k', '-movflags', '+faststart', outPath], {
      env: { ...process.env, PATH: `${path.dirname(ffmpeg)}:/opt/homebrew/bin:/usr/local/bin:${process.env.PATH}` },
    });
    let err = '';
    p.stderr.on('data', (d) => (err += d));
    p.on('error', (e) => reject(e));
    p.on('close', (code) => (code === 0 ? resolve() : reject(new Error(err.slice(-600)))));
  });
  } finally {
    fs.rmSync(tmp, { force: true }); // 失敗しても一時ファイルを残さない
  }
  if (!process.env.YE_SMOKE_OUT) shell.showItemInFolder(outPath);
  return outPath;
});

ipcMain.handle('quit', () => { allowClose = true; app.quit(); }); // 動作確認用の終了は確認なし
