// 微密 LANDrop 兼容层的「规范实现」（JS 镜像 lib/services/landrop_service.dart 的协议逻辑）。
// 用途：与真实 LANDrop 主进程代码（bundle.mjs）做双向互通对拍——
//   测试 A：真实 LANDrop 客户端 → 本规范服务端（验证我方收）
//   测试 B：本规范客户端 → 真实 LANDrop 服务端（验证我方发）
// 密码学直接用 libsodium-wrappers + secp256k1（与 Dart 侧 FFI 调用的 Rust 原语同源，
// Rust 原语已用同一套向量逐字节对拍，见 rust_crypto/tests/landrop_vectors.json）。
import net from 'net';
import dgram from 'dgram';
import fs from 'fs';
import os from 'os';
import path from 'path';
import sodium from 'libsodium-wrappers';
import secp from 'secp256k1';

const MAX_BLOCK = 65518;

const hex = (u8) => Buffer.from(u8).toString('hex');

export class SpecSession {
  constructor(sock, { isClient }) {
    this.sock = sock;
    this.isClient = isClient;
    this.rxNonce = Buffer.alloc(12);
    this.txNonce = Buffer.alloc(12);
    this.buf = Buffer.alloc(0);
    this.rxKey = null;
    this.txKey = null;
    this.peerPkB64 = '';
    this.peerName = '对端设备';
  }

  // ---------- 帧 ----------
  _writeRaw(data) {
    const hdr = Buffer.alloc(2);
    hdr.writeUInt16BE(data.length, 0);
    this.sock.write(Buffer.concat([hdr, data]));
  }

  /// 读一个完整记录。每次调用挂/摘一次性监听；无监听期间 socket 流自动暂停，
  /// 数据进 Node 流内部缓冲，不丢。
  _readRaw() {
    return new Promise((resolve, reject) => {
      let done = false;
      const finish = (v, isErr) => {
        if (done) return;
        done = true;
        this.sock.removeListener('data', onData);
        this.sock.removeListener('close', onClose);
        this.sock.removeListener('error', onError);
        isErr ? reject(v) : resolve(v);
      };
      const onData = (d) => {
        this.buf = Buffer.concat([this.buf, d]);
        pump();
      };
      const onClose = () => finish(null, false);
      const onError = (e) => finish(e, true);
      const pump = () => {
        if (this.buf.length >= 2) {
          const len = this.buf.readUInt16BE(0);
          if (process.env.LD_DEBUG) {
            console.log(`[frame] len=${len} buf=${this.buf.length}`);
          }
          // 单记录明文 = 1B push + 数据（≤MAX_BLOCK），密文 +16B tag → 上限 MAX_BLOCK+17
          if (len > MAX_BLOCK + 17) {
            finish(new Error(`记录超长 ${len}`), true);
            return;
          }
          if (this.buf.length >= len + 2) {
            const out = this.buf.subarray(2, len + 2);
            this.buf = this.buf.subarray(len + 2);
            finish(out, false);
            return;
          }
        }
        this.sock.once('data', onData);
      };
      this.sock.once('close', onClose);
      this.sock.once('error', onError);
      pump();
    });
  }

  // ---------- 消息 ----------
  async sendBytes(data) {
    let offset = 0;
    do {
      const isLast = offset + MAX_BLOCK >= data.length;
      const end = isLast ? data.length : offset + MAX_BLOCK;
      const chunk = data.subarray(offset, end);
      const plain = Buffer.concat([Buffer.from([isLast ? 1 : 0]), chunk]);
      const ct = sodium.crypto_aead_chacha20poly1305_ietf_encrypt(
        plain, null, null, this.txNonce, this.txKey);
      this._writeRaw(ct);
      sodium.increment(this.txNonce);
      offset = end;
    } while (offset < data.length);
  }

  async recvBytes() {
    const out = [];
    for (;;) {
      const ct = await this._readRaw();
      if (ct === null) return null;
      const plain = sodium.crypto_aead_chacha20poly1305_ietf_decrypt(
        null, ct, null, this.rxNonce, this.rxKey);
      sodium.increment(this.rxNonce);
      if (plain.length === 0) throw new Error('异常的空记录');
      out.push(plain.subarray(1));
      if (plain[0] === 1) return Buffer.concat(out);
    }
  }

