// 画面の見た目の確認用: 既定・台本・各プロパティ・設定ダイアログ・各解像度を撮影する(確認用スクリプト)
// 実行: npx electron tests/ui-shots.js   出力: $SHOT_DIR/ui2-*.png
'use strict';
const { app, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');
const ROOT = path.join(__dirname, '..');
const OUT = process.env.SHOT_DIR || '/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad';
require('../main.js');
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

app.whenReady().then(async () => {
  let win; while (!(win = BrowserWindow.getAllWindows()[0])) await sleep(100);
  // executeJavaScript は全部同じグローバルを共有するので、毎回 IIFE で包んで const の重複を避ける
  const js = (s) => win.webContents.executeJavaScript(`(() => { ${s} })()`);
  const snap = async (n) => { fs.writeFileSync(path.join(OUT, `ui2-${n}.png`), (await win.webContents.capturePage()).toPNG()); console.log('shot', n); };
  const setRes = async (v) => { await js(`const s = $('#res-select'); s.value = '${v}'; s.dispatchEvent(new Event('change', { bubbles: true }));`); await sleep(400); };

  async function set(W, H, sfx) {
    const n = (name) => name + sfx;
    win.setSize(W, H); await win.loadFile(path.join(ROOT, 'index.html')); await sleep(2500);
    await js(`window.alert = (m) => { window.__alert = m; }; window.confirm = () => true;`);
    await snap(n('default'));
    await js(`$('#script').value = '霊夢: ゆっくりしていってね\\nずんだもん: こんにちは\\n魔理沙: 今日もよろしくね'; $('#btn-script').click();`); await sleep(6000);
    await snap(n('script'));
    await js(`$('#btn-text').click();`); await sleep(300); await snap(n('text-selected'));
    await js(`$('#btn-blur').click();`); await sleep(300); await snap(n('blur-selected'));
    await js(`document.querySelector('.clip.voice').dispatchEvent(new MouseEvent('mousedown', { bubbles: true, clientX: 200, clientY: 600 }));`); await sleep(200);
    await js(`window.dispatchEvent(new MouseEvent('mouseup'));`); await sleep(300); await snap(n('voice-selected'));
    await js(`document.querySelector('.char').click();`); await sleep(300); await snap(n('char-selected'));
    await js(`const r = $('#right'); r.scrollTop = r.scrollHeight;`); await sleep(200); await snap(n('char-selected-bottom'));
    await js(`$('#btn-settings').click();`); await sleep(400); await snap(n('settings'));
    await js(`$('#dlg-settings').close();`); await sleep(200);
    await setRes('1080x1920'); await snap(n('portrait-1080x1920'));
    await setRes('3840x2160'); await snap(n('uhd-3840x2160'));
    await setRes('1920x1080');
    await js(`$('#btn-settings').click(); const p = $('#set-bg-preset'); p.value = '#ffffff'; p.dispatchEvent(new Event('change')); $('#dlg-settings').close();`); await sleep(400); await snap(n('white-bg'));
  }
  await set(1400, 900, '');
  await set(1100, 700, '-1100x700');
  app.exit(0);
});
