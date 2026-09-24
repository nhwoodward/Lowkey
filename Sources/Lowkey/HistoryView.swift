import AppKit
import AVFoundation
import SwiftUI

extension HistoryItem: Identifiable {}

struct HistorySection: Identifiable {
    let id: Date
    let title: String
    let items: [HistoryItem]
}

struct ReplacementRequest: Equatable {
    let itemID: UUID
    let heard: String
    let inDetail: Bool
}

enum HistoryFormat {
    static func dayTitle(for day: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) { return "Yesterday" }
        var style = Date.FormatStyle.dateTime.weekday(.wide).month(.wide).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) { style = style.year() }
        return day.formatted(style)
    }

    static func caption(for item: HistoryItem, includingDate: Bool = false) -> String {
        let when = includingDate
            ? item.createdAt.formatted(date: .long, time: .shortened)
            : item.createdAt.formatted(date: .omitted, time: .shortened)
        var parts = [when, duration(item.duration)]
        if let language = languageName(item.language) { parts.append(language) }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let whole = seconds.isFinite ? Int(min(max(seconds, 1), 86_400).rounded()) : 1
        return Duration.seconds(whole).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    // English is the default, and "auto" says nothing about the words.
    static func languageName(_ code: String) -> String? {
        guard !code.isEmpty, code != "en", code != "auto" else { return nil }
        return Config.languages.first(where: { $0.0 == code })?.1
            ?? Locale.current.localizedString(forLanguageCode: code)
    }
}

@MainActor
final class HistoryModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var items: [HistoryItem] = []
    @Published private(set) var sections: [HistorySection] = []
    @Published private(set) var playable: Set<UUID> = []
    @Published var query = "" {
        didSet { if query != oldValue { regroup() } }
    }
    @Published var selection: UUID?
    @Published private(set) var hoveredID: UUID?
    @Published private(set) var playingID: UUID?
    @Published private(set) var copiedID: UUID?
    @Published var detail: HistoryItem?
    @Published var replacement: ReplacementRequest?
    @Published var playbackError: String?
    @Published var hotkeyTitle: String
    @Published private(set) var focusRequest = 0

    var onPaste: ((HistoryItem) -> Void)?
    var pasteTargetName: (() -> String?)?

    private let source: () -> [HistoryItem]
    private var visible: [HistoryItem] = []
    private var player: AVAudioPlayer?
    private var copyReset: Task<Void, Never>?

    init(hotkeyTitle: String, source: @escaping () -> [HistoryItem]) {
        self.hotkeyTitle = hotkeyTitle
        self.source = source
        super.init()
        reload()
    }

    var searchText: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    var selectedItem: HistoryItem? { item(selection) }

    var pasteTitle: String {
        if let name = pasteTargetName?(), !name.isEmpty { return "Paste into \(name)" }
        return "Paste"
    }

    func item(_ id: UUID?) -> HistoryItem? {
        guard let id else { return nil }
        return visible.first { $0.id == id }
    }

    func reload() {
        items = source()
        playable = Set(items.compactMap { item in
            item.audioURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? item.id : nil }
        })
        if let playingID, !items.contains(where: { $0.id == playingID }) { stopPlayback() }
        regroup()
    }

    private func regroup() {
        let needle = searchText
        let matches = needle.isEmpty ? items : items.filter { $0.text.localizedStandardContains(needle) }
        let calendar = Calendar.current
        let now = Date()
        let days = Dictionary(grouping: matches) { calendar.startOfDay(for: $0.createdAt) }
        sections = days.keys.sorted(by: >).map { day in
            HistorySection(
                id: day,
                title: HistoryFormat.dayTitle(for: day, now: now, calendar: calendar),
                items: (days[day] ?? []).sorted { $0.createdAt > $1.createdAt }
            )
        }
        visible = sections.flatMap(\.items)
        if let selection, !visible.contains(where: { $0.id == selection }) { self.selection = nil }
    }

    func hover(_ id: UUID, _ inside: Bool) {
        if inside {
            if hoveredID != id { hoveredID = id }
        } else if hoveredID == id {
            hoveredID = nil
        }
    }

    func copy(_ item: HistoryItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(item.text, forType: .string)
        flashCopied(item.id)
    }

    func flashCopied(_ id: UUID) {
        copiedID = id
        copyReset?.cancel()
        copyReset = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.copiedID = nil
        }
    }

    func paste(_ item: HistoryItem) { onPaste?(item) }

    func openDetail(_ id: UUID?) {
        guard let item = item(id) else { return }
        selection = item.id
        detail = item
    }

    func delete(_ item: HistoryItem) {
        // Keep keyboard deletion flowing by selecting the neighbor, as Mail does.
        if selection == item.id, let index = visible.firstIndex(where: { $0.id == item.id }) {
            let next = index + 1 < visible.count ? visible[index + 1] : (index > 0 ? visible[index - 1] : nil)
            selection = next?.id
        }
        if playingID == item.id { stopPlayback() }
        if hoveredID == item.id { hoveredID = nil }
        items.removeAll { $0.id == item.id }
        regroup()
        HistoryStore.shared.delete(id: item.id)
    }

    func togglePlayback(_ item: HistoryItem) {
        if playingID == item.id {
            stopPlayback()
            return
        }
        stopPlayback()
        guard playable.contains(item.id), let url = item.audioURL else { return }
        do {
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            guard next.play() else { return }
            player = next
            playingID = item.id
        } catch {
            playbackError = error.localizedDescription
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        playingID = nil
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        finished(ObjectIdentifier(player))
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        finished(ObjectIdentifier(player))
    }

    private nonisolated func finished(_ id: ObjectIdentifier) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let player = self.player, ObjectIdentifier(player) == id else { return }
            self.player = nil
            self.playingID = nil
        }
    }

    func beginReplacement(for item: HistoryItem, heard: String, inDetail: Bool) {
        replacement = ReplacementRequest(itemID: item.id, heard: heard, inDetail: inDetail)
    }

    func addReplacement(heard: String, writeAs: String) {
        let heard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let writeAs = writeAs.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !heard.isEmpty else { return }
        VocabularyStore.shared.add(heard: heard, writeAs: writeAs)
        replacement = nil
    }

    func focusList(selectingFirst: Bool) {
        if selectingFirst, selection == nil { selection = visible.first?.id }
        focusRequest += 1
    }

    func windowClosed() {
        stopPlayback()
        hoveredID = nil
        replacement = nil
    }

    #if DEBUG
    func stageDemo(_ demo: String) {
        let first = visible.first
        switch demo {
        case "select":
            selection = first?.id
            hoveredID = visible.dropFirst().first?.id
            playingID = visible.dropFirst(2).first?.id
        case "detail", "replace":
            detail = first
        case "replace-row":
            selection = first?.id
            if let first { beginReplacement(for: first, heard: "", inDetail: false) }
        default:
            break
        }
    }
    #endif
}