  async sendJson(msg) {
    await this.sendBytes(Buffer.from(JSON.stringify(msg), 'utf-8'));
  }

  async recvJson() {
    const b = await this.recvBytes();
    if (b === null) return null;
    try {
      return JSON.parse(b.toString('utf-8'));
    } catch {
      return null;
    }
  }

  // ---------- 握手 ----------
  /// npm secp256k1 对入参做严格原型检查（Buffer 虽 instanceof Uint8Array 也被拒），
  /// 统一转原生 Uint8Array 零拷贝视图。
  static u8(b) {
    return new Uint8Array(b.buffer, b.byteOffset, b.byteLength);
  }

  static signEcdhe(ecdhePk, sk) {
    const digest = sodium.crypto_generichash(32, ecdhePk);
    return Buffer.from(secp.ecdsaSign(digest, sk).signature);
  }

  static verifyEcdhe(sig, ecdhePk, pk) {
    const digest = sodium.crypto_generichash(32, ecdhePk);
    // secp256k1@5 的 signatureNormalize 直接返回规范化签名（与 LANDrop 源码用法一致）
    const norm = secp.signatureNormalize(SpecSession.u8(sig));
    return secp.ecdsaVerify(norm, digest, SpecSession.u8(pk));
  }

  /// 服务端握手（我方收）
  async handshakeAsServer(identitySk, identityPkB64) {
    const helloBytes = await this._readRaw();
    if (helloBytes === null) throw new Error('ClientHello 未到达');
    const hello = JSON.parse(helloBytes.toString('utf-8'));
    if (!(hello.supported_versions || []).includes('v2')) {
      throw new Error('对端不支持 v2');
    }
    const ecdhePk = Buffer.from(hello.ecdhe.public_key, 'base64');
    const sig = Buffer.from(hello.ecdhe.sig, 'base64');
    const peerPk = Buffer.from(hello.public_key, 'base64');
    if (!SpecSession.verifyEcdhe(sig, ecdhePk, peerPk)) {
      throw new Error('ClientHello 验签失败');
    }
    // 我方 kx 密钥对 + 签名
    const kx = sodium.crypto_kx_keypair();
    const mySig = SpecSession.signEcdhe(Buffer.from(kx.publicKey), identitySk);
    this._writeRaw(Buffer.from(JSON.stringify({
      version: 'v2',
      public_key: identityPkB64,
      ecdhe: {
        public_key: Buffer.from(kx.publicKey).toString('base64'),
        sig: mySig.toString('base64'),
      },
    }), 'utf-8'));
    const keys = sodium.crypto_kx_server_session_keys(
      Buffer.from(kx.publicKey), Buffer.from(kx.privateKey), ecdhePk);
    this.rxKey = keys.sharedRx;
    this.txKey = keys.sharedTx;
    this.peerPkB64 = hello.public_key;
    this.verifCode = SpecSession.verifCode(this.txKey, this.rxKey); // server: kSc=tx, kCs=rx
  }

  /// 客户端握手（我方发）
  async handshakeAsClient(identitySk, identityPkB64) {
    const kx = sodium.crypto_kx_keypair();
    const mySig = SpecSession.signEcdhe(Buffer.from(kx.publicKey), identitySk);
    this._writeRaw(Buffer.from(JSON.stringify({
      supported_versions: ['v2'],
      public_key: identityPkB64,
      ecdhe: {
        public_key: Buffer.from(kx.publicKey).toString('base64'),
        sig: mySig.toString('base64'),
      },
    }), 'utf-8'));
    const helloBytes = await this._readRaw();
    if (helloBytes === null) throw new Error('ServerHello 未到达');
    const hello = JSON.parse(helloBytes.toString('utf-8'));
    if (hello.version !== 'v2') throw new Error('对端不是 v2');
    const ecdhePk = Buffer.from(hello.ecdhe.public_key, 'base64');
    const sig = Buffer.from(hello.ecdhe.sig, 'base64');
    const peerPk = Buffer.from(hello.public_key, 'base64');
    if (!SpecSession.verifyEcdhe(sig, ecdhePk, peerPk)) {
      throw new Error('ServerHello 验签失败');
    }
    const keys = sodium.crypto_kx_client_session_keys(
      Buffer.from(kx.publicKey), Buffer.from(kx.privateKey), ecdhePk);
    this.rxKey = keys.sharedRx;
    this.txKey = keys.sharedTx;
    this.peerPkB64 = hello.public_key;
    this.verifCode = SpecSession.verifCode(this.rxKey, this.txKey); // client: kSc=rx, kCs=tx
  }

