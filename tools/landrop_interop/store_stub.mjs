// electron-store stub：内存 Map（LANDrop settings/身份/信任列表落盘这里全走内存）
export default class ElectronStoreStub {
  constructor() {
    this._m = new Map();
  }
  get(k, d) {
    return this._m.has(k) ? this._m.get(k) : d;
  }
  set(k, v) {
    this._m.set(k, v);
  }
  delete(k) {
    this._m.delete(k);
  }
  clear() {
    this._m.clear();
  }
}
