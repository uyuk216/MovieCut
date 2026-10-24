// レイアウト確認: タイムラインの拡大(#zoom)を変えても、ウィンドウからはみ出さないかを確かめる
// 実行: npx electron tests/layout-check.js   (失敗が1つでもあれば終了コード1)
'use strict';

const { app, BrowserWindow } = require('electron');
const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '..');
const SCRATCH = '/private/tmp/claude-501/-Users-USER------------/07529bfa-5715-4444-bf9c-c37229b6ab4d/scratchpad';
const ZOOMS = [10, 80, 400];
const SIZES = [[1400, 900], [1100, 700]];

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
    exportBtn: R('#btn-export'), script: R('#btn-script'), timeline: R('#timeline'), tlArea: R('#timeline-area'), innerHeight: window.innerHeight,
    tlBar: (() => { const t = document.querySelector('#timeline'); return { dh: t.offsetHeight - t.clientHeight, dw: t.offsetWidth - t.clientWidth, ovx: t.scrollWidth > t.clientWidth, ovy: t.scrollHeight > t.clientHeight }; })(),
    headsClip: [...document.querySelectorAll('.track-head')].filter((h) => h.scrollWidth > h.clientWidth || h.scrollHeight > h.clientHeight).length,
    leftScroll: (() => { const l = document.querySelector('#left'); return l.scrollHeight - l.clientHeight; })(),
    playhead: (() => { const p = document.querySelector('#playhead'), t = document.querySelector('#tracks'), r = document.querySelector('#ruler'); return { h: p.offsetHeight, need: t.offsetHeight + r.offsetHeight }; })(),
  };
})()`;

function setZoom(win, n) {
  return win.webContents.executeJavaScript(
    `(() => { const z = document.querySelector('#zoom'); z.value = '${n}'; z.dispatchEvent(new Event('input', { bubbles: true })); return z.value; })()`,
  );
}

async function snap(win, file) {
  const img = await win.webContents.capturePage();
  fs.writeFileSync(file, img.toPNG());
  console.log(`screenshot: ${file}`);
}

function verify(z, m) {
  check(`${z} scrollWidth<=innerWidth`, m.scrollWidth <= m.innerWidth, `scrollWidth=${m.scrollWidth} innerWidth=${m.innerWidth}`);
  const inView = (r) => !!r && r.l >= -0.5 && r.t >= -0.5 && r.r <= m.innerWidth + 0.5 && r.b <= m.innerHeight + 0.5;
  check(`${z} #right inside viewport`, inView(m.right), m.right && `right=${m.right.r.toFixed(1)} bottom=${m.right.b.toFixed(1)}`);
  check(`${z} #timecode inside viewport`, inView(m.timecode), m.timecode && `timecode=[${m.timecode.l.toFixed(0)},${m.timecode.r.toFixed(0)}]`);
  check(`${z} #btn-export inside viewport`, inView(m.exportBtn), m.exportBtn && `export.right=${m.exportBtn.r.toFixed(1)}`);
  check(`${z} #preview has size`, !!m.preview && m.preview.w > 0 && m.preview.h > 0, m.preview && `${m.preview.w.toFixed(0)}x${m.preview.h.toFixed(0)}`);
  const w = m.previewWrap, p = m.preview;
  check(`${z} #preview inside #preview-wrap`, !!w && !!p && p.l >= w.l - 1 && p.r <= w.r + 1 && p.t >= w.t - 1 && p.b <= w.b + 1, w && p ? `wrap=[${w.l.toFixed(0)},${w.t.toFixed(0)},${w.r.toFixed(0)},${w.b.toFixed(0)}] preview=[${p.l.toFixed(0)},${p.t.toFixed(0)},${p.r.toFixed(0)},${p.b.toFixed(0)}]` : 'missing');
  check(`${z} #preview inside viewport`, inView(p));
  const bad = m.heads.flatMap((h) => h.labels.filter((l) => !l.inside).map((l) => l.text));
  check(`${z} track-head labels fit in header`, m.heads.length > 0 && bad.length === 0, m.heads.length === 0 ? 'no track heads' : `clipped: ${bad.join(', ') || 'none'}`);
  check(`${z} no .track-head scrollWidth>clientWidth`, m.headsClip === 0, `clipping heads=${m.headsClip}`);
  check(`${z} #btn-script fully visible w/o scrolling #left`, inView(m.script) && m.script.b <= m.tlArea.t + 0.5 && m.leftScroll <= 1, m.script && `script.bottom=${m.script.b.toFixed(0)} left overflow=${m.leftScroll}`);
  const th = m.tlArea.h;
  check(`${z} timeline height within 160..55%`, th >= 160 - 1 && th <= m.innerHeight * 0.55 + 1, `timeline-area h=${th.toFixed(0)} innerHeight=${m.innerHeight}`);
  check(`${z} #timeline has no visible scrollbar`, m.tlBar.dh === 0 && m.tlBar.dw === 0, `offset-client dh=${m.tlBar.dh} dw=${m.tlBar.dw} overflowX=${m.tlBar.ovx} overflowY=${m.tlBar.ovy}`);
  check(`${z} playhead spans tracks`, m.playhead.h >= m.playhead.need - 1, `playhead=${m.playhead.h} need=${m.playhead.need}`);
}

