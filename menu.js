// macOS のメニューバー(日本語)。項目はレンダラーへ 'menu-action' を送るだけで、
// 実際の処理はツールバーのボタンと同じ関数を呼ぶ(renderer.js 側で対応づける)
'use strict';
const { app, Menu, shell } = require('electron');
const path = require('path');
const fs = require('fs');

// 解像度の候補(画面の #res-select と同じ並び)
const RESOLUTIONS = [
  ['1920x1080', '1920×1080'],
  ['2560x1440', '2560×1440'],
  ['3840x2160', '3840×2160'],
  ['1080x1920', '縦 1080×1920'],
  ['720x1280', '縦 720×1280'],
  ['1080x1080', '正方形 1080×1080'],
];
const BACKGROUNDS = [['#000000', '黒'], ['#ffffff', '白'], ['#00b140', '緑(クロマキー)']];
const CODECS = [['h264', 'H.264'], ['hevc', 'HEVC']];

// パッケージ内(asar)のファイルは外のアプリで開けないので、userData にコピーしてから開く
function openBundled(rel) {
  const dst = path.join(app.getPath('userData'), 'docs', path.basename(rel));
  fs.mkdirSync(path.dirname(dst), { recursive: true });
  fs.copyFileSync(path.join(__dirname, rel), dst);
  return shell.openPath(dst);
}