struct HistoryView: View {
    @ObservedObject var model: HistoryModel
    @FocusState private var listFocused: Bool

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.items) { item in
                        HistoryRow(
                            item: item,
                            model: model,
                            isSelected: model.selection == item.id,
                            isHovered: model.hoveredID == item.id,
                            isPlaying: model.playingID == item.id,
                            isCopied: model.copiedID == item.id,
                            canPlay: model.playable.contains(item.id),
                            isReplacing: model.replacement.map { $0.itemID == item.id && !$0.inDetail } ?? false
                        )
                    }
                }
            }
        }
        .listStyle(.inset)
        .focused($listFocused)
        .contextMenu(forSelectionType: UUID.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            model.openDetail(ids.first)
        }
        .onCopyCommand {
            guard let item = model.selectedItem else { return [] }
            model.flashCopied(item.id)
            return [NSItemProvider(object: item.text as NSString)]
        }
        .onDeleteCommand {
            if let item = model.selectedItem { model.delete(item) }
        }
        .onKeyPress(.space) {
            guard let item = model.selectedItem else { return .ignored }
            model.togglePlayback(item)
            return .handled
        }
        .overlay { emptyState }
        .onAppear { listFocused = true }
        .onChange(of: model.focusRequest) { listFocused = true }
        .sheet(item: $model.detail) { item in
            HistoryDetail(item: item, model: model)
        }
        .alert("Can't Play Recording", isPresented: playbackErrorShown, presenting: model.playbackError) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.items.isEmpty {
            ContentUnavailableView {
                Label("No Dictations Yet", systemImage: "waveform")
            } description: {
                Text("Hold \(model.hotkeyTitle) and speak. Your dictations appear here.")
            }
        } else if model.sections.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        }
    }

    @ViewBuilder private func menu(for ids: Set<UUID>) -> some View {
        if ids.count == 1, let item = model.item(ids.first) {
            Button("Copy") { model.copy(item) }
            Button(model.pasteTitle) { model.paste(item) }
            Button(model.playingID == item.id ? "Stop" : "Play") { model.togglePlayback(item) }
                .disabled(!model.playable.contains(item.id))
            Divider()
            Button("Add Replacement…") { model.beginReplacement(for: item, heard: "", inDetail: false) }
            Divider()
            Button("Delete") { model.delete(item) }
        }
    }

    private var playbackErrorShown: Binding<Bool> {
        Binding(get: { model.playbackError != nil }, set: { if !$0 { model.playbackError = nil } })
    }
}

