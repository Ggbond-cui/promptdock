import PromptDockCore
import SwiftUI

struct PromptPanelView: View {
    @ObservedObject var model: PanelModel
    var onActivate: (PanelCommand) -> Void

    @FocusState private var searchFocused: Bool

    private var isActionMode: Bool { model.mode != .prompts }
    private var showsResult: Bool { isActionMode && model.phase != .choosing }

    var body: some View {
        VStack(spacing: 0) {
            if showsResult { resultHeader } else { searchField }
            if let notice = model.notice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.bottom, 8)
            }
            if isActionMode && !showsResult { selectionBar }
            Divider()
            if showsResult {
                resultBody
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
    }

    // MARK: - 选择阶段

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: isActionMode ? "wand.and.stars" : "magnifyingglass").foregroundStyle(.secondary)
            TextField(isActionMode ? "选择要执行的动作…" : "搜索提示词…", text: $model.query)
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
            Text("选中 \(text.count) 字").font(.caption.weight(.medium))
            Text(oneLine).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16).padding(.bottom, 8)
    }

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.results.enumerated()), id: \.element.prompt.id) { index, item in
                        row(item.prompt, selected: index == model.selection)
                            .id(item.prompt.id)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { model.selection = index; onActivate(.paste) }
                            .onTapGesture { model.selection = index }
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

    private func row(_ prompt: Prompt, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(prompt.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
            if !prompt.keywords.isEmpty {
                Text(prompt.keywords.joined(separator: " · "))
                    .font(.caption).foregroundStyle(selected ? Color.white.opacity(0.85) : .secondary).lineLimit(1)
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
                Label("完成", systemImage: "checkmark.circle").foregroundStyle(.green)
            case .failed:
                Label("失败", systemImage: "xmark.octagon").foregroundStyle(.red)
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

    // MARK: - 底栏

    private var footer: some View {
        HStack {
            Text(footerLeft).foregroundStyle(.secondary)
            Spacer()
            Text(footerHints).foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var footerLeft: String {
        showsResult ? "\(model.output.count) 字" : "\(model.results.count) 条"
    }

    private var footerHints: String {
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
