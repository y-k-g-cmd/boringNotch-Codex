import CoreImage
//
//  Constants.swift
//  boringNotch
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI
import AppKit
import AVFoundation

extension KeyboardShortcuts.Name {
    static let lookupDictionary = Self("lookupDictionary", default: .init(.d, modifiers: [.control, .option]))
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
}

// MARK: - Dictionary presentation
struct NotchDictionaryEntry: Equatable {
    let word: String
    let phonetic: String
    let definition: String

    var compactDefinition: String {
        // Keep source meanings; never generate translations for an unfamiliar format.
        let pattern = #"\b(intransitive verb|transitive verb|phrasal verb|noun|adjective|adverb|verb|pronoun|preposition|conjunction|interjection|determiner)\b"#
        guard let range = definition.range(of: pattern, options: .regularExpression) else { return definition }
        let part = String(definition[range])
        let labels = ["noun": "n.", "adjective": "adj.", "adverb": "adv.", "verb": "v.",
                      "intransitive verb": "vi.", "transitive verb": "vt.", "phrasal verb": "v.",
                      "pronoun": "pron.", "preposition": "prep.", "conjunction": "conj.",
                      "interjection": "interj.", "determiner": "det."]
        var body = String(definition[range.upperBound...])
        if let next = body.range(of: #"\b[A-Z]\.\s+(?:noun|adjective|adverb|verb|transitive verb|intransitive verb)\b"#, options: .regularExpression) {
            body = String(body[..<next.lowerBound])
        }
        let senses = body.components(separatedBy: CharacterSet(charactersIn: "①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳"))
        var meanings: [String] = []
        for sense in senses {
            // Usage labels, English explanations and romanized pronunciations are not the gloss.
            let cleaned = sense.replacingOccurrences(of: #"‹[^›]*›|〈[^〉]*〉"#, with: "", options: .regularExpression)
            if let chinese = cleaned.range(of: #"[\p{Han}]+(?:[、，][\p{Han}]+)*"#, options: .regularExpression) {
                let meaning = String(cleaned[chinese])
                if !meanings.contains(meaning) { meanings.append(meaning) }
            }
            if meanings.count == 3 { break }
        }
        guard !meanings.isEmpty else { return definition }
        return (labels[part] ?? part) + " " + meanings.joined(separator: "；")
    }

    func displayedPhonetic(accent: String) -> String {
        // Split only at explicit dialect labels, preserving variant pronunciations.
        guard let regex = try? NSRegularExpression(pattern: #"\b(BrE|AmE)\s+"#) else { return phonetic }
        let source = phonetic as NSString
        let matches = regex.matches(in: phonetic, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return phonetic }
        let wanted = accent == "en-US" ? "AmE" : "BrE"
        let index = matches.firstIndex { source.substring(with: $0.range(at: 1)) == wanted } ?? 0
        let start = matches[index].range.location
        let end = index + 1 < matches.count ? matches[index + 1].range.location : source.length
        return source.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;，；")))
    }

    static func parse(word: String, raw: String) -> Self {
        let pieces = raw.components(separatedBy: "|")
        let hasPhonetic = pieces.count >= 3 && pieces[1].count < 240
        let phonetic = hasPhonetic ? pieces[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        var body = hasPhonetic ? pieces.dropFirst(2).joined(separator: "|") : raw
        if !hasPhonetic && body.lowercased().hasPrefix(word.lowercased()) {
            body = String(body.dropFirst(word.count))
        }
        // Apple dictionary entries are plain text. Drop marked examples only;
        // keep unrecognized formats readable instead of guessing their meaning.
        body = body.replacingOccurrences(of: "▸[^①②③④⑤⑥⑦⑧⑨⑩⑪⑫⑬⑭⑮⑯⑰⑱⑲⑳]*", with: "", options: .regularExpression)
        body = body.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        body = body.replacingOccurrences(of: " ?([①②③④⑤⑥⑦⑧⑨⑩])", with: "\n$1", options: .regularExpression)
        return Self(word: word, phonetic: phonetic, definition: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

@MainActor
final class NotchDictionary: ObservableObject {
    static let shared = NotchDictionary()
    @Published var visible = false
    @Published var sequence = 0
    @Published var query = ""
    @Published var entry: NotchDictionaryEntry?
    @Published var busy = false
    @Published var message = ""
    @Published var needsSelectionPermission = false
    var screenID: String?
    private var generation = UUID()
    private let speaker = AVSpeechSynthesizer()

    func trigger() {
        let token = UUID(); generation = token
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let point = NSEvent.mouseLocation
        screenID = NSScreen.screens.first(where: { $0.frame.contains(point) })?.displayUUID
            ?? NSScreen.main?.displayUUID
        Task {
            // Read before showing/focusing any field so the source app retains its selection.
            let (selection, authorized) = await XPCHelperClient.shared.selectedDictionaryText(pid: pid)
            guard generation == token else { return }
            query = selection; entry = nil; message = ""; busy = false
            needsSelectionPermission = !authorized
            visible = true; sequence += 1
            if !selection.isEmpty { lookup() }
        }
    }

    func lookup() {
        let word = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = UUID(); generation = token
        speaker.stopSpeaking(at: .immediate)
        guard !word.isEmpty else { entry = nil; busy = false; message = "请输入要查询的单词或短语"; return }
        guard word.count <= 200 else { entry = nil; busy = false; message = "请输入不超过 200 字的单词或短语"; return }
        query = word; busy = true; entry = nil; message = ""
        Task {
            do {
                let raw = try await XPCHelperClient.shared.dictionaryDefinition(word)
                guard generation == token, visible else { return }
                busy = false
                guard let raw, !raw.isEmpty else {
                    message = "未找到释义，请检查拼写或在系统词典中下载所需词库"; return
                }
                entry = NotchDictionaryEntry.parse(word: word, raw: raw)
            } catch {
                guard generation == token, visible else { return }
                busy = false; message = "词典服务暂不可用，请重试"
            }
        }
    }

    func dismiss() {
        generation = UUID(); visible = false; busy = false
        speaker.stopSpeaking(at: .immediate)
    }

    func speak(_ text: String) {
        guard !text.isEmpty else { return }
        speaker.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        let identifier = UserDefaults.standard.string(forKey: "dictionaryVoice") ?? ""
        let hasChinese = text.unicodeScalars.contains { (0x3400...0x9fff).contains($0.value) }
        utterance.voice = AVSpeechSynthesisVoice(identifier: identifier)
            ?? AVSpeechSynthesisVoice(language: hasChinese ? "zh-CN" : (UserDefaults.standard.string(forKey: "dictionaryAccent") == "en-US" ? "en-US" : "en-GB"))
        let speed = UserDefaults.standard.object(forKey: "dictionarySpeechSpeed") as? Double ?? 1
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * Float(min(1.5, max(0.5, speed.isFinite ? speed : 1)))
        speaker.speak(utterance)
    }
}

private struct DictionaryInputHost: NSViewRepresentable {
    final class Host: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? CodexInputWindow)?.codexInputEnabled = true
            NSApp.activate(ignoringOtherApps: true)
            window?.makeKey()
        }
    }
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {}
    static func dismantleNSView(_ view: Host, coordinator: ()) {
        (view.window as? CodexInputWindow)?.codexInputEnabled = false
        if view.window?.isKeyWindow == true { view.window?.resignKey() }
    }
}

struct NotchDictionaryCard: View {
    @ObservedObject var model = NotchDictionary.shared
    @AppStorage("dictionaryAccent") private var accent = "en-GB"
    @FocusState private var focused: Bool
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let entry = model.entry {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.word).font(.system(size: 21, weight: .semibold))
                            .lineLimit(1).truncationMode(.tail)
                        if !entry.phonetic.isEmpty {
                            Text(entry.displayedPhonetic(accent: accent))
                                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    iconButton("speaker.wave.2.fill", help: "朗读单词") { model.speak(entry.word) }
                    iconButton("magnifyingglass", help: "查询") { model.entry = nil; focused = true }
                } else {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                    TextField("", text: $model.query,
                              prompt: Text("输入单词或短语").foregroundStyle(.white.opacity(0.4)))
                        .textFieldStyle(.plain).font(.system(size: 17, weight: .medium))
                        .foregroundColor(.white).tint(.white)
                        .focused($focused).onSubmit { model.lookup() }
                }
                iconButton("xmark", help: "关闭", action: close)
            }
            if model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在查询…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            } else if let entry = model.entry {
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                Text(entry.compactDefinition).font(.system(size: 14)).lineSpacing(4)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(2).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                HStack(spacing: 8) {
                    Text(model.message.isEmpty ? String(localized: "回车查询") : String(localized: String.LocalizationValue(model.message)))
                        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.45)).lineLimit(2)
                    Spacer(minLength: 0)
                    if model.needsSelectionPermission && model.message.isEmpty {
                        Button("授权读取选中文字") { MediaKeyInterceptor.shared.requestAccessibilityAuthorization() }
                            .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white).environment(\.colorScheme, .dark)
        .background(DictionaryInputHost().frame(width: 0, height: 0))
        .onAppear { DispatchQueue.main.async { focused = model.query.isEmpty } }
        .onChange(of: model.sequence) { focused = model.query.isEmpty }
        .onExitCommand(perform: close)
    }