  /// LANDrop verifCode 公式（与 Rust landrop.rs 同源）
  static verifCode(kSc, kCs) {
    // crypto_generichash 回 Uint8Array，readBigUInt64LE 需要 Buffer
    const digest = Buffer.from(sodium.crypto_generichash(
      16, Buffer.concat([Buffer.from(kSc), Buffer.from(kCs)])));
    const t = digest.readBigUInt64LE(0);
    const s = digest.readBigUInt64LE(8);
    return ((t ^ s) % 1000000n).toString().padStart(6, '0');
  }

  close() {
    try { this.sock.destroy(); } catch {}
  }
}

// ==================== 规范服务端（= 我方接收端） ====================

export class SpecReceiver {
  constructor({ identitySk, identityPkB64, deviceName = '微密文件', declineAll = false }) {
    this.identitySk = identitySk;
    this.identityPkB64 = identityPkB64;
    this.deviceName = deviceName;
    this.declineAll = declineAll; // 测试 D：一律拒收
    this.received = []; // {filename, path, size}
  }

  start(port = 0) {
    this.server = net.createServer((sock) => this._onConn(sock));
    return new Promise((resolve) => {
      this.server.listen(port, '127.0.0.1', () => resolve(this.server.address().port));
    });
  }

  async _onConn(sock) {
    try {
      const s = new SpecSession(sock, { isClient: false });
      await s.handshakeAsServer(this.identitySk, this.identityPkB64);
      this.lastVerifCode = s.verifCode;
      this.lastSession = s;
      for (;;) {
        const msg = await s.recvJson();
        if (msg === null) return;
        switch (msg.type) {
          case 'supported_message_types':
            await s.sendJson({
              type: 'supported_message_types',
              data: { types: ['ack', 'supported_message_types', 'device_info',
                'file_send_request', 'file_send_request_reply', 'text_send'] },
            });
            break;
          case 'device_info':
            s.peerName = msg.data.name || '对端设备';
            await s.sendJson({
              type: 'device_info',
              data: { name: this.deviceName, type: 'windows' },
            });
            break;
          case 'file_send_request':
            await this._onFileSendRequest(s, msg.data.files || []);
            break;
          case 'text_send':
            await s.sendJson({ type: 'ack', data: { ack: true } });
            break;
          default:
            await s.sendJson({ type: 'ack', data: { ack: false } });
        }
      }
    } catch (e) {
      console.error('[spec-receiver] 连接异常:', e.message);
    } finally {
      try { sock.destroy(); } catch {}
    }
  }

  async _onFileSendRequest(s, files) {
    if (!files.length || this.declineAll) {
      await s.sendJson({ type: 'file_send_request_reply', data: { accept: false, compression: 'none' } });
      return;
    }
    await s.sendJson({ type: 'file_send_request_reply', data: { accept: true, compression: 'none' } });
    for (const f of files) {
      const outDir = process.env.LD_SPEC_RECV_DIR;
      const out = path.join(outDir, f.filename);
      fs.mkdirSync(path.dirname(out), { recursive: true });
      const fd = fs.openSync(out, 'w');
      let remaining = f.size;
      while (remaining > 0) {
        const chunk = await s.recvBytes();
        if (chunk === null) throw new Error('对端中途断开');
        fs.writeSync(fd, chunk);
        remaining -= chunk.length;
      }
      fs.closeSync(fd);
      // 恢复 mtime / 权限（与 Dart landrop_service 一致）
      fs.utimesSync(out, new Date(f.last_modified * 1000), new Date(f.last_modified * 1000));
      try { fs.chmodSync(out, parseInt(f.permissions || '644', 8)); } catch {}
      this.received.push({ filename: f.filename, path: out, size: f.size });
    }
  }
}

