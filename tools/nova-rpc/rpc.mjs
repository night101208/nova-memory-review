#!/usr/bin/env node
/**
 * 게이트웨이 메서드 하나를 앱 신원으로 호출하고 응답을 그대로 찍는다.
 *
 * 왜 필요한가: 플러그인이 등록한 메서드(`nova.memory.*`)는 CLI에 없다.
 * 게이트웨이에 붙어서만 부를 수 있는데, 붙는 데 v3 디바이스 서명이 필요하다.
 * `tools/roundtrip/`이 그 절차를 이미 갖고 있어서 그쪽 규약을 그대로 쓰되,
 * 대화 대신 **아무 메서드나** 부를 수 있게 열어둔 것이다.
 *
 *   node tools/nova-rpc/rpc.mjs --method nova.memory.lint
 *   node tools/nova-rpc/rpc.mjs --method nova.memory.session.capture \
 *        --params '{"sessionKey":"agent:main:main","dryRun":true}'
 *
 * ⚠️ 소켓을 일찍 닫으면 처리가 중단된다 (하드윈 22번). 응답을 받고 닫는다.
 */
import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import crypto from "node:crypto";
import { createRequire } from "node:module";

const require = createRequire("/opt/homebrew/lib/node_modules/openclaw/");
const WebSocket = require("ws");

const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i !== -1 && process.argv[i + 1] ? process.argv[i + 1] : fallback;
};

const URL_ = arg("url", "ws://GATEWAY-HOST:18789");
const METHOD = arg("method", "");
const PARAMS = JSON.parse(arg("params", "{}"));
const TIMEOUT = Number(arg("timeout", "60")) * 1000;

if (!METHOD) {
  console.error("--method 가 필요합니다.");
  process.exit(2);
}

// ── 신원 ────────────────────────────────────────────────────────────────
// 디바이스 키는 파일이 정본이다 (하드윈 24번 ★ — 키체인은 파티션 목록 때문에
// 빌드마다 암호를 물어서 옮겼다). 예전 키체인 항목은 폴백으로만 본다.
const KEY_FILE = join(homedir(), ".openclaw", "nova-device-identity");
const KEYCHAIN_SERVICE = "ai.openclaw.nova.device-identity";

function loadSeed() {
  try {
    return { raw: readFileSync(KEY_FILE, "utf8").trim(), from: "파일" };
  } catch {
    const raw = execFileSync("security", [
      "find-generic-password", "-w", "-s", KEYCHAIN_SERVICE, "-a", "default",
    ]).toString().trim();
    return { raw, from: "키체인" };
  }
}

function loadDeviceKey() {
  const { raw, from } = loadSeed();
  const seed = /^[0-9a-fA-F]{64}$/.test(raw) ? Buffer.from(raw, "hex") : Buffer.from(raw, "utf8");
  if (seed.length !== 32) throw new Error(`Ed25519 시드가 32바이트가 아닙니다 (${seed.length})`);
  const pkcs8 = Buffer.concat([Buffer.from("302e020100300506032b657004220420", "hex"), seed]);
  const privateKey = crypto.createPrivateKey({ key: pkcs8, format: "der", type: "pkcs8" });
  const spki = crypto.createPublicKey(privateKey).export({ format: "der", type: "spki" });
  const publicKeyRaw = spki.subarray(spki.length - 32);
  const deviceId = crypto.createHash("sha256").update(publicKeyRaw).digest("hex");
  return { privateKey, publicKeyRaw, deviceId, from };
}

const b64url = (buf) => buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

const token = (() => {
  const cfg = JSON.parse(readFileSync(join(homedir(), ".openclaw", "openclaw.json"), "utf8"));
  return cfg?.gateway?.auth?.token ?? "";
})();

// 앱과 같은 선언값. 다르게 선언하면 metadata-upgrade로 재승인을 요구받는다 (하드윈 7번).
const CLIENT_ID = "openclaw-macos";
const CLIENT_MODE = "ui";
const ROLE = "operator";
const SCOPES = ["operator.read", "operator.write"];
const PLATFORM = "macos";
const DEVICE_FAMILY = "Mac";

function buildDeviceParams({ privateKey, publicKeyRaw, deviceId }, nonce) {
  const signedAt = Date.now();
  const payload = [
    "v3", deviceId, CLIENT_ID, CLIENT_MODE, ROLE, SCOPES.join(","),
    String(signedAt), token, nonce, PLATFORM.toLowerCase(), DEVICE_FAMILY.toLowerCase(),
  ].join("|");
  return {
    id: deviceId,
    publicKey: b64url(publicKeyRaw),
    signature: b64url(crypto.sign(null, Buffer.from(payload, "utf8"), privateKey)),
    signedAt,
    nonce,
  };
}

// ── 호출 ────────────────────────────────────────────────────────────────
const identity = loadDeviceKey();
console.error(`대상 ${URL_} · 신원 ${identity.deviceId.slice(0, 12)}… (${identity.from}) · ${METHOD}`);

const ws = new WebSocket(URL_);
let connectId = null, callId = null, done = false;
const send = (o) => ws.send(JSON.stringify(o));

const finish = (code, note) => {
  if (done) return;
  done = true;
  if (note) console.error(note);
  try { ws.close(); } catch {}
  process.exit(code);
};

const timer = setTimeout(() => finish(1, `✗ 타임아웃 (${TIMEOUT / 1000}초)`), TIMEOUT);
ws.on("error", (e) => { clearTimeout(timer); finish(1, `✗ 소켓 오류: ${e.message}`); });

ws.on("message", (raw) => {
  let f;
  try { f = JSON.parse(raw.toString()); } catch { return; }

  if (f.type === "event" && f.event === "connect.challenge") {
    connectId = "c1";
    send({
      type: "req", id: connectId, method: "connect",
      params: {
        minProtocol: 4, maxProtocol: 4,
        client: {
          id: CLIENT_ID, displayName: "NOVA RPC", version: "0.1.0",
          platform: PLATFORM, deviceFamily: DEVICE_FAMILY, mode: CLIENT_MODE,
        },
        role: ROLE, scopes: SCOPES,
        ...(token ? { auth: { token } } : {}),
        device: buildDeviceParams(identity, f.payload?.nonce ?? ""),
      },
    });
    return;
  }

  if (f.type === "res" && f.id === connectId) {
    if (f.error) return finish(1, `✗ connect 거부: ${JSON.stringify(f.error)}`);
    // 부여된 권한은 payload.auth 아래다. 최상위를 읽으면 늘 빈 배열이다 (하드윈 23번).
    const granted = (f.payload ?? f.result ?? {}).auth ?? {};
    console.error(`✓ 연결됨 role=${granted.role ?? "?"} scopes=[${granted.scopes ?? []}]`);
    callId = "r1";
    send({ type: "req", id: callId, method: METHOD, params: PARAMS });
    return;
  }

  if (f.type === "res" && f.id === callId) {
    clearTimeout(timer);
    if (f.error) {
      console.log(JSON.stringify({ error: f.error }, null, 2));
      return finish(1, null);
    }
    console.log(JSON.stringify(f.payload ?? f.result ?? null, null, 2));
    return finish(0, null);
  }
});
