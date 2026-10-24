// メインプロセス: ウィンドウ、ファイル操作、音声エンジン連携、ffmpeg 書き出し
const { app, BrowserWindow, ipcMain, dialog, shell, screen, protocol, net } = require('electron');
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

function createWindow() {
  const saved = loadBounds();
  const win = new BrowserWindow({
    width: 1400,
    height: 900,
    ...(saved ?? {}),
    title: 'ゆっくりエディタ',
    backgroundColor: '#1e1f24',
    webPreferences: { preload: path.join(__dirname, 'preload.js') },
  });
  if (saved?.maximized) win.maximize();
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
  createWindow();
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
    const r = await dialog.showSaveDialog({ defaultPath: 'project.ymproj', filters: [{ name: 'プロジェクト', extensions: ['ymproj'] }] });
    if (r.canceled) return null;
    p = r.filePath;
  }
  fs.writeFileSync(p, json);
  return p;
});

ipcMain.handle('load-project', async () => {
  const r = await dialog.showOpenDialog({ properties: ['openFile'], filters: [{ name: 'プロジェクト', extensions: ['ymproj'] }] });
  if (r.canceled) return null;
  return { path: r.filePaths[0], json: fs.readFileSync(r.filePaths[0], 'utf8') };
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

ipcMain.handle('quit', () => app.quit());
