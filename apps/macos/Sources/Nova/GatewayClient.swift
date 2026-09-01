import Foundation

/// OpenClaw Gateway WebSocket 클라이언트 (프로토콜 v4).
///
/// 흐름:
///   1. 게이트웨이가 `connect.challenge` 이벤트를 먼저 보낸다.
///   2. 클라이언트가 `connect` 요청으로 응답한다.
///   3. `hello-ok` 응답을 받으면 `sessions.messages.subscribe`로 세션 전사를 구독한다.
///      (구독하지 않으면 chat/session.message 이벤트가 오지 않는다.)
///   4. `chat.send { sessionKey, message }`로 보내고, `chat` 이벤트로 응답을 받는다.
///
/// 값들은 설치된 패키지(openclaw 2026.7.1-2)의 TypeBox 스키마에서 확인했다:
///   client.id   ∈ webchat-ui, openclaw-control-ui, openclaw-tui, webchat, cli,
///                 gateway-client, openclaw-macos, openclaw-ios, openclaw-android,
///                 node-host, test, fingerprint, openclaw-probe
///   client.mode ∈ webchat, cli, test, probe, ui, backend, node
final class GatewayClient {

    enum State: Equatable {
        case disconnected
        case connecting
        case connected(server: String)
    }

    // 모든 콜백은 메인 스레드에서 호출된다.
    var onState: ((State) -> Void)?
    /// 증분 텍스트 — 진행 중인 답변 뒤에 이어 붙인다.
    var onAgentDelta: ((String) -> Void)?
    /// 누적 스냅샷 — 진행 중인 답변을 통째로 교체한다.
    var onAgentSnapshot: ((String) -> Void)?
    var onAgentDone: (() -> Void)?
    var onEvent: ((String, JSONValue) -> Void)?
    var onError: ((String) -> Void)?
    /// hello-ok가 실제로 부여한 role과 scope. 선언한 것과 다를 수 있다.
    var onGrant: ((String, [String]) -> Void)?

    private(set) var state: State = .disconnected {
        didSet { if oldValue != state { onState?(state) } }
    }

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var urlString = ""
    private var token = ""
    private var sessionKey = "main"
    private var connectRequestID: String?
    /// 아직 응답을 기다리는 chat.send 요청들. 응답에 답변이 실려 오면 화면에 반영한다.
    private var chatRequestIDs = Set<String>()

    /// 응답을 콜백으로 받아야 하는 일반 요청들. `call(method:params:)`이 여기에 넣는다.
    private var pendingRequests: [String: (Bool, JSONValue?, JSONValue?) -> Void] = [:]

    /// 사용자가 연결을 원하는 상태인지. 끊겼을 때 다시 붙을지를 이걸로 판단한다.
    private var shouldStayConnected = false
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    /// 이미 교체된 소켓의 뒤늦은 콜백을 무시하기 위한 세대 번호.
    private var generation = 0

    /// 디바이스 신원. 원격 게이트웨이(맥 미니)에 붙으려면 반드시 있어야 한다.
    /// 키체인 접근이 막히면 nil이 되는데, 그때는 조용히 실패하지 않도록 이유를 남긴다.
    private var identity: DeviceIdentity?
    private var identityError: String?
    /// 키체인 조회가 끝났는지. 끝나기 전에는 connect를 보류한다 — 신원 없이 붙으면
    /// 원격에서 스코프가 빈 배열로 지워진다 (하드윈 2번).
    private var identityReady = false
    /// 신원을 기다리느라 미뤄둔 connect 요청.
    private var pendingConnect: (url: String, token: String, sessionKey: String)?
    /// 승인 대기 중임을 사용자에게 알렸는지. 재연결마다 같은 안내를 반복하지 않으려고 둔다.
    private var announcedPairing = false

    /// 신원 조회가 끝나면 알린다. (deviceID, 실패 이유)
    var onIdentity: ((String?, String?) -> Void)?

