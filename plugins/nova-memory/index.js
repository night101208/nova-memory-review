import { promises as fs, constants } from "node:fs";
import path from "node:path";
import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { resolveAgentWorkspaceDir, resolveDefaultAgentId } from "openclaw/plugin-sdk/health";
import { resolveAgentDir, resolveAgentIdFromSessionKey } from "openclaw/plugin-sdk/agent-runtime";
import {
  assertSafeShortTermText,
  findContamination,
  renderShortTermMemory,
} from "./short-term-format.js";

/**
 * NOVA Memory — 기억 파일을 고치고 지우는 게이트웨이 메서드.
 *
 * 왜 필요한가: 읽기는 기본 게이트웨이로 이미 된다
 * (`agents.workspace.list` / `agents.workspace.get`). 없는 것은 쓰기뿐이다.
 *   - `agents.files.set`은 루트 여덟 개(AGENTS/SOUL/TOOLS/IDENTITY/USER/
 *     HEARTBEAT/BOOTSTRAP/MEMORY.md)만 받고 `memory/` 아래는 거부한다
 *   - `agents.workspace.*`는 스키마 주석이 "intentionally read-only"라고 못박고 있다
 *   - `tools.invoke`로는 write/edit에 못 닿는다. 그 도구들은 claude-cli 서브프로세스
 *     안에 있어서 게이트웨이가 직접 부를 수 없다 ("Tool not available: write")
 *
 * 전부 실제로 호출해서 확인한 것이다.
 */

const READ_SCOPE = "operator.read";
const WRITE_SCOPE = "operator.write";

/**
 * 단기 기억으로 인정되는 파일 이름.
 * 원본은 `short-term-promotion-stx0l04M.js:555`의 `SHORT_TERM_BASENAME_RE`.
 * 이 꼴이 아니면 dreaming이 장기 기억(evergreen)으로 보고 굳히기 후보에서 뺀다.
 */
const SHORT_TERM_BASENAME_RE = /^(\d{4})-(\d{2})-(\d{2})(?:-[^/]+)?\.md$/;

/** 세션 id로 받아들일 글자. 경로 구분자와 `..`가 절대 못 들어오게 한다. */
const SESSION_ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/;

/** 슬러그로 받을 수 있는 글자. 경로를 벗어날 여지를 남기지 않는다. */
const SLUG_RE = /^[0-9a-z가-힣][0-9a-z가-힣-]{0,48}$/i;

/**
 * 세션 전사가 있는 곳.
 *
 * ⚠️ `resolveAgentDir`는 `<stateDir>/agents/<id>/agent`를 준다 — **한 칸 더 들어간 곳**이다.
 * 세션은 그 형제인 `<stateDir>/agents/<id>/sessions/`에 있다. 실제 배치는
 * `audit-extra.async-H-AndR0o.js:410`이 `path.join(stateDir, "agents", agentId,
 * "sessions", "sessions.json")`으로 못박고 있고, plugin-sdk에는 stateDir을 주는
 * 함수가 없어서 agentDir의 부모로 되짚는다.
 */
function resolveSessionsDir(cfg, agentId) {
  return path.join(path.dirname(resolveAgentDir(cfg, agentId)), "sessions");
}

const pad2 = (n) => String(n).padStart(2, "0");
const formatLocalDate = (d) => `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}`;
const formatLocalTime = (d) => `${pad2(d.getHours())}:${pad2(d.getMinutes())}`;

/** 전사의 content는 사용자면 문자열, 어시스턴트면 파트 배열이다. */
function extractMessageText(content) {
  if (typeof content === "string") return content.trim();
  if (!Array.isArray(content)) return "";
  return content
    .filter((part) => part?.type === "text" && typeof part.text === "string")
    .map((part) => part.text)
    .join("\n")
    .trim();
}

/**
 * 쓸 파일의 상대 경로를 정한다. 같은 분에 두 번 부르면 덮어쓰지 않고 `-2`를 붙인다.
 * 기억을 소리 없이 잃는 것보다 파일이 하나 느는 편이 낫다.
 */