// ==================== 规范客户端（= 我方发送端） ====================

export async function specSendFiles({
  host, port, identitySk, identityPkB64, files, deviceName = '微密文件',
}) {
  const sock = net.createConnection({ host, port });
  await new Promise((res, rej) => {
    sock.once('connect', res);
    sock.once('error', rej);
  });
  const s = new SpecSession(sock, { isClient: true });
  await s.handshakeAsClient(identitySk, identityPkB64);
  await s.sendJson({ type: 'supported_message_types',
    data: { types: ['ack', 'supported_message_types', 'device_info',
      'file_send_request', 'file_send_request_reply', 'text_send'] } });
  const mt = await s.recvJson();
  if (!mt || mt.type !== 'supported_message_types') throw new Error('对端不回 supported_message_types');
  await s.sendJson({ type: 'device_info', data: { name: deviceName, type: 'windows' } });
  const di = await s.recvJson();
  if (!di || di.type !== 'device_info') throw new Error('对端不回 device_info');

  const req = {
    type: 'file_send_request',
    data: {
      files: files.map((f) => ({
        filename: f.filename,
        size: fs.statSync(f.path).size,
        last_modified: Math.floor(fs.statSync(f.path).mtimeMs / 1000),
        permissions: '644',
      })),
      supported_compressions: ['none'],
      ios_live_photos: [],
    },
  };
  await s.sendJson(req);
  const reply = await s.recvJson();
  if (!reply || reply.type !== 'file_send_request_reply' || !reply.data.accept) {
    throw new Error('对端拒收');
  }
  for (const f of files) {
    const data = fs.readFileSync(f.path);
    await s.sendBytes(data); // ≤65518/条自动分片，末片 push=1
  }
  // 等对端处理完（对端读完即关）
  await new Promise((res) => {
    const t = setTimeout(res, 3000);
    sock.once('close', () => { clearTimeout(t); res(); });
  });
  s.close();
  return { verifCode: s.verifCode, peerName: di.data.name };
}

// ==================== 规范发现层（= 我方发现端） ====================
// 镜像 lib/services/landrop_service.dart 的发现逻辑（v1.2.1 起）：
//   - bind 52637 被占 → 降级临时端口 + 每 5s 重试抢回（rebind）
//   - 周期 announce + query 双发（组播 + 广播）——LANDrop 被动设计，
//     不主动查就发现不了先启动的对方
//   - 只按身份公钥判自（同主机对方包也来自本机 IP，按 IP 判自会误杀）
//   - 任何 discoverable 包（含 request 查询包）都先登记设备再按需应答
export class SpecDiscovery {
  static MULTICAST_GROUP = '239.192.52.63';
  static PORT = 52637;

  constructor({
    identitySk, identityPkB64,
    deviceName = '微密文件(spec)',
    deviceType = 'windows',
    serverPort = 0,
    announceIntervalMs = 10000,
    rebindIntervalMs = 5000,
  }) {
    this.identitySk = identitySk;
    this.identityPkB64 = identityPkB64;
    this.deviceName = deviceName;
    this.deviceType = deviceType;
    this.serverPort = serverPort;
    this.announceIntervalMs = announceIntervalMs;
    this.rebindIntervalMs = rebindIntervalMs;
    this.sock = dgram.createSocket('udp4');
    this.port = 0;
    this.degraded = false;
    this.devices = new Map(); // pk -> {publicKey,name,type,address,port,lastSeen}
    this.rxLog = [];         // {addr, port, request}
    this.queryCount = 0;     // 发出的 query 包数（announce+query 双发验证）
    this.rebindCount = 0;
    this.timer = null;
    this.rebindTimer = null;
    this.stopped = false;

    this.sock.on('message', (msg, rinfo) => this._onMessage(msg, rinfo));
  }