    private func iconButton(_ symbol: String, help: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.09), in: Circle())
                .contentShape(Circle())
        }.buttonStyle(.plain).help(help).accessibilityLabel(help)
    }
}

struct DictionaryPreferences: View {
    @AppStorage("dictionaryVoice") private var voice = ""
    @AppStorage("dictionaryAccent") private var accent = "en-GB"
    @AppStorage("dictionarySpeechSpeed") private var speed = 1.0
    private var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted { ($0.language, $0.name) < ($1.language, $1.name) }
    }
    var body: some View {
        Section {
            KeyboardShortcuts.Recorder("查词快捷键", name: .lookupDictionary)
            Picker("默认英语音标", selection: $accent) {
                Text("英式英语").tag("en-GB")
                Text("美式英语").tag("en-US")
            }
            Text("自动朗读跟随音标选择；指定朗读声音优先。词库缺少所选音标时显示已有音标。")
                .font(.caption).foregroundStyle(.secondary)
            Picker("朗读声音", selection: $voice) {
                Text("自动选择语言").tag("")
                ForEach(voices, id: \.identifier) { item in
                    Text("\(item.name) · \(item.language)").tag(item.identifier)
                }
            }
            Slider(value: $speed, in: 0.5...1.5, step: 0.05) {
                Text("朗读速度：\(speed, specifier: "%.2f")×")
            }
            HStack {
                Button("试听") { NotchDictionary.shared.speak("example") }
                Button("打开系统词典") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Dictionary.app")) }
            }
            Text("优先查询选中文字；未选中文字时输入查询。使用本机已下载词库，读音由系统语音合成。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("系统词典") }
    }
}

// MARK: - Phone page turner
@MainActor
final class BooksRemoteModel: ObservableObject {
    static let shared = BooksRemoteModel()
    struct Status: Decodable {
        let state: String
        var message: String = ""
        var addresses: [String] = []
        var pin: String = ""
        var token: String = ""
    }
    @Published var status = Status(state: "stopped")
    @Published var pending = false
    @Published var address = ""
    private var heartbeat: Timer?
    private var generation = UUID()
    var active: Bool { status.state == "ready" || status.state == "starting" }

    func perform(_ action: String) {
        guard !pending else { return }
        pending = true
        let request = generation
        Task {
            defer { pending = false }
            do {
                let data = try await XPCHelperClient.shared.booksRemote(action)
                guard generation == request else { return }
                status = try JSONDecoder().decode(Status.self, from: data)
                if !status.addresses.contains(address) { address = status.addresses.first ?? "" }
                if active && heartbeat == nil {
                    let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
                        Task { @MainActor in self?.perform("renew") }
                    }
                    heartbeat = timer
                    RunLoop.main.add(timer, forMode: .common)
                } else if !active { heartbeat?.invalidate(); heartbeat = nil }
            } catch {
                status = Status(state: "error", message: "翻页服务连接中断，请重新启动")
                heartbeat?.invalidate(); heartbeat = nil
            }
        }
    }
    var qrImage: NSImage? {
        guard status.state == "ready", !address.isEmpty, !status.token.isEmpty,
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data((address + "/#" + status.token).utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}

struct BooksRemotePreferences: View {
    @ObservedObject private var model = BooksRemoteModel.shared
    var body: some View {
        Section {
            HStack {
                Label("手机翻页器", systemImage: "iphone.and.arrow.forward")
                Spacer()
                if model.pending { ProgressView().controlSize(.small) }
                Button(model.active ? "停止服务" : "启动服务") {
                    model.perform(model.active ? "stop" : "start")
                }.disabled(model.pending)
            }
            if model.status.state == "ready" {
                HStack(alignment: .top, spacing: 18) {
                    if let qr = model.qrImage {
                        Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                            .frame(width: 142, height: 142).padding(10).background(.white, in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityLabel("手机扫码连接")
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("手机扫码连接").font(.headline)
                        Text("或在 Safari 打开地址，输入配对码。").font(.caption).foregroundStyle(.secondary)
                        Picker("连接地址", selection: $model.address) {
                            ForEach(model.status.addresses, id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                        HStack {
                            Text(model.status.pin).font(.system(size: 23, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                            Button("复制地址") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(model.address, forType: .string)
                            }
                        }
                        Text("停止或重启服务后，旧配对失效。").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 6)
            } else if model.status.state == "starting" {
                Text("正在启动局域网服务…").foregroundStyle(.secondary)
            } else if !model.status.message.isEmpty {
                Text(LocalizedStringKey(model.status.message)).foregroundStyle(.orange)
            }
            HStack {
                Button("打开图书") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Books.app")) }
                Button("授权辅助功能") { MediaKeyInterceptor.shared.requestAccessibilityAuthorization() }
            }
            Text("在图书中打开 EPUB 正文，保持 Mac 唤醒。手机与 Mac 连接同一可信 Wi-Fi；翻页时会切到图书。")
                .font(.caption).foregroundStyle(.secondary)
            Text("仅在手动启动时开放局域网服务。二维码等同控制凭证，请勿分享；退出应用后服务停止。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("阅读遥控") }
    }
}