/**
 * 해석된 경로가 **실제로도** `memory/` 안인지 본다.
 *
 * `resolveMemoryPath`는 `path.resolve`로만 판단한다 — 글자 계산이라
 * `memory/link -> /바깥`처럼 **중간 디렉터리가 심볼릭 링크**면 그대로 통과한다.
 * 그러면 write가 OS 수준에서 링크를 따라가 워크스페이스 밖을 건드린다.
 * `assertPlainFile`은 마지막 파일만 `lstat`하므로 이걸 못 잡는다.
 *
 * 그래서 존재하는 가장 깊은 조상까지 올라가 `realpath`로 실체를 확인한다.
 * 아직 없는 구간은 만들어질 자리 그대로 이어붙여 비교한다.
 * **디렉터리를 만들기 전에** 불러야 한다 — `mkdir -p`가 링크를 따라가 버리면 늦는다.
 */
/**
 * 해석된 경로가 **실제로도** `root` 안인지 본다. 이름에 `Memory`가 없는 이유는
 * 이제 `memory/`뿐 아니라 `sessions/`에도 같은 검사를 걸기 때문이다 — 뿌리만 다르고
 * 위험은 같다: 중간 디렉터리가 심볼릭 링크면 글자 비교(`resolveMemoryPath`)로는
 * 못 잡고, 마지막 파일만 보는 `assertPlainFile`로도 못 잡는다.
 *
 * 존재하는 가장 깊은 조상까지 올라가 `realpath`로 실체를 확인하고,
 * 아직 없는 구간은 만들어질 자리 그대로 이어붙여 비교한다.
 * **디렉터리를 만들기 전에** 불러야 한다 — `mkdir -p`가 링크를 따라가 버리면 늦는다.
 */
async function assertRealPathInside(root, target, label) {
  const resolvedRoot = path.resolve(root);
  const rootLabel = label ?? path.basename(resolvedRoot) + "/";

  // ⚠️ root 자체를 `realpath`로 따라가면 안 된다. 그러면 root가 심볼릭
  // 링크일 때 "그 링크가 가리키는 곳"이 기준선이 되어 버려서, 거기 안쪽인지
  // 검사해봐야 **항상 통과한다.** (`lint`·`sessions/` 검사에서 실측으로 확인한
  // 구멍이다 — target이 root의 바로 아래에 있으면 walk-up이 첫 걸음에서
  // root 자신을 만나고, 그 실체가 이미 링크를 따라간 값이라 자기 자신과
  // 비교해 항상 같다고 나온다.)
  //
  // 그래서 root의 **부모**만 realpath로 확인하고, root의 이름은 글자 그대로
  // 이어붙인다. root가 심볼릭 링크로 바뀌어 있으면 "있어야 할 자리"와
  // "실제로 가리키는 곳"이 갈라지고, 그 차이로 잡아낸다.
  const rootParent = path.dirname(resolvedRoot);
  let realRootParent;
  try {
    realRootParent = await fs.realpath(rootParent);
  } catch (err) {
    if (err?.code !== "ENOENT") throw err;
    realRootParent = rootParent;
  }
  const realRoot = path.join(realRootParent, path.basename(resolvedRoot));

  let actualRootReal = null;
  try {
    actualRootReal = await fs.realpath(resolvedRoot);
  } catch (err) {
    if (err?.code !== "ENOENT") throw err;
    // 아직 없으면(예: `.trash`를 처음 만드는 중) 나중에 `mkdir`이 만든다 — 통과.
  }
  if (actualRootReal !== null && actualRootReal !== realRoot) {
    throw badRequest(`경로가 심볼릭 링크로 ${rootLabel} 밖을 가리킵니다.`);
  }

  const tail = [];
  let probe = path.dirname(target);
  for (;;) {
    let real;
    try {
      real = await fs.realpath(probe);
    } catch (err) {
      if (err?.code !== "ENOENT") throw err;
      const parent = path.dirname(probe);
      if (parent === probe) throw badRequest("경로를 확인할 수 없습니다.");
      tail.push(path.basename(probe));
      probe = parent;
      continue;
    }
    const rebuilt = path.resolve(real, ...[...tail].reverse());
    if (rebuilt !== realRoot && !rebuilt.startsWith(realRoot + path.sep)) {
      throw badRequest(`경로가 심볼릭 링크로 ${rootLabel} 밖을 가리킵니다.`);
    }
    return;
  }
}

