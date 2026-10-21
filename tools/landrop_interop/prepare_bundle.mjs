// 从已安装的 LANDrop（electron 版）提取 asar 主进程 JS，改造成可在纯 Node 加载的
// ESM bundle：electron/electron-store/electron-updater 换成本地 stub，末尾导出协议类。
//
// 输入（按优先级）：
//   1. 环境变量 LD_ASAR_JS 指向已解出的 main index.js
//   2. <LANDrop 安装目录>\resources\app.asar（用 asar npm 包解出）
// 输出：./bundle.mjs（生成物，勿手改；.gitignore 已排除）
import fs from 'fs';
import path from 'path';
import os from 'os';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
const OUT = path.join(here, 'bundle.mjs');

const ASAR_CANDIDATES = [
  'C:\\Users\\Administrator\\AppData\\Local\\Programs\\landrop-v2-electron\\resources\\app.asar',
  'F:\\下载\\LANDrop-latest-win\\LANDrop\\resources\\app.asar',
];

async function findSourceJs() {
  if (process.env.LD_ASAR_JS && fs.existsSync(process.env.LD_ASAR_JS)) {
    return fs.readFileSync(process.env.LD_ASAR_JS, 'utf-8');
  }
  for (const asarPath of ASAR_CANDIDATES) {
    if (!fs.existsSync(asarPath)) continue;
    // 用 asar 包整包解出（缓存到临时目录，避免重复解压）
    const asar = await import('asar');
    const dest = path.join(os.tmpdir(), 'ld-asar-extracted');
    if (!fs.existsSync(path.join(dest, 'package.json'))) {
      fs.rmSync(dest, { recursive: true, force: true });
      asar.extractAll(asarPath, dest);
    }
    const pkg = JSON.parse(
      fs.readFileSync(path.join(dest, 'package.json'), 'utf-8'));
    const main = pkg.main || 'dist/main/index.js';
    const mainPath = path.join(dest, main);
    if (!fs.existsSync(mainPath)) {
      throw new Error(`解出的 asar 里找不到入口 ${main}`);
    }
    return fs.readFileSync(mainPath, 'utf-8');
  }
  throw new Error(
    '找不到 LANDrop asar/主进程 JS。设置 LD_ASAR_JS 指向已解出的 main index.js，' +
      '或安装 landrop-v2-electron 到默认目录。',
  );
}

const src = await findSourceJs();

// 替换外部依赖 import（保持本地别名不变）
const replacements = [
  [
    /import \{ app as u, safeStorage as W, shell as Te, BrowserWindow as Ce, Tray as Ae, nativeImage as P, Menu as Oe, ipcMain as a, dialog as se \} from "electron";/,
    'import { app as u, safeStorage as W, shell as Te, BrowserWindow as Ce, Tray as Ae, nativeImage as P, Menu as Oe, ipcMain as a, dialog as se } from "./stubs.mjs";',
  ],
  [
    /import \{ is as Se, optimizer as Ee, electronApp as Ne \} from "@electron-toolkit\/utils";/,
    'import { is as Se, optimizer as Ee, electronApp as Ne } from "./stubs.mjs";',
  ],
  [/import Re from "electron-store";/, 'import Re from "./store_stub.mjs";'],
  [/import Ue from "electron-updater";/, 'import Ue from "./updater_stub.mjs";'],
];
let out = src;
for (const [re, to] of replacements) {
  if (!re.test(out)) throw new Error(`bundle 结构变化，替换失败: ${re}`);
  out = out.replace(re, to);
}

// 导出协议类（类名取自 bundle 作用域，版本升级若变名会在这里报错）
out += `
export { T as Session, p as SessionHandler, we as SessionKeys, v as Crypto,
  Q as KxKeypair, z as SecpKeypair, F as Ecdhe, X as ClientHello, Y as ServerHello,
  G as DiscoveryPacket, at as TcpServer, ot as Connections, ct as Discovery,
  f as Settings, c as settings, l as identity, w as connections, le as FileEntry };
`;
fs.writeFileSync(OUT, out);
console.log('bundle.mjs written:', OUT, `(${(out.length / 1024).toFixed(1)} KB)`);
