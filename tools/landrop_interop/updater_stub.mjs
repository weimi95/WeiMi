// electron-updater stub：不检查更新
const autoUpdater = {
  autoDownload: false,
  autoInstallOnAppQuit: false,
  on: () => {},
  checkForUpdates: async () => {},
  quitAndInstall: () => {},
};

class ElectronUpdaterStub {
  constructor() {}
  on() {}
  startCheckingForUpdates() {}
  quitAndInstall() {}
}
ElectronUpdaterStub.autoUpdater = autoUpdater;

export default ElectronUpdaterStub;