// ctx: { send(id, arg), getUi(), getRecent(), clearRecent() }
function createMenu(ctx) {
  const act = (id, arg) => () => ctx.send(id, arg);

  function template() {
    const ui = ctx.getUi();
    const recent = ctx.getRecent();
    const resKey = `${ui.width}x${ui.height}`;
    const resItems = RESOLUTIONS.map(([k, label]) => ({ label, type: 'radio', checked: k === resKey, click: act('set-resolution', k) }));
    if (!RESOLUTIONS.some(([k]) => k === resKey)) resItems.push({ label: `${ui.width}×${ui.height}`, type: 'radio', checked: true, click: act('set-resolution', resKey) });
    resItems.push({ type: 'separator' }, { label: '自由…', click: act('settings') });

    return [
      {
        label: 'ゆっくりエディタ',
        submenu: [
          { label: 'ゆっくりエディタについて', click: () => app.showAboutPanel() },
          { type: 'separator' },
          { label: '設定…', accelerator: 'CmdOrCtrl+,', click: act('settings') },
          { type: 'separator' },
          { label: 'サービス', role: 'services' },
          { type: 'separator' },
          { label: 'ゆっくりエディタを隠す', role: 'hide' },
          { label: 'ほかを隠す', role: 'hideOthers' },
          { label: 'すべてを表示', role: 'unhide' },
          { type: 'separator' },
          { label: '終了', role: 'quit', accelerator: 'CmdOrCtrl+Q' },
        ],
      },
      {
        label: 'ファイル',
        submenu: [
          { label: '新規', accelerator: 'CmdOrCtrl+N', click: act('new') },
          { label: '開く…', accelerator: 'CmdOrCtrl+O', click: act('open') },
          {
            label: '最近使った項目',
            submenu: [
              ...recent.map((p) => ({ label: path.basename(p), sublabel: p, click: act('open-path', p) })),
              ...(recent.length ? [{ type: 'separator' }] : []),
              { label: 'メニューを消去', enabled: recent.length > 0, click: () => ctx.clearRecent() },
            ],
          },
          { type: 'separator' },
          { label: '保存', accelerator: 'CmdOrCtrl+S', click: act('save') },
          { label: '別名で保存…', accelerator: 'Shift+CmdOrCtrl+S', click: act('save-as') },
          { type: 'separator' },
          { label: '素材を追加…', accelerator: 'CmdOrCtrl+I', click: act('add-media') },
          { type: 'separator' },
          { label: 'MP4 を書き出す…', accelerator: 'CmdOrCtrl+E', click: act('export') },
          { type: 'separator' },
          { label: '閉じる', role: 'close', accelerator: 'CmdOrCtrl+W' },
        ],
      },
      {
        label: '編集',
        submenu: [
          { label: '切り取り', role: 'cut' },
          { label: 'コピー', role: 'copy' },
          { label: 'ペースト', role: 'paste' },
          { label: 'すべてを選択', role: 'selectAll' },
          { type: 'separator' },
          // 表示だけのショートカット(キーはレンダラーが受ける。登録すると入力欄で打てなくなる)
          { label: '分割', accelerator: 'S', registerAccelerator: false, enabled: ui.hasSelection, click: act('split') },
          { label: '削除', accelerator: 'Backspace', registerAccelerator: false, enabled: ui.hasSelection, click: act('delete') },
          { type: 'separator' },
          { label: 'テキストを追加', accelerator: 'Shift+CmdOrCtrl+T', click: act('add-text') },
          { label: 'ぼかし範囲を追加', accelerator: 'Shift+CmdOrCtrl+B', click: act('add-blur') },
          { label: 'キャラクターを追加', accelerator: 'Shift+CmdOrCtrl+C', click: act('add-char') },
          { label: '台本から音声を作る', accelerator: 'CmdOrCtrl+Return', click: act('make-voices') },
        ],
      },
      {
        label: '再生',
        submenu: [
          { label: '再生 / 停止', accelerator: 'Space', registerAccelerator: false, click: act('play') },
          { label: '先頭へ戻る', accelerator: 'Home', registerAccelerator: false, click: act('home') },
          { label: '1コマ戻る', accelerator: 'Left', registerAccelerator: false, click: act('step-back') },
          { label: '1コマ進む', accelerator: 'Right', registerAccelerator: false, click: act('step-forward') },
        ],
      },
      {
        label: '表示',
        submenu: [
          { label: 'タイムラインを拡大', accelerator: 'CmdOrCtrl+=', click: act('zoom-in') },
          { label: 'タイムラインを縮小', accelerator: 'CmdOrCtrl+-', click: act('zoom-out') },
          { label: '全体表示', accelerator: 'CmdOrCtrl+0', click: act('zoom-fit') },
          { type: 'separator' },
          { label: '解像度', submenu: resItems },
          { label: '書き出し形式', submenu: CODECS.map(([k, label]) => ({ label, type: 'radio', checked: ui.codec === k, click: act('set-codec', k) })) },
          { label: '背景色', submenu: BACKGROUNDS.map(([k, label]) => ({ label, type: 'radio', checked: String(ui.bg).toLowerCase() === k, click: act('set-bg', k) })) },
          { type: 'separator' },
          { label: 'プレビューを別画面に表示', accelerator: 'CmdOrCtrl+P', click: act('popout') },
          { type: 'separator' },
          { label: '全画面表示', role: 'togglefullscreen' },
          ...(app.isPackaged ? [] : [{ label: '開発者ツール', role: 'toggleDevTools' }]),
        ],
      },
      { label: 'ウィンドウ', role: 'windowMenu' },
      {
        label: 'ヘルプ',
        role: 'help',
        submenu: [
          { label: 'VOICEVOX 公式サイト', click: () => shell.openExternal('https://voicevox.hiroshiba.jp/') },
          { label: 'AquesTalkPlayer 公式サイト', click: () => shell.openExternal('https://www.a-quest.com/products/aquestalkplayer.html') },
          { type: 'separator' },
          { label: 'ライセンス', click: () => openBundled('LICENSE.ja.md') },
          { label: '第三者の規約', click: () => openBundled(path.join('docs', '第三者の規約.md')) },
        ],
      },
    ];
  }

  return {
    rebuild() {
      Menu.setApplicationMenu(Menu.buildFromTemplate(template()));
    },
    dockMenu() {
      return Menu.buildFromTemplate([
        { label: '新規', click: act('new') },
        { label: '開く…', click: act('open') },
      ]);
    },
  };
}

module.exports = { createMenu };
