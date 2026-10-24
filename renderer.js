// 編集画面: プロジェクト、タイムライン、プレビュー、音声、書き出し
'use strict';

const $ = (s) => document.querySelector(s);
const uid = () => Math.random().toString(36).slice(2, 10);
const fileUrl = (p) => 'media://local' + p.split('/').map(encodeURIComponent).join('/');
const esc = (s) => String(s).replace(/[&<>"']/g, (ch) => `&#${ch.charCodeAt(0)};`);
const fmt = (t) => {
  const m = Math.floor(t / 60), s = t - m * 60;
  return `${String(m).padStart(2, '0')}:${s.toFixed(2).padStart(5, '0')}`;
};

// macOS 標準の日本語フォント(この Mac で確認済み)
const FONTS = ['Hiragino Maru Gothic ProN', 'Hiragino Sans', 'Hiragino Mincho ProN', 'YuGothic', 'YuMincho', 'Klee', 'Toppan Bunkyu Gothic'];

// ---------- プロジェクト ----------
const AQP_COMMAND = '/Applications/AquesTalkPlayer.app/Contents/MacOS/AquesTalkPlayer -P {voice} -T {text} -W {out}';
const KYOKO_COMMAND = 'say -v Kyoko -o {out} --data-format=LEI16@24000 {text}';
function newProject() {
  return {
    width: 1920, height: 1080, fps: 60, bg: '#00b140', codec: 'h264',
    voicevoxUrl: 'http://127.0.0.1:50021',
    // AquesTalkPlayer Mac版(ネイティブ)。入っていなければ起動時に Kyoko へ切り替える
    aquestalkCommand: AQP_COMMAND,
    characters: [
      { id: uid(), name: '霊夢', engine: 'aquestalk', voice: 'れいむ', speed: 100, color: '#e8384f', ...charDefaults(0) },
      { id: uid(), name: '魔理沙', engine: 'aquestalk', voice: 'まりさ', speed: 100, color: '#f2c53d', ...charDefaults(1) },
      { id: uid(), name: 'ずんだもん', engine: 'voicevox', speaker: 3, speed: 1, pitch: 0, intonation: 1, color: '#7ac943', ...charDefaults(2) },
    ],
    tracks: [0, 1, 2, 3, 4].map((i) => ({ id: uid(), name: `レイヤー${i + 1}`, clips: [] })),
  };
}
function charDefaults(i) {
  return { imgClosed: null, imgOpen: null, x: [0.18, 0.82, 0.82][i] ?? 0.5, y: 0.72, scale: 1, flip: i === 0, alwaysShow: true };
}

let project = newProject();
let projectPath = null;
let selectedClipId = null;
let selectedCharId = project.characters[0].id;
let t = 0;
let playing = false;
let pps = 80; // 1秒あたりの画素数

// ---------- 素材キャッシュ ----------
const images = new Map(); // path -> HTMLImageElement
const videos = new Map(); // clipId -> HTMLVideoElement
const buffers = new Map(); // path -> AudioBuffer
const envelopes = new Map(); // path -> Float32Array(口パク用の音量, 1/60秒ごと)

const actx = new AudioContext({ latencyHint: 'playback', sampleRate: 48000 });
const master = actx.createGain();
master.connect(actx.destination);
const recordDest = actx.createMediaStreamDestination();
master.connect(recordDest);

function getImage(p) {
  if (!p) return null;
  let img = images.get(p);
  if (!img) {
    img = new Image();
    img.crossOrigin = 'anonymous';
    img.onload = draw;
    img.src = fileUrl(p);
    images.set(p, img);
  }
  return img.complete && img.naturalWidth ? img : null;
}

function getVideo(clip) {
  let v = videos.get(clip.id);
  if (!v || v.dataset.src !== clip.src) {
    if (v) disposeVideo(clip.id); // 素材が変わったら古い要素を捨てる
    v = document.createElement('video');
    v.dataset.src = clip.src;
    v.crossOrigin = 'anonymous';
    v.src = fileUrl(clip.src);
    v.preload = 'auto';
    v.playsInline = true;
    v.addEventListener('seeked', draw);
    v.addEventListener('loadeddata', draw);
    // 動画の音も WebAudio に通す(書き出しで録音できるように)
    const g = actx.createGain();
    actx.createMediaElementSource(v).connect(g).connect(master);
    v._gain = g;
    videos.set(clip.id, v);
  }
  return v;
}

// 動画の要素を片付ける(消したクリップや新規・読み込みで残さない)
function disposeVideo(id) {
  const v = videos.get(id);
  if (!v) return;
  try { v.pause(); v._gain?.disconnect(); v.removeAttribute('src'); v.load(); } catch {}
  videos.delete(id);
}
function disposeAllVideos() { [...videos.keys()].forEach(disposeVideo); }

async function getBuffer(p) {
  if (buffers.has(p)) return buffers.get(p);
  const res = await fetch(fileUrl(p));
  const buf = await actx.decodeAudioData(await res.arrayBuffer());
  buffers.set(p, buf);
  // 口パク用に 1/60 秒ごとの音量を計算しておく
  const data = buf.getChannelData(0), step = Math.floor(buf.sampleRate / 60);
  const env = new Float32Array(Math.ceil(data.length / step));
  for (let i = 0; i < env.length; i++) {
    let sum = 0;
    for (let j = i * step, e = Math.min(data.length, j + step); j < e; j++) sum += data[j] * data[j];
    env[i] = Math.sqrt(sum / step);
  }
  envelopes.set(p, env);
  return buf;
}

function probeDuration(p, kind) {
  return new Promise((resolve) => {
    const el = document.createElement(kind);
    el.preload = 'metadata';
    el.onloadedmetadata = () => resolve(isFinite(el.duration) ? el.duration : 5);
    el.onerror = () => resolve(5);
    el.src = fileUrl(p);
  });
}

// ---------- 便利関数 ----------
const allClips = () => project.tracks.flatMap((tr) => tr.clips);
const findClip = (id) => allClips().find((c) => c.id === id);
const trackOf = (id) => project.tracks.find((tr) => tr.clips.some((c) => c.id === id));
const charById = (id) => project.characters.find((c) => c.id === id);
const charByName = (n) => project.characters.find((c) => c.name === n.trim());
const projectEnd = () => Math.max(0, ...allClips().map((c) => c.start + c.duration));
const status = (s) => ($('#status').textContent = s);
function trackEnd(tr) { return Math.max(0, ...tr.clips.map((c) => c.start + c.duration)); }

// ---------- 音声合成 ----------
async function synth(ch, text) {
  if (ch.engine === 'voicevox') {
    return window.api.voicevoxSynth({ base: project.voicevoxUrl, text, speaker: ch.speaker, speed: ch.speed, pitch: ch.pitch, intonation: ch.intonation });
  }
  return window.api.aquestalkSynth({ command: project.aquestalkCommand, text, voice: ch.voice, speed: ch.speed });
}

async function makeVoiceClip(ch, text, start, track) {
  const src = await synth(ch, text);
  const buf = await getBuffer(src);
  const clip = { id: uid(), type: 'voice', start, duration: buf.duration + 0.15, offset: 0, src, text, charId: ch.id, volume: 1, subtitle: true, fontSize: 64, font: FONTS[0] };
  track.clips.push(clip);
  return clip;
}

async function regenerateVoice(clip) {
  const ch = charById(clip.charId);
  if (!ch) return;
  status('音声を作り直しています…');
  try {
    clip.src = await synth(ch, clip.text);
    clip.duration = (await getBuffer(clip.src)).duration + 0.15;
    clip.offset = 0; // 新しい音声は頭から(前の音声の切り詰め位置を引きずらない)
    status('');
  } catch (e) { status('音声エラー: ' + e.message); }
  renderAll();
}

async function scriptToTimeline() {
  const lines = $('#script').value.split('\n').map((l) => l.trim()).filter(Boolean);
  if (!lines.length) return;
  // 音声は一番下のレイヤー、空いていなければ新しく作る
  let track = project.tracks.find((tr) => tr.clips.every((c) => c.type === 'voice'));
  if (!track) { track = { id: uid(), name: `レイヤー${project.tracks.length + 1}`, clips: [] }; project.tracks.push(track); }
  let cursor = trackEnd(track);
  overlay(`音声を作っています 0/${lines.length}`);
  try {
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(/^(.+?)[:：](.+)$/);
      const ch = (m && charByName(m[1])) || charById(selectedCharId) || project.characters[0];
      const text = m && charByName(m[1]) ? m[2].trim() : lines[i];
      overlay(`音声を作っています ${i + 1}/${lines.length}\n${ch.name}: ${text}`);
      const clip = await makeVoiceClip(ch, text, cursor, track);
      cursor = clip.start + clip.duration + 0.1;
    }
    status(`${lines.length} 個のセリフを並べました`);
  } catch (e) {
    console.log('SMOKE synth error', e.message);
    alert('音声を作れませんでした:\n' + e.message);
  } finally { overlay(null); renderAll(); }
}

// ---------- 描画 ----------
const canvas = $('#preview');
const ctx = canvas.getContext('2d', { alpha: false, desynchronized: true });

function resizeCanvas() {
  canvas.width = project.width;
  canvas.height = project.height;
}

function drawText(text, x, y, size, color, font, align = 'center', outline = '#000') {
  ctx.font = `bold ${size}px "${font}"`;
  ctx.textAlign = align;
  ctx.textBaseline = 'middle';
  ctx.lineJoin = 'round';
  const lines = String(text).split('\n');
  lines.forEach((ln, i) => {
    const yy = y + (i - (lines.length - 1) / 2) * size * 1.2;
    ctx.lineWidth = size * 0.22; ctx.strokeStyle = outline; ctx.strokeText(ln, x, yy);
    ctx.lineWidth = size * 0.1; ctx.strokeStyle = '#fff'; ctx.strokeText(ln, x, yy);
    ctx.fillStyle = color; ctx.fillText(ln, x, yy);
  });
}

function mouthOpen(clip, time) {
  const env = envelopes.get(clip.src);
  if (!env) return false;
  const i = Math.floor((time - clip.start + clip.offset) * 60);
  return i >= 0 && i < env.length && env[i] > 0.03;
}

function draw() {
  const W = canvas.width, H = canvas.height;
  ctx.fillStyle = project.bg;
  ctx.fillRect(0, 0, W, H);
  const active = (c) => t >= c.start && t < c.start + c.duration;
  const speaking = new Map(); // charId -> voice clip
  const subtitles = [];

  // レイヤー1 が奥、番号が大きいほど手前
  for (const tr of project.tracks) {
    if (tr.hidden) continue;
    for (const c of tr.clips) {
      if (!active(c)) continue;
      ctx.save();
      ctx.globalAlpha = c.opacity ?? 1;
      if (c.type === 'image' || c.type === 'video') {
        const el = c.type === 'image' ? getImage(c.src) : getVideo(c);
        const w0 = c.type === 'image' ? el?.naturalWidth : el.videoWidth;
        const h0 = c.type === 'image' ? el?.naturalHeight : el.videoHeight;
        if (el && w0) {
          const fit = Math.min(W / w0, H / h0) * (c.scale ?? 1);
          const w = w0 * fit, h = h0 * fit;
          ctx.drawImage(el, (c.x ?? 0.5) * W - w / 2, (c.y ?? 0.5) * H - h / 2, w, h);
        }
      } else if (c.type === 'text') {
        drawText(c.text, (c.x ?? 0.5) * W, (c.y ?? 0.5) * H, c.fontSize ?? 80, c.color ?? '#fff', c.font ?? FONTS[0], 'center', c.outline ?? '#000');
      } else if (c.type === 'voice') {
        speaking.set(c.charId, c);
        if (c.subtitle) subtitles.push(c);
      }
      ctx.restore();
    }
  }

  // 立ち絵(しゃべっている間は口パク)
  for (const ch of project.characters) {
    const v = speaking.get(ch.id);
    if (!v && !ch.alwaysShow) continue;
    const img = getImage(v && mouthOpen(v, t) && ch.imgOpen ? ch.imgOpen : ch.imgClosed);
    if (!img) continue;
    const h = H * 0.6 * ch.scale, w = img.naturalWidth * (h / img.naturalHeight);
    ctx.save();
    ctx.translate(ch.x * W, ch.y * H);
    if (ch.flip) ctx.scale(-1, 1);
    ctx.drawImage(img, -w / 2, -h / 2, w, h);
    ctx.restore();
  }

  // 字幕(キャラの色で縁取り)
  for (const c of subtitles) {
    const ch = charById(c.charId);
    drawText(c.text, W / 2, H * 0.88, c.fontSize ?? 64, '#fff', c.font ?? FONTS[0], 'center', ch?.color ?? '#000');
  }

  $('#timecode').textContent = `${fmt(t)} / ${fmt(projectEnd())}`;
  $('#playhead').style.left = 90 + t * pps + 'px';
}

// 止まっている間は動画の位置を合わせる
function syncVideosPaused() {
  for (const c of allClips()) {
    if (c.type !== 'video') continue;
    const v = getVideo(c);
    v.pause();
    const local = t - c.start + (c.offset ?? 0);
    if (t >= c.start && t < c.start + c.duration && Math.abs(v.currentTime - local) > 0.02) v.currentTime = local;
  }
}

// ---------- 再生 ----------
let sources = [];
let clockBase = 0, tBase = 0, raf = 0, onEnded = null;
let playGen = 0, starting = false, exporting = false; // 読み込み待ちの間に stop/seek/連打されても二重に鳴らさない

async function play(fromT = t, until = projectEnd()) {
  if (playing || starting) return;
  starting = true;
  const gen = ++playGen;
  await actx.resume().catch(() => {});
  // 音声を先に読み込んでおく
  await Promise.all(allClips().filter((c) => c.type === 'audio' || c.type === 'voice').map((c) => getBuffer(c.src).catch(() => null)));
  if (gen !== playGen) return; // 待っている間に止められた
  starting = false;
  playing = true;
  $('#btn-play').textContent = '⏸';
  t = fromT;
  clockBase = actx.currentTime + 0.05;
  tBase = fromT;
  for (const c of allClips()) {
    if ((c.type !== 'audio' && c.type !== 'voice') || c.start + c.duration <= fromT || trackOf(c.id)?.muted) continue;
    const buf = buffers.get(c.src);
    if (!buf) continue;
    const s = actx.createBufferSource();
    s.buffer = buf;
    const g = actx.createGain();
    g.gain.value = c.volume ?? 1;
    s.connect(g).connect(master);
    const delay = Math.max(0, c.start - fromT);
    const into = (c.offset ?? 0) + Math.max(0, fromT - c.start);
    if (into >= buf.duration) continue; // 素材の長さを超えた位置からは鳴らさない
    s.start(clockBase + delay, into, Math.max(0, c.duration - Math.max(0, fromT - c.start)));
    sources.push(s);
  }
  const tick = () => {
    t = tBase + Math.max(0, actx.currentTime - clockBase);
    for (const c of allClips()) {
      if (c.type !== 'video') continue;
      const v = getVideo(c);
      const on = t >= c.start && t < c.start + c.duration;
      v._gain.gain.value = trackOf(c.id)?.muted ? 0 : c.volume ?? 1;
      if (on) {
        const local = t - c.start + (c.offset ?? 0);
        if (Math.abs(v.currentTime - local) > 0.15) v.currentTime = local;
        if (v.paused) v.play().catch(() => {});
      } else if (!v.paused) v.pause();
    }
    draw();
    if (t >= until) { stop(); onEnded?.(); return; }
    raf = requestAnimationFrame(tick);
  };
  tick();
}

function stop() {
  playGen++; starting = false;
  if (!playing) return;
  playing = false;
  cancelAnimationFrame(raf);
  sources.forEach((s) => { try { s.stop(); } catch {} });
  sources = [];
  videos.forEach((v) => v.pause());
  $('#btn-play').textContent = '▶';
  syncVideosPaused();
  draw();
}

function seek(nt) {
  if (exporting) return;
  t = Math.max(0, nt);
  if (playing) { stop(); play(t); } else { syncVideosPaused(); draw(); }
}

// ---------- タイムライン ----------
function renderTimeline() {
  const tl = $('#timeline'), sx = tl.scrollLeft, sy = tl.scrollTop; // 作り直してもスクロール位置を保つ
  const end = Math.max(projectEnd() + 30, 60);
  const width = end * pps;
  const ruler = $('#ruler');
  ruler.style.width = width + 'px';
  ruler.innerHTML = '';
  const step = pps >= 150 ? 1 : pps >= 40 ? 5 : pps >= 20 ? 10 : 30;
  for (let s = 0; s <= end; s += step) {
    const d = document.createElement('div');
    d.className = 'tick';
    d.style.left = s * pps + 'px';
    d.textContent = fmt(s).slice(0, 5);
    ruler.appendChild(d);
  }

  const tracksEl = $('#tracks');
  tracksEl.innerHTML = '';
  project.tracks.forEach((tr, ti) => {
    const row = document.createElement('div');
    row.className = 'track';
    row.innerHTML = `<div class="track-head">${esc(tr.name)}<br>
      <label><input type="checkbox" data-k="hidden" ${tr.hidden ? 'checked' : ''}>隠す</label>
      <label><input type="checkbox" data-k="muted" ${tr.muted ? 'checked' : ''}>消音</label></div>
      <div class="track-body" style="width:${width}px"></div>`;
    row.querySelectorAll('input').forEach((cb) => (cb.onchange = () => { tr[cb.dataset.k] = cb.checked; draw(); }));
    const body = row.querySelector('.track-body');
    body.dataset.track = ti;
    for (const c of tr.clips) body.appendChild(clipEl(c));
    tracksEl.appendChild(row);
  });
  tl.scrollLeft = sx; tl.scrollTop = sy;
  if (!playing) syncVideosPaused(); // 止まっている間は、動かした動画の絵も合わせる
  draw();
}

function clipLabel(c) {
  if (c.type === 'voice') return `${charById(c.charId)?.name ?? '?'}: ${c.text}`;
  if (c.type === 'text') return `T ${c.text}`;
  return c.src.split('/').pop();
}

function clipEl(c) {
  const el = document.createElement('div');
  el.className = `clip ${c.type}` + (c.id === selectedClipId ? ' selected' : '');
  el.style.left = c.start * pps + 'px';
  el.style.width = Math.max(4, c.duration * pps) + 'px';
  if (c.type === 'voice') el.style.borderLeft = `4px solid ${charById(c.charId)?.color ?? '#999'}`;
  el.textContent = clipLabel(c);
  el.title = clipLabel(c);
  const hl = document.createElement('div'); hl.className = 'handle l';
  const hr = document.createElement('div'); hr.className = 'handle r';
  el.append(hl, hr);
  el.onmousedown = (e) => startDrag(e, c, e.target === hl ? 'l' : e.target === hr ? 'r' : 'move');
  return el;
}

function snapTime(time, self) {
  if (!$('#snap').checked) return time;
  const pts = [0, t];
  for (const c of allClips()) if (c !== self) pts.push(c.start, c.start + c.duration);
  for (const p of pts) if (Math.abs(p - time) * pps < 8) return p;
  return time;
}

function startDrag(e, c, mode) {
  e.preventDefault();
  e.stopPropagation();
  document.activeElement?.blur?.(); // 入力途中の欄を確定してから作り直す(preventDefault で blur されないため)
  select(c.id);
  const x0 = e.clientX, start0 = c.start, dur0 = c.duration, off0 = c.offset ?? 0;
  const srcLen = c.type === 'video' || c.type === 'audio' || c.type === 'voice' ? c.srcDuration ?? Infinity : Infinity;
  const move = (ev) => {
    const dt = (ev.clientX - x0) / pps;
    if (mode === 'move') {
      let ns = snapTime(Math.max(0, start0 + dt), c);
      const ne = snapTime(ns + dur0, c);
      if (ne !== ns + dur0) ns = ne - dur0;
      c.start = Math.max(0, ns);
      // 別のレイヤーへ移す
      const body = document.elementFromPoint(ev.clientX, ev.clientY)?.closest('.track-body');
      const to = body && project.tracks[+body.dataset.track];
      const from = trackOf(c.id);
      if (to && from && to !== from) { from.clips.splice(from.clips.indexOf(c), 1); to.clips.push(c); }
    } else if (mode === 'r') {
      const ne = snapTime(start0 + Math.max(0.05, dur0 + dt), c);
      c.duration = Math.min(Math.max(0.05, ne - start0), srcLen - off0);
    } else {
      const timed = c.type === 'video' || c.type === 'audio' || c.type === 'voice'; // 画像・文字は素材の時間軸がない
      const ns = snapTime(Math.min(start0 + dur0 - 0.05, Math.max(0, start0 + dt)), c);
      // 吸着で最小の長さを割らないよう上限も押さえる。素材の頭(offset 0)より左へは広げられない
      const d = Math.min(dur0 - 0.05, Math.max(timed ? Math.max(-off0, -start0) : -start0, ns - start0));
      c.start = start0 + d; c.duration = dur0 - d;
      if (timed) c.offset = off0 + d;
    }
    renderTimeline();
  };
  const up = () => { removeEventListener('mousemove', move); removeEventListener('mouseup', up); renderProps(); };
  addEventListener('mousemove', move);
  addEventListener('mouseup', up);
}

$('#timeline').addEventListener('mousedown', (e) => {
  if (e.target.closest('.clip, .track-head')) return;
  document.activeElement?.blur?.();
  const rect = $('#timeline').getBoundingClientRect();
  const x = e.clientX - rect.left + $('#timeline').scrollLeft - 90;
  if (x < 0) return;
  const scrub = (ev) => seek((ev.clientX - rect.left + $('#timeline').scrollLeft - 90) / pps);
  scrub(e);
  if (!e.target.closest('#ruler')) select(null);
  const up = () => { removeEventListener('mousemove', scrub); removeEventListener('mouseup', up); };
  addEventListener('mousemove', scrub);
  addEventListener('mouseup', up);
});

// ---------- プロパティ ----------
function select(id) {
  selectedClipId = id;
  document.querySelectorAll('.clip').forEach((el) => el.classList.remove('selected'));
  renderTimeline();
  renderProps();
}

function field(label, value, onChange, opts = {}) {
  const l = document.createElement('label');
  l.textContent = label;
  let input;
  if (opts.options) {
    input = document.createElement('select');
    for (const [v, txt] of opts.options) input.add(new Option(txt, v, false, String(v) === String(value)));
  } else if (opts.multiline) {
    input = document.createElement('textarea');
    input.rows = 3;
    input.value = value ?? '';
  } else {
    input = document.createElement('input');
    input.type = opts.type ?? 'text';
    if (opts.step) input.step = opts.step;
    if (input.type === 'checkbox') input.checked = !!value; else input.value = value ?? '';
  }
  input.onchange = () => {
    const v = input.type === 'checkbox' ? input.checked : input.type === 'number' || input.type === 'range' ? +input.value : input.value;
    onChange(v);
    renderTimeline();
  };
  if (opts.live) input.oninput = input.onchange;
  l.appendChild(input);
  return l;
}

function renderProps() {
  const box = $('#props');
  box.innerHTML = '';
  const c = findClip(selectedClipId);
  if (!c) { box.innerHTML = '<p class="hint">クリップを選ぶと設定が出ます。</p>'; return; }
  const set = (k) => (v) => (c[k] = v);
  box.append(
    field('開始(秒)', +c.start.toFixed(3), (v) => (c.start = Math.max(0, v)), { type: 'number', step: 0.01 }),
    field('長さ(秒)', +c.duration.toFixed(3), (v) => (c.duration = Math.max(0.05, v)), { type: 'number', step: 0.01 }),
  );
  if (c.type === 'voice') {
    box.append(
      field('キャラクター', c.charId, (v) => { c.charId = v; regenerateVoice(c); }, { options: project.characters.map((ch) => [ch.id, ch.name]) }),
      field('セリフ', c.text, (v) => { c.text = v; regenerateVoice(c); }, { multiline: true }),
      field('字幕を出す', c.subtitle, set('subtitle'), { type: 'checkbox' }),
      field('字幕の大きさ', c.fontSize, set('fontSize'), { type: 'number' }),
      field('フォント', c.font, set('font'), { options: FONTS.map((f) => [f, f]) }),
      field('音量', c.volume, set('volume'), { type: 'range', step: 0.05, live: true }),
    );
    box.lastChild.querySelector('input').max = 2;
  }
  if (c.type === 'text') {
    box.append(
      field('文字', c.text, set('text'), { multiline: true, live: true }),
      field('大きさ', c.fontSize, set('fontSize'), { type: 'number', live: true }),
      field('色', c.color, set('color'), { type: 'color', live: true }),
      field('縁の色', c.outline, set('outline'), { type: 'color', live: true }),
      field('フォント', c.font, set('font'), { options: FONTS.map((f) => [f, f]) }),
    );
  }
  if (['image', 'video', 'text'].includes(c.type)) {
    const r = document.createElement('div'); r.className = 'row';
    r.append(field('横位置', c.x ?? 0.5, set('x'), { type: 'number', step: 0.01, live: true }), field('縦位置', c.y ?? 0.5, set('y'), { type: 'number', step: 0.01, live: true }));
    box.append(r, field('不透明度', c.opacity ?? 1, set('opacity'), { type: 'range', step: 0.01, live: true }));
    box.lastChild.querySelector('input').max = 1;
  }
  if (c.type === 'image' || c.type === 'video') box.append(field('拡大', c.scale ?? 1, set('scale'), { type: 'number', step: 0.05, live: true }));
  if (c.type === 'video' || c.type === 'audio') {
    box.append(field('音量', c.volume ?? 1, set('volume'), { type: 'range', step: 0.05, live: true }));
    box.lastChild.querySelector('input').max = 2;
  }
}

// ---------- キャラクター ----------
let speakers = [];
async function loadSpeakers(retried = false) {
  try {
    speakers = await window.api.voicevoxSpeakers(project.voicevoxUrl);
    status(`VOICEVOX につながりました(${speakers.length}キャラ)`);
  } catch {
    status('VOICEVOX を起動しています…');
    // 起動し直すのは1回だけ(設定した URL がつながらないときに無限に繰り返さない)
    if (!retried && await window.api.voicevoxLaunch()) return loadSpeakers(true);
    status('VOICEVOX が見つからないか起動できません(未インストールなら右下の案内を見てください)');
  }
  renderChars();
}

function renderChars() {
  const list = $('#char-list');
  list.innerHTML = '';
  for (const ch of project.characters) {
    const el = document.createElement('div');
    el.className = 'char' + (ch.id === selectedCharId ? ' selected' : '');
    const engineLabel = ch.engine === 'voicevox'
      ? speakers.flatMap((s) => s.styles.map((st) => [st.id, `${s.name}（${st.name}）`])).find(([id]) => id === ch.speaker)?.[1] ?? `VOICEVOX #${ch.speaker}`
      : `ゆっくり ${ch.voice}`;
    el.innerHTML = `<span class="dot" style="background:${esc(ch.color)}"></span><div><div>${esc(ch.name)}</div><div class="meta">${esc(engineLabel)}</div></div>`;
    el.onclick = () => { selectedCharId = ch.id; selectedClipId = null; renderChars(); renderCharProps(ch); };
    list.appendChild(el);
  }
}

function renderCharProps(ch) {
  renderTimeline();
  const box = $('#props');
  box.innerHTML = '<h3>キャラクター</h3>';
  const set = (k) => (v) => { ch[k] = v; renderChars(); draw(); };
  box.append(
    field('名前', ch.name, set('name')),
    field('字幕の縁の色', ch.color, set('color'), { type: 'color' }),
    field('音声エンジン', ch.engine, (v) => {
      ch.engine = v;
      // エンジンごとに「速さ」の単位が違う(VOICEVOX は 1 が標準、ゆっくりは 100)ので、切り替え時に合わせる
      if (v === 'voicevox') { if (!(ch.speed <= 5)) ch.speed = 1; ch.pitch ??= 0; ch.intonation ??= 1; ch.speaker ??= 3; }
      else { if (!(ch.speed > 5)) ch.speed = 100; ch.voice ||= aqPresets[0] ?? 'れいむ'; }
      renderCharProps(ch); renderChars();
    }, { options: [['voicevox', 'VOICEVOX'], ['aquestalk', 'ゆっくり (AquesTalk)']] }),
  );
  if (ch.engine === 'voicevox') {
    const opts = speakers.flatMap((s) => s.styles.map((st) => [st.id, `${s.name}（${st.name}）`]));
    box.append(
      field('話者', ch.speaker, (v) => set('speaker')(+v), { options: opts.length ? opts : [[ch.speaker, `#${ch.speaker}`]] }),
      field('話す速さ', ch.speed ?? 1, set('speed'), { type: 'number', step: 0.05 }),
      field('高さ', ch.pitch ?? 0, set('pitch'), { type: 'number', step: 0.01 }),
      field('抑揚', ch.intonation ?? 1, set('intonation'), { type: 'number', step: 0.05 }),
    );
  } else {
    box.append(
      field('声(AquesTalkPlayer のプリセット名)', ch.voice, set('voice'), { options: [...new Set([...aqPresets, ch.voice])].map((p) => [p, p]) }),
    );
  }
  const imgBtn = (label, key) => {
    const b = document.createElement('button');
    b.textContent = `${label}: ${ch[key] ? ch[key].split('/').pop() : '未設定'}`;
    b.className = 'wide';
    b.style.marginBottom = '6px';
    b.onclick = async () => { const p = await window.api.openImage(); if (p) { ch[key] = p; renderCharProps(ch); draw(); } };
    return b;
  };
  const r = document.createElement('div'); r.className = 'row';
  r.append(field('横位置', ch.x, set('x'), { type: 'number', step: 0.01, live: true }), field('縦位置', ch.y, set('y'), { type: 'number', step: 0.01, live: true }));
  const test = document.createElement('button');
  test.textContent = '試しに読み上げる';
  test.className = 'wide';
  test.onclick = async () => {
    try {
      const p = await synth(ch, `${ch.name}です。よろしくお願いします。`);
      const s = actx.createBufferSource(); s.buffer = await getBuffer(p); s.connect(master); await actx.resume(); s.start();
    } catch (e) { alert(e.message); }
  };
  const del = document.createElement('button');
  del.textContent = 'このキャラを消す';
  del.className = 'wide';
  del.onclick = () => {
    if (project.characters.length <= 1) return alert('最後の1人は消せません(台本からの音声作成に必要です)');
    const mine = allClips().filter((c) => c.type === 'voice' && c.charId === ch.id);
    if (!confirm(`${ch.name} を消しますか？` + (mine.length ? `\nこのキャラのセリフ ${mine.length} 個もタイムラインから消えます。` : ''))) return;
    stop();
    for (const tr of project.tracks) tr.clips = tr.clips.filter((c) => !(c.type === 'voice' && c.charId === ch.id));
    if (mine.some((c) => c.id === selectedClipId)) selectedClipId = null;
    project.characters = project.characters.filter((c) => c !== ch);
    selectedCharId = project.characters[0]?.id;
    renderAll();
  };
  box.append(
    imgBtn('立ち絵(口閉じ)', 'imgClosed'), imgBtn('立ち絵(口開き)', 'imgOpen'), r,
    field('大きさ', ch.scale, set('scale'), { type: 'number', step: 0.05, live: true }),
    field('左右反転', ch.flip, set('flip'), { type: 'checkbox' }),
    field('いつも表示', ch.alwaysShow, set('alwaysShow'), { type: 'checkbox' }),
    test, del,
  );
}

$('#btn-add-char').onclick = () => {
  const ch = { id: uid(), name: `キャラ${project.characters.length + 1}`, engine: 'voicevox', speaker: 3, speed: 1, pitch: 0, intonation: 1, color: '#4f8cff', ...charDefaults(9) };
  project.characters.push(ch);
  selectedCharId = ch.id;
  renderChars();
  renderCharProps(ch);
};

// ---------- 素材 ----------
const kindOf = (p) => {
  const ext = p.split('.').pop().toLowerCase();
  if (['png', 'jpg', 'jpeg', 'gif', 'webp'].includes(ext)) return 'image';
  if (['mp3', 'wav', 'm4a', 'aac', 'ogg'].includes(ext)) return 'audio';
  return 'video';
};

const MEDIA_EXT = ['png', 'jpg', 'jpeg', 'gif', 'webp', 'mp3', 'wav', 'm4a', 'aac', 'ogg', 'mp4', 'mov', 'webm', 'm4v'];
async function addMedia(paths) {
  paths = paths.filter((p) => MEDIA_EXT.includes(p.split('.').pop().toLowerCase())); // ドロップされた関係ない種類のファイルは無視
  for (const p of paths) {
    const type = kindOf(p);
    const dur = type === 'image' ? 5 : await probeDuration(p, type === 'audio' ? 'audio' : 'video');
    // 空いているレイヤーの、再生位置に置く
    const tr = project.tracks.find((tr) => tr.clips.every((c) => c.type !== 'voice' && (c.start >= t + dur || c.start + c.duration <= t))) ?? project.tracks[0];
    tr.clips.push({ id: uid(), type, src: p, start: t, duration: dur, srcDuration: type === 'image' ? undefined : dur, offset: 0, x: 0.5, y: 0.5, scale: 1, opacity: 1, volume: 1 });
  }
  renderAll();
}

$('#btn-media').onclick = async () => addMedia(await window.api.openMedia());
document.addEventListener('dragover', (e) => e.preventDefault());
document.addEventListener('drop', (e) => {
  e.preventDefault();
  const paths = [...e.dataTransfer.files].map((f) => window.api.pathOf(f)).filter(Boolean);
  if (paths.length) addMedia(paths);
});

$('#btn-text').onclick = () => {
  const tr = project.tracks[project.tracks.length - 1];
  const c = { id: uid(), type: 'text', text: 'テキスト', start: t, duration: 3, x: 0.5, y: 0.15, fontSize: 96, color: '#ffffff', outline: '#000000', font: FONTS[0], opacity: 1 };
  tr.clips.push(c);
  select(c.id);
};

function splitAtPlayhead() {
  const c = findClip(selectedClipId);
  if (!c || t <= c.start || t >= c.start + c.duration) return;
  const cut = t - c.start;
  const b = { ...c, id: uid(), start: t, duration: c.duration - cut, offset: (c.offset ?? 0) + cut };
  c.duration = cut;
  trackOf(c.id).clips.push(b);
  renderAll();
}

function deleteSelected() {
  const tr = trackOf(selectedClipId);
  if (!tr) return;
  tr.clips = tr.clips.filter((c) => c.id !== selectedClipId);
  disposeVideo(selectedClipId);
  selectedClipId = null;
  renderAll();
}

$('#btn-split').onclick = splitAtPlayhead;
$('#btn-delete').onclick = deleteSelected;
$('#btn-add-track').onclick = () => { project.tracks.push({ id: uid(), name: `レイヤー${project.tracks.length + 1}`, clips: [] }); renderTimeline(); };
$('#btn-script').onclick = scriptToTimeline;
$('#btn-play').onclick = () => { if (exporting) return; if (playing || starting) stop(); else play(t >= projectEnd() ? 0 : t); };
$('#btn-home').onclick = () => seek(0);
$('#zoom').oninput = (e) => { pps = +e.target.value; renderTimeline(); };

document.addEventListener('keydown', (e) => {
  if (exporting || e.target.matches('input, textarea, select')) return;
  if (e.code === 'Space') { e.preventDefault(); $('#btn-play').click(); }
  else if (e.key === 's' && !e.metaKey) splitAtPlayhead();
  else if (e.key === 'Delete' || e.key === 'Backspace') deleteSelected();
  else if (e.key === 'ArrowLeft') seek(t - 1 / project.fps);
  else if (e.key === 'ArrowRight') seek(t + 1 / project.fps);
  else if (e.metaKey && e.key === 's') { e.preventDefault(); saveProject(); }
  else if (e.metaKey && e.key === 'o') { e.preventDefault(); openProject(); }
});

// ---------- 保存・読み込み ----------
async function saveProject() {
  const p = await window.api.saveProject(JSON.stringify(project, null, 1), projectPath);
  if (p) { projectPath = p; status('保存しました: ' + p.split('/').pop()); }
}
async function openProject() {
  const r = await window.api.loadProject();
  if (!r) return;
  let loaded;
  try { loaded = JSON.parse(r.json); } catch (e) { return alert('プロジェクトを読めませんでした:\n' + e.message); }
  stop();
  project = { ...newProject(), ...loaded };
  if (!project.characters?.length) project.characters = newProject().characters;
  if (!project.tracks?.length) project.tracks = newProject().tracks;
  projectPath = r.path;
  disposeAllVideos();
  selectedClipId = null;
  selectedCharId = project.characters[0]?.id;
  t = 0;
  resizeCanvas();
  renderAll();
  loadSpeakers();
  Promise.all(allClips().filter((c) => c.type === 'voice' || c.type === 'audio').map((c) => getBuffer(c.src).catch(() => null))).then(draw);
}
$('#btn-save').onclick = saveProject;
$('#btn-open').onclick = openProject;
$('#btn-new').onclick = () => {
  if (!confirm('今のプロジェクトを閉じて新しく始めますか？')) return;
  stop(); disposeAllVideos(); project = newProject(); projectPath = null; selectedClipId = null; selectedCharId = project.characters[0].id; t = 0;
  resizeCanvas(); renderAll();
};

// ---------- 設定 ----------
$('#btn-settings').onclick = () => {
  $('#set-w').value = project.width; $('#set-h').value = project.height; $('#set-fps').value = project.fps;
  $('#set-bg').value = project.bg; $('#set-vv').value = project.voicevoxUrl; $('#set-aq').value = project.aquestalkCommand;
  $('#set-codec').value = project.codec;
  const key = `${project.width}x${project.height}`;
  $('#set-size').value = [...$('#set-size').options].some((o) => o.value === key) ? key : 'custom';
  $('#dlg-settings').showModal();
};
$('#set-size').onchange = (e) => {
  if (e.target.value === 'custom') return;
  const [w, h] = e.target.value.split('x');
  $('#set-w').value = w; $('#set-h').value = h;
  // 4K は HEVC の方が小さくきれいに収まる
  if (+w * +h >= 3840 * 2160) $('#set-codec').value = 'hevc';
};
$('#dlg-settings').addEventListener('close', () => {
  const oldVv = project.voicevoxUrl;
  project.width = +$('#set-w').value || 1920; project.height = +$('#set-h').value || 1080;
  project.fps = +$('#set-fps').value || 60; project.bg = $('#set-bg').value;
  project.voicevoxUrl = $('#set-vv').value.replace(/\/$/, ''); project.aquestalkCommand = $('#set-aq').value;
  project.codec = $('#set-codec').value;
  resizeCanvas(); draw();
  if (oldVv !== project.voicevoxUrl) loadSpeakers();
});

// ---------- 別画面プレビュー ----------
let previewWin = null;
$('#btn-popout').onclick = () => {
  if (previewWin && !previewWin.closed) { previewWin.close(); previewWin = null; return; }
  previewWin = window.open('preview.html', 'preview');
  previewWin.addEventListener('load', () => {
    previewWin.document.querySelector('video').srcObject = canvas.captureStream(project.fps);
  });
};

// ---------- 書き出し ----------
async function exportVideo() {
  if (exporting) return;
  const end = projectEnd();
  if (end <= 0) return alert('タイムラインが空です');
  exporting = true;
  try { await exportVideoInner(end); } finally { exporting = false; overlay(null); }
}
async function exportVideoInner(end) {
  const out = window.api.smokeOut ?? (await window.api.chooseExportPath());
  if (!out) return;
  stop();
  try {
    await actx.resume(); // 録音の音声が止まったままにならないように、録り始める前に動かしておく
    await Promise.all(allClips().filter((c) => c.type === 'voice' || c.type === 'audio').map((c) => getBuffer(c.src)));
  } catch (e) {
    console.log('SMOKE export error', e.message);
    return alert('音声素材を読み込めませんでした:\n' + e.message);
  }
  t = 0; syncVideosPaused(); draw(); // 録り始めの絵を先頭にそろえる
  const stream = new MediaStream([...canvas.captureStream(project.fps).getVideoTracks(), ...recordDest.stream.getAudioTracks()]);
  // 一時ファイルは画質を落とさないよう高いビットレートで録る(最終の圧縮は VideoToolbox)
  const pixels = project.width * project.height;
  const rec = new MediaRecorder(stream, { mimeType: 'video/webm;codecs=vp9,opus', videoBitsPerSecond: Math.round(pixels * project.fps * 0.5), audioBitsPerSecond: 256000 });
  const chunks = [];
  rec.ondataavailable = (e) => e.data.size && chunks.push(e.data);
  const done = new Promise((r) => (rec.onstop = r));
  overlay('書き出し中… 0%');
  rec.start(1000);
  const progress = setInterval(() => overlay(`書き出し中… ${Math.min(100, Math.round((t / end) * 100))}%\n(動画の長さと同じだけ時間がかかります)`), 250);
  await new Promise((resolve) => { onEnded = resolve; play(0, end); });
  onEnded = null;
  clearInterval(progress);
  rec.stop();
  await done;
  stream.getVideoTracks().forEach((tr) => tr.stop()); // captureStream を毎回解放する
  overlay('MP4 に変換中…(M5 のハードウェアエンコーダを使っています)');
  try {
    const bytes = new Uint8Array(await new Blob(chunks, { type: 'video/webm' }).arrayBuffer());
    await window.api.finishExport(bytes, out, project.fps, project.codec);
    status('書き出しました: ' + out.split('/').pop());
  } catch (e) {
    console.log('SMOKE export error', e.message);
    alert('変換に失敗しました:\n' + e.message);
  }
}
$('#btn-export').onclick = exportVideo;

function overlay(msg) {
  $('#overlay').hidden = !msg;
  if (msg) $('#overlay-msg').innerText = msg;
}

function renderAll() { renderTimeline(); renderProps(); renderChars(); }

let aqPresets = [];
async function detectAquesTalk() {
  const info = await window.api.aquestalkInfo();
  aqPresets = info.presets;
  if (!info.installed && project.aquestalkCommand === AQP_COMMAND) project.aquestalkCommand = KYOKO_COMMAND;
  if (info.installed && project.aquestalkCommand === KYOKO_COMMAND) project.aquestalkCommand = AQP_COMMAND;
}

// 足りない外部ソフトがあれば、小さな案内を出す
async function showDeps() {
  const d = await window.api.depsStatus();
  const items = [];
  if (!d.voicevox) items.push('VOICEVOX(音声合成): <code>https://voicevox.hiroshiba.jp/</code> からインストールして /Applications に置いてください。まだ入っていないので、VOICEVOX の声は使えません');
  if (!d.aquestalkPlayer) items.push('AquesTalkPlayer(ゆっくり声): <code>https://www.a-quest.com/products/aquestalkplayer.html</code> からインストールしてください。なくても macOS 標準の声(Kyoko)で代用します');
  if (!d.ffmpeg) items.push('ffmpeg(MP4 書き出し): ターミナルで <code>brew install ffmpeg</code> を実行してください');
  const box = $('#deps-notice');
  if (!items.length) { box.hidden = true; return; }
  box.innerHTML = `<b>足りないものがあります</b><ul>${items.map((t) => `<li>${t}</li>`).join('')}</ul><button id="deps-close" class="small">閉じる</button>`;
  box.hidden = false;
  $('#deps-close').onclick = () => (box.hidden = true);
}

resizeCanvas();
renderAll();
showDeps().catch(() => {});
loadSpeakers().then(async () => {
  await detectAquesTalk();
  // 動作確認用: YE_SMOKE_OUT を付けて起動すると、台本→音声→書き出しを自動で行って終わる
  if (!window.api.smokeOut) return;
  $('#script').value = '霊夢: ゆっくりしていってね\nずんだもん: ずんだもんなのだ';
  await scriptToTimeline();
  project.tracks[4].clips.push({ id: uid(), type: 'text', text: 'テスト', start: 0, duration: 2, x: 0.5, y: 0.2, fontSize: 120, color: '#ffffff', outline: '#000000', font: FONTS[0], opacity: 1 });
  console.log('SMOKE clips', JSON.stringify(allClips().map((c) => [c.type, c.text, +c.duration.toFixed(2)])));
  await exportVideo();
  window.api.quit();
});
