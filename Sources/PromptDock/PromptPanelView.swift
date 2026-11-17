import PromptDockCore
import AppKit
import SwiftUI

struct PromptPanelView: View {
    @ObservedObject var model: PanelModel
    var onActivate: (PanelCommand) -> Void
    /// 面板内新增表单保存：参数为（名称、关键词、内容），返回 nil 成功，否则为表单内显示的错误信息。
    var onAddPrompt: (String, [String], String) -> String? = { _, _, _ in nil }
    /// 编辑表单保存：参数为（打开表单时的原条目、名称、关键词、内容），返回 nil 成功。
    /// id 不随改名变化（使用统计按 id 关联）；原条目用于检测编辑期间的外部修改。
    var onUpdatePrompt: (Prompt, String, [String], String) -> String? = { _, _, _, _ in nil }
    /// 删除条目：返回 nil 成功。
    var onDeletePrompt: (String) -> String? = { _ in nil }
    /// ✨ 直接用大模型跑该条（输入=剪贴板文本，spec 8.1）。
    var onRunPrompt: (Prompt) -> Void = { _ in }
    /// 表单内「生成关键词」：从内容文本提炼搜索关键词，回调返回（空数组=失败）。
    var onGenerateKeywords: (String, @escaping ([String]) -> Void) -> Void = { _, _ in }
    /// 结果页/生成中点击返回箭头：由外部取消进行中的请求，模型状态由 backToChoosing 处理。
    var onBack: () -> Void = {}
    /// 🔊 朗读/停止朗读：参数为要读的文本（动作面板读选中原文，结果页读模型输出）。
    var onToggleSpeech: (String) -> Void = { _ in }
    /// ⭐ 收藏到 Obsidian 词汇表：（原文、模型解释、音标释义，回调 nil=成功/否则错误信息）。
    /// 异步：收藏时先用模型把解释提炼成精简要点。
    var onFavorite: (String, String, PhoneticInfo?, @escaping (String?) -> Void) -> Void = { _, _, _, _ in }

    @FocusState private var searchFocused: Bool
    @FocusState private var addTitleFocused: Bool

    // 新增/编辑表单共用的输入状态
    @State private var addTitle = ""
    @State private var addKeywords = ""
    @State private var addContent = ""
    @State private var addError: String?
    @State private var generatingKeywords = false
    /// 关键词生成请求的序号：表单关闭或重开后递增，迟到的旧结果不回填。
    @State private var keywordRequest = 0
    /// 上一次行点击（时间、条目 id），用于自定义双击检测（单击立即选中不延迟）。
    @State private var lastRowClick: (date: Date, id: String)?

    private var isActionMode: Bool { model.mode != .prompts }
    /// 结果阶段：⌥⇧Space 动作执行中/完成/失败，或 ⌥Space 面板 ✨ 跑模型中。
    private var showsResult: Bool {
        (isActionMode || model.runningPrompt != nil) && model.phase != .choosing
    }
    private var isEditing: Bool { model.editingPrompt != nil }