    /// 키체인 조회는 **절대 메인 스레드에서 하지 않는다.**
    ///
    /// 바이너리가 애드혹 서명이라 빌드할 때마다 코드 신원이 바뀌고, 그러면 키체인 항목의
    /// ACL이 안 맞아 macOS가 로그인 암호를 묻는 대화상자를 띄운다. 그 대화상자는
    /// `SecItemCopyMatching` 안에서 사용자를 기다리는데, 이걸 `AppState.init()`에서
    /// 동기로 부르면 **SwiftUI가 첫 씬을 만들다 멈춰서 창조차 안 뜬다.**
    /// (2026-08-29 실측: 창 없음·소켓 없음·로그 없음. 스택은 SecItemCopyMatching에서 정지.)
    init() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var loaded: DeviceIdentity?
            var failure: String?
            do { loaded = try DeviceIdentity.loadOrCreate() } catch { failure = error.localizedDescription }
            DispatchQueue.main.async {
                guard let self else { return }
                self.identity = loaded
                self.identityError = failure
                self.identityReady = true
                self.onIdentity?(loaded?.deviceID, failure)
                if let failure {
                    self.onError?("디바이스 신원을 읽지 못했습니다: \(failure)")
                }
                if let pending = self.pendingConnect {
                    self.pendingConnect = nil
                    self.connect(urlString: pending.url, token: pending.token, sessionKey: pending.sessionKey)
                }
            }
        }
    }

    /// 이 기기의 디바이스 ID. 설정 화면에 띄워두면 승인할 때 대조할 수 있다.
    var deviceID: String? { identity?.deviceID }

    func connect(urlString: String, token: String, sessionKey: String) {
        // 신원이 아직이면 붙지 않고 기다린다. 기다리는 게 보이도록 상태는 "연결 중"으로 둔다.
        guard identityReady else {
            pendingConnect = (urlString, token, sessionKey)
            onState?(.connecting)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, !self.identityReady else { return }
                self.onError?("키체인에서 디바이스 신원을 읽는 데 시간이 걸리고 있습니다. "
                    + "승인 대화상자가 떠 있으면 허용해 주세요. "
                    + "매번 물어본다면 scripts/make-signing-cert.sh 로 서명 신원을 고정하세요.")
            }
            return
        }

        teardownSocket()
        self.urlString = urlString
        self.token = token
        self.sessionKey = sessionKey.isEmpty ? "main" : sessionKey
        shouldStayConnected = true
        reconnectAttempt = 0
        openSocket()
    }

    func disconnect() {
        shouldStayConnected = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        reconnectAttempt = 0
        teardownSocket()
        state = .disconnected
    }

    private func openSocket() {
        guard let url = URL(string: urlString) else {
            shouldStayConnected = false
            onError?("잘못된 게이트웨이 주소: \(urlString)")
            state = .disconnected
            return
        }
        teardownSocket()
        state = .connecting

        generation += 1
        let generation = self.generation
        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        listen(generation: generation)
    }

    private func teardownSocket() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        connectRequestID = nil
        chatRequestIDs.removeAll()
        // 이 소켓으로 나간 요청은 이제 응답을 받을 길이 없다. 여기서 실패로
        // 끝내지 않으면 콜백을 기다리는 쪽(예: "새 대화"의 저장 중 상태)이
        // **영원히 안 풀린다.** 재연결·명시적 해제·`connect()` 재호출 전부
        // 결국 여기를 거치므로 실패 처리 자리는 한 곳이면 된다.
        failAllPendingRequests()
    }

    /// 응답을 못 받게 된 요청을 전부 실패로 마무리한다. 완료 콜백은 메인
    /// 스레드에서 불린다는 계약(`call`의 문서 참고)을 여기서도 지킨다.
    private func failAllPendingRequests() {
        guard !pendingRequests.isEmpty else { return }
        let completions = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for completion in completions {
            completion(false, nil, .object(["message": .string("게이트웨이 연결이 끊겨 응답을 받지 못했습니다.")]))
        }
    }

    /// 지수 백오프로 재연결을 예약한다 (1초에서 시작해 최대 30초).
    private func scheduleReconnect() {
        guard shouldStayConnected else {
            state = .disconnected
            return
        }
        reconnectWorkItem?.cancel()
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(reconnectAttempt - 1)), 30.0)
        state = .connecting

        let item = DispatchWorkItem { [weak self] in self?.openSocket() }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// 토큰이 틀린 경우처럼 다시 시도해도 소용없는 실패에는 재연결을 멈춘다.
    private func stopRetrying() {
        shouldStayConnected = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        state = .disconnected
    }

    func sendChat(_ text: String) {
        // ChatSendParams의 필수 항목은 sessionKey, message, idempotencyKey 셋이다.
        // (필드 이름이 text가 아니라 message라는 점에 주의.)
        // idempotencyKey는 재전송이 중복 실행되지 않도록 보내는 건마다 새로 만든다.
        let id = sendRequest(method: "chat.send", params: [
            "sessionKey": sessionKey,
            "message": text,
            "idempotencyKey": UUID().uuidString,
        ])
        chatRequestIDs.insert(id)
    }

    // MARK: - 수신

    private func listen(generation: Int) {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    // 이미 교체된 소켓의 뒤늦은 실패는 무시한다.
                    guard generation == self.generation else { return }
                    if self.shouldStayConnected {
                        // 재연결을 예약하므로 매 시도마다 에러를 띄우지는 않는다.
                        if self.reconnectAttempt == 0 {
                            self.onError?("게이트웨이 연결이 끊겨 다시 연결하는 중입니다: \(error.localizedDescription)")
                        }
                        self.scheduleReconnect()
                    } else {
                        self.state = .disconnected
                    }
                }
            case .success(let message):
                if case .string(let text) = message {
                    DispatchQueue.main.async {
                        guard generation == self.generation else { return }
                        self.handle(text)
                    }
                }
                self.listen(generation: generation)
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let frame = try? JSONDecoder().decode(JSONValue.self, from: data) else { return }

        switch frame["type"]?.stringValue {
        case "event":
            let name = frame["event"]?.stringValue ?? "?"
            let payload = frame["payload"] ?? .null
            if name == "connect.challenge" {
                // nonce는 게이트웨이가 준다. 우리가 만들면 서명이 통과하지 못한다.
                sendConnectRequest(nonce: payload["nonce"]?.stringValue ?? "")
            }
            routeEvent(name: name, payload: payload)
            onEvent?(name, payload)

        case "res":
            let ok = frame["ok"]?.boolValue ?? false
            // 응답도 콘솔에 남긴다. 조용히 실패하면 원인을 찾을 길이 없다.
            onEvent?(ok ? "res ok" : "res error", frame)

            if let id = frame["id"]?.stringValue,
               let completion = pendingRequests.removeValue(forKey: id) {
                completion(ok, frame["payload"], frame["error"])
                return
            }

            if let id = frame["id"]?.stringValue, chatRequestIDs.remove(id) != nil {
                // chat.send의 응답은 답변이 아니라 접수 확인(ack)이다.
                // 페이로드는 { runId, status: "started" }가 전부고, 답변은 구독한
                // 세션의 chat 이벤트로만 온다. (dist/chat-pg-*.js의 ackPayload)
                //
                // 여기서 onAgentDone을 부르면 시작도 안 한 답변을 끝난 것으로 처리해서,
                // 몇 초 뒤 도착한 첫 델타가 새 말풍선을 만들며 답변이 쪼개진다.
                if !ok {
                    onError?(frame["error"]?["message"]?.stringValue ?? "메시지 전송 실패")
                }
                return
            }

            if frame["id"]?.stringValue == connectRequestID {
                if ok {
                    let payload = frame["payload"]
                    let server = payload?["server"]?["version"]?.stringValue ?? "unknown"
                    let grantedRole = payload?["auth"]?["role"]?.stringValue ?? "?"
                    let grantedScopes = payload?["auth"]?["scopes"]?.arrayValue?
                        .compactMap { $0.stringValue } ?? []
                    onGrant?(grantedRole, grantedScopes)
                    reconnectAttempt = 0
                    announcedPairing = false
                    state = .connected(server: server)

                    // 붙긴 했는데 스코프가 비어 있으면 아무 호출도 못 한다.
                    // 조용히 "연결됨"으로 보이면 원인을 찾을 수 없으니 여기서 잡아준다.
                    if grantedScopes.isEmpty {
                        onError?("연결은 됐지만 권한이 비어 있습니다. 디바이스 서명이 빠졌거나"
                                 + " 승인되지 않은 상태입니다. \(identityError.map { "(키체인: \($0)) " } ?? "")"
                                 + "게이트웨이에서 `openclaw devices list`로 확인하세요.")
                    }
                    subscribeToSession()
                } else {
                    let error = frame["error"]
                    let message = error?["message"]?.stringValue ?? "인증 실패"
                    let detailCode = error?["details"]?["code"]?.stringValue ?? ""

                    // 페어링 대기는 "실패"가 아니라 "승인만 기다리는 중"이다.
                    // 사용자가 맥 미니에서 승인하면 그다음 연결부터 통과하므로 재시도를 유지한다.
                    if detailCode == "PAIRING_REQUIRED" || detailCode == "DEVICE_IDENTITY_REQUIRED" {
                        if !announcedPairing {
                            announcedPairing = true
                            let id = identity?.deviceID ?? "(알 수 없음)"
                            onError?("이 기기가 아직 승인되지 않았습니다. 맥 미니에서"
                                     + " `openclaw devices list`로 요청을 확인하고"
                                     + " `openclaw devices approve <요청ID>`로 승인해 주세요."
                                     + " 이 기기 ID: \(id.prefix(16))…")
                        }
                        scheduleReconnect()
                    } else {
                        // 토큰이나 파라미터가 틀린 것이므로 재시도해도 같은 결과다.
                        onError?("연결 거부: \(message)")
                        stopRetrying()
                    }
                }
            } else if !ok {
                let message = frame["error"]?["message"]?.stringValue ?? "요청 실패"
                onError?(message)
            }

        default:
            break
        }
    }

    /// chat / session.message 이벤트를 대화 화면에 반영한다.
    private func routeEvent(name: String, payload: JSONValue) {
        guard name == "chat" || name.hasPrefix("chat.") || name == "session.message" else { return }

        // 다른 세션의 이벤트는 무시한다 (키가 실려 있을 때만 판단).
        if let key = payload["sessionKey"]?.stringValue ?? payload["key"]?.stringValue,
           !matchesSession(key) {
            return
        }

        // 사용자가 보낸 줄이 되돌아오는 것은 이미 화면에 있으므로 건너뛴다.
        if Self.role(payload) == "user" { return }

        // v4: message = 누적 스냅샷, deltaText = 증분.
        // 스냅샷이 오면 그것이 가장 정확하므로 통째로 교체한다.
        if let snapshot = Self.snapshotText(payload), !snapshot.isEmpty {
            onAgentSnapshot?(snapshot)
        } else if let delta = payload["deltaText"]?.stringValue, !delta.isEmpty {
            // replace=true는 접두사 교체가 아닌 치환이다.
            if payload["replace"]?.boolValue == true {
                onAgentSnapshot?(delta)
            } else {
                onAgentDelta?(delta)
            }
        }

        let phase = payload["state"]?.stringValue
            ?? payload["status"]?.stringValue
            ?? payload["phase"]?.stringValue
        if let phase, ["final", "done", "complete", "completed", "end"].contains(phase.lowercased()) {
            onAgentDone?()
        }
    }

    /// 게이트웨이는 세션 키를 `agent:<agentId>:<키>` 형태로 정규화하므로,
    /// 우리가 보낸 `main` 같은 원본 키와 이벤트에 실려 오는 키가 글자 그대로는 다르다.
    ///
    /// ⚠️ 예전에는 접미사 일치(`hasSuffix`)로 봤는데, 그러면 세션 이름이 겹칠 때
    /// 범위가 너무 넓어진다 — 우리 세션이 `foo`인데 다른 에이전트의
    /// `agent:other:foo` 이벤트까지 "같은 세션"으로 잡을 수 있었다.
    /// 지금은 정확히 두 형태만 인정한다: 글자 그대로 같거나, **우리 에이전트로**
    /// 정규화된 형태(`agent:<우리 agentId>:<키>`)와 같은 것.
    private func matchesSession(_ key: String) -> Bool {
        key == sessionKey || key == normalizedSessionKey
    }

    /// 이 앱은 단일 에이전트(`main`)만 다룬다 — `AppState.memoryAgentID`와 같다.
    private var normalizedSessionKey: String {
        sessionKey.hasPrefix("agent:") ? sessionKey : "agent:main:\(sessionKey)"
    }

    /// 누적 스냅샷(`message`)에서 텍스트를 꺼낸다. 문자열일 수도, 메시지 레코드일 수도 있다.
    static func snapshotText(_ payload: JSONValue) -> String? {
        guard let message = payload["message"] else { return nil }
        if let text = message.stringValue { return text }
        if let text = message["text"]?.stringValue { return text }
        if let blocks = message["content"]?.arrayValue {
            let parts = blocks.compactMap { $0["text"]?.stringValue }
            if !parts.isEmpty { return parts.joined() }
        }
        if let text = message["content"]?.stringValue { return text }
        return nil
    }

    static func role(_ payload: JSONValue) -> String? {
        payload["role"]?.stringValue ?? payload["message"]?["role"]?.stringValue
    }

    // MARK: - 송신

    private func sendConnectRequest(nonce: String) {
        let id = UUID().uuidString
        connectRequestID = id

        // 정식 신원으로 붙는다. 예전에는 CLI 신원(`cli`/`cli`)으로 우회했는데,
        // 그 예외(`shouldPreserveLocalCliSharedAuthScopes`)는 **루프백에서만** 걸린다.
        // 맥 미니처럼 원격 게이트웨이에 붙으면 스코프가 빈 배열로 지워져
        // 모든 호출이 `missing scope: operator.read`로 거부된다.
        //
        // 그래서 Ed25519 디바이스 서명을 실어 보낸다. 규약과 검증 내역은
        // DeviceIdentity.swift와 CLAUDE.md 하드윈 7번에 있다.
        let role = "operator"
        let scopes = ["operator.read", "operator.write"]
        let clientID = "openclaw-macos"
        let clientMode = "ui"
        let platform = "macos"
        let deviceFamily = "Mac"

        var params: [String: Any] = [
            "minProtocol": 4,
            "maxProtocol": 4,
            "client": [
                "id": clientID,
                "displayName": "NOVA",
                "version": "0.1.0",
                "platform": platform,
                "deviceFamily": deviceFamily,
                "mode": clientMode,
            ],
            "role": role,
            "scopes": scopes,
        ]
        if !token.isEmpty {
            params["auth"] = ["token": token]
        }

        // nonce가 없으면 서명할 수 없다. 신원 없이 보내면 원격에서는 어차피 거부되므로
        // 조용히 실패하지 않도록 이유를 남긴다.
        if nonce.isEmpty {
            onError?("게이트웨이가 nonce를 주지 않아 디바이스 서명을 만들 수 없습니다.")
        } else if let identity {
            params["device"] = identity.connectParams(
                nonce: nonce,
                token: token,
                clientID: clientID,
                clientMode: clientMode,
                role: role,
                scopes: scopes,
                platform: platform,
                deviceFamily: deviceFamily
            )
        }

        sendFrame(["type": "req", "id": id, "method": "connect", "params": params])
    }

    /// 게이트웨이 메서드를 부르고 응답을 콜백으로 받는다.
    ///
    /// 콜백 인자는 `(ok, payload, error)`이고 **메인 스레드에서** 불린다
    /// (프레임 처리 자체가 메인에서 돈다). 연결 전에 부르면 조용히 사라지지 않도록
    /// 즉시 실패로 돌려준다.
    func call(
        method: String,
        params: [String: Any],
        completion: @escaping (Bool, JSONValue?, JSONValue?) -> Void
    ) {
        guard case .connected = state else {
            completion(false, nil, nil)
            return
        }
        let id = UUID().uuidString
        pendingRequests[id] = completion
        sendFrame(["type": "req", "id": id, "method": method, "params": params])
    }

    /// 대화하는 세션을 바꾸고 새 세션의 전사를 구독한다.
    ///
    /// 게이트웨이는 세션을 미리 만들 필요가 없다 — 처음 `chat.send`가 가면 생긴다.
    /// 구독은 **다시 걸어야 한다.** 안 걸면 새 세션의 응답 이벤트가 전혀 안 온다(하드윈 4번).
    func switchSession(to key: String) {
        sessionKey = key.isEmpty ? "main" : key
        guard case .connected = state else { return }
        subscribeToSession()
    }

    /// 지금 대화 중인 세션 키. 게이트웨이가 정규화하기 전의 우리 쪽 값이다.
    var currentSessionKey: String { sessionKey }

    /// 세션 전사를 구독한다. 이걸 하지 않으면 응답 이벤트가 전혀 오지 않는다.
    private func subscribeToSession() {
        sendRequest(method: "sessions.messages.subscribe", params: ["key": sessionKey])
    }

    @discardableResult
    private func sendRequest(method: String, params: [String: Any]) -> String {
        let id = UUID().uuidString
        sendFrame(["type": "req", "id": id, "method": method, "params": params])
        return id
    }

    private func sendFrame(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            if let error {
                DispatchQueue.main.async {
                    self?.onError?("전송 실패: \(error.localizedDescription)")
                }
            }
        }
    }
}