private struct HistoryRow: View {
    let item: HistoryItem
    let model: HistoryModel
    let isSelected: Bool
    let isHovered: Bool
    let isPlaying: Bool
    let isCopied: Bool
    let canPlay: Bool
    let isReplacing: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                Text(HistoryFormat.caption(for: item))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityActions {
                Button("Copy") { model.copy(item) }
                if canPlay { Button(isPlaying ? "Stop" : "Play") { model.togglePlayback(item) } }
                Button("Delete") { model.delete(item) }
            }

            // Space stays reserved so the transcript never reflows on hover.
            HStack(spacing: 0) {
                RowIconButton(
                    symbol: isCopied ? "checkmark" : "doc.on.doc",
                    label: "Copy",
                    help: "Copy",
                    visible: isHovered || isSelected || isCopied
                ) { model.copy(item) }
                RowIconButton(
                    symbol: isPlaying ? "stop.fill" : "play.fill",
                    label: isPlaying ? "Stop" : "Play",
                    help: canPlay ? (isPlaying ? "Stop" : "Play") : "No recording",
                    visible: isHovered || isSelected || isPlaying
                ) { model.togglePlayback(item) }
                .disabled(!canPlay)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { model.hover(item.id, $0) }
        .popover(isPresented: replacing, arrowEdge: .bottom) {
            ReplacementForm(heard: "") { model.addReplacement(heard: $0, writeAs: $1) }
        }
    }

    private var replacing: Binding<Bool> {
        Binding(get: { isReplacing }, set: { if !$0, isReplacing { model.replacement = nil } })
    }
}

private struct RowIconButton: View {
    let symbol: String
    let label: String
    let help: String
    let visible: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(isEnabled ? .secondary : .quaternary)
        .help(help)
        .accessibilityLabel(label)
        .opacity(visible ? 1 : 0)
        .allowsHitTesting(visible)
    }
}

private struct HistoryDetail: View {
    let item: HistoryItem
    @ObservedObject var model: HistoryModel
    @Environment(\.dismiss) private var dismiss
    @State private var transcript = TranscriptHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TranscriptView(text: item.text, handle: transcript) { dismiss() }
                .frame(minWidth: 460, idealWidth: 540, maxWidth: .infinity,
                       minHeight: 220, idealHeight: 280, maxHeight: .infinity)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Text(HistoryFormat.caption(for: item, includingDate: true))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("Add Replacement…") {
                    model.beginReplacement(for: item, heard: transcript.selectedText, inDetail: true)
                }
                .popover(isPresented: replacing, arrowEdge: .bottom) {
                    ReplacementForm(heard: model.replacement?.heard ?? "") {
                        model.addReplacement(heard: $0, writeAs: $1)
                    }
                }
                Spacer()
                Button("Copy") { model.copy(item) }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onExitCommand { dismiss() }
    }

    private var replacing: Binding<Bool> {
        Binding(get: { model.replacement?.inDetail == true },
                set: { if !$0, model.replacement?.inDetail == true { model.replacement = nil } })
    }
}

private struct ReplacementForm: View {
    @State private var heard: String
    @State private var writeAs = ""
    @FocusState private var focus: Field?
    let onAdd: (String, String) -> Void

    private enum Field { case heard, writeAs }

    init(heard: String, onAdd: @escaping (String, String) -> Void) {
        _heard = State(initialValue: heard)
        self.onAdd = onAdd
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 14) {
            Form {
                TextField("Heard", text: $heard)
                    .focused($focus, equals: .heard)
                TextField("Write as", text: $writeAs)
                    .focused($focus, equals: .writeAs)
            }
            Button("Add") { onAdd(heard, writeAs) }
                .keyboardShortcut(.defaultAction)
                .disabled(heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { focus = heard.isEmpty ? .heard : .writeAs }
    }
}

// Lets the detail sheet read the transcript's current text selection on demand.
private final class TranscriptHandle {
    weak var textView: NSTextView?

    var selectedText: String {
        guard let textView else { return "" }
        let range = textView.selectedRange()
        guard range.location != NSNotFound, range.length > 0 else { return "" }
        return (textView.string as NSString).substring(with: range)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct TranscriptView: NSViewRepresentable {
    let text: String
    let handle: TranscriptHandle
    let onCancel: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let size = scroll.contentSize
        let textView = CancelableTextView(frame: NSRect(origin: .zero, size: size))
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(width: size.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 6, height: 10)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.string = text
        textView.font = .systemFont(ofSize: NSFont.systemFontSize)
        textView.textColor = .labelColor
        textView.onCancel = onCancel
        scroll.documentView = textView
        handle.textView = textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? CancelableTextView else { return }
        textView.onCancel = onCancel
        handle.textView = textView
        if textView.string != text { textView.string = text }
    }
}

// Read-only text views swallow Escape; the sheet should close instead.
private final class CancelableTextView: NSTextView {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        if let onCancel { onCancel() } else { super.cancelOperation(sender) }
    }
}
