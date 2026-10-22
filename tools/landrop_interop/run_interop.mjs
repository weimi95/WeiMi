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
import dgram from 'dgram';
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

// ==================== 测试 E：发现层互通（LANDrop Discovery ↔ SpecDiscovery） ====================
// 场景语义（逆向 asar class x 源码确认）：
//   发现包目的端口恒为 52637 → 绑 52637 的一方能收到对方的广播/组播；
//   被占降级临时端口的一方只能靠「我方 query → 对方单播应答到临时端口」入向。
//   LANDrop 对收到的包（无论 request 与否）都 emit discovery 登记设备；
//   对 request 包额外单播应答。另：LANDrop isSelf() 按源 IP 判自且含
//   127.0.0.1 → 同主机场景它的发现层必然全聋（其自身设计限制，非我方问题）。
section('测试 E：发现层互通');
{
  const { SpecDiscovery } = await import('./spec.mjs');
  const specKp = LD.SecpKeypair.generate();
  const specPkB64 = Buffer.from(specKp.pk).toString('base64');
  const unicastastReplyAddr = (s) => (s && s.addr) || '?';

  // 前置：52637 不得被外部进程占用（真 LANDrop.exe 在跑会让 E1 双方都降级）
  const probe = dgram.createSocket('udp4');
  const occupied = await new Promise((resolve) => {
    probe.once('error', (e) => resolve(e.code === 'EADDRINUSE'));
    probe.bind(52637, () => { probe.close(); resolve(false); });
  });
  if (occupied) {
    console.log('  ✗ UDP 52637 被外部进程占用（真 LANDrop 在跑？）——'
      + '请退出 LANDrop.exe 后重跑本测试');
    process.exit(1);
  }

  // ---- E1：微密先启动占 52637，LANDrop 后启动降级 ----
  section('E1：微密占 52637（LANDrop 降级）→ 微密应能发现 LANDrop');
  const spec = new SpecDiscovery({
    identitySk: Buffer.from(specKp.sk),
    identityPkB64: specPkB64,
    announceIntervalMs: 400, // 缩短周期，验证「周期主动 query」而非仅启动那一次
  });
  const e1 = await spec.start();
  ok(!e1.degraded && e1.port === 52637, `spec 绑上 52637（port=${e1.port}）`);

  const ldEvents = [];
  const ld = new LD.Discovery();
  ld.service.on('discovery', (e) => ldEvents.push(e)); // service=class x（真正 bind 52637）
  await ld.start(); // 52637 被 spec 占 → LANDrop 自身降级

  await new Promise((r) => setTimeout(r, 1200));
  const ldPkB64 = LD.identity.kp.pkBase64;
  ok(spec.devices.has(ldPkB64),
    'spec 登记了 LANDrop 设备（LANDrop 启动查询包也带完整身份 → 查询包也登记）');
  ok(!spec.devices.has(specPkB64), 'spec 不把自己登记为设备（组播回环按 pk 判自过滤）');
  ok(spec.queryCount >= 3, `spec 周期主动发 query 查询包（count=${spec.queryCount}）`);
  const ldSeesSpec = ldEvents.some((e) => e.discovery.public_key === specPkB64);
  if (ldSeesSpec) {
    ok(true, 'LANDrop 也发现了 spec（意外之喜）');
  } else {
    // LANDrop isSelf() 按本机所有网卡 IP 判自 → 同主机它的发现层全聋，
    // 这是它自身的设计限制（跨机源 IP 非本机则正常，见 E2 验证）。
    console.log('  - LANDrop 未发现 spec：同主机 isSelf(本机网卡 IP) 铁壁'
      + '（LANDrop 自身设计限制，跨机场景见 E2）');
  }

  // ---- E3：同机源 IP 精确复现「IP 判自误杀」 ----
  section('E3：同主机源 IP=127.0.0.1 的包不得被误判为自已');
  {
    const s3 = dgram.createSocket('udp4');
    await new Promise((res) => s3.bind(0, '127.0.0.1', res));
    const sendFromLoopback = (obj) => new Promise((res) => {
      s3.send(Buffer.from(JSON.stringify(obj)), spec.port, '127.0.0.1', res);
    });
    // 先摘除（discoverable=false），排除「E1 已登记导致断言恒真」
    await sendFromLoopback({
      public_key: ldPkB64, request: false, supported_versions: ['v2'],
      port: 52637, device_info: { name: 'LANDrop', type: 'windows' },
      discoverable: false,
    });
    await new Promise((r) => setTimeout(r, 200));
    ok(!spec.devices.has(ldPkB64), 'discoverable=false 正确摘除设备');
    // 再从 127.0.0.1 发 discoverable 包——按源 IP 判自的实现会在这里误杀
    await sendFromLoopback({
      public_key: ldPkB64, request: false, supported_versions: ['v2'],
      port: 52637, device_info: { name: 'LANDrop', type: 'windows' },
      discoverable: true,
    });
    await new Promise((r) => setTimeout(r, 300));
    ok(spec.devices.has(ldPkB64),
      '源 IP=127.0.0.1 的对方包仍被登记（只按 pk 判自，不按源 IP）');
    // 自己的包（即使来自 127.0.0.1）必须被过滤
    await sendFromLoopback({
      public_key: specPkB64, request: true, supported_versions: ['v2'],
      port: 52637, device_info: { name: '微密', type: 'windows' },
      discoverable: true,
    });
    await new Promise((r) => setTimeout(r, 300));
    ok(!spec.devices.has(specPkB64), '自己的包（源 127.0.0.1）被正确过滤');
    s3.close();
  }

  spec.stop();
  ld.service.socket.close(); // Discovery 类无 stop，直接关 socket

  // ---- E2：LANDrop 先启动占 52637，微密降级 ----
  section('E2：LANDrop 占 52637（微密降级临时端口）→ query/应答闭环');
  const ldSends = [];
  const ld2Events = [];
  const ld2 = new LD.Discovery();
  ld2.service.on('discovery', (e) => ld2Events.push(e));
  const origSend = ld2.service.sendDiscoveryPacket.bind(ld2.service);
  ld2.service.sendDiscoveryPacket = (req, addr, port) => {
    ldSends.push({ req, addr, port });
    return origSend(req, addr, port);
  };
  await ld2.start(); // 先启动 → 占住 52637

  const spec2 = new SpecDiscovery({
    identitySk: Buffer.from(specKp.sk),
    identityPkB64: specPkB64,
    serverPort: 52637, // TCP 服务端口（与 UDP 端口无关，发现包里报它）
  });
  const e2 = await spec2.start();
  ok(e2.degraded && e2.port !== 52637,
    `spec 降级临时端口（port=${e2.port} degraded=${e2.degraded}）`);

  await new Promise((r) => setTimeout(r, 800));
  // 同主机铁壁：ld2 的 announce/query 目的端口 52637，spec2 临时端口收不到；
  // spec2 的 query 到达 ld2 但源 IP=本机网卡 IP（192.168.250.x），被
  // LANDrop isSelf() 拦截。注意：局域网上其他真 LANDrop 机器可能已通过
  // 单播应答进到 spec2.devices（源地址非本机）——那是真实跨机证据，
  // 故断言只针对 ld2 自己。
  ok(!spec2.devices.has(LD.identity.kp.pkBase64),
    '同主机 ld2 未被 spec2 发现（LANDrop isSelf 按本机网卡 IP 判自，已知限制）');
  const foreignDevices = [...spec2.devices.keys()]
    .filter((pk) => pk !== LD.identity.kp.pkBase64).length;
  if (foreignDevices > 0) {
    console.log(`  + 额外证据：局域网上 ${foreignDevices} 台真实 LANDrop 已通过`
      + ' query→单播应答链路被发现（降级场景真机闭环）');
  }

  ld2.service.isSelf = () => false; // 模拟跨机：源 IP 非本机
  spec2.announce(); // announce + query 双发

  await new Promise((r) => setTimeout(r, 600));
  const unicastReply = ldSends.find(
    (s) => s.req === false && s.port === spec2.port);
  ok(!!unicastReply,
    'LANDrop 对 spec 的 query 单播应答到 spec 临时端口'
    + `（应答目标 ${unicastastReplyAddr(unicastReply)}:${unicastReply?.port}）`);
  ok(ld2Events.some((e) => e.discovery.public_key === specPkB64),
    'LANDrop 登记了 spec 设备（announce 与 query 都触发 discovery 事件）');
  ok(ld2.devices.some((d) => d.publicKey === specPkB64),
    'LANDrop manager 设备列表含 spec（产品语义层）');
  ok(spec2.devices.has(LD.identity.kp.pkBase64),
    'spec 通过单播应答登记到 LANDrop（降级场景入向通路闭环）');

  // ---- E4：降级期间 rebind（LANDrop 退出释放 52637 → 微密抢回） ----
  section('E4：LANDrop 退出 → 微密 rebind 抢回 52637');
  ld2.service.socket.close();
  await new Promise((r) => setTimeout(r, 200));
  const rebindOk = await spec2.rebindNow();
  ok(rebindOk && !spec2.degraded && spec2.port === 52637,
    `rebind 成功（port=${spec2.port} degraded=${spec2.degraded}）`);
  const ld3 = new LD.Discovery();
  await ld3.start(); // 此时 52637 被 spec2 占 → LD3 降级
  await new Promise((r) => setTimeout(r, 800));
  ok(spec2.devices.has(LD.identity.kp.pkBase64),
    'rebind 后恢复完整发现能力（收到 LANDrop 广播/组播 announce）');
  ld3.service.socket.close();
  spec2.stop();
}

console.log(`\n${failures === 0 ? '全部通过' : `${failures} 项失败`}`);
process.exit(failures === 0 ? 0 : 1);
