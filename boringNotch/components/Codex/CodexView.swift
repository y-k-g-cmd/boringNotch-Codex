import SwiftUI

struct CodexView: View {
    @ObservedObject var monitor: CodexMonitor = .shared
    @State private var requestSessionID: String?
    @State private var requestSelectedAutomatically = false
    @State private var visibleTaskID: String?
    @State private var taskScrollIndex: Double = 0
    @AppStorage("codexTaskNavigation") private var codexTaskNavigation = "region"

    private var requestSignature: String {
        monitor.sessions.map { session in
            let requests = session.requests.map { String($0.rawData.hashValue) }.joined()
            let lineage = session.isSubagent ? ":child:" : ":root:"
            return session.id + lineage + requests
        }.joined(separator: ";")
    }
    private var requestSession: CodexSession? {
        monitor.sessions.first { $0.id == requestSessionID && !$0.requests.isEmpty }
    }

    var body: some View {
        GeometryReader { geometry in
            content(cardHeight: max(0, geometry.size.height - 32))
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .transition(.opacity)
        .onAppear { selectPendingRequest() }
        .onChange(of: requestSignature) { selectPendingRequest() }
    }

    private func content(cardHeight: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(monitor.connected ? Color.green : Color.gray).frame(width: 5, height: 5)
                Text(monitor.connectionLabel).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
                Spacer()
                Button { monitor.reconnect() } label: {
                    Label(monitor.connected ? "重新连接" : "连接 Codex", systemImage: "arrow.triangle.2.circlepath")
                }
                .help("使用已授权目录重新连接 Codex")
                Button { monitor.markCompletedRead() } label: {
                    Label("标记已读", systemImage: "checkmark.circle")
                }
                .disabled(!monitor.hasUnreadCompleted)
                .help("将已完成任务的提醒标为已读")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 6))
            .controlSize(.small)
            .font(.system(size: 10, weight: .medium))
            .frame(height: 24)
            if let session = requestSession {
                CodexRequestPanel(session: session, monitor: monitor) { requestSessionID = nil }
            } else if monitor.sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right").font(.title2)
                    Text("在 Codex 中打开会话后，这里会显示任务状态")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    Text(monitor.remindersEnabled ? "任务完成或需要你处理时，刘海会自动展开" : "自动提醒已关闭，可在设置 → Codex 中开启")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    VStack(spacing: 4) {
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(monitor.sessions) { session in
                                Button { monitor.open(session) } label: {
                                    VStack(alignment: .leading, spacing: 0) {
                                        VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Image(systemName: "chevron.left.forwardslash.chevron.right")
                                            Text("Codex").fontWeight(.medium)
                                            Spacer()
                                            if monitor.unread.contains(session.id) {
                                                Circle().fill(tint(session)).frame(width: 5, height: 5)
                                            }
                                        }
                                        .font(.system(size: compactCards(cardHeight) ? 9 : 10)).foregroundStyle(.secondary)
                                        Text(session.title).font(.system(size: 12, weight: .medium, design: .rounded))
                                            .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                                        Text(session.summary.isEmpty ? "点击打开会话" : session.summary)
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(compactCards(cardHeight) ? 1 : 2)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                        Spacer(minLength: 6)
                                        Label(session.activity.label, systemImage: symbol(session))
                                            .font(.system(size: compactCards(cardHeight) ? 9 : 10, weight: .medium)).foregroundStyle(tint(session))
                                            .padding(.horizontal, 6).padding(.vertical, 2)
                                            .background(tint(session).opacity(0.1), in: Capsule())
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, compactCards(cardHeight) ? 8 : 10)
                                    .frame(width: 180, height: max(0, cardHeight - (monitor.sessions.count > 3 ? 22 : 0)))
                                    .clipped()
                                    .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12)
                                            .stroke(session.activity.needsAttention ? Color.orange.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1)
                                    }
                                }
                                .overlay {
                                    CodexCompletionBorder(request: monitor.completionHighlights[session.id])
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    if !session.requests.isEmpty {
                                        Button("处理请求") { requestSelectedAutomatically = false; requestSessionID = session.id }
                                            .buttonStyle(.bordered).controlSize(.mini)
                                            .font(.system(size: 9)).padding(6)
                                            .disabled(!monitor.connected)
                                    }
                                }
                                .id(session.id)
                                .buttonStyle(.plain)
                                .opacity(monitor.connected ? 1 : 0.5)
                                .accessibilityLabel("\(session.title)，\(session.activity.label)，在 Codex 中打开")
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollPosition(id: $visibleTaskID, anchor: .leading)
                    .scrollDisabled(codexTaskNavigation == "pages")
                    .scrollIndicators(.never)
                    .onChange(of: visibleTaskID) {
                        if let index = monitor.sessions.firstIndex(where: { $0.id == visibleTaskID }) {
                            taskScrollIndex = Double(min(index, max(0, monitor.sessions.count - 3)))
                        }
                    }
                    .onAppear { revealCompletion(using: proxy) }
                    .onChange(of: monitor.completionFocus) { revealCompletion(using: proxy) }
                    if monitor.sessions.count > 3 {
                        HStack(spacing: 8) {
                            Button { browseTask(-1, using: proxy) } label: { Image(systemName: "chevron.left") }
                                .disabled(taskScrollIndex <= 0).help("上一个任务")
                            Slider(value: Binding(get: { taskScrollIndex }, set: { value in
                                taskScrollIndex = value
                                let index = min(max(0, monitor.sessions.count - 3), max(0, Int(value.rounded())))
                                proxy.scrollTo(monitor.sessions[index].id, anchor: .leading)
                            }), in: 0...Double(max(1, monitor.sessions.count - 3)), step: 1)
                                .controlSize(.mini).tint(.gray).accessibilityLabel("浏览 Codex 任务")
                            Button { browseTask(1, using: proxy) } label: { Image(systemName: "chevron.right") }
                                .disabled(taskScrollIndex >= Double(max(0, monitor.sessions.count - 3))).help("下一个任务")
                            Text("\(monitor.sessions.count) 个任务").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.bordered).controlSize(.mini).font(.system(size: 9))
                        .frame(height: 18)
                        .pageSwipe(enabled: codexTaskNavigation == "region") { step in browseTask(step, using: proxy) }
                    }
                    }
                    .taskSwipeRegion()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func compactCards(_ height: CGFloat) -> Bool {
        height - (monitor.sessions.count > 3 ? 22 : 0) < 100
    }

    private func browseTask(_ step: Int, using proxy: ScrollViewProxy) {
        let index = min(max(0, monitor.sessions.count - 3), max(0, Int(taskScrollIndex.rounded()) + step))
        guard monitor.sessions.indices.contains(index) else { return }
        taskScrollIndex = Double(index)
        withAnimation(.smooth) { proxy.scrollTo(monitor.sessions[index].id, anchor: .leading) }
    }

    private func selectPendingRequest() {
        if let current = requestSession,
           !requestSelectedAutomatically || !current.isSubagent { return }
        requestSessionID = monitor.sessions.first { !$0.isSubagent && $0.activity.needsAttention && !$0.requests.isEmpty }?.id
        requestSelectedAutomatically = requestSessionID != nil
    }

    private func revealCompletion(using proxy: ScrollViewProxy) {
        guard let focus = monitor.completionFocus,
              let highlight = monitor.completionHighlights[focus.sessionID], highlight.expiresAt > Date() else { return }
        proxy.scrollTo(focus.sessionID, anchor: .center)
    }

    private func tint(_ session: CodexSession) -> Color {
        if !monitor.connected { return .gray }
        switch session.activity {
        case .needsApproval, .needsInput: return .orange
        case .completed: return .green
        case .failed: return .red
        default: return .gray
        }
    }

    private func symbol(_ session: CodexSession) -> String {
        switch session.activity {
        case .needsApproval: return "exclamationmark.shield"
        case .needsInput: return "questionmark.bubble"
        case .completed: return "checkmark.circle"
        case .running: return "ellipsis.circle"
        case .failed: return "exclamationmark.circle"
        default: return "circle"
        }
    }
}