/** `memory/` 전용 별칭. 기존 호출부를 그대로 둔다. */
async function assertRealPathInsideMemory(workspaceDir, target) {
  await assertRealPathInside(path.join(workspaceDir, "memory"), target, "memory/");
}

/**
 * 단기 기억 파일을 만들고 내용을 쓴다. **이름 선점과 생성이 한 번에 일어난다.**
 *
 * 예전에는 `fs.access`로 없는 이름을 고른 뒤 따로 `writeFile`을 했다. 그 사이가
 * 원자적이지 않아서, 같은 분에 두 번 불리면 둘 다 "없다"를 보고 같은 파일에 써서
 * **먼저 쓴 기억이 사라졌다.** `wx`(O_CREAT|O_EXCL)는 이름 선점을 커널이 보장하고,
 * 덤으로 **마지막 경로 요소가 심볼릭 링크면 아예 열리지 않는다.**
 * 이미 있으면 `EEXIST`가 나므로 `-2`, `-3`으로 넘어간다.
 */
async function createShortTermMemoryFile(workspaceDir, now, rawSlug, content) {
  const day = formatLocalDate(now);
  let base;
  if (rawSlug != null && String(rawSlug).trim() !== "") {
    const slug = String(rawSlug).trim();
    if (!SLUG_RE.test(slug)) throw badRequest("슬러그에 쓸 수 없는 글자가 있습니다.");
    base = `${day}-${slug}`;
  } else {
    base = `${day}-${pad2(now.getHours())}${pad2(now.getMinutes())}`;
  }

  for (let n = 1; n <= 50; n += 1) {
    const name = n === 1 ? `${base}.md` : `${base}-${n}.md`;
    if (!SHORT_TERM_BASENAME_RE.test(name)) throw badRequest(`단기 기억 이름 규칙에 안 맞습니다: ${name}`);
    const relative = path.posix.join("memory", name);
    const target = resolveMemoryPath(workspaceDir, relative);
    await assertRealPathInsideMemory(workspaceDir, target);
    await fs.mkdir(path.dirname(target), { recursive: true });

    let handle;
    try {
      handle = await fs.open(target, "wx");
    } catch (err) {
      if (err?.code === "EEXIST") continue;
      throw err;
    }
    try {
      await handle.writeFile(content, "utf-8");
      const stat = await handle.stat();
      return { relative, size: stat.size, updatedAtMs: Math.floor(stat.mtimeMs) };
    } finally {
      await handle.close();
    }
  }
  throw badRequest("같은 이름이 너무 많습니다.");
}

/** 이 플러그인이 손댈 수 있는 곳. 워크스페이스의 `memory/` 아래 `.md`뿐이다. */
function resolveMemoryPath(workspaceDir, rawPath) {
  const value = typeof rawPath === "string" ? rawPath.trim() : "";
  if (!value) throw badRequest("path가 필요합니다.");
  if (path.isAbsolute(value)) throw badRequest("워크스페이스 기준 상대 경로만 받습니다.");
  if (!value.endsWith(".md")) throw badRequest("`.md` 파일만 다룹니다.");

  const memoryRoot = path.resolve(workspaceDir, "memory");
  const target = path.resolve(workspaceDir, value);

  // `..`로 빠져나가는 것을 막는다. 문자열 검사가 아니라 해석된 경로로 판단한다.
  if (target !== memoryRoot && !target.startsWith(memoryRoot + path.sep)) {
    throw badRequest("memory/ 아래 파일만 다룹니다.");
  }
  // dreaming이 쓰는 내부 디렉터리는 손대지 않는다.
  if (path.relative(memoryRoot, target).split(path.sep).includes(".dreams")) {
    throw badRequest(".dreams 아래는 다루지 않습니다.");
  }
  return target;
}

