import SwiftUI

struct ChatView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if let status = app.chatStatus {
                statusBar(status)
            }
            Divider()
            composer
        }
        .navigationSubtitle(app.isConnected ? "게이트웨이 연결됨" : "오프라인")
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if let error = app.lastError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                newConversationButton
            }
        }
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if app.messages.isEmpty {
                        emptyState
                    }
                    ForEach(app.messages) { message in
                        MessageRow(message: message)
                            .id(message.id)
                    }
                }
                .padding(20)
            }
            .onChange(of: app.messages) { _, messages in
                if let last = messages.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    /// 지금 대화를 기억으로 남기고 새로 시작한다.
    ///
    /// 이 버튼이 **단기 기억이 생기는 유일한 방아쇠**다. openclaw의 훅은 `/reset`에만
    /// 걸리는데 앱에 그 권한(`operator.admin`)이 없다 — 하드윈 21번. 안 누르면
    /// 대화가 아무리 쌓여도 기억으로 남지 않고, 새벽 정리(dreaming)가 처리할 것도 없다.
    private var newConversationButton: some View {
        Button {
            app.startNewConversation()
        } label: {
            if app.isStartingNewConversation {
                ProgressView().controlSize(.small)
            } else {
                Label("새 대화", systemImage: "square.and.pencil")
            }
        }
        .disabled(app.isStartingNewConversation)
        .help("지금까지의 대화를 기억으로 남기고 새 대화를 시작합니다")
    }

    /// 기억으로 남았는지 아닌지를 알린다. 조용히 실패하면 사용자가 알 방법이 없다.
    private func statusBar(_ status: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button {
                app.chatStatus = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("무엇이든 시켜보세요")
                .font(.title3.weight(.semibold))
            Text("예: \"어제 읽던 논문 3개 요약해서 아이패드로 보내줘\"")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 24)
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("메시지를 입력하세요", text: $app.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.secondary.opacity(0.25))
                )
                .onSubmit { app.sendDraft() }
                // 기억으로 남기는 중에는 입력도 막는다. 그 사이에 보낸 말은
                // 닫히는 중인 옛 세션으로 들어가고 화면에서는 사라진 것처럼 보인다.
                .disabled(app.isStartingNewConversation)

            Button {
                app.sendDraft()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
            }
            .buttonStyle(.plain)
            .disabled(
                app.isStartingNewConversation
                    || app.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(14)
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 80) }

            VStack(alignment: .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .foregroundStyle(message.role == .user ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(background)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                Text(message.date, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
            }

            if message.role != .user { Spacer(minLength: 80) }
        }
    }

    private var background: some ShapeStyle {
        switch message.role {
        case .user:
            return AnyShapeStyle(Color.accentColor)
        case .assistant:
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
        case .system:
            return AnyShapeStyle(Color.yellow.opacity(0.15))
        }
    }
}