    var body: some View {
        VStack(spacing: 0) {
            if showsResult { resultHeader }
            else if model.isFormActive { formHeader }
            else { searchField }
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if let pending = model.pendingDelete, !model.isFormActive, !showsResult { deleteConfirmBar(pending) }
            if isActionMode && !showsResult && !model.isFormActive { selectionBar }
            Divider()
            if showsResult {
                resultBody
            } else if model.isFormActive {
                promptForm
            } else {
                HStack(spacing: 0) {
                    resultList.frame(width: 300)
                    Divider()
                    preview
                }
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 420)
        .background(VisualEffectBackground())
        .onChange(of: model.focusRequest, initial: true) { searchFocused = true }
        .onChange(of: model.addingPrompt) { keywordRequest += 1; generatingKeywords = false; formFocusChanged() }
        .onChange(of: model.editingPrompt) { keywordRequest += 1; generatingKeywords = false; formFocusChanged() }
    }

    private func formFocusChanged() {
        if model.isFormActive {
            addTitleFocused = true
        } else {
            searchFocused = true
        }
    }

    // MARK: - 选择阶段

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: isActionMode ? "wand.and.stars" : "magnifyingglass").foregroundStyle(.secondary)
            TextField(
                isActionMode
                    ? (model.isInputFallbackMode ? "输入要处理的内容…（↑↓ 或数字键选动作，↩ 执行）" : "选择要执行的动作…")
                    : "搜索提示词…",
                text: $model.query
            )
            .textFieldStyle(.plain)
            .font(.system(size: 20))
            .focused($searchFocused)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var selectionBar: some View {
        let text = model.selectionText
        let oneLine = text.replacingOccurrences(of: "\n", with: " ⏎ ")
        return HStack(spacing: 6) {
            Text("\(model.isInputFallbackMode ? "输入" : "选中") \(text.count) 字").font(.caption.weight(.medium))
            Text(oneLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            Spacer()
            phoneticText
            // 🔊 固定在最右端不随音标伸缩：听清不认识的词；配合回车执行「解释」类动作边听边看
            speechButton(text: text, help: model.isSpeaking ? "停止朗读" : "朗读\(model.isInputFallbackMode ? "输入的内容" : "选中的原文")")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    /// 音标 + 简要中文释义（模型异步返回），长在 🔊 左侧，喇叭钉在右端不动。
    @ViewBuilder private var phoneticText: some View {
        if let phonetic = model.phonetic {
            HStack(spacing: 4) {
                Text(phonetic.ipa)
                    .font(.system(.caption, design: .monospaced))
                if let gloss = phonetic.gloss {
                    Text(gloss).font(.caption)
                }
            }
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }

    /// 🔊/⏹ 组合按钮：朗读中全局显示 ⏹（无论读的是原文还是结果），点击即停。
    private func speechButton(text: String, help: String) -> some View {
        Button { onToggleSpeech(text) } label: {
            Image(systemName: model.isSpeaking ? "stop.circle" : "speaker.wave.2")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help(help)
    }

    /// ⭐ 收藏到 Obsidian 词汇表：提炼中转进度圈，成功后变实心黄星，防重复收藏。
    private var favoriteButton: some View {
        Button { favorite() } label: {
            if model.favoriting {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: model.favorited ? "star.fill" : "star")
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(model.favorited ? Color.yellow : .secondary)
        .disabled(model.favoriting
                  || model.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .help(model.favorited ? "已收藏到词汇表" : "收藏到 Obsidian 词汇表（自动提炼精简要点）")
    }

    private func favorite() {
        guard !model.favorited, !model.favoriting else { return }
        model.favoriting = true
        onFavorite(model.activeInput, model.output, model.phonetic) { error in
            model.favoriting = false
            if let error {
                model.notice = error
            } else {
                model.favorited = true
            }
        }
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.prompt.id) { index, item in
                        row(item.prompt, selected: index == model.selection, number: index < 9 ? index + 1 : nil)
                            .id(item.prompt.id)
                            .contentShape(Rectangle())
                            // 不用 onTapGesture(count:2)+onTapGesture 组合：SwiftUI 为区分单双击
                            // 会把单击延迟约 300ms（等双击窗口过期），手感明显卡顿（实测踩坑）。
                            // 改为单击立即选中，300ms 内二次点击同一条才视为双击粘贴。
                            .onTapGesture {
                                model.selection = index
                                let now = Date()
                                if let last = lastRowClick, now.timeIntervalSince(last.date) < NSEvent.doubleClickInterval,
                                   last.id == item.prompt.id {
                                    lastRowClick = nil
                                    onActivate(.paste)
                                } else {
                                    lastRowClick = (date: now, id: item.prompt.id)
                                }
                            }
                            .contextMenu {
                                // 编辑/删除只对提示词面板开放；动作面板的条目仍在设置窗口维护
                                if !isActionMode {
                                    Button("编辑…") { beginEdit(item.prompt) }
                                    Divider()
                                    Button("删除…", role: .destructive) { model.pendingDelete = item.prompt }
                                }
                            }
                    }
                }
                .padding(6)
            }
            .onChange(of: model.selection) {
                if let id = model.selected?.prompt.id { proxy.scrollTo(id) }
            }
            .overlay {
                if model.results.isEmpty {
                    Text(emptyText).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                }
            }
        }
    }

    private var emptyText: String {
        if !model.query.isEmpty { return isActionMode ? "没有匹配的动作" : "没有匹配的提示词" }
        return isActionMode ? "还没有动作\n在 prompts.yaml 中添加 type: action 的条目" : "还没有提示词"
    }

    private func row(_ prompt: Prompt, selected: Bool, number: Int?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                // 数字角标：提示可按数字键直选；搜索中数字是输入内容，角标隐藏
                if let number, model.query.isEmpty, model.phase == .choosing, !model.isFormActive {
                    Text("\(number)")
                        .font(.caption2.monospaced().weight(.medium))
                        .foregroundStyle(selected ? AnyShapeStyle(Color.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
                        .frame(width: 14)
                }
                Text(prompt.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            }
            HStack(spacing: 6) {
                if !prompt.keywords.isEmpty {
                    Text(prompt.keywords.joined(separator: " · "))
                        .font(.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary).lineLimit(1)
                }
                // ✨：剪贴板内容 + 该提示词直接跑大模型，结果在面板内显示（spec 8.1）。
                // 动作面板的输入是选区，不显示，避免和剪贴板输入混淆
                if !isActionMode {
                    Button { onRunPrompt(prompt) } label: {
                        Image(systemName: "wand.and.stars")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary)
                    .help("用大模型处理剪贴板内容")
                }
            }
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
    }

    private var preview: some View {
        ScrollView {
            Text(model.selected?.prompt.content ?? "")
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(14)
        }
    }

    // MARK: - 结果阶段

    private var resultHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars").foregroundStyle(.secondary)
            Text(model.activePrompt?.title ?? "").font(.system(size: 18, weight: .medium))
            Text(model.activeTargetLabel).font(.caption).foregroundStyle(.secondary)
            Spacer()
            switch model.phase {
            case .running:
                ProgressView().controlSize(.small)
                Text(model.isThinking && model.output.isEmpty ? "思考中…" : "生成中…").foregroundStyle(.secondary)
            case .done:
                // 淡色底胶囊徽章：裸绿字在浅灰面板上太素（用户反馈），加底色和描边更像状态标签
                Label("完成", systemImage: "checkmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.12)))
                    .overlay(Capsule().strokeBorder(Color.green.opacity(0.3)))
            case .failed:
                Label("失败", systemImage: "xmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.red.opacity(0.1)))
                    .overlay(Capsule().strokeBorder(Color.red.opacity(0.3)))
            case .choosing:
                EmptyView()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var resultBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if case .failed(let message) = model.phase {
                        Text(message).foregroundStyle(.red).padding(.bottom, 8)
                    }
                    Text(model.output)
                        .font(.system(size: 14))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(16)
            }
            .onChange(of: model.output) { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }

    // MARK: - 新增 / 编辑表单

    private var formHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: isEditing ? "pencil.circle" : "plus.circle").foregroundStyle(.secondary)
            Text(isEditing ? "编辑提示词" : "新增提示词").font(.system(size: 18, weight: .medium))
            Text("保存后写入 prompts.yaml，立即生效").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    private var promptForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("名称").font(.caption).foregroundStyle(.secondary)
                TextField("例如：周报骨架", text: $addTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($addTitleFocused)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("关键词（可选，逗号或空格分隔，用于搜索）").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    // ✨：从「内容」提炼关键词（走默认模型服务）
                    Button(action: generateKeywords) {
                        if generatingKeywords {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "wand.and.stars").font(.caption)
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(generatingKeywords)
                    .help("用大模型从内容提炼关键词")
                }
                TextField("例如：周报 weekly 汇报", text: $addKeywords)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("内容").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $addContent)
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.3)))
            }
            HStack(spacing: 12) {
                if let addError {
                    Text(addError).font(.callout).foregroundStyle(.red).lineLimit(2)
                }
                Spacer()
                Button("取消") {
                    addError = nil
                    model.dismissForm()
                }
                Button("保存") { saveForm() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(addTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || addContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    /// 右键「编辑…」：回填条目并切到表单。
    private func beginEdit(_ prompt: Prompt) {
        addTitle = prompt.title
        addKeywords = prompt.keywords.joined(separator: " ")
        addContent = prompt.content
        addError = nil
        model.editingPrompt = prompt
    }

    /// 右键「删除…」后的确认条：确认才写盘（写前备份 .bak），失败时以面板 notice 提示。
    private func deleteConfirmBar(_ prompt: Prompt) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "trash").foregroundStyle(.red)
            Text("删除「\(prompt.title)」？").lineLimit(1)
            Spacer()
            Button("取消") { model.pendingDelete = nil }
            Button("删除", role: .destructive) {
                model.pendingDelete = nil
                if let error = onDeletePrompt(prompt.id) { model.notice = error }
            }
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private func generateKeywords() {
        let content = addContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            addError = "先填「内容」，再生成关键词"
            return
        }
        generatingKeywords = true
        keywordRequest += 1
        let request = keywordRequest
        onGenerateKeywords(content) { keywords in
            guard request == keywordRequest else { return }   // 表单已关闭或重开，丢弃旧结果
            generatingKeywords = false
            if keywords.isEmpty {
                addError = "关键词生成失败：模型服务不可用或返回为空，稍后再试"
            } else {
                addError = nil
                addKeywords = keywords.joined(separator: " ")
            }
        }
    }

    private func saveForm() {
        let title = addTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = addContent.trimmingCharacters(in: .whitespacesAndNewlines)
        // 逗号（中英文）、顿号、空白都可以作分隔符
        let keywords = addKeywords.split(whereSeparator: { ",，、 ".contains($0) }).map(String.init)
        let error: String?
        if let editing = model.editingPrompt {
            error = onUpdatePrompt(editing, title, keywords, content)
        } else {
            error = onAddPrompt(title, keywords, content)
        }
        if let error {
            addError = error
            return
        }
        addTitle = ""; addKeywords = ""; addContent = ""; addError = nil
        model.dismissForm()
    }

    // MARK: - 底栏

    private var footer: some View {
        HStack {
            Text(footerLeft).foregroundStyle(.secondary)
            Spacer()
            if showsResult {
                favoriteButton
                    .padding(.trailing, 12)
                phoneticText
                    .padding(.trailing, 8)
                speechButton(text: model.output, help: model.isSpeaking ? "停止朗读" : "朗读结果")
                    .padding(.trailing, 12)
            }
            if showsBackButton {
                Button { onBack() } label: {
                    Image(systemName: "chevron.backward.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(model.phase == .running ? "取消并返回动作列表" : "返回动作列表")
                .padding(.trailing, 12)
            }
            if showsAddButton {
                Button {
                    addTitle = ""; addKeywords = ""; addContent = ""; addError = nil
                    model.addingPrompt = true
                } label: {
                    Image(systemName: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("新增提示词")
                .padding(.trailing, 12)
            }
            Text(footerHints).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    /// 只在 Prompt 面板的选择阶段显示新增入口；动作模式、结果阶段与表单激活时不显示。
    private var showsAddButton: Bool {
        model.mode == .prompts && !showsResult && !model.isFormActive
    }

    /// 动作模式或 ✨ 跑模型时（选完之后的所有阶段）都显示返回箭头：生成中点击取消请求，
    /// 完成/失败点击回到列表，不关面板。
    private var showsBackButton: Bool {
        (isActionMode || model.runningPrompt != nil) && model.phase != .choosing
    }

    private var footerLeft: String {
        showsResult ? "\(model.output.count) 字" : "\(model.results.count) 条"
    }

    private var footerHints: String {
        if model.isFormActive { return "⌘↩ 保存    esc 取消" }
        guard isActionMode else { return "↩ 粘贴    ⌘↩ 复制    esc 关闭" }
        switch model.phase {
        case .choosing: return "↩ 执行    esc 关闭"
        case .running: return "esc 取消"
        case .failed: return "↩ 重试    esc 关闭"
        case .done:
            switch model.activeOutputMode {
            case .replace: return "↩ 替换原文    ⌘↩ 复制    esc 关闭"
            case .copy: return "已复制到剪贴板    esc 关闭"
            case .show: return "↩ 复制    esc 关闭"
            }
        }
    }
}

/// 毛玻璃背景，跟随系统深浅色。
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
