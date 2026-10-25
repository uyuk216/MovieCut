const { contextBridge, ipcRenderer, webUtils } = require('electron');

const invoke = (ch) => (...a) => ipcRenderer.invoke(ch, ...a);

contextBridge.exposeInMainWorld('api', {
  openMedia: invoke('open-media'),
  openImage: invoke('open-image'),
  saveProject: invoke('save-project'),
  loadProject: invoke('load-project'),
  loadProjectPath: invoke('load-project-path'),
  voicevoxSpeakers: invoke('voicevox-speakers'),
  voicevoxLaunch: invoke('voicevox-launch'),
  voicevoxSynth: invoke('voicevox-synth'),
  aquestalkSynth: invoke('aquestalk-synth'),
  aquestalkInfo: invoke('aquestalk-info'),
  chooseExportPath: invoke('choose-export-path'),
  finishExport: invoke('finish-export'),
  depsStatus: invoke('deps-status'),
  displays: invoke('displays'),
  smokeOut: process.env.YE_SMOKE_OUT || null,
  smokeBlur: process.env.YE_SMOKE_BLUR === '1',
  smokeSize: process.env.YE_SMOKE_SIZE || null, // 例 1080x1920
  smokeCodec: process.env.YE_SMOKE_CODEC || null, // h264 | hevc
  // メニュー(main)との連絡
  onMenuAction: (cb) => ipcRenderer.on('menu-action', (_e, m) => cb(m)),
  pushUiState: (s) => ipcRenderer.send('ui-state', s),
  notifySaved: (ok) => ipcRenderer.send('saved', !!ok),
  rendererReady: () => ipcRenderer.send('renderer-ready'),
  exportProgress: (f) => ipcRenderer.send('export-progress', f),
  exportFinished: () => ipcRenderer.send('export-finished'),
  quit: () => ipcRenderer.invoke('quit'),
  pathOf: (file) => webUtils.getPathForFile(file),
});
