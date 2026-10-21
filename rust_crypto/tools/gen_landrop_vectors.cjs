// LANDrop v2 加密原语对拍向量生成器
//
// 用官方实现生成确定性测试向量，供 Rust 侧（rust_crypto/tests/landrop_vectors.rs 内嵌单测）逐项对拍：
//   - libsodium-wrappers：crypto_kx_* / crypto_generichash / crypto_aead_chacha20poly1305_ietf_* / increment
//   - secp256k1（npm）：publicKeyCreate / ecdsaSign / ecdsaVerify（LANDrop 用的就是这个包）
//
// 运行：
//   cd C:\Users\Administrator\.workbuddy\binaries\node\workspace
//   node <本脚本>
// 输出：rust_crypto/tests/landrop_vectors.json（全部 hex 编码）

const fs = require('fs');
const path = require('path');
const sodium = require('libsodium-wrappers');
const secp = require('secp256k1');

const OUT = path.resolve(__dirname, '..', 'tests', 'landrop_vectors.json');

const hex = (u8) => Buffer.from(u8).toString('hex');
const unhex = (s) => Uint8Array.from(Buffer.from(s, 'hex'));

// 确定性伪随机（LCG），避免引入随机源导致向量不可复现
function detBytes(n, seed) {
  const out = new Uint8Array(n);
  let s = seed >>> 0;
  for (let i = 0; i < n; i++) {
    s = (Math.imul(s, 1664525) + 1013904223) >>> 0;
    out[i] = s & 0xff;
  }
  return out;
}

