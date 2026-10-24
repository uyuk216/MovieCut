// レイアウト確認: タイムラインの拡大(#zoom)を変えても、ウィンドウからはみ出さないかを確かめる
// 実行: npx electron tests/layout-check.js   (失敗が1つでもあれば終了コード1)
'use strict';

const { app, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SCRATCH = '/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad';
const ZOOMS = [10, 80, 400];

require('../main.js'); // IPC とプロトコルを登録し、ウィンドウを作る

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let fails = 0;
function check(name, ok, detail) {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}${detail ? ` :: ${detail}` : ''}`);
  if (!ok) fails++;
}

// ページ内で要素の矩形を集める(数値だけを返す)
const MEASURE = `(() => {
  const R = (s) => { const e = document.querySelector(s); if (!e) return null;
    const r = e.getBoundingClientRect(); return { l: r.left, t: r.top, r: r.right, b: r.bottom, w: r.width, h: r.height }; };
  const heads = [...document.querySelectorAll('.track-head')].map((h) => {
    const hr = h.getBoundingClientRect();
    const labels = [...h.querySelectorAll('label')].map((l) => {
      const r = l.getBoundingClientRect();
      return { text: l.textContent.trim(), inside: r.left >= hr.left - 1 && r.right <= hr.right + 1 && r.top >= hr.top - 1 && r.bottom <= hr.bottom + 1 };
    });
    return { labels };
  });
  return {
    scrollWidth: document.documentElement.scrollWidth,
    innerWidth: window.innerWidth,
    right: R('#right'), transport: R('#transport'), timecode: R('#timecode'),
    previewWrap: R('#preview-wrap'), preview: R('#preview'), heads,
  };
})()`;

function setZoom(win, n) {
  return win.webContents.executeJavaScript(
    `(() => { const z = document.querySelector('#zoom'); z.value = '${n}'; z.dispatchEvent(new Event('input', { bubbles: true })); return z.value; })()`,
  );
}

async function run() {
  let win = null;
  while (!(win = BrowserWindow.getAllWindows()[0])) await sleep(100);
  win.setSize(1400, 900);
  // main.js の loadFile('index.html') は tests/ 基準で解決されるので、プロジェクト直下の index.html を読み直す
  await win.loadFile(path.join(ROOT, 'index.html'));
  await sleep(1500);

  for (const n of ZOOMS) {
    console.log(`--- zoom ${n} px/s ---`);
    await setZoom(win, n);
    await sleep(300);
    const m = await win.webContents.executeJavaScript(MEASURE);
    const z = `zoom${n}`;

    check(`${z} scrollWidth<=innerWidth`, m.scrollWidth <= m.innerWidth, `scrollWidth=${m.scrollWidth} innerWidth=${m.innerWidth}`);
    check(`${z} #right inside viewport`, !!m.right && m.right.r <= m.innerWidth + 0.5, `right=${m.right && m.right.r.toFixed(1)}`);
    check(`${z} #timecode inside viewport`, !!m.timecode && m.timecode.r <= m.innerWidth + 0.5, `timecode.right=${m.timecode && m.timecode.r.toFixed(1)}`);
    check(`${z} #preview has size`, !!m.preview && m.preview.w > 0 && m.preview.h > 0, `preview=${m.preview && `${m.preview.w.toFixed(0)}x${m.preview.h.toFixed(0)}`}`);
    const w = m.previewWrap, p = m.preview;
    const inside = !!w && !!p && p.l >= w.l - 1 && p.r <= w.r + 1 && p.t >= w.t - 1 && p.b <= w.b + 1;
    check(`${z} #preview inside #preview-wrap`, inside, w && p ? `wrap=[${w.l.toFixed(0)},${w.t.toFixed(0)},${w.r.toFixed(0)},${w.b.toFixed(0)}] preview=[${p.l.toFixed(0)},${p.t.toFixed(0)},${p.r.toFixed(0)},${p.b.toFixed(0)}]` : 'missing');
    // 追加: wrap 自体が伸びると上の判定は通ってしまうので、プレビューが画面内に見えているかも確かめる
    check(`${z} #preview inside viewport`, !!p && p.l >= -0.5 && p.r <= m.innerWidth + 0.5, p ? `preview.left=${p.l.toFixed(0)} preview.right=${p.r.toFixed(0)} innerWidth=${m.innerWidth}` : 'missing');
    const bad = m.heads.flatMap((h) => h.labels.filter((l) => !l.inside).map((l) => l.text));
    check(`${z} track-head labels fit in header`, m.heads.length > 0 && bad.length === 0, m.heads.length === 0 ? 'no track heads' : `clipped: ${bad.join(', ') || 'none'}`);

    const img = await win.webContents.capturePage();
    fs.writeFileSync(`${SCRATCH}/layout-zoom-${n}.png`, img.toPNG());
    console.log(`screenshot: ${SCRATCH}/layout-zoom-${n}.png`);
  }

  console.log(fails ? `RESULT: ${fails} FAIL` : 'RESULT: all PASS');
  app.exit(fails ? 1 : 0);
}

app.whenReady().then(() => run().catch((e) => { console.log(`FAIL harness error :: ${e.stack || e}`); app.exit(1); }));
