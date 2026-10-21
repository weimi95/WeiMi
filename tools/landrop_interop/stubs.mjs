// electron  stub（让 LANDrop 主进程 bundle 能在纯 Node 里加载）
// 关键：app.whenReady() 返回永不 resolve 的 Promise —— bundle 启动函数 It()
// 在 whenReady 之后才会建窗口/起服务/连信令，全部不会执行；我们只取协议类。
export const app = {
  requestSingleInstanceLock: () => true,
  on: () => {},
  quit: () => {},
  whenReady: () => new Promise(() => {}),
  getPath: (name) =>
      name === 'downloads' ? (process.env.LD_DOWNLOADS || '.') : '.',
  getLoginItemSettings: () => ({ openAtLogin: false }),
  setLoginItemSettings: () => {},
  dock: { show() {}, hide() {} },
};
export const safeStorage = {
  isEncryptionAvailable: () => false,
  setUsePlainTextEncryption: () => {},
  encryptString: (s) => Buffer.from(String(s), 'utf-8'),
  decryptString: (b) => Buffer.from(b).toString('utf-8'),
};
export const shell = { openPath: async () => '' };
export const BrowserWindow = class {};
export const Tray = class {};
export const nativeImage = { createFromPath: () => ({}) };
export const Menu = { buildFromTemplate: () => ({}), setApplicationMenu: () => {} };
export const ipcMain = { handle: () => {}, on: () => {} };
export const dialog = {};
// @electron-toolkit/utils
export const is = { dev: false, macos: false, windows: false };
export const optimizer = { watchWindowShortcuts: () => {} };
export const electronApp = { setAppUserModelId: () => {} };