async function measure(win, z, file) {
  await sleep(300);
  const m = await win.webContents.executeJavaScript(MEASURE);
  verify(z, m);
  await snap(win, file);
}

async function run() {
  let win = null;
  while (!(win = BrowserWindow.getAllWindows()[0])) await sleep(100);
  for (const [W, H] of SIZES) {
    win.setSize(W, H);
    await win.loadFile(path.join(ROOT, 'index.html')); // main.js の loadFile は tests/ 基準なので読み直す
    await sleep(1500);
    // 最小サイズの確認
    const [mw, mh] = win.getMinimumSize();
    check(`${W}x${H} window minimum size 1100x700`, mw === 1100 && mh === 700, `min=${mw}x${mh}`);
    for (const n of ZOOMS) {
      const z = `${W}x${H} zoom${n}`;
      console.log(`--- ${W}x${H} zoom ${n} px/s ---`);
      await setZoom(win, n);
      await measure(win, z, `${SCRATCH}/polish-${W}x${H}-zoom${n}.png`);
    }
    console.log(`--- ${W}x${H} 全体表示 ---`);
    await win.webContents.executeJavaScript(`document.querySelector('#btn-fit').click()`);
    await measure(win, `${W}x${H} fit`, `${SCRATCH}/polish-${W}x${H}-zoomfit.png`);
    const fit = await win.webContents.executeJavaScript(`(() => { const t = document.querySelector('#timeline'); return { z: +document.querySelector('#zoom').value, sl: t.scrollLeft, sw: t.scrollWidth, cw: t.clientWidth }; })()`);
    check(`${W}x${H} fit: 10s fits visible width`, 90 + 10 * fit.z <= fit.cw + 1, `zoom=${fit.z.toFixed(1)} clientWidth=${fit.cw}`);

    // スクロールバー無しでも scrollLeft で動くか(zoom 400)
    await setZoom(win, 400);
    await sleep(200);
    const sc = await win.webContents.executeJavaScript(`(() => { const t = document.querySelector('#timeline'); t.scrollLeft = 500; return { sl: t.scrollLeft, ov: t.scrollWidth > t.clientWidth, dh: t.offsetHeight - t.clientHeight, dw: t.offsetWidth - t.clientWidth }; })()`);
    check(`${W}x${H} zoom400 scrollLeft works & no scrollbar`, sc.ov && sc.sl === 500 && sc.dh === 0 && sc.dw === 0, JSON.stringify(sc));
    // Ctrl+wheel でポインタ下の時刻が動かない
    const zr = await win.webContents.executeJavaScript(`(async () => {
      const t = document.querySelector('#timeline'); const z = document.querySelector('#zoom');
      z.value = '100'; z.dispatchEvent(new Event('input')); t.scrollLeft = 300;
      const x = 400, r = t.getBoundingClientRect();
      const before = (x + t.scrollLeft - 90) / 100;
      t.dispatchEvent(new WheelEvent('wheel', { deltaY: -50, ctrlKey: true, clientX: r.left + x, clientY: r.top + 50, bubbles: true, cancelable: true }));
      const pps = +z.value; const after = (x + t.scrollLeft - 90) / pps;
      return { pps, before, after };
    })()`);
    check(`${W}x${H} ctrl+wheel zooms around pointer`, zr.pps > 100 && Math.abs(zr.before - zr.after) < 0.05, JSON.stringify(zr));
    // 縦にあふれない時、ホイールで横に動く
    const wh = await win.webContents.executeJavaScript(`(() => {
      const t = document.querySelector('#timeline'); t.scrollLeft = 0;
      t.dispatchEvent(new WheelEvent('wheel', { deltaY: 120, bubbles: true, cancelable: true }));
      return { sl: t.scrollLeft, vov: t.scrollHeight > t.clientHeight };
    })()`);
    check(`${W}x${H} plain wheel scrolls horizontally (no vertical overflow)`, wh.vov || wh.sl > 0, JSON.stringify(wh));
  }

  // 白背景・台本つきのスクリーンショット(1400x900)
  win.setSize(1400, 900);
  await win.loadFile(path.join(ROOT, 'index.html'));
  await sleep(1500);
  await setZoom(win, 40);
  const bg = await win.webContents.executeJavaScript(`(() => {
    const s = document.querySelector('#set-bg-preset');
    const out = {};
    document.querySelector('#btn-settings').click();
    out.defaultBg = document.querySelector('#set-bg').value; out.defaultPreset = s.value;
    s.value = '#ffffff'; s.dispatchEvent(new Event('change'));
    out.afterPreset = document.querySelector('#set-bg').value;
    const c = document.querySelector('#set-bg'); c.value = '#123456'; c.dispatchEvent(new Event('input'));
    out.afterEdit = s.value;
    s.value = '#ffffff'; s.dispatchEvent(new Event('change'));
    document.querySelector('#dlg-settings').close();
    return out;
  })()`);
  check('default bg black + preset 黒', bg.defaultBg === '#000000' && bg.defaultPreset === '#000000', JSON.stringify(bg));
  check('preset sets colour / edit switches to 自由', bg.afterPreset === '#ffffff' && bg.afterEdit === 'custom', JSON.stringify(bg));
  await sleep(400);
  await snap(win, `${SCRATCH}/polish-white-bg.png`);

  // alert/confirm は止まるので潰してから台本を流す(音声エンジンが無ければ0クリップ→スキップ)
  let clips = 0;
  try {
    await win.webContents.executeJavaScript("window.alert = (m) => { window.__alert = m; }; window.confirm = () => true; document.querySelector('#script').value = '霊夢: ゆっくりしていってね\\nまりさ: こんにちは\\n魔理沙: よろしくね'; document.querySelector('#btn-script').click(); 0");
    await sleep(8000);
    clips = await win.webContents.executeJavaScript(`document.querySelectorAll('.clip').length`);
    console.log('script alert:', await win.webContents.executeJavaScript('window.__alert || null'));
  } catch (e) { console.log('NOTE: script step error:', String(e).slice(0, 120)); }
  if (clips > 0) {
    await win.webContents.executeJavaScript(`document.querySelector('#btn-fit').click()`);
    await sleep(500);
    await snap(win, `${SCRATCH}/polish-script-loaded.png`);
    const m = await win.webContents.executeJavaScript(MEASURE);
    verify('script-loaded', m);
  } else console.log('NOTE: script synthesis produced no clips; loaded-project screenshot skipped');

  console.log(fails ? `RESULT: ${fails} FAIL` : 'RESULT: all PASS');
  app.exit(fails ? 1 : 0);
}

app.whenReady().then(() => run().catch((e) => { console.log(`FAIL harness error :: ${e.stack || e}`); app.exit(1); }));
