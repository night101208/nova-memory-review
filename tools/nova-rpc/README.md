# 게이트웨이 메서드 호출기

플러그인이 등록한 메서드(`nova.memory.*`)를 **앱과 같은 신원**으로 부른다.

## 왜 필요한가

`registerGatewayMethod`로 등록한 메서드는 `openclaw` CLI에 안 나온다. 게이트웨이에
붙어서만 부를 수 있는데, 붙으려면 v3 디바이스 서명이 필요하다(하드윈 7번).
`tools/roundtrip/`이 그 절차를 이미 갖고 있어서 규약은 그대로 쓰되,
대화 대신 **아무 메서드나** 부를 수 있게 열어둔 것이다.

## 쓰는 법

```bash
# 단기 기억이 승격 경로에서 버려지는지 본다
node tools/nova-rpc/rpc.mjs --method nova.memory.lint

# 세션 전사에서 단기 기억을 만든다 (먼저 dryRun으로 본문을 확인할 것)
node tools/nova-rpc/rpc.mjs --method nova.memory.session.capture \
  --params '{"sessionKey":"agent:main:main","maxMessages":8,"dryRun":true}'

# 기본 게이트웨이 메서드도 부를 수 있다
node tools/nova-rpc/rpc.mjs --method agents.workspace.get \
  --params '{"agentId":"main","path":"memory/MEMORY.md"}'
```

`--url`은 기본이 맥 미니의 Tailscale 주소(`ws://GATEWAY-HOST:18789`)다.
경로가 뒤집히는 일이 잦으니(CLAUDE.md "아직 안 한 것" 참고) 안 되면 LAN 별칭도 시도한다.

## 알아둘 것

- **디바이스 키는 파일이 정본이다** — `~/.openclaw/nova-device-identity`.
  키체인(`ai.openclaw.nova.device-identity`)은 폴백으로만 본다 (하드윈 24번 ★)
- **부여된 권한은 `payload.auth` 아래다.** 최상위 `payload.scopes`를 읽으면 늘 빈 배열이라
  페어링이 깨진 것처럼 보인다 (하드윈 23번)
- 앱과 **같은 값**(`openclaw-macos`/`ui`, `operator`, read+write)으로 선언한다.
  다르게 선언하면 `metadata-upgrade`/`scope-upgrade`로 재승인을 요구받는다
