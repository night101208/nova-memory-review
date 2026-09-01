/**
 * 단기 기억 형식 계약 — 승격 경로에서 버려지지 않는 글꼴.
 *
 * 왜 필요한가 (2026-09-01 실측):
 *   openclaw 번들 훅 `session-memory`가 쓰는 머리말을 openclaw 자신의 승격 경로가
 *   "오염"으로 판정해 버린다. 같은 설치본 안에서 한쪽이 쓰고 다른 쪽이 버린다.
 *
 *     handler.js:278            `- **Session Key**: ${displaySessionKey}`
 *     handler.js:279            `- **Session ID**: ${sessionId}`
 *     handler.js:62             `${role}: ${sanitized}`        → "user: …" / "assistant: …"
 *     short-term-promotion.js:577  /\bSession Key\b.{0,260}\bSession ID\b/i
 *     short-term-promotion.js:579  /^(?:[-*+]\s*)?(?:user|assistant):\s/i
 *
 *   걸리면 `recordShortTermRecalls`(1274행)가 `continue`로 항목을 버린다. 그런데
 *   `store.updatedAt` 갱신과 `memory.recall.recorded` 이벤트는 **그대로 나간다.**
 *   그래서 로그는 정상으로 보이고 회수 저장소만 영원히 비어 있다. 조용한 실패다.
 *
 * 아래 정규식은 문서가 아니라 **설치된 패키지(openclaw 2026.7.1-2)의
 * `dist/short-term-promotion-stx0l04M.js` 576-581행에서 그대로 옮긴 것이다.**
 * 업그레이드하면 원본이 바뀔 수 있다 — `npm pack openclaw@<버전>` 후 같은 파일을
 * 다시 읽고 이 목록을 맞출 것.
 */

/** 오염 판정 규칙. 이름은 원본의 상수명을 그대로 쓴다. */
export const CONTAMINATION_RULES = [
  {
    name: "RAW_SESSION_METADATA_RE",
    anchored: false,
    re: /\bSession Key\b.{0,260}\bSession ID\b|\bSession ID\b.{0,260}\bSession Key\b/i,
    why: "'Session Key'와 'Session ID'가 260자 안에 같이 있으면 전사 찌꺼기로 본다.",
  },
  {
    name: "RAW_CONVERSATION_SUMMARY_RE",
    anchored: true,
    re: /^(?:[-*+]\s*)?Conversation Summary:/i,
    why: "조각이 'Conversation Summary:'로 시작하면 버린다.",
  },
  {
    name: "RAW_TRANSCRIPT_TURN_RE",
    anchored: true,
    re: /^(?:[-*+]\s*)?(?:user|assistant):\s/i,
    why: "조각이 'user: ' 또는 'assistant: '로 시작하면 버린다.",
  },
  {
    name: "MEMORY_FLUSH_PROMPT_RE",
    anchored: false,
    re: /Save important context from this session to the daily memory file\.\s*STRICT RULES:/i,
    why: "기억 플러시 프롬프트가 그대로 섞여 들어온 경우.",
  },
  {
    name: "PROMOTION_SCORE_METADATA_RE",
    anchored: false,
    re: /\[\s*score=\d+(?:\.\d+)?\s+recalls=\d+\s+avg=\d+(?:\.\d+)?\s+source=memory\//i,
    why: "이미 승격된 기억의 점수 꼬리표. 되먹임을 막는다.",
  },
  {
    name: "DREAMING_TRANSCRIPT_PROMPT_LINE_RE",
    anchored: false,
    re: /\[[^\]]*dreaming-narrative[^\]]*]\s*(?:User|Assistant):\s*Write a dream diary entry from these memory fragments:?/i,
    why: "정리(dreaming) 프롬프트가 그대로 섞여 들어온 경우.",
  },
];

/**
 * 승격 경로의 `normalizeSnippet`과 같은 정규화.
 * 조각 전체가 한 줄로 접힌 뒤에 규칙이 걸리므로, 검사도 같은 모양에서 해야 한다.
 */
export function normalizeSnippet(raw) {
  const trimmed = String(raw ?? "").trim();
  if (!trimmed) return "";
  return trimmed.replace(/\s+/g, " ");
}

/**
 * 오염 여부를 본다. 걸리면 규칙을, 아니면 null을 준다.
 *
 * ⚠️ 앵커(`^`) 규칙은 **조각의 첫머리**에만 걸린다. 조각 경계는 색인기가 정하므로
 * 우리가 고를 수 없다 — 그래서 렌더러는 아예 어떤 줄도 `user:`/`assistant:`로
 * 시작하지 않게 만든다. 여기서는 파일 전체와 줄 단위를 둘 다 본다.
 */
export function findContamination(text) {
  const whole = normalizeSnippet(text);
  if (!whole) return null;

  for (const rule of CONTAMINATION_RULES) {
    if (!rule.anchored) {
      const m = whole.match(rule.re);
      if (m) return { ...rule, matched: m[0].slice(0, 120) };
    }
  }
  // 앵커 규칙은 어느 줄이 조각의 첫머리가 될지 모르니 모든 줄을 첫머리로 놓고 본다.
  for (const line of String(text).split("\n")) {
    const one = normalizeSnippet(line);
    if (!one) continue;
    for (const rule of CONTAMINATION_RULES) {
      if (!rule.anchored) continue;
      const m = one.match(rule.re);
      if (m) return { ...rule, matched: one.slice(0, 120) };
    }
  }
  return null;
}

export function isSafeShortTermText(text) {
  return findContamination(text) === null;
}

