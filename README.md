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
| 청크 경계에서 `^user:`가 시작될 수 있다 | **⚠️ 지적이 맞았습니다. 앞선 반박은 틀렸습니다.** `chunkMarkdown` 앞부분만 읽고 "줄 단위"라고 답했는데, 함수 뒷부분이 `maxChars`보다 긴 줄을 segment로 쪼갭니다 — 청크가 줄 중간에서 시작할 수 있습니다. 원본은 `docs/openclaw-evidence.md`에 인용했습니다. **고쳤습니다**: 줄 길이에 기대는 대신 본문의 `user:`/`assistant:`/`Conversation Summary:`를 콜론 앞 공백으로 무해화합니다(설정과 무관). 검증은 **본문의 모든 문자 위치를 조각 시작으로 놓고** 앵커 규칙을 돌렸고, 정화 전 `at:34` 검출 → 정화 후 `null` |
| `sanitizeForShortTerm` 설계 | 현행 유지 (검사 의견과 같음) |

## 2차 검사 반영

- `docs/openclaw-evidence.md`에 **openclaw 설치본 원본을 인용**했습니다.
  1차 검사에서 "chunkMarkdown 구현을 이 사본만으로는 독립 확인할 수 없다"는
  단서를 다셨는데, 그 확인이 가능하도록 넣은 것입니다.
  openclaw는 MIT이고 `npm pack openclaw@2026.7.1-2`로 누구나 같은 내용을 얻을 수 있습니다.
- 그 원본을 끝까지 읽고 **1차 검사의 ①번 지적이 맞았음을 확인했습니다.** 위 표를 고쳤습니다.

## 3차 검사 반영

| 지적 | 처리 |
|---|---|
| `delete`의 `.trash` 목적지에 realpath 검사가 없음 | **고침.** `parked`에도 `assertRealPathInsideMemory`를 걸고, `assertNotSymlink`로 `.trash` 자체를 `mkdir` 전후로 확인합니다. 실측: `.trash -> /tmp/...`를 놓고 삭제 요청 시 거부되고 밖에 아무것도 안 생깁니다 |
| `save`의 검사–쓰기 TOCTOU | **고침.** `fs.writeFile` 대신 `O_WRONLY\|O_CREAT\|O_TRUNC\|O_NOFOLLOW`로 연 핸들에 씁니다. 마지막 경로 요소의 심볼릭 링크 판정을 커널이 여는 순간 합니다. **부모 디렉터리 교체까지는 못 막습니다** — Node가 `openat`을 안 내줍니다 |
| `rpc.mjs`의 `--url` 제한 없음 | **현행 유지.** 로컬 관리용 CLI라 신뢰할 수 없는 입력을 받지 않습니다. 외부 입력을 넘기는 용도로 확장하면 그때 제한이 필요하다는 지적에 동의합니다 |

---

## 4차 — 새로 추가된 검사 대상: 맥 앱의 "새 대화"

지금까지는 게이트웨이 플러그인만 봤습니다. 이번에 **그 플러그인을 부르는 쪽**이 붙어서
같이 올립니다.

| 파일 | 이번에 바뀐 것 |
|---|---|
| `apps/macos/Sources/Nova/Views/ChatView.swift` | 툴바 "새 대화" 버튼 + 결과 상태줄 |
| `apps/macos/Sources/Nova/AppState.swift` | `startNewConversation()` · `beginFreshSession()` |
| `apps/macos/Sources/Nova/GatewayClient.swift` | `switchSession(to:)` · `currentSessionKey` |

### 무슨 문제를 푸는 코드인가

`nova.memory.session.capture`(이 저장소의 플러그인)를 만들어놓고 **부르는 곳이 없었습니다.**
단기 기억이 생기는 유일한 경로가 CLI로 손수 부르는 것뿐이라, 앱으로 아무리 대화해도
기억이 안 쌓이고 새벽 정리(dreaming)가 처리할 것도 없었습니다.

openclaw의 `session-memory` 훅이 원래 이 일을 하지만 두 겹으로 막혀 있습니다 —
`/reset`에만 걸리는데 앱에 `operator.admin`이 없고(보내도 **에러 없이 무시**됨),
훅이 쓰는 형식은 승격 경로가 오염으로 버립니다. 그래서 직접 부릅니다.

### 봐줬으면 하는 것

1. **세션 전환의 정합성.** `beginFreshSession()`이 `AppState.sessionKey`와
   `GatewayClient.switchSession()`을 각각 갱신합니다. 두 곳에 같은 상태가 있는데
   재연결(`connect(sessionKey:)`) 경로와 어긋날 여지가 있는지.
2. **구독 재등록.** `switchSession`이 `state == .connected`일 때만 재구독합니다.
   연결이 끊긴 동안 세션을 바꾸고 나중에 재연결되면 구독이 제대로 걸리는지.
3. **실패 처리 정책.** 저장에 실패해도 새 대화를 시작합니다(사용자가 요청한 건
   새 대화이므로). 이 선택이 타당한지, 그리고 실패가 사용자에게 확실히 보이는지.
4. **경합.** `isStartingNewConversation`으로 버튼을 잠그지만, 저장 중에 사용자가
   메시지를 보내면 어느 세션으로 가는지.
5. **콜백 수명.** `client.call`의 클로저가 `[weak self]`인데, 그 사이 창이 닫히거나
   재연결되면 어떻게 되는지.

### 검증 상태 (정직하게)

- `swift build` 통과 · 번들 생성 · 앱 실행 확인
- `session.capture` 자체는 CLI로 실제 호출해 파일 생성까지 확인
- ⚠️ **버튼을 눌러 끝까지 도는 것은 아직 확인 못 했습니다.** 사람이 눌러야 합니다
