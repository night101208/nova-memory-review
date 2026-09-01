import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {

    enum Pane: Hashable {
        case chat
        case vision
        case memory
        case devices
        case mcp
        case settings
    }

    // 내비게이션
    @Published var pane: Pane? = .chat

    // 대화
    @Published var messages: [ChatMessage] = []

    // 뷰 로컬 상태.
    // SwiftUI의 @State는 최신 SDK에서 매크로(SwiftUIMacros)로 바뀌었는데
    // 그 플러그인은 Xcode에만 있고 Command Line Tools에는 없다.
    // Xcode 없이도 빌드되도록 뷰 로컬 상태를 여기로 끌어올렸다.
    // (부수 효과로 탭을 옮겨도 입력 중이던 내용이 남는다.)
    @Published var draft = ""
    /// "새 대화"의 결과를 한 줄로 알린다. 기억 저장은 조용히 실패하면 안 된다.
    @Published var chatStatus: String?
    /// 저장하고 새 대화를 시작하는 중인지. 버튼을 두 번 눌러 세션이 꼬이는 걸 막는다.
    @Published var isStartingNewConversation = false
    @Published var selectedMemoryID: MemoryItem.ID?
    @Published var memoryDraft = ""

    // 게이트웨이
    @Published var connection: GatewayClient.State = .disconnected
    @Published var gatewayURL = "ws://127.0.0.1:18789"
    @Published var token = ""
    @Published var sessionKey = "main"
    @Published var lastError: String?
    /// 로컬 openclaw 설정을 읽어온 결과 안내.
    @Published var configStatus: String?
    /// 붙어볼 후보들. 맥 미니가 먼저고 이 맥은 폴백이다.
    @Published var endpoints: [OpenClawConfig.Endpoint] = []
    /// 이 기기의 디바이스 ID. 맥 미니에서 승인할 때 대조하려면 보여야 한다.
    @Published var deviceID: String?
    /// hello-ok가 실제로 부여한 role·scope (선언한 것과 다를 수 있어 진단에 필요).
    @Published var grantedRole: String?
    @Published var grantedScopes: [String] = []

    // 이벤트
    @Published var eventLog: [EventLine] = []
    @Published var actionLog: [EventLine] = []

    // 기억 — 맥 미니 워크스페이스의 실제 파일을 비춘다.
    @Published var memories: [MemoryItem] = []
    /// 목록을 불러오는 중이거나 실패했을 때 화면에 보일 한 줄.
    @Published var memoryStatus: String?
    @Published var isLoadingMemories = false

    // 데모 데이터 (게이트웨이 연동 전 자리 채움)
    @Published var devices: [DeviceStatus] = DeviceStatus.demo
    @Published var mcpServers: [McpServer] = McpServer.demo

    private let client = GatewayClient()
    private var streamingMessageID: UUID?
    private var smokeMessageSent = false

    var isConnected: Bool {
        if case .connected = connection { return true }
        return false
    }

    var connectionLabel: String {
        switch connection {
        case .disconnected: return "게이트웨이 연결 안 됨"
        case .connecting: return "연결 중…"
        case .connected(let server): return "게이트웨이 연결됨 · v\(server)"
        }
    }

    init() {
        client.onState = { [weak self] state in
            Task { @MainActor in
                self?.connection = state
                self?.sendSmokeMessageIfRequested()
                if case .connected = state {
                    // 붙었으면 붙기 전에 띄운 경고는 더 이상 사실이 아니다.
                    // (키체인을 기다린다는 안내가 연결된 뒤에도 남아 있던 버그를 여기서 막는다.)
                    self?.lastError = nil
                    self?.loadMemories()
                }
            }
        }
        client.onAgentDelta = { [weak self] text in
            Task { @MainActor in self?.appendStreamingText(text) }
        }
        client.onAgentSnapshot = { [weak self] text in
            Task { @MainActor in self?.replaceStreamingText(text) }
        }
        client.onAgentDone = { [weak self] in
            Task { @MainActor in self?.streamingMessageID = nil }
        }
        client.onEvent = { [weak self] name, payload in
            Task { @MainActor in self?.recordEvent(name: name, payload: payload) }
        }
        client.onError = { [weak self] message in
            Task { @MainActor in self?.lastError = message }
        }
        client.onGrant = { [weak self] role, scopes in
            Task { @MainActor in
                self?.grantedRole = role
                self?.grantedScopes = scopes
            }
        }

        // 키체인 조회가 백그라운드로 빠졌으므로 deviceID는 나중에 온다.
        client.onIdentity = { [weak self] id, _ in
            Task { @MainActor in self?.deviceID = id }
        }

        // 맥 미니(총괄 서버)를 먼저 보고, 안 되면 이 맥의 폴백을 본다.
        // 게이트웨이는 LaunchAgent로 상주하므로 앱이 알아서 붙는 게 자연스럽다.
        loadLocalConfig()
        if !gatewayURL.isEmpty { connect() }
    }

    // MARK: - 로컬 설정

    /// `~/.openclaw/openclaw.json`에서 주소와 토큰을 채운다.
    /// 게이트웨이가 같은 맥에 있으면 사용자가 토큰을 옮겨 적을 필요가 없다.
    func loadLocalConfig() {
        guard let config = OpenClawConfig.loadFromDisk() else {
            configStatus = "\(OpenClawConfig.configPath.path) 을 읽지 못했습니다. 주소와 토큰을 직접 입력하세요."
            return
        }
        gatewayURL = config.primaryURL
        token = config.token
        endpoints = config.endpoints

        // 진단용 주소 오버라이드. 블랙박스(tools/blackbox/)를 앱과 게이트웨이 사이에
        // 끼우려면 주소를 돌려야 하는데, 설정 화면을 거치면 사람이 클릭해야 한다.
        // 총괄 서버는 여전히 맥 미니다 — 이건 그 앞에 프록시를 세울 때만 쓴다.
        if let override = ProcessInfo.processInfo.environment["NOVA_GATEWAY_URL"],
           !override.isEmpty {
            gatewayURL = override
            endpoints.insert(
                .init(url: override, label: "환경변수 지정 (진단)", isPrimary: false),
                at: 0
            )
            configStatus = "NOVA_GATEWAY_URL 로 \(override) 에 붙습니다 (진단 모드)."
            return
        }

        let where_ = config.endpoints.first?.label ?? "알 수 없음"
        if config.authMode == "none" {
            configStatus = "\(where_)에 토큰 없이 붙습니다 (auth.mode: none)."
        } else if config.token.isEmpty {
            configStatus = "설정을 불러왔지만 토큰이 비어 있습니다 (auth.mode: \(config.authMode))."
        } else {
            configStatus = "\(where_)로 붙습니다. 토큰은 openclaw.json에서 읽었습니다."
        }
    }

    // MARK: - 게이트웨이

    func connect() {
        lastError = nil
        grantedRole = nil
        grantedScopes = []
        client.connect(urlString: gatewayURL, token: token, sessionKey: sessionKey)
    }

    func disconnect() {
        client.disconnect()
    }

    /// `NOVA_SMOKE_MESSAGE`가 있으면 연결되자마자 그 한 줄을 **앱의 정상 전송 경로로** 보낸다.
    /// 왕복이 되는지 확인하려고 사람이 창에 타이핑하는 대신 쓰는 방아쇠다.
    /// 한 번만 쏘고, 재연결해도 다시 쏘지 않는다.
    private func sendSmokeMessageIfRequested() {
        guard isConnected, !smokeMessageSent,
              let text = ProcessInfo.processInfo.environment["NOVA_SMOKE_MESSAGE"],
              !text.isEmpty else { return }
        smokeMessageSent = true
        sendChat(text)
    }

    // MARK: - 대화

    func sendChat(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messages.append(ChatMessage(role: .user, text: text))
        streamingMessageID = nil

        if isConnected {
            client.sendChat(text)
        } else {
            messages.append(ChatMessage(
                role: .system,
                text: "게이트웨이에 연결되어 있지 않습니다. Mac mini에서 `openclaw gateway`를 실행한 뒤, 설정 탭에서 연결하세요."
            ))
        }
    }

    /// 컴포저의 현재 입력을 보내고 비운다.
    func sendDraft() {
        // ⚠️ 기억으로 남기는 중에는 보내지 않는다.
        // 지금 보내면 그 말이 **닫히는 중인 옛 세션**으로 들어가고, 곧 이어질
        // `beginFreshSession()`이 화면을 비워서 사용자에게는 말이 그냥 사라진 것처럼 보인다.
        // 게다가 그 말이 방금 저장한 기억에 들어갔는지 아닌지가 타이밍에 따라 달라진다.
        // 버튼만 잠그는 것으로는 부족했다 — 이 경로가 열려 있었다.
        //
        // 입력은 **지우지 않는다.** 저장이 끝난 뒤 그대로 다시 누르면 된다.
        guard !isStartingNewConversation else {
            chatStatus = "대화를 기억으로 남기는 중입니다. 잠시 뒤에 보내주세요."
            return
        }
        let text = draft
        draft = ""
        sendChat(text)
    }

    /// 증분 텍스트를 진행 중인 답변 뒤에 이어 붙인다.
    private func appendStreamingText(_ text: String) {
        if let index = streamingIndex {
            messages[index].text += text
        } else {
            startStreamingMessage(with: text)
        }
    }

    /// 누적 스냅샷으로 진행 중인 답변을 통째로 교체한다.
    private func replaceStreamingText(_ text: String) {
        if let index = streamingIndex {
            messages[index].text = text
        } else {
            startStreamingMessage(with: text)
        }
    }

    private var streamingIndex: Int? {
        guard let streamingMessageID else { return nil }
        return messages.lastIndex { $0.id == streamingMessageID }
    }

    private func startStreamingMessage(with text: String) {
        let message = ChatMessage(role: .assistant, text: text)
        streamingMessageID = message.id
        messages.append(message)
    }

    // MARK: - 기억

    var selectedMemoryIndex: Int? {
        guard let selectedMemoryID else { return nil }
        return memories.firstIndex { $0.id == selectedMemoryID }
    }

    /// 선택이 비어 있으면 첫 항목을 고르고, 편집창을 선택된 기억의 내용으로 맞춘다.
    func syncMemorySelection() {
        if selectedMemoryID == nil || selectedMemoryIndex == nil {
            selectedMemoryID = memories.first?.id
        }
        memoryDraft = selectedMemoryIndex.map { memories[$0].content ?? "" } ?? ""
        if let id = selectedMemoryID { loadMemoryContent(for: id) }
    }

    // MARK: - 진단 기록

    /// `NOVA_DIAG_LOG`에 경로가 있으면 그 파일에 한 줄씩 붙인다.
    ///
    /// 창을 못 보는 상황(원격·자동화·GUI 세션 없음)에서 앱이 실제로 뭘 받았는지
    /// 확인할 길이 이것뿐이다. 화면 기록 권한이 없으면 스크린샷도 못 찍는다.
    /// 환경변수가 없으면 아무 일도 하지 않는다.
    func diagLog(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["NOVA_DIAG_LOG"], !path.isEmpty else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp)  \(line)\n".data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    // MARK: - 기억 (맥 미니 워크스페이스)

    /// 에이전트 id. 게이트웨이가 `agents.list`에서 `defaultId: "main"`을 준다.
    private let memoryAgentID = "main"

    /// 기억 목록을 불러온다.
    ///
    /// 두 곳을 합친다:
    ///   - `agents.files.list` → 루트 `MEMORY.md` (기억들의 목록이자 세션 부트스트랩에 실리는 파일)
    ///   - `agents.workspace.list path="memory"` → 개별 기억 파일들
    ///
    /// 목록 응답에는 본문이 없다. 본문은 선택했을 때 `agents.workspace.get`으로 따로 읽는다
    /// (30개를 한꺼번에 읽을 이유가 없다).
    func loadMemories() {
        guard !isLoadingMemories else { return }
        isLoadingMemories = true
        memoryStatus = "기억을 불러오는 중입니다…"

        client.call(method: "agents.workspace.list", params: [
            "agentId": memoryAgentID,
            "path": "memory",
            "limit": 500,
        ]) { [weak self] ok, payload, error in
            guard let self else { return }
            guard ok, let entries = payload?["entries"]?.arrayValue else {
                self.isLoadingMemories = false
                self.memoryStatus = "기억 목록을 불러오지 못했습니다: "
                    + (error?["message"]?.stringValue ?? "게이트웨이에 연결되어 있지 않습니다.")
                return
            }

            var items: [MemoryItem] = entries.compactMap { entry in
                guard entry["kind"]?.stringValue == "file",
                      let path = entry["path"]?.stringValue,
                      let name = entry["name"]?.stringValue,
                      name.hasSuffix(".md") else { return nil }
                return MemoryItem(
                    path: path,
                    name: name,
                    title: name.replacingOccurrences(of: ".md", with: ""),
                    summary: "",
                    kind: "",
                    sizeBytes: entry["size"]?.intValue ?? 0,
                    updatedAt: (entry["updatedAtMs"]?.intValue).map {
                        Date(timeIntervalSince1970: Double($0) / 1000)
                    },
                    content: nil
                )
            }
            // 최근에 고친 것부터. 날짜가 없는 항목은 뒤로 보낸다.
            items.sort { ($0.updatedAt ?? .distantPast) > ($1.updatedAt ?? .distantPast) }

            self.appendRootMemoryIndex(to: items)
        }
    }

    /// 루트 `MEMORY.md`를 목록 맨 앞에 붙인다. 이것만 앱에서 고쳐 쓸 수 있다.
    private func appendRootMemoryIndex(to items: [MemoryItem]) {
        client.call(method: "agents.files.list", params: ["agentId": memoryAgentID]) { [weak self] ok, payload, _ in
            guard let self else { return }
            var all = items
            if ok, let files = payload?["files"]?.arrayValue,
               let root = files.first(where: { $0["name"]?.stringValue == "MEMORY.md" }),
               root["missing"]?.boolValue != true {
                all.insert(MemoryItem(
                    path: "MEMORY.md",
                    name: "MEMORY.md",
                    title: "MEMORY.md (기억 목록)",
                    summary: "세션이 시작될 때 통째로 문맥에 실리는 색인입니다. 여기서만 고쳐 쓸 수 있습니다.",
                    kind: "색인",
                    sizeBytes: root["size"]?.intValue ?? 0,
                    updatedAt: (root["updatedAtMs"]?.intValue).map {
                        Date(timeIntervalSince1970: Double($0) / 1000)
                    },
                    content: nil
                ), at: 0)
            }

            self.memories = all
            self.isLoadingMemories = false
            self.diagLog("기억 \(all.count)개 불러옴")
            for item in all.prefix(6) {
                self.diagLog("  · \(item.path)  \(item.displaySize)  편집가능=\(item.isEditable) 단기=\(item.isShortTerm)")
            }
            let shortTerm = all.filter(\.isShortTerm).count
            self.memoryStatus = all.isEmpty
                ? "기억이 없습니다."
                : "장기 \(all.count - shortTerm - 1)개 · 단기 \(shortTerm)개"
            self.syncMemorySelection()
        }
    }

    /// 선택한 기억의 본문을 읽어 채운다. 이미 읽었으면 다시 부르지 않는다.
    func loadMemoryContent(for id: MemoryItem.ID) {
        guard let index = memories.firstIndex(where: { $0.id == id }),
              memories[index].content == nil else { return }
        let item = memories[index]

        // 루트 파일은 agents.files.get, memory/ 아래는 agents.workspace.get으로 읽는다.
        let method = item.isRootFile ? "agents.files.get" : "agents.workspace.get"
        let params: [String: Any] = item.isRootFile
            ? ["agentId": memoryAgentID, "name": item.name]
            : ["agentId": memoryAgentID, "path": item.path]

        client.call(method: method, params: params) { [weak self] ok, payload, error in
            guard let self,
                  let index = self.memories.firstIndex(where: { $0.id == id }) else { return }
            guard ok, let text = payload?["file"]?["content"]?.stringValue else {
                self.memoryStatus = "본문을 읽지 못했습니다: "
                    + (error?["message"]?.stringValue ?? "알 수 없는 오류")
                return
            }
            self.memories[index].applyContent(text)
            let parsed = self.memories[index]
            self.diagLog("본문 읽음 \(parsed.path) → 제목=\(parsed.title) 분류=\(parsed.kind.isEmpty ? "(없음)" : parsed.kind) 요약=\(parsed.summary.prefix(40))")
            if self.selectedMemoryID == id { self.memoryDraft = text }
        }
    }

    /// 지금까지의 대화를 기억으로 남기고 새 대화를 시작한다.
    ///
    /// **왜 우리가 하는가.** openclaw의 `session-memory` 훅이 이 일을 하지만 두 겹으로 막혀 있다:
    ///   1. 훅은 `/new`·`/reset`에만 걸리는데 그 명령을 게이트웨이로 쏘려면 `operator.admin`이
    ///      필요하다. 앱은 read+write만 선언하고, admin 없이 보내면 **에러도 없이 무시된다**
    ///      (하드윈 21번).
    ///   2. 훅이 쓰는 머리말을 openclaw 자신의 승격 경로가 오염으로 판정해 버려서,
    ///      만들어져도 장기 기억으로 굳을 후보에 영원히 못 들어간다 (하드윈 16번).
    ///
    /// 그래서 `nova.memory.session.capture`를 직접 부른다. `operator.write`면 되고
    /// 형식은 우리가 지킨다.
    ///
    /// **기억 저장에 실패해도 새 대화는 시작한다.** 사용자가 요청한 건 새 대화이고,
    /// 저장 실패 때문에 그걸 막으면 더 나쁘다. 대신 실패했다는 사실은 반드시 알린다.
    func startNewConversation() {
        guard isConnected else {
            chatStatus = "게이트웨이에 연결되어 있지 않습니다. 새 대화만 시작합니다."
            beginFreshSession()
            return
        }
        guard !isStartingNewConversation else { return }

        // 나눈 말이 없으면 저장할 것도 없다. 빈 기억 파일을 만들지 않는다.
        guard !messages.isEmpty else {
            beginFreshSession()
            chatStatus = "새 대화를 시작했습니다."
            return
        }

        isStartingNewConversation = true
        chatStatus = "대화를 기억으로 남기는 중입니다…"

        // 게이트웨이는 세션 키를 `agent:<agentId>:<키>`로 정규화한다 (하드윈 5번).
        // 세션 인덱스도 그 형태로 저장하므로 조회할 때 맞춰서 보내야 한다.
        let normalized = "agent:\(memoryAgentID):\(client.currentSessionKey)"

        client.call(method: "nova.memory.session.capture", params: [
            "agentId": memoryAgentID,
            "sessionKey": normalized,
        ]) { [weak self] ok, payload, error in
            guard let self else { return }
            self.isStartingNewConversation = false
            self.beginFreshSession()

            guard ok else {
                let message = error?["message"]?.stringValue ?? "알 수 없는 오류"
                self.chatStatus = message.contains("nova.memory")
                    ? "새 대화를 시작했습니다. 다만 맥 미니에 nova-memory 플러그인이 없어 기억으로 남기지 못했습니다."
                    : "새 대화를 시작했습니다. 다만 기억으로 남기지 못했습니다: \(message)"
                self.diagLog("session.capture 실패 — \(message)")
                return
            }

            let path = payload?["path"]?.stringValue ?? "(경로 불명)"
            let count = payload?["messageCount"]?.intValue ?? 0
            self.chatStatus = "\(count)마디를 \(path)로 남기고 새 대화를 시작했습니다."
            self.diagLog("session.capture 성공 — \(path) (\(count)마디)")

            // 방금 만든 기억이 목록에 보이도록 새로고침한다.
            self.loadMemories()
        }
    }

    /// 화면과 세션을 새 대화로 돌린다. 저장 성공 여부와 무관하게 이 부분은 항상 돈다.
    private func beginFreshSession() {
        messages.removeAll()
        draft = ""
        // 세션 키를 새로 만든다. 같은 키를 계속 쓰면 전사가 한없이 길어지고,
        // 다음 capture가 예전 대화까지 다시 담는다.
        //
        // ⚠️ 초 단위 타임스탬프는 충돌한다. 나눈 말이 없으면 capture를 건너뛰고
        // 바로 여기로 오기 때문에, 같은 초에 "새 대화"를 두 번 누르면
        // **두 대화가 같은 세션 키를 쓰게 된다.** 밀리초에 짧은 난수를 덧붙인다.
        // (시각을 앞에 두는 건 전사를 눈으로 훑을 때 순서가 보이게 하려는 것이다.)
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let salt = String(UUID().uuidString.prefix(8)).lowercased()
        let key = "main-\(stamp)-\(salt)"
        sessionKey = key
        client.switchSession(to: key)
        diagLog("새 대화 세션 = \(key)")
    }

    /// 편집한 내용을 맥 미니에 쓴다.
    ///
    /// 루트 파일은 기본 게이트웨이의 `agents.files.set`, `memory/` 아래는
    /// `nova-memory` 플러그인의 `nova.memory.save`를 쓴다. 기본 게이트웨이는
    /// 루트 여덟 개 이름만 받기 때문이다.
    func saveMemoryDraft() {
        guard let index = selectedMemoryIndex else { return }
        let item = memories[index]
        let text = memoryDraft
        memoryStatus = "저장하는 중입니다…"

        let method = item.isRootFile ? "agents.files.set" : "nova.memory.save"
        let params: [String: Any] = item.isRootFile
            ? ["agentId": memoryAgentID, "name": item.name, "content": text]
            : ["agentId": memoryAgentID, "path": item.path, "content": text]

        client.call(method: method, params: params) { [weak self] ok, payload, error in
            guard let self else { return }
            guard ok else {
                let message = error?["message"]?.stringValue ?? "알 수 없는 오류"
                // 플러그인이 안 붙어 있으면 메서드 자체가 없다. 그걸 구분해서 알려준다.
                self.memoryStatus = message.contains("nova.memory")
                    ? "맥 미니에 nova-memory 플러그인이 없습니다. plugins/nova-memory/README.md 참고."
                    : "저장하지 못했습니다: \(message)"
                return
            }
            if let index = self.memories.firstIndex(where: { $0.id == item.id }) {
                self.memories[index].applyContent(text)
                // 루트는 payload.file.size, 플러그인은 payload.size로 준다.
                self.memories[index].sizeBytes = payload?["file"]?["size"]?.intValue
                    ?? payload?["size"]?.intValue ?? text.utf8.count
                self.memories[index].updatedAt = Date()
            }
            self.memoryStatus = "맥 미니에 저장했습니다."
        }
    }

    /// 기억 하나를 지운다.
    ///
    /// 기본은 **휴지통**이다 (`memory/.trash/`로 옮긴다). 잘못 지운 기억을 되살릴 길을
    /// 남겨두려는 것이고, 플러그인 쪽에서 `hard: true`를 줘야 실제로 지운다.
    /// 루트 `MEMORY.md`는 지우지 않는다 — 세션 부트스트랩이 그 파일을 읽는다.
    func deleteSelectedMemory() {
        guard let index = selectedMemoryIndex else { return }
        let item = memories[index]
        guard item.isDeletable else {
            memoryStatus = "\(item.name)은 기억들의 색인이라 지우지 않습니다. 내용을 고치세요."
            return
        }
        memoryStatus = "\(item.name)을(를) 휴지통으로 옮기는 중입니다…"

        client.call(method: "nova.memory.delete", params: [
            "agentId": memoryAgentID,
            "path": item.path,
        ]) { [weak self] ok, payload, error in
            guard let self else { return }
            guard ok else {
                let message = error?["message"]?.stringValue ?? "알 수 없는 오류"
                self.memoryStatus = message.contains("nova.memory")
                    ? "맥 미니에 nova-memory 플러그인이 없습니다. plugins/nova-memory/README.md 참고."
                    : "지우지 못했습니다: \(message)"
                return
            }
            self.memories.removeAll { $0.id == item.id }
            self.selectedMemoryID = nil
            let trashed = payload?["trashPath"]?.stringValue
            self.memoryStatus = trashed.map { "휴지통으로 옮겼습니다 (\($0))." }
                ?? "지웠습니다."
            self.diagLog("기억 삭제 \(item.path) → \(payload?["removed"]?.stringValue ?? "?")")
            self.syncMemorySelection()
        }
    }

    // MARK: - 이벤트

    private func recordEvent(name: String, payload: JSONValue) {
        let line = EventLine(name: name, payload: payload.compactDescription)
        eventLog.append(line)
        if eventLog.count > 300 { eventLog.removeFirst(eventLog.count - 300) }

        // 조작/실행 계열 이벤트는 화면·조작 탭의 액션 로그에도 쌓는다.
        if name.contains("exec") || name.contains("tool") || name.hasPrefix("node") || name.hasPrefix("device") {
            actionLog.append(line)
            if actionLog.count > 150 { actionLog.removeFirst(actionLog.count - 150) }
        }
    }
}
