const { contextBridge, ipcRenderer, webUtils } = require('electron');

const invoke = (ch) => (...a) => ipcRenderer.invoke(ch, ...a);

contextBridge.exposeInMainWorld('api', {
  openMedia: invoke('open-media'),
  openImage: invoke('open-image'),
  saveProject: invoke('save-project'),
  loadProject: invoke('load-project'),
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
  quit: () => ipcRenderer.invoke('quit'),
  pathOf: (file) => webUtils.getPathForFile(file),
});