  start() {
    return new Promise((resolve, reject) => {
      const onReady = (degraded) => {
        this.sock.removeAllListeners('error');
        this.port = this.sock.address().port;
        this.degraded = degraded;
        try { this.sock.setBroadcast(true); } catch {}
        try { this.sock.setMulticastTTL(32); } catch {}
        this._joinMulticast();
        this.timer = setInterval(() => {
          this._joinMulticast();
          this.announce();
        }, this.announceIntervalMs);
        if (degraded) {
          this.rebindTimer = setInterval(() => this.rebindNow(),
            this.rebindIntervalMs);
        }
        this.announce(); // 启动即播一轮（ Dart _startDiscovery 后立即 _announce）
        resolve({ port: this.port, degraded });
      };
      this.sock.on('error', (e) => {
        if (e.code === 'EADDRINUSE') {
          this.sock.bind(0, () => onReady(true));
        } else {
          reject(e);
        }
      });
      this.sock.bind(SpecDiscovery.PORT, () => onReady(false));
    });
  }

  _joinMulticast() {
    for (const addrs of Object.values(os.networkInterfaces())) {
      for (const a of addrs) {
        if (a.family !== 'IPv4' || a.internal) continue;
        try { this.sock.addMembership(SpecDiscovery.MULTICAST_GROUP, a.address); }
        catch {}
      }
    }
  }

  _packet(request = false) {
    return {
      request,
      supported_versions: ['v2'],
      public_key: this.identityPkB64,
      port: this.serverPort,
      device_info: { name: this.deviceName, type: this.deviceType },
      discoverable: true,
    };
  }

  /// 周期广播：组播 + 广播 × (announce + query)（与 Dart _announce 一致）
  announce() {
    if (this.stopped) return;
    for (const request of [false, true]) {
      const data = Buffer.from(JSON.stringify(this._packet(request)));
      if (request) this.queryCount++;
      for (const [host, dstPort] of [
        [SpecDiscovery.MULTICAST_GROUP, SpecDiscovery.PORT],
        ['255.255.255.255', SpecDiscovery.PORT],
      ]) {
        try { this.sock.send(data, dstPort, host); } catch {}
      }
    }
  }

  _onMessage(msg, rinfo) {
    let packet;
    try {
      packet = JSON.parse(msg.toString());
    } catch {
      return;
    }
    const pk = packet.public_key || '';
    if (!pk) return;
    this.rxLog.push({ addr: rinfo.address, port: rinfo.port, request: !!packet.request });
    // 只按身份公钥判自（同主机并存的对方包源 IP 也是本机 IP，按 IP 判自会误杀）
    if (pk === this.identityPkB64) return;
    if (packet.discoverable !== true) {
      this.devices.delete(pk); // 对方关掉可被发现 → 摘除
      return;
    }
    // announce 与查询包都带完整设备信息 → 先登记，再按需单播应答
    const info = packet.device_info || {};
    this.devices.set(pk, {
      publicKey: pk,
      name: info.name || '未知设备',
      type: info.type || '',
      address: rinfo.address,
      port: packet.port || SpecDiscovery.PORT,
      lastSeen: Date.now(),
    });
    if (packet.request === true) {
      // 对方在主动查询 → 单播应答（LANDrop 对广播/组播查询都回单播）
      try {
        this.sock.send(Buffer.from(JSON.stringify(this._packet(false))),
          rinfo.port, rinfo.address);
      } catch {}
    }
  }

  /// 重试 bind 52637（降级恢复路径；测试用手动触发）
  rebindNow() {
    if (this.stopped || !this.degraded) return Promise.resolve(false);
    return new Promise((resolve) => {
      const s2 = dgram.createSocket('udp4');
      s2.on('error', () => { try { s2.close(); } catch {} resolve(false); });
      s2.bind(SpecDiscovery.PORT, () => {
        try { s2.setBroadcast(true); } catch {}
        try { s2.setMulticastTTL(32); } catch {}
        const old = this.sock;
        this.sock = s2;
        this.port = s2.address().port;
        this.degraded = false;
        this.rebindCount++;
        s2.on('message', (msg, rinfo) => this._onMessage(msg, rinfo));
        this._joinMulticast();
        clearInterval(this.rebindTimer);
        this.rebindTimer = null;
        try { old.close(); } catch {}
        this.announce();
        resolve(true);
      });
    });
  }

  stop() {
    this.stopped = true;
    clearInterval(this.timer);
    clearInterval(this.rebindTimer);
    this.timer = null;
    this.rebindTimer = null;
    try { this.sock.close(); } catch {}
  }
}
