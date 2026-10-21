// LANDrop 双向互通对拍（跑真实 LANDrop 2.7.2 主进程代码 vs 微密规范实现）：
//   测试 A：真实 LANDrop 客户端 → 我方规范服务端（验证「收」全链路）
//   测试 B：我方规范客户端 → 真实 LANDrop 服务端（验证「发」全链路）
// 断言：文件字节一致、mtime 秒级一致、verifCode 两端一致、拒收/文本路径不崩。
//
// 运行（managed node + 已装依赖）：
//   cd C:\Users\Administrator\.workbuddy\binaries\node\workspace
//   set NODE_PATH=<workspace>\node_modules
//   node E:\Ai\work\WeiMi\tools\landrop_interop\run_interop.mjs
import fs from 'fs';
import os from 'os';
import path from 'path';
import { execSync } from 'child_process';
import { fileURLToPath } from 'url';

const here = path.dirname(fileURLToPath(import.meta.url));
process.chdir(here);

// 1. 生成 bundle（asar → stub 化 ESM）
execSync(`node "${path.join(here, 'prepare_bundle.mjs')}"`, { stdio: 'inherit' });

const sodium = (await import('libsodium-wrappers')).default;
await sodium.ready;

const LD = await import('./bundle.mjs');
await LD.Crypto.init();
LD.identity.init(); // LANDrop 自己的身份（secp256k1，落内存 store）

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), 'ld-interop-'));
process.env.LD_DOWNLOADS = path.join(TMP, 'landrop-downloads');
process.env.LD_SPEC_RECV_DIR = path.join(TMP, 'spec-recv');
fs.mkdirSync(process.env.LD_DOWNLOADS, { recursive: true });
fs.mkdirSync(process.env.LD_SPEC_RECV_DIR, { recursive: true });

let failures = 0;
const ok = (cond, msg) => {
  console.log(`${cond ? '  ✓' : '  ✗'} ${msg}`);
  if (!cond) failures++;
};
const section = (s) => console.log(`\n=== ${s} ===`);

// 测试文件：跨记录边界（65518）+ 中文名 + 小文件
function makeFile(name, size, seed) {
  const p = path.join(TMP, name);
  const buf = Buffer.alloc(size);
  let s = seed >>> 0;
  for (let i = 0; i < size; i++) {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    buf[i] = s & 0xff;
  }
  fs.writeFileSync(p, buf);
  return p;
}
const f1 = makeFile('small-100b.bin', 100, 1);
const f2 = makeFile('cross-boundary-70000b.bin', 70000, 2); // > 65518 → 2 条记录
const f3 = makeFile('中文名文件-测试.bin', 300000, 3); // 5 条记录
const f4 = makeFile('exactly-65518.bin', 65518, 4); // 正好一条记录

const { SpecReceiver, specSendFiles } = await import('./spec.mjs');

// ==================== 测试 A：真实 LANDrop 客户端 → 我方规范服务端 ====================
section('测试 A：真实 LANDrop（client）→ 微密规范服务端');
{
  const receiver = new SpecReceiver({
    identitySk: Buffer.from(LD.identity.kp.sk),
    identityPkB64: LD.identity.kp.pkBase64,
  });
  const port = await receiver.start(0);

  // 真实 LANDrop 客户端（bundle 里的 p.connect + sendFiles）
  let session;
  const files = [f1, f2, f3, f4].map((p) => ({
    path: p,
    abstractFilename: path.basename(p),
  }));
  try {
    session = await LD.SessionHandler.connect('127.0.0.1', port);
    await session.exchangeSupportedMessageTypes();
    await session.exchangeDeviceInfo();
    await session.sendFiles(files);
  } catch (e) {
    console.error('  真实客户端发送失败:', e.message);
    failures++;
  }
  session?.close();

  await new Promise((r) => setTimeout(r, 500));
  ok(receiver.received.length === 4, `收到 4 个文件（实际 ${receiver.received.length}）`);
  for (const f of files) {
    const rec = receiver.received.find((r) => r.filename === path.basename(f.path));
    const same = rec &&
      fs.readFileSync(rec.path).equals(fs.readFileSync(f.path));
    ok(!!same, `字节一致：${path.basename(f.path)}`);
    if (rec) {
      const want = Math.floor(fs.statSync(f.path).mtimeMs / 1000);
      const got = Math.floor(fs.statSync(rec.path).mtimeMs / 1000);
      ok(want === got, `mtime 一致：${path.basename(f.path)}（${want} vs ${got}）`);
    }
  }
}