function badRequest(message) {
  const err = new Error(message);
  err.code = "INVALID_REQUEST";
  return err;
}

/** 이 자리가 심볼릭 링크면 거부한다. 디렉터리에 쓴다 — `assertPlainFile`은 파일용이다. */
async function assertNotSymlink(dir) {
  let stat;
  try {
    stat = await fs.lstat(dir);
  } catch (err) {
    if (err?.code === "ENOENT") return;
    throw err;
  }
  if (stat.isSymbolicLink()) throw badRequest(`${path.basename(dir)}가 심볼릭 링크입니다.`);
}

/** 심볼릭 링크·하드링크로 워크스페이스 밖을 건드리는 것을 막는다. */
async function assertPlainFile(target) {
  let stat;
  try {
    stat = await fs.lstat(target);
  } catch (err) {
    if (err?.code === "ENOENT") return false;
    throw err;
  }
  if (stat.isSymbolicLink()) throw badRequest("심볼릭 링크는 다루지 않습니다.");
  if (!stat.isFile()) throw badRequest("일반 파일이 아닙니다.");
  if (stat.nlink > 1) throw badRequest("하드링크가 걸린 파일은 다루지 않습니다.");
  return true;
}

function workspaceFor(context, params) {
  const cfg = context.getRuntimeConfig();
  const agentId =
    (typeof params.agentId === "string" && params.agentId.trim()) || resolveDefaultAgentId(cfg);
  return { agentId, workspaceDir: resolveAgentWorkspaceDir(cfg, agentId) };
}

function fail(respond, error) {
  const code = error?.code === "INVALID_REQUEST" ? "INVALID_REQUEST" : "INTERNAL";
  respond(false, undefined, {
    code,
    message: error instanceof Error ? error.message : String(error),
  });
}