private struct CodexRequestPanel: View {
    let session: CodexSession
    @ObservedObject var monitor: CodexMonitor
    let onBack: () -> Void
    @State private var selectedID = ""
    private var request: CodexPendingRequest { session.requests.first { $0.id == selectedID } ?? session.requests[0] }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Button(action: onBack) { Label("返回任务", systemImage: "chevron.left") }
                Button { monitor.open(session) } label: {
                    Label(session.title, systemImage: "arrow.up.forward.app").lineLimit(1)
                }.help("在 Codex 中打开此任务")
                Spacer(minLength: 0)
                if session.requests.count > 1 {
                    Picker("请求", selection: $selectedID) {
                        ForEach(session.requests) { r in Text(r.title).tag(r.id) }
                    }.frame(maxWidth: 150).labelsHidden()
                }
            }
            .buttonStyle(.bordered).controlSize(.mini).font(.system(size: 10))
            CodexRequestEditor(session: session, request: request, monitor: monitor)
                .id(request.rawData)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct CodexRequestEditor: View {
    let session: CodexSession
    let request: CodexPendingRequest
    @ObservedObject var monitor: CodexMonitor
    @State private var answers: [String: String] = [:]
    @State private var custom: [String: String] = [:]
    @FocusState private var editingQuestion: String?
    private var busy: Bool { monitor.submissions[session.id]?.busy == true }
    private var reply: CodexReply {
        .answers(Dictionary(uniqueKeysWithValues: request.questions.map { q in
            let text = custom[q.id]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (q.id, [text.isEmpty ? (answers[q.id] ?? "") : text])
        }))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 6) {
                    if request.questions.isEmpty { Text(request.title).fontWeight(.semibold).foregroundStyle(.orange) }
                    if !request.details.isEmpty {
                        Text(request.details).textSelection(.enabled)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(request.questions) { q in
                        HStack(alignment: .top, spacing: 10) {
                            Text(q.title).fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Group {
                                if q.isSecret {
                                    SecureField("自定义回答", text: binding(for: q.id))
                                } else {
                                    TextField("自定义回答", text: binding(for: q.id))
                                }
                            }
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .frame(width: 175)
                            .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(editingQuestion == q.id ? Color.orange : Color.white.opacity(0.16), lineWidth: 1))
                            .focused($editingQuestion, equals: q.id)
                        }
                        if q.options.count <= 4 && q.options.allSatisfy({ $0.description.isEmpty && $0.label.count <= 16 }) {
                            HStack(spacing: 6) {
                                ForEach(q.options.indices, id: \.self) { index in optionButton(q, q.options[index]) }
                            }
                        } else {
                            ForEach(q.options.indices, id: \.self) { index in optionButton(q, q.options[index]) }
                        }
                    }
                    if !request.supportsReply {
                        Text("此请求类型请在 Codex 中处理").foregroundStyle(.secondary)
                    }
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            .disabled(busy || !monitor.connected)
            HStack(spacing: 6) {
                if request.supportsReply {
                    if request.method == "item/tool/requestUserInput" || request.method == CodexPendingRequest.asyncMethod {
                        Button { send(reply) } label: { Label("提交回答", systemImage: "arrow.up.circle.fill") }
                            .buttonStyle(CodexPrimaryActionStyle())
                            .disabled((try? request.response(reply)) == nil)
                    } else {
                        Button { send(request.method == "item/permissions/requestApproval" ? .permissions(true) : .decision("accept")) } label: { Label("允许本次", systemImage: "checkmark.shield") }
                            .buttonStyle(CodexPrimaryActionStyle())
                            .disabled((try? request.response(request.method == "item/permissions/requestApproval" ? .permissions(true) : .decision("accept"))) == nil)
                        Button("拒绝") { send(request.method == "item/permissions/requestApproval" ? .permissions(false) : .decision("decline")) }
                    }
                }
                Button("打开原任务") { monitor.open(session) }
                if let status = monitor.submissions[session.id] {
                    if status.busy { ProgressView().controlSize(.mini) }
                    Text(status.message).foregroundStyle(status.busy ? Color.secondary : .orange).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .buttonStyle(.bordered).controlSize(.mini)
            .disabled(busy || !monitor.connected)
        }
        .font(.system(size: 10))
        .background(CodexInputHost(enabled: !request.questions.isEmpty))
        .onChange(of: editingQuestion) {
            guard editingQuestion != nil else { return }
            NSApp.windows.first {
                $0.frame.contains(NSEvent.mouseLocation) && ($0 as? CodexInputWindow)?.codexInputEnabled == true
            }?.makeKey()
        }
    }
    private func binding(for id: String) -> Binding<String> {
        Binding(get: { custom[id] ?? "" }, set: { custom[id] = $0 })
    }
    private func optionButton(_ question: CodexQuestion, _ option: CodexQuestion.Option) -> some View {
        let selected = answers[question.id] == option.label && (custom[question.id] ?? "").isEmpty
        return Button {
            answers[question.id] = option.label
            custom[question.id] = ""
        } label: {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.orange : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).fontWeight(.medium)
                    if !option.description.isEmpty { Text(option.description).foregroundStyle(.secondary) }
                }
                Spacer(minLength: 0)
            }
            .padding(8).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Color.orange.opacity(0.14) : Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Color.orange.opacity(0.9) : Color.white.opacity(0.1), lineWidth: selected ? 1.5 : 0.5))
        }.buttonStyle(.plain)
    }
    private func send(_ reply: CodexReply) { monitor.submit(reply, request: request, session: session) }
}