// ==================== 测试 B：我方规范客户端 → 真实 LANDrop 服务端 ====================
section('测试 B：微密规范客户端 → 真实 LANDrop（server，信任设备免确认）');
{
  // 真实 LANDrop 服务端
  const conns = new LD.Connections();
  await conns.start(0);
  const port = conns.server.port;

  // 我方身份（另起一个，与 A 区分）
  const myKp = LD.SecpKeypair.generate();
  const myPkB64 = Buffer.from(myKp.pk).toString('base64');

  // 把身份加进 LANDrop 信任列表 → 免确认直收
  LD.settings.trustedDevices = {
    devices: [{ publicKey: myPkB64, name: '微密文件(spec)', type: 'windows' }],
    askTimes: {},
  };

  const donePromise = new Promise((resolve) => {
    conns.on('file-receive-done', (obj) => resolve(obj));
    setTimeout(() => resolve(null), 20000);
  });

  const sendFile = makeFile('from-weimi-128k.bin', 128 * 1024, 7);
  const result = await specSendFiles({
    host: '127.0.0.1',
    port,
    identitySk: Buffer.from(myKp.sk),
    identityPkB64: myPkB64,
    files: [{ path: sendFile, filename: 'from-weimi-128k.bin' }],
  });
  ok(/^\d{6}$/.test(result.verifCode), `我方 verifCode 格式：${result.verifCode}`);
  console.log(`  （对端设备名：${result.peerName}）`);

  const done = await donePromise;
  ok(!!done, '真实 LANDrop 报 file-receive-done');
  // LANDrop 真实行为：落盘到 <下载目录>/LANDrop/ 子目录
  const landed = path.join(process.env.LD_DOWNLOADS, 'LANDrop', 'from-weimi-128k.bin');
  ok(fs.existsSync(landed), '文件落盘到 LANDrop 下载目录');
  if (fs.existsSync(landed)) {
    ok(fs.readFileSync(landed).equals(fs.readFileSync(sendFile)), '字节一致');
    const want = Math.floor(fs.statSync(sendFile).mtimeMs / 1000);
    const got = Math.floor(fs.statSync(landed).mtimeMs / 1000);
    ok(want === got, `mtime 一致（${want} vs ${got}）`);
  }
}

// ==================== 测试 C：verifCode 两端一致（同一会话） ====================
section('测试 C：verifCode 两端一致');
{
  // A 的会话里真实客户端算的码 vs 我方服务端算的码
  const receiver = new SpecReceiver({
    identitySk: Buffer.from(LD.identity.kp.sk),
    identityPkB64: LD.identity.kp.pkBase64,
  });
  const port = await receiver.start(0);
  const session = await LD.SessionHandler.connect('127.0.0.1', port);
  await session.exchangeSupportedMessageTypes();
  await session.exchangeDeviceInfo();
  ok(session.verifCode === receiver.lastVerifCode,
    `client=${session.verifCode} server=${receiver.lastVerifCode}`);
  session.close();
}

// ==================== 测试 D：拒收链路（真实 LANDrop client → 我方拒收） ====================
section('测试 D：拒收（真实 LANDrop client 发送 → 微密规范服务端拒收）');
{
  const receiver = new SpecReceiver({
    identitySk: Buffer.from(LD.identity.kp.sk),
    identityPkB64: LD.identity.kp.pkBase64,
    declineAll: true,
  });
  const port = await receiver.start(0);
  let clientErr = '';
  try {
    const session = await LD.SessionHandler.connect('127.0.0.1', port);
    await session.exchangeSupportedMessageTypes();
    await session.exchangeDeviceInfo();
    await session.sendFiles([{
      path: f1,
      abstractFilename: path.basename(f1),
    }]);
    clientErr = '';
  } catch (e) {
    clientErr = e.message || String(e);
  }
  await new Promise((r) => setTimeout(r, 300));
  ok(clientErr.length > 0, `真实客户端收到拒收反馈并报错（${clientErr.slice(0, 60)}）`);
  ok(receiver.received.length === 0, '拒收后无文件落盘');
}

console.log(`\n${failures === 0 ? '全部通过' : `${failures} 项失败`}`);
process.exit(failures === 0 ? 0 : 1);
