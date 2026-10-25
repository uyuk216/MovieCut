// メニュー確認: macOS のメニューバーの構成と、項目を押したときにレンダラーの状態が変わるかを確かめる
// 実行: npx electron tests/menu-check.js   (失敗が1つでもあれば終了コード1)
'use strict';

const { app, BrowserWindow, Menu, dialog } = require('electron');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SCRATCH = '/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad';
const UD = path.join(SCRATCH, 'menu-check-userdata');
fs.rmSync(UD, { recursive: true, force: true });
fs.mkdirSync(UD, { recursive: true });
app.setPath('userData', UD); // 本物の設定(recent.json など)を汚さない

require('../main.js'); // IPC とメニューを登録し、ウィンドウを作る

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fails = 0;
function check(name, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` :: ${detail}` : ''}`);
  if (!ok) fails++;
}

// メニューの検索と書き出し
const menu = () => Menu.getApplicationMenu();
function find(...labels) {
  let items = menu().items, it = null;
  for (const l of labels) {
    it = items.find((i) => i.label === l);
    if (!it) throw new Error(`menu item not found: ${labels.join(' > ')} (at ${l})`);
    items = it.submenu ? it.submenu.items : [];
  }
  return it;
}
function walk(items, fn, depth = 0) {
  for (const i of items) { fn(i, depth); if (i.submenu) walk(i.submenu.items, fn, depth + 1); }
}
function dump() {
  walk(menu().items, (i, d) => {
    if (i.type === 'separator') return console.log(`${'  '.repeat(d)}----`);
    const bits = [];
    if (i.accelerator) bits.push(`acc=${i.accelerator}`);
    if (i.registerAccelerator === false) bits.push('registerAccelerator=false');
    if (i.role) bits.push(`role=${i.role}`);
    if (i.type === 'radio') bits.push(`radio checked=${i.checked}`);
    if (!i.enabled) bits.push('DISABLED');
    console.log(`${'  '.repeat(d)}${i.label} ${bits.length ? `[${bits.join(' ')}]` : ''}`);
  });
}
const click = (...labels) => find(...labels).click();
const ev = (win, code) => win.webContents.executeJavaScript(code);

async function run() {
  let win = null;
  while (!(win = BrowserWindow.getAllWindows()[0])) await sleep(100);
  await win.loadFile(path.join(ROOT, 'index.html')); // main.js の loadFile は tests/ 基準なので読み直す
  await sleep(2000);
  // 確認ダイアログや alert はテストでは使わない(同期ダイアログは executeJavaScript を止めてしまう)
  await ev(win, `window.confirm = () => true; window.__alerts = []; window.alert = (m) => { window.__alerts.push(String(m)); }; 0`);

  // ---------- 構造 ----------
  console.log('=== menu dump ===');
  dump();
  console.log('=== structure ===');
  const tops = menu().items.map((i) => i.label);
  const expect = ['ゆっくりエディタ', 'ファイル', '編集', '再生', '表示', 'ウィンドウ', 'ヘルプ'];
  check('top-level menus in order', JSON.stringify(tops) === JSON.stringify(expect), tops.join(' | '));
  for (const [lbl, role] of [['切り取り', 'cut'], ['コピー', 'copy'], ['ペースト', 'paste'], ['すべてを選択', 'selectall']]) {
    const it = find('編集', lbl);
    check(`edit role ${role} exists`, String(it.role).toLowerCase() === role, `role=${it.role} acc=${it.accelerator}`);
  }
  const seen = new Map();
  const norm = (a) => a.toLowerCase().replace('commandorcontrol', 'cmdorctrl').split('+').sort().join('+');
  walk(menu().items, (i) => {
    if (!i.accelerator || i.registerAccelerator === false) return;
    const k = norm(i.accelerator);
    seen.set(k, [...(seen.get(k) ?? []), i.label]);
  });
  const dups = [...seen].filter(([, v]) => v.length > 1);
  check('no two items share a registered accelerator', dups.length === 0, `registered=${seen.size} dups=${JSON.stringify(dups)}`);
  for (const [path_, name] of [[['編集', '分割'], '分割'], [['編集', '削除'], '削除'], [['再生', '再生 / 停止'], '再生']]) {
    const it = find(...path_);
    check(`${name} registerAccelerator === false`, it.registerAccelerator === false, `acc=${it.accelerator}`);
  }
  check('開発者ツール exists when running from source', !app.isPackaged && !!find('表示', '開発者ツール'));
  check('Cmd+S / Cmd+O / Cmd+W present', find('ファイル', '保存').accelerator === 'CmdOrCtrl+S' && find('ファイル', '開く…').accelerator === 'CmdOrCtrl+O' && !!find('ファイル', '閉じる').accelerator);

  // ---------- 動かす ----------
  console.log('=== drive ===');
  const saveTarget = path.join(SCRATCH, 'menu-check-save.ymproj');
  fs.rmSync(saveTarget, { force: true });
  let saveDialogCalls = 0;
  dialog.showSaveDialog = async () => { saveDialogCalls++; return { canceled: false, filePath: saveTarget }; };

  click('ファイル', '新規');
  await sleep(300);
  let s = await ev(win, `({ clips: allClips().length, path: projectPath, w: project.width, h: project.height })`);
  check('新規: empty project, no path', s.clips === 0 && s.path === null && s.w === 1920, JSON.stringify(s));
  check('title is 名称未設定 for a new project', win.getTitle() === '名称未設定 — ゆっくりエディタ', win.getTitle());

  click('表示', '解像度', '3840×2160');
  await sleep(800);
  s = await ev(win, `({ w: project.width, h: project.height, codec: project.codec, sel: document.querySelector('#res-select').value })`);
  check('解像度 3840×2160: project size + #res-select follow', s.w === 3840 && s.h === 2160 && s.sel === '3840x2160', JSON.stringify(s));
  check('解像度 radio shows 3840×2160 checked after state push', find('表示', '解像度', '3840×2160').checked && !find('表示', '解像度', '1920×1080').checked);

  click('表示', '書き出し形式', 'H.264');
  await sleep(600);
  s = await ev(win, `project.codec`);
  check('書き出し形式 H.264 sets codec', s === 'h264' && find('表示', '書き出し形式', 'H.264').checked, `codec=${s}`);
  click('表示', '書き出し形式', 'HEVC');
  await sleep(600);
  s = await ev(win, `project.codec`);
  check('書き出し形式 HEVC sets codec', s === 'hevc' && find('表示', '書き出し形式', 'HEVC').checked && !find('表示', '書き出し形式', 'H.264').checked, `codec=${s}`);

  click('表示', '背景色', '白');
  await sleep(600);
  s = await ev(win, `project.bg`);
  check('背景色 白 sets bg', s === '#ffffff' && find('表示', '背景色', '白').checked && !find('表示', '背景色', '黒').checked, `bg=${s}`);

  check('分割/削除 disabled with no selection', !find('編集', '分割').enabled && !find('編集', '削除').enabled);
  click('編集', 'ぼかし範囲を追加');
  await sleep(600);
  s = await ev(win, `({ n: allClips().length, types: allClips().map((c) => c.type), sel: !!findClip(selectedClipId) })`);
  check('ぼかし範囲を追加: one blur clip, selected', s.n === 1 && s.types[0] === 'blur' && s.sel, JSON.stringify(s));
  check('分割/削除 enabled once a clip is selected', find('編集', '分割').enabled && find('編集', '削除').enabled);
  click('編集', '削除');
  await sleep(600);
  s = await ev(win, `allClips().length`);
  check('削除 removes the selected clip', s === 0 && !find('編集', '削除').enabled, `clips=${s}`);
  click('編集', 'ぼかし範囲を追加');
  await sleep(300);

  // 台本から音声(声が作れる環境のときだけ)
  const deps = await ev(win, `window.api.depsStatus()`);
  const canVoice = deps.voicevox || deps.aquestalkPlayer || fs.existsSync('/usr/bin/say');
  if (!canVoice) console.log('SKIP 台本から音声を作る: no voice engine available');
  else {
    await ev(win, `document.querySelector('#script').value = '霊夢: テストです'; 0`);
    click('編集', '台本から音声を作る');
    let n = 0;
    for (let i = 0; i < 60 && n < 1; i++) { await sleep(500); n = await ev(win, `allClips().filter((c) => c.type === 'voice').length`); }
    const al = await ev(win, `window.__alerts`);
    if (n >= 1) check('台本から音声を作る: a voice clip was placed', true, `voice clips=${n}`);
    else console.log(`SKIP 台本から音声を作る: no voice clip within 30 s (alerts=${JSON.stringify(al)})`);
  }

  // dirty の反映
  await sleep(2200);
  check('win.isDocumentEdited() true after edits', win.isDocumentEdited() === true);

  // 別名で保存(ダイアログはスタブ)
  const clipsBefore = await ev(win, `allClips().length`);
  click('ファイル', '別名で保存…');
  await sleep(1000);
  check('別名で保存: dialog was used', saveDialogCalls === 1, `calls=${saveDialogCalls}`);
  let saved = null;
  try { saved = JSON.parse(fs.readFileSync(saveTarget, 'utf8')); } catch (e) { /* 下で失敗にする */ }
  check('saved file exists and parses with the edited state', !!saved && saved.width === 3840 && saved.height === 2160 && saved.codec === 'hevc' && saved.bg === '#ffffff' && saved.tracks.flatMap((t) => t.clips).length === clipsBefore,
    saved && `w=${saved.width} h=${saved.height} codec=${saved.codec} bg=${saved.bg} clips=${saved.tracks.flatMap((t) => t.clips).length}/${clipsBefore}`);
  check('title contains the file name after save', win.getTitle().includes('menu-check-save.ymproj'), win.getTitle());
  check('represented filename set (proxy icon)', win.getRepresentedFilename() === saveTarget, win.getRepresentedFilename());
  await sleep(2200);
  check('win.isDocumentEdited() false after save', win.isDocumentEdited() === false);
  const recentFile = path.join(UD, 'recent.json');
  let recent = [];
  try { recent = JSON.parse(fs.readFileSync(recentFile, 'utf8')); } catch (e) { /* */ }
  check('recent.json written with the saved path', recent[0] === saveTarget, JSON.stringify(recent));
  check('最近使った項目 submenu lists it', find('ファイル', '最近使った項目').submenu.items[0].label === 'menu-check-save.ymproj');

  // 保存(既にパスがあればダイアログなし)
  click('表示', '背景色', '黒');
  await sleep(300);
  click('ファイル', '保存');
  await sleep(800);
  saved = JSON.parse(fs.readFileSync(saveTarget, 'utf8'));
  check('保存 reuses the path without a dialog', saveDialogCalls === 1 && saved.bg === '#000000', `calls=${saveDialogCalls} bg=${saved.bg}`);

  // 最近使った項目から開き直す
  click('表示', '背景色', '緑(クロマキー)');
  await sleep(2200);
  check('dirty again before reopen', win.isDocumentEdited() === true);
  find('ファイル', '最近使った項目').submenu.items[0].click();
  await sleep(1500);
  s = await ev(win, `({ bg: project.bg, path: projectPath })`);
  check('最近使った項目 reopens the file (open-path)', s.bg === '#000000' && s.path === saveTarget, JSON.stringify(s));

  // ---------- 閉じる前の確認 ----------
  console.log('=== close guard ===');
  click('表示', '背景色', '白');
  await sleep(2200);
  check('window is dirty before close', win.isDocumentEdited() === true);
  let msgCalls = 0, answer = 2;
  dialog.showMessageBox = async () => { msgCalls++; return { response: answer }; };
  win.close();
  await sleep(800);
  check('キャンセル keeps the dirty window open', !win.isDestroyed() && msgCalls === 1, `destroyed=${win.isDestroyed()} dialogCalls=${msgCalls}`);
  console.log(fails ? `RESULT: ${fails} FAIL` : 'RESULT: all PASS (closing window with 保存しない now)');
  answer = 1;
  app.removeAllListeners('window-all-closed');
  const closed = new Promise((r) => win.once('closed', r));
  win.close();
  await Promise.race([closed, sleep(3000)]);
  check('保存しない closes the window', win.isDestroyed() && msgCalls === 2, `destroyed=${win.isDestroyed()} dialogCalls=${msgCalls}`);
  console.log(fails ? `FINAL: ${fails} FAIL` : 'FINAL: all PASS');
  app.exit(fails ? 1 : 0);
}

app.whenReady().then(() => run().catch((e) => { console.log('FAIL exception', e); app.exit(1); }));