private struct CodexPrimaryActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .padding(.horizontal, 9).padding(.vertical, 3)
            .foregroundStyle(enabled ? Color.black : Color.white.opacity(0.35))
            .background(enabled ? Color.orange.opacity(configuration.isPressed ? 0.75 : 1) : Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
    }
}

protocol CodexInputWindow: AnyObject { var codexInputEnabled: Bool { get set } }
private struct CodexInputHost: NSViewRepresentable {
    let enabled: Bool
    final class Host: NSView {
        var enabled = false { didSet { configure() } }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); configure() }
        func configure() { (window as? CodexInputWindow)?.codexInputEnabled = enabled }
    }
    func makeNSView(context: Context) -> Host { let view = Host(); view.enabled = enabled; return view }
    func updateNSView(_ view: Host, context: Context) { view.enabled = enabled }
    static func dismantleNSView(_ view: Host, coordinator: ()) {
        (view.window as? CodexInputWindow)?.codexInputEnabled = false
        if view.window?.isKeyWindow == true { view.window?.resignKey() }
    }
}

/// Three gentle green pulses. Re-entering after expiry cannot replay an old completion.
private struct CodexCompletionBorder: View {
    let request: CodexCompletionHighlight?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var flashing = false
    @State private var bright = false

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.green.opacity(flashing ? (bright ? 1 : 0.18) : 0), lineWidth: 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task(id: request?.id) {
                flashing = false
                bright = false
                guard let request, request.expiresAt > Date() else { return }
                if reduceMotion {
                    flashing = true; bright = true
                    try? await Task.sleep(for: .seconds(max(0, request.expiresAt.timeIntervalSinceNow)))
                    guard !Task.isCancelled else { return }
                    flashing = false
                    return
                }
                for _ in 0..<3 {
                    guard !Task.isCancelled else { return }
                    if request.expiresAt <= Date() { break }
                    flashing = true
                    withAnimation(.easeInOut(duration: 0.28)) { bright = true }
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.28)) { bright = false }
                    try? await Task.sleep(for: .milliseconds(450))
                }
                guard !Task.isCancelled else { return }
                flashing = false
            }
    }
}