export default definePluginEntry({
  id: "nova-memory",
  name: "NOVA Memory",
  description: "기억 파일 쓰기·삭제 게이트웨이 메서드",
  register(api) {
    /** 한 파일을 통째로 쓴다. 없으면 만든다. */
    api.registerGatewayMethod(
      "nova.memory.save",
      async ({ params, respond, context }) => {
        try {
          const { agentId, workspaceDir } = workspaceFor(context, params);
          const target = resolveMemoryPath(workspaceDir, params.path);
          const content = typeof params.content === "string" ? params.content : "";
          await assertRealPathInsideMemory(workspaceDir, target);
          await assertPlainFile(target);
          await fs.mkdir(path.dirname(target), { recursive: true });

          // `assertPlainFile`은 검사 시점의 사실일 뿐이다. 검사와 쓰기 사이에
          // 누가 그 자리를 심볼릭 링크로 바꿔치기하면 링크 대상에 쓰게 된다(TOCTOU).
          // `O_NOFOLLOW`는 그 판정을 **커널이 열 때** 하므로 그 틈이 없어진다.
          // (부모 디렉터리 교체까지는 못 막는다 — Node가 openat을 안 내준다.)
          const handle = await fs.open(
            target,
            constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW,
            0o600,
          );
          let stat;
          try {
            await handle.writeFile(content, "utf-8");
            stat = await handle.stat();
          } finally {
            await handle.close();
          }
          respond(true, {
            agentId,
            path: path.relative(workspaceDir, target),
            size: stat.size,
            updatedAtMs: Math.floor(stat.mtimeMs),
          });
        } catch (error) {
          fail(respond, error);
        }
      },
      { scope: WRITE_SCOPE },
    );

    /**
     * 한 파일을 지운다.
     *
     * 되돌릴 수 없으니 기본은 휴지통처럼 `memory/.trash/`로 옮기는 것이고,
     * `hard: true`를 줘야 실제로 지운다. 잘못 지운 기억을 되살릴 길은 남겨둔다.
     */
    api.registerGatewayMethod(
      "nova.memory.delete",
      async ({ params, respond, context }) => {
        try {
          const { agentId, workspaceDir } = workspaceFor(context, params);
          const target = resolveMemoryPath(workspaceDir, params.path);
          await assertRealPathInsideMemory(workspaceDir, target);
          if (!(await assertPlainFile(target))) {
            respond(false, undefined, { code: "NOT_FOUND", message: "그런 파일이 없습니다." });
            return;
          }
          const relative = path.relative(workspaceDir, target);

          if (params.hard === true) {
            await fs.rm(target);
            respond(true, { agentId, path: relative, removed: "deleted" });
            return;
          }

          const trashDir = path.join(workspaceDir, "memory", ".trash");
          const stamp = new Date().toISOString().replace(/[:.]/g, "-");
          const parked = path.join(trashDir, `${stamp}__${path.basename(target)}`);

          // ⚠️ 지우는 쪽도 목적지를 봐야 한다. 원본만 검사하고 `.trash`를 안 보면,
          // `.trash -> /바깥`이 미리 놓여 있을 때 `rename`이 링크를 따라가
          // **파일을 워크스페이스 밖으로 옮겨준다.** `mkdir`은 이미 있는 심볼릭
          // 링크를 지우지 않으므로 그것만으로는 아무것도 막지 못한다.
          await assertRealPathInsideMemory(workspaceDir, parked);
          await assertNotSymlink(trashDir);
          await fs.mkdir(trashDir, { recursive: true });
          await assertNotSymlink(trashDir);
          await fs.rename(target, parked);
          respond(true, {
            agentId,
            path: relative,
            removed: "trashed",
            trashPath: path.relative(workspaceDir, parked),
          });
        } catch (error) {
          fail(respond, error);
        }
      },
      { scope: WRITE_SCOPE },
    );

    /** 휴지통에 뭐가 있는지. 되살릴 수 있는지 확인하려면 보여야 한다. */
    api.registerGatewayMethod(
      "nova.memory.trash.list",
      async ({ params, respond, context }) => {
        try {
          const { agentId, workspaceDir } = workspaceFor(context, params);
          const trashDir = path.join(workspaceDir, "memory", ".trash");
          // ⚠️ 읽기도 링크를 따라간다. `.trash -> /바깥`이 놓여 있으면
          // `fs.readdir`이 워크스페이스 밖 디렉터리의 목록을 그대로 돌려준다.
          // 지우는 쪽만 막고 여기를 안 막으면 **목록이 새는 문이 남는다.**
          await assertNotSymlink(trashDir);
          await assertRealPathInsideMemory(workspaceDir, path.join(trashDir, "x"));
          let names = [];
          try {
            names = (await fs.readdir(trashDir, { withFileTypes: true }))
              .filter((entry) => entry.isFile())
              .map((entry) => entry.name);
          } catch (err) {
            if (err?.code !== "ENOENT") throw err;
          }
          const entries = await Promise.all(
            names.map(async (name) => {
              const stat = await fs.stat(path.join(trashDir, name));
              return {
                name,
                path: path.posix.join("memory", ".trash", name),
                size: stat.size,
                updatedAtMs: Math.floor(stat.mtimeMs),
              };
            }),
          );
          entries.sort((a, b) => b.updatedAtMs - a.updatedAtMs);
          respond(true, { agentId, entries });
        } catch (error) {
          fail(respond, error);
        }
      },
      { scope: READ_SCOPE },
    );

    /**
     * 세션 전사에서 단기 기억 한 편을 만들어 `memory/YYYY-MM-DD-HHMM.md`로 쓴다.
     *
     * **왜 번들 훅에 맡기지 않는가.** 두 가지가 다 막혀 있다:
     *   1. `session-memory` 훅은 `/new`·`/reset`에만 걸리는데, 그 명령을 게이트웨이로
     *      쏘려면 `operator.admin`이 필요하다. 앱은 read+write만 선언한다 —
     *      admin 없이 보내면 에러도 없이 조용히 무시된다.
     *   2. 그 훅이 쓰는 머리말을 openclaw 자신의 승격 경로가 오염으로 판정해 버려서,
     *      만들어져도 굳히기 후보에 영원히 못 들어간다 (`short-term-format.js` 참고).
     *
     * 이 메서드는 `operator.write`만으로 되고 형식은 우리가 지킨다.
     * 방아쇠가 필요 없는 것은 dreaming이 `memory/`를 디스크에서 직접 훑기 때문이다
     * (`collectDailyIngestionBatches`가 파일마다 `{mtimeMs, size}` 지문을 비교한다).
     */
    api.registerGatewayMethod(
      "nova.memory.session.capture",
      async ({ params, respond, context }) => {
        try {
          const cfg = context.getRuntimeConfig();

          const sessionKey = typeof params.sessionKey === "string" ? params.sessionKey.trim() : "";
          if (!sessionKey) throw badRequest("sessionKey가 필요합니다.");

          const agentId =
            (typeof params.agentId === "string" && params.agentId.trim()) ||
            resolveAgentIdFromSessionKey(sessionKey) ||
            resolveDefaultAgentId(cfg);
          const workspaceDir = resolveAgentWorkspaceDir(cfg, agentId);
          const sessionsDir = resolveSessionsDir(cfg, agentId);
          // ⚠️ sessionId는 정규식으로 막았지만 그건 **파일 이름** 얘기다.
          // `sessions/` 디렉터리 자체가 심볼릭 링크면 정상적인 이름이라도
          // 그 링크가 가리키는 곳에서 읽힌다. `memory/`에 건 것과 같은 종류의
          // 검사를 여기도 걸어야 한다 — 뿌리가 다르니 함수도 따로 둔다.
          await assertRealPathInside(sessionsDir, path.join(sessionsDir, "x"));

          // 세션 키 → 세션 id. 인덱스는 `agent:<id>:<키>`로 정규화된 키를 쓴다 (하드윈 5번).
          const indexPath = path.join(sessionsDir, "sessions.json");
          let index;
          try {
            index = JSON.parse(await fs.readFile(indexPath, "utf-8"));
          } catch (err) {
            if (err?.code === "ENOENT") throw badRequest(`세션 인덱스가 없습니다: ${indexPath}`);
            throw err;
          }
          const entry = index?.[sessionKey];
          const sessionId = entry?.sessionId;
          if (!sessionId) throw badRequest(`그런 세션이 없습니다: ${sessionKey}`);
          // 인덱스는 openclaw가 쓰는 파일이지만 그걸 믿고 경로에 이어붙이지 않는다.
          // `../..` 같은 값이 들어오면 sessions/ 밖의 파일을 읽게 된다.
          if (typeof sessionId !== "string" || !SESSION_ID_RE.test(sessionId)) {
            throw badRequest("세션 id 형식이 올바르지 않습니다.");
          }

          const transcriptPath = path.join(sessionsDir, `${sessionId}.jsonl`);
          if (path.dirname(path.resolve(transcriptPath)) !== path.resolve(sessionsDir)) {
            throw badRequest("전사 경로가 sessions/ 밖을 가리킵니다.");
          }
          let raw;
          try {
            raw = await fs.readFile(transcriptPath, "utf-8");
          } catch (err) {
            if (err?.code === "ENOENT") throw badRequest("전사 파일이 없습니다.");
            throw err;
          }

          const maxMessages = Number.isFinite(params.maxMessages)
            ? Math.max(1, Math.min(200, Math.floor(params.maxMessages)))
            : 15;

          const turns = [];
          for (const line of raw.split("\n")) {
            if (!line.trim()) continue;
            let row;
            try {
              row = JSON.parse(line);
            } catch {
              continue; // 깨진 줄 하나 때문에 기억을 통째로 버리지 않는다
            }
            if (row?.type !== "message") continue;
            const msg = row.message;
            const role = msg?.role;
            if (role !== "user" && role !== "assistant") continue;
            const text = extractMessageText(msg?.content);
            if (!text) continue;
            turns.push({ role, text });
          }
          if (turns.length === 0) throw badRequest("전사에 담을 대화가 없습니다.");
          const kept = turns.slice(-maxMessages);

          const now = new Date();
          const { text, sanitizeNotes } = renderShortTermMemory({
            title: `${formatLocalDate(now)} ${formatLocalTime(now)} 대화`,
            when: `${formatLocalDate(now)} ${formatLocalTime(now)}`,
            sessionKey,
            source: typeof params.source === "string" ? params.source.trim() : undefined,
            turns: kept,
          });

          // 마지막 관문. 여기서 걸리면 쓰지 않는다 — 써봐야 승격 경로가 버린다.
          assertSafeShortTermText(text);

          if (params.dryRun === true) {
            respond(true, {
              agentId,
              dryRun: true,
              messageCount: kept.length,
              sanitizeNotes,
              content: text,
            });
            return;
          }

          const written = await createShortTermMemoryFile(workspaceDir, now, params.slug, text);

          respond(true, {
            agentId,
            path: written.relative,
            messageCount: kept.length,
            size: written.size,
            sanitizeNotes,
            updatedAtMs: written.updatedAtMs,
          });
        } catch (error) {
          fail(respond, error);
        }
      },
      { scope: WRITE_SCOPE },
    );

    /**
     * 이미 있는 기억 파일이 승격 경로에서 버려지는지 본다. 고치지는 않는다.
     * 훅이 만든 파일이 왜 안 굳는지 눈으로 확인하는 용도다.
     */
    api.registerGatewayMethod(
      "nova.memory.lint",
      async ({ params, respond, context }) => {
        try {
          const { agentId, workspaceDir } = workspaceFor(context, params);
          const memoryDir = path.join(workspaceDir, "memory");
          // ⚠️ 다른 메서드는 전부 실체를 확인하는데 여기만 빠져 있었다.
          // `memory/`가 심볼릭 링크면 `readdir`이 워크스페이스 밖 디렉터리를
          // 그대로 목록으로 준다 — 읽기 전용이라 방심하기 쉬운 자리였다.
          await assertNotSymlink(memoryDir);
          await assertRealPathInsideMemory(workspaceDir, path.join(memoryDir, "x"));
          let names = [];
          try {
            names = (await fs.readdir(memoryDir, { withFileTypes: true }))
              .filter((e) => e.isFile() && SHORT_TERM_BASENAME_RE.test(e.name))
              .map((e) => e.name);
          } catch (err) {
            if (err?.code !== "ENOENT") throw err;
          }
          names.sort();

          const entries = [];
          for (const name of names) {
            const filePath = path.join(memoryDir, name);
            // 목록에 있던 파일이 그 사이 심볼릭 링크로 바뀌었을 수도 있다.
            // 개별 파일도 다른 메서드와 같은 기준(`assertPlainFile`)으로 본다.
            if (!(await assertPlainFile(filePath))) continue;
            const body = await fs.readFile(filePath, "utf-8");
            const hit = findContamination(body);
            entries.push({
              name,
              path: path.posix.join("memory", name),
              safe: hit === null,
              ...(hit ? { rule: hit.name, why: hit.why, matched: hit.matched } : {}),
            });
          }
          respond(true, {
            agentId,
            checked: entries.length,
            unsafe: entries.filter((e) => !e.safe).length,
            entries,
          });
        } catch (error) {
          fail(respond, error);
        }
      },
      { scope: READ_SCOPE },
    );

  },
});