(async () => {
  await sodium.ready;

  // ---------- 1. kx 会话密钥 ----------
  // 固定 sk（X25519 任意 32 字节均合法，内部 clamp）
  const clientSk = detBytes(32, 0x11);
  const serverSk = detBytes(32, 0x22);
  const clientPk = sodium.crypto_scalarmult_base(clientSk);
  const serverPk = sodium.crypto_scalarmult_base(serverSk);
  const cks = sodium.crypto_kx_client_session_keys(clientPk, clientSk, serverPk);
  const sks = sodium.crypto_kx_server_session_keys(serverPk, serverSk, clientPk);
  const kx = {
    client: { pk: hex(clientPk), sk: hex(clientSk) },
    server: { pk: hex(serverPk), sk: hex(serverSk) },
    session: {
      client_rx: hex(cks.sharedRx),
      client_tx: hex(cks.sharedTx),
      server_rx: hex(sks.sharedRx),
      server_tx: hex(sks.sharedTx),
    },
  };

  // ---------- 2. verifCode（LANDrop we.verifCode 公式复刻） ----------
  // client 视角：kSc = rx, kCs = tx
  const kSc = cks.sharedRx;
  const kCs = cks.sharedTx;
  const digest = sodium.crypto_generichash(16, Buffer.concat([Buffer.from(kSc), Buffer.from(kCs)]));
  const t = Buffer.from(digest.slice(0, 8)).readBigUInt64LE();
  const s = Buffer.from(digest.slice(8, 16)).readBigUInt64LE();
  const code = ((t ^ s) % 1000000n).toString().padStart(6, '0');
  const verif = { kSc: hex(kSc), kCs: hex(kCs), code };

  // ---------- 3. secp256k1 身份密钥 / 签名 ----------
  const idSk = detBytes(32, 0x33); // 0x33 开头 < 曲线阶 n，privateKeyVerify 必过
  if (!secp.privateKeyVerify(idSk)) throw new Error('idSk invalid');
  const idPk = secp.publicKeyCreate(idSk, true); // 压缩 33B
  const ecdhePk = detBytes(32, 0x44); // 模拟握手里的 ecdhe.pk
  const sig = secp.ecdsaSign(Buffer.from(sodium.crypto_generichash(32, ecdhePk)), idSk).signature;
  // 自校验：npm 包自身验签必须过
  if (!secp.ecdsaVerify(sig, Buffer.from(sodium.crypto_generichash(32, ecdhePk)), idPk)) {
    throw new Error('secp self-verify failed');
  }
  const secpVec = {
    sk: hex(idSk),
    pk: hex(idPk),
    msg: hex(ecdhePk), // secp_sign 内部先 blake2b-256，这里向量只存原始 msg
    sig: hex(sig),
  };
  // 高 S 变体（s' = n - s）：LANDrop 验签前先 normalize_s，Rust 侧必须同行为
  {
    const N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141n;
    const r = Buffer.from(sig.slice(0, 32));
    const s = BigInt('0x' + Buffer.from(sig.slice(32)).toString('hex'));
    const sHigh = N - s;
    const sigHigh = Buffer.concat([r, Buffer.from(sHigh.toString(16).padStart(64, '0'), 'hex')]);
    secpVec.sig_high_s = hex(sigHigh);
    secpVec.high_s_verify_npm = secp.ecdsaVerify(
      sigHigh,
      Buffer.from(sodium.crypto_generichash(32, ecdhePk)),
      idPk,
    );
  }

  // ---------- 4. BLAKE2b 多长度 ----------
  const blake2b = [
    { out_len: 16, in: hex(detBytes(0, 0x51)) },
    { out_len: 16, in: hex(detBytes(64, 0x52)) },
    { out_len: 32, in: hex(detBytes(64, 0x53)) },
    { out_len: 32, in: hex(ecdhePk) },
    { out_len: 64, in: hex(detBytes(100, 0x54)) },
    { out_len: 64, in: hex(Buffer.concat([Buffer.from(kSc), Buffer.from(kCs)])) },
  ].map((c) => ({ ...c, out: hex(sodium.crypto_generichash(c.out_len, unhex(c.in))) }));

  // ---------- 5. ChaCha20-Poly1305-IETF ----------
  const aeadKey = detBytes(32, 0x61);
  const aeadNonce = detBytes(12, 0x62);
  const aeadCases = [
    detBytes(0, 0x63), // 空明文
    detBytes(1, 0x64),
    detBytes(100, 0x65),
    detBytes(65518, 0x66), // 正好一个记录
    detBytes(65519, 0x67), // 跨记录
    detBytes(70000, 0x68),
  ].map((pt) => ({
    key: hex(aeadKey),
    nonce: hex(aeadNonce),
    pt: hex(pt),
    ct: hex(sodium.crypto_aead_chacha20poly1305_ietf_encrypt(pt, null, null, aeadNonce, aeadKey)),
  }));
  // 换一把 key/nonce 再各来一例，防"只对固定输入成立"
  const aeadKey2 = detBytes(32, 0x71);
  const aeadNonce2 = detBytes(12, 0x72);
  aeadCases.push({
    key: hex(aeadKey2),
    nonce: hex(aeadNonce2),
    pt: hex(detBytes(555, 0x73)),
    ct: hex(sodium.crypto_aead_chacha20poly1305_ietf_encrypt(detBytes(555, 0x73), null, null, aeadNonce2, aeadKey2)),
  });

  // ---------- 6. sodium_increment（12B 小端） ----------
  const nonceInc = [];
  {
    const starts = [detBytes(12, 0x81), unhex('ffffffffffff000000000000'), unhex('ff0000000000000000000000'), new Uint8Array(12), unhex('ffffffffffffffffffffffff')];
    for (const st of starts) {
      const n = Uint8Array.from(st);
      const steps = [];
      for (let i = 0; i < 5; i++) {
        sodium.increment(n);
        steps.push(hex(n));
      }
      nonceInc.push({ start: hex(st), steps });
    }
  }

  const vectors = { kx, verif, secp: secpVec, blake2b, aead: aeadCases, nonce_inc: nonceInc };
  fs.mkdirSync(path.dirname(OUT), { recursive: true });
  fs.writeFileSync(OUT, JSON.stringify(vectors, null, 2));
  console.log('written:', OUT);
  console.log('verifCode =', code, '| aead cases =', aeadCases.length, '| blake2b cases =', blake2b.length);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
