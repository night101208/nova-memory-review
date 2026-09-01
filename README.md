# nova-memory — 코드 검사용 사본

openclaw 기반 개인 AI의 플러그인 일부입니다. **검사를 받으려고 떼어낸 사본**이라
본 저장소가 아니고 히스토리도 없습니다.

## 무슨 문제를 고친 코드인가

openclaw에는 대화가 끝날 때 단기 기억 파일을 만드는 번들 훅(`session-memory`)이 있고,
매일 새벽 그 기억들을 장기 기억으로 굳히는 승격 경로가 따로 있습니다.
**앞의 것이 쓴 형식을 뒤의 것이 "전사 찌꺼기"로 판정해 전부 버리고 있었습니다.**

```
쓰는 쪽   bundled/session-memory/handler.js:278
          `- **Session Key**: ${displaySessionKey}`
          `- **Session ID**: ${sessionId}`
          handler.js:62  `${role}: ${sanitized}`      → "user: …" / "assistant: …"

버리는 쪽 short-term-promotion.js:577
          RAW_SESSION_METADATA_RE  = /\bSession Key\b.{0,260}\bSession ID\b/i
          RAW_TRANSCRIPT_TURN_RE   = /^(?:[-*+]\s*)?(?:user|assistant):\s/i
```

걸리면 `recordShortTermRecalls`가 `continue`로 항목을 버리는데,
**`store.updatedAt` 갱신과 `memory.recall.recorded` 이벤트는 그대로 나갑니다.**
그래서 로그상으로는 정상으로 보이고 회수 저장소만 영원히 비어 있었습니다.

실측: 같은 질의 3개로 검색했을 때 오염된 파일은 `Recall store: 0`,
형식을 고친 파일은 `Recall store: 4`(recallCount 3 · uniqueQueries 3)였습니다.

## 고친 방향

openclaw 본체는 건드리지 않습니다(업그레이드마다 날아가므로).
대신 단기 기억을 **버려지지 않는 형식으로 직접 씁니다.**

| 파일 | 역할 |
|---|---|
| `plugins/nova-memory/short-term-format.js` | 형식 계약. 오염 규칙 사본 + 렌더러 + 정화기 + 마지막 관문 |
| `plugins/nova-memory/index.js` | 게이트웨이 메서드. `session.capture`(쓰기) · `lint`(검사) 등 |
| `tools/nova-rpc/rpc.mjs` | 그 메서드를 호출하는 WebSocket 클라이언트 |

## 봐줬으면 하는 것

1. **오염 회피 로직의 구멍** — 특히 앵커 규칙(`^user:`) 처리.
   승격 경로는 조각(chunk) 단위로 검사하는데 조각 경계를 우리가 정할 수 없습니다.
   `findContamination`이 모든 줄을 조각 첫머리로 가정하고 보는데 이걸로 충분한지.
2. **경로 처리** — `resolveMemoryPath` / `resolveShortTermTarget`에
   `memory/` 밖으로 빠져나갈 여지가 있는지 (심볼릭 링크·하드링크·`..`·슬러그).
3. **전사 파싱** — `nova.memory.session.capture`가 깨진 JSONL이나
   예상 밖 구조에 안전한지.
4. **경합** — 같은 분에 두 번 호출될 때 파일 덮어쓰기.
   `resolveShortTermTarget`의 `fs.access` → `writeFile` 사이가 원자적이지 않습니다.
5. `sanitizeForShortTerm`이 본문을 고치는 것이 타당한 선택인지.
   (버려지느니 라벨의 공백을 붙임표로 바꾸는 쪽을 골랐습니다.)

## 참고

- 주석과 문서는 한국어입니다.
- 호스트명·IP는 `GATEWAY-HOST`로, 홈 경로는 `/Users/USER`로 치환했습니다.
- 정규식들은 문서가 아니라 **설치된 패키지(openclaw 2026.7.1-2)의
  `dist/short-term-promotion-*.js` 576-581행에서 그대로 옮긴 것**입니다.

---

## 1차 검사 반영 (수정됨)

외부 검사에서 나온 지적 중 셋을 고쳤습니다. 재검사할 때는 아래를 감안해주세요.

| 지적 | 처리 |
|---|---|
| 파일 생성 경합 (`fs.access` → `writeFile`) | **고침.** `fs.open(target,"wx")`로 원자화. 동시 3회 호출이 파일 3개를 만드는 것으로 실측 확인 |
| 부모 디렉터리 심볼릭 링크로 `memory/` 밖 접근 | **고침.** `assertRealPathInsideMemory` 추가 — 존재하는 가장 깊은 조상까지 `realpath`로 확인. `mkdir` 전에 검사. `save`·`delete`·`capture` 전부 적용. 실측으로 차단 확인 |
| `sessionId` 경로 검증 없음 | **고침.** `SESSION_ID_RE` + 이어붙인 경로가 `sessions/` 바로 아래인지 확인 |
| 청크 경계에서 `^user:`가 시작될 수 있다 | **해당 없음.** `internal-ss-Qpla0.js:270`의 `chunkMarkdown`이 `content.split("\n")` 후 줄 단위로 모으고 `join("\n")`으로 합칩니다. 청크는 항상 줄 경계에서 시작하므로 줄 단위 검사가 맞는 입자입니다 |
| `sanitizeForShortTerm` 설계 | 현행 유지 (검사 의견과 같음) |
