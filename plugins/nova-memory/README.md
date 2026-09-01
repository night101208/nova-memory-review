# NOVA Memory 플러그인

기억 파일을 **고치고 지우는** 게이트웨이 메서드를 더합니다. 읽기는 이미 되므로 쓰기만 채웁니다.

## 왜 필요한가

앱의 기억 화면을 붙이면서 게이트웨이 메서드 217개를 다 확인했습니다. 읽기는 전부 되는데
쓰기가 막혀 있었고, 막힌 이유가 셋 다 명시적이었습니다.

| 시도한 것 | 결과 |
|---|---|
| `agents.files.set { name: "memory/x.md" }` | `unsupported file` — 받는 이름이 루트 8개뿐 |
| `agents.workspace.*` | 스키마 주석이 "intentionally read-only"라고 못박음 |
| `tools.invoke { name: "write" }` | `Tool not available` — 그 도구는 claude-cli 서브프로세스 안에 있음 |

전부 실제로 호출해서 확인한 것입니다. 그래서 이 플러그인이 그 구멍만 메웁니다.

## 더하는 메서드

| 메서드 | 스코프 | 하는 일 |
|---|---|---|
| `nova.memory.save` | `operator.write` | `{ agentId?, path, content }` → 파일을 통째로 씁니다 |
| `nova.memory.delete` | `operator.write` | `{ agentId?, path, hard? }` → 휴지통으로 옮기거나(`hard`면) 지웁니다 |
| `nova.memory.trash.list` | `operator.read` | `{ agentId? }` → 휴지통 목록 |

## 안전장치

기억은 지우면 되돌릴 수 없으므로 좁게 막아뒀습니다.

- **`memory/` 아래 `.md`만** 다룹니다. 절대 경로와 `..`는 거부합니다.
  문자열 검사가 아니라 `path.resolve`로 해석한 뒤 판단합니다
- **`.dreams/`는 건드리지 않습니다.** 정리(dreaming)가 쓰는 내부 디렉터리입니다
- **심볼릭 링크·하드링크는 거부합니다.** 워크스페이스 밖을 가리킬 수 있습니다
- **삭제는 기본이 휴지통입니다.** `memory/.trash/<시각>__<이름>`으로 옮기고,
  `hard: true`를 줘야 실제로 지웁니다. 잘못 지운 기억을 되살릴 길을 남깁니다

## 설치

```bash
# 맥 미니에서
openclaw plugins install /경로/plugins/nova-memory
openclaw gateway restart
openclaw plugins list | grep nova-memory
```

게이트웨이를 다시 띄워야 메서드가 붙습니다. 붙었는지는 hello-ok의 `features.methods`에
`nova.memory.save`가 보이는지로 확인합니다 (앱 설정 탭의 이벤트 콘솔에서도 보입니다).

## 단기 기억 쓰기 (2026-09-01 추가)

### 왜 우리가 쓰는가 — 번들 훅은 두 겹으로 막혀 있다

1. **방아쇠.** `session-memory` 훅은 `/new`·`/reset`에만 걸린다. 그 명령을 게이트웨이로
   쏘려면 `operator.admin`이 필요한데 앱은 read+write만 선언한다. admin 없이 보내면
   **에러도 없이 조용히 무시된다** (하드윈 21번).
2. **형식.** 그 훅이 쓰는 머리말을 openclaw 자신의 승격 경로가 오염으로 판정해 버린다.
   만들어져도 굳히기 후보에 영원히 못 들어간다.

   ```
   handler.js:278               `- **Session Key**: ${displaySessionKey}`
   short-term-promotion.js:577  /\bSession Key\b.{0,260}\bSession ID\b/i
   ```

   같은 설치본 안에서 한쪽이 쓰고 다른 쪽이 버린다. 자세한 것은
   `short-term-format.js`의 머리 주석과 CLAUDE.md 하드윈 16번.

### 메서드

| 메서드 | 스코프 | 하는 일 |
|---|---|---|
| `nova.memory.session.capture` | `operator.write` | 세션 전사에서 단기 기억 한 편을 만들어 `memory/YYYY-MM-DD-HHMM.md`로 쓴다 |
| `nova.memory.lint` | `operator.read` | 이미 있는 단기 기억이 승격 경로에서 버려지는지 본다. 고치지는 않는다 |

`capture` 파라미터: `sessionKey`(필수) · `agentId` · `maxMessages`(기본 15) ·
`slug` · `source` · `dryRun`.

**`dryRun: true`로 본문을 먼저 보는 것을 권한다.** 쓰기 전에 마지막 관문
(`assertSafeShortTermText`)이 한 번 더 걸러내지만, 무엇이 들어가는지 눈으로 보는 게 낫다.

### 형식 계약

`short-term-format.js`가 한 곳에서 관리한다.

- 정규식은 **설치된 패키지에서 그대로 옮긴 것**이다. openclaw를 올리면
  `dist/short-term-promotion-*.js`를 다시 읽고 목록을 맞출 것
- 각 턴은 **한 줄로 접는다.** 줄이 나뉘면 앵커 규칙(`^user:`)에 걸릴 자리가 늘어난다
- 역할은 `사용자` / `NOVA`. 영어 `user:`/`assistant:`를 쓰면 그 조각이 버려진다
- 본문에 `Session Key`/`Session ID`가 섞여 들어오면 붙임표로 바꾸고 그 사실을 돌려준다.
  (이게 필요하다는 걸 사고로 알았다 — 진단용 파일에 그 낱말을 그대로 적었다가
  그 파일이 스스로 버려졌다)