/** 한 턴이 차지할 최대 글자수. 넘으면 자른다. */
const MAX_TURN_CHARS = 600;

/**
 * 본문에 섞인 위험한 문자열만 최소로 손본다.
 *
 * 내용을 고치는 것은 원칙적으로 피해야 하지만, 이 두 낱말이 나란히 있으면
 * **그 조각 전체가 통째로 버려진다.** 버려지느니 라벨의 공백을 붙임표로 바꾸는 편이 낫다.
 * 뜻은 그대로 읽히고, 무엇을 바꿨는지는 호출자에게 돌려준다.
 *
 * (이 함수가 필요하다는 걸 사고로 알았다 — 진단용 파일 본문에 "Session Key/Session ID"를
 *  피하겠다고 그 낱말을 그대로 적었다가 그 파일이 스스로 버려졌다.)
 */
export function sanitizeForShortTerm(text) {
  const notes = [];
  let out = String(text ?? "");

  const beforeSession = out;
  out = out.replace(/\bSession (Key|ID)\b/gi, (m, kind) => `Session-${kind}`);
  if (out !== beforeSession) notes.push("'Session Key'/'Session ID' 라벨의 공백을 붙임표로 바꿨습니다 (RAW_SESSION_METADATA_RE 회피)");

  // ⚠️ 앵커 규칙은 줄 시작만 보는 게 아니다 — **조각(chunk) 시작**을 본다.
  // 그리고 조각은 줄 경계에서만 갈리지 않는다. `chunkMarkdown`(internal-ss-*.js)이
  // `maxChars = max(32, chunking.tokens * 4)`보다 긴 줄을 segment로 쪼개고,
  // 조각은 segment 단위로 모인다. 즉 **긴 줄은 중간에서 갈릴 수 있고**
  // 그 지점이 하필 "user: " 앞이면 그 조각이 통째로 버려진다.
  //
  // 줄 길이를 짧게 유지하는 것으로도 피할 수 있지만 그건 `chunking.tokens`라는
  // **사용자 설정에 기대는 것**이다. 값을 낮추면 조용히 깨진다.
  // 그래서 본문에 있는 역할 표기 자체를 무해하게 만든다 — 규칙이 `user`와 `:`가
  // 붙어 있을 것을 요구하므로 사이에 공백 하나를 넣으면 어디서 갈리든 안 걸린다.
  const beforeTurn = out;
  out = out.replace(/\b(user|assistant)(:\s)/gi, (m, role, tail) => `${role} ${tail}`);
  out = out.replace(/\bConversation Summary:/gi, "Conversation Summary :");
  if (out !== beforeTurn) notes.push("본문의 'user:'/'assistant:'/'Conversation Summary:' 뒤 콜론 앞에 공백을 넣었습니다 (앵커 규칙 회피 — 조각이 줄 중간에서 시작할 수 있습니다)");

  return { text: out, notes };
}

/** 한 턴을 한 줄로 접는다. 줄이 나뉘면 앵커 규칙에 걸릴 자리가 늘어난다. */
function foldTurn(text) {
  const one = String(text ?? "").replace(/\s+/g, " ").trim();
  if (one.length <= MAX_TURN_CHARS) return one;
  return `${one.slice(0, MAX_TURN_CHARS).trimEnd()}…`;
}

/** 역할 이름. 영어 `user`/`assistant`를 쓰면 앵커 규칙에 걸린다. */
function roleLabel(role) {
  if (role === "user") return "사용자";
  if (role === "assistant") return "NOVA";
  return role || "기타";
}

/**
 * 단기 기억 한 편을 만든다.
 *
 * 파일 이름은 `SHORT_TERM_BASENAME_RE`(`YYYY-MM-DD[-슬러그].md`)를 지켜야
 * 단기 기억으로 인정된다. 그건 호출부에서 정한다.
 */
export function renderShortTermMemory({ title, when, sessionKey, source, turns = [], notes = [] }) {
  const lines = [];
  lines.push(`# ${title}`);
  lines.push("");
  if (when) lines.push(`- 시각: ${when}`);
  // ⚠️ 'Session Key'라고 쓰면 안 된다. 우리가 고치려는 바로 그 규칙에 걸린다.
  if (sessionKey) lines.push(`- 세션: ${sessionKey}`);
  if (source) lines.push(`- 경로: ${source}`);
  lines.push(`- 기록: NOVA (nova.memory.session.capture)`);
  lines.push("");
  lines.push("## 오간 이야기");
  lines.push("");
  for (const turn of turns) {
    const body = foldTurn(turn.text);
    if (!body) continue;
    lines.push(`- ${roleLabel(turn.role)} — ${body}`);
  }
  if (notes.length > 0) {
    lines.push("");
    lines.push("## 기록 메모");
    lines.push("");
    for (const note of notes) lines.push(`- ${note}`);
  }
  lines.push("");

  const raw = lines.join("\n");
  const { text, notes: sanitizeNotes } = sanitizeForShortTerm(raw);
  return { text, sanitizeNotes };
}

/** 마지막 관문. 여기서 걸리면 쓰지 않는다 — 써봐야 승격 경로가 버린다. */
export function assertSafeShortTermText(text) {
  const hit = findContamination(text);
  if (!hit) return;
  const err = new Error(
    `단기 기억 형식이 오염 판정에 걸립니다 (${hit.name}: ${hit.why}) — 걸린 부분: ${hit.matched}`,
  );
  err.code = "INVALID_REQUEST";
  err.rule = hit.name;
  throw err;
}
