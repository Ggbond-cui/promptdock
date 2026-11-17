import AppKit
import PromptDockCore
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let promptPanelHotkeyID: UInt32 = 1
    private static let actionPanelHotkeyID: UInt32 = 2
    /// 版本号以应用包 Info.plist 为准（构建时由 git tag 写入）。
    private static let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? PromptDockCore.version

    private var statusItem: NSStatusItem?
    private var state = LibraryState()
    private var usage: UsageStore?
    private let hotkeys = HotkeyManager()
    private let panel = PromptPanelController()
    private let settingsWindow = SettingsWindowController()
    private var watcher: FileWatcher?
    private var hotkeyErrors: [UInt32: String] = [:]
    private var registeredHotkeys: [UInt32: String] = [:]
    /// 进行中的模型调用；面板关闭时取消。
    private var actionTask: Task<Void, Never>?
    /// 执行动作时的目标应用（替换原文时粘贴回去）。
    private var actionTarget: NSRunningApplication?
    /// 最近一个处于前台的「其他」应用，粘贴目标。
    private var lastExternalApp: NSRunningApplication?

    // MARK: - 生命周期

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("启动 PromptDock \(Self.appVersion)")
        MainMenu.install()
        trackFrontmostApp()
        ensureConfigExists()
        openUsageStore()
        setupStatusItem()

        panel.onCommand = { [weak self] command in self?.handlePanelCommand(command) }
        panel.onClose = { [weak self] in self?.cancelAction() }
        settingsWindow.onSave = { [weak self] base, target in self?.saveLibrary(from: base, to: target) }

        reload()
        watcher = FileWatcher(file: Paths.configFile) { [weak self] in
            Log.info("检测到配置文件变化，重新加载")
            self?.reload()
        }

        if !PasteService.isTrusted {
            Log.info("未获得辅助功能权限，弹出系统授权提示")
            PasteService.requestTrust()
        }
    }

    /// promptdock://panel —— 便于脚本或其他工具调起面板。
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "promptdock" {
            if url.host == "panel" { showPanel() }
            if url.host == "settings" {
                let tab = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "tab" }?.value.flatMap(SettingsTab.init) ?? .general
                settingsWindow.show(library: state.library, tab: tab)
            }
        }
    }

    // MARK: - 配置

    private func ensureConfigExists() {
        let url = Paths.configFile
        let fm = FileManager.default
        let isSymlink = (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil
        guard !fm.fileExists(atPath: url.path), !isSymlink else { return }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let example = Bundle.main.url(forResource: "prompts.example", withExtension: "yaml") {
                try fm.copyItem(at: example, to: url)
            } else {
                try "version: 1\nprompts: []\n".write(to: url, atomically: true, encoding: .utf8)
            }
            Log.info("已生成示例配置：\(url.path)")
        } catch {
            Log.error("生成示例配置失败：\(error)")
        }
    }

    private func reload() {
        let result: Result<LoadResult, PromptLibraryError>
        do {
            let text = try String(contentsOf: Paths.configFile, encoding: .utf8)
            result = .success(try PromptLibraryParser.parse(text))
        } catch let error as PromptLibraryError {
            result = .failure(error)
        } catch {
            result = .failure(.unreadable(error.localizedDescription))
        }
        state.apply(result)

        if let summary = state.errorSummary {
            Log.error("配置加载失败，沿用上次结果：\(summary)")
        } else {
            Log.info("配置已加载：\(state.library.prompts.count) 条，警告 \(state.warnings.count) 条")
            state.warnings.forEach { Log.info("配置警告：\($0.message)") }
        }

        registerHotkeysIfChanged()
        panel.update(prompts: state.library.prompts)
        updateStatusIcon()
    }

    /// 把设置窗口或菜单的修改写回 prompts.yaml（spec 9.5）。成功返回 nil，失败返回给用户看的错误信息。
    @discardableResult
    private func saveLibrary(from base: PromptLibrary, to target: PromptLibrary) -> String? {
        // 配置文件是符号链接时写入链接指向的真实文件，不破坏链接
        let url = Paths.configFile.resolvingSymlinksInPath()
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let updated: String
            do {
                updated = try ConfigWriter.update(text, from: base, to: target)
            } catch let error as PromptLibraryError {
                return "配置文件当前有错误，请先修复后再保存：\(error)"
            }
            if updated != text {
                try text.write(to: url.appendingPathExtension("bak"), atomically: true, encoding: .utf8)
                try updated.write(to: url, atomically: true, encoding: .utf8)
                Log.info("已写入配置：默认服务 \(target.settings.llm.provider)，服务 \(target.settings.providers.count) 个，提示词 \(target.prompts.count) 条")
            }
        } catch let error as SettingsWriterError {
            return error.message
        } catch {
            Log.error("写入配置失败：\(error)")
            return "写入失败：\(error)"
        }
        for name in Set(base.settings.providers.keys).subtracting(target.settings.providers.keys).sorted() {
            KeychainStore.deleteAPIKey(provider: name)
            Log.info("服务 \(name) 已删除，同时清除其 API Key")
        }
        reload()
        return nil
    }

    private func registerHotkeysIfChanged() {
        let config = state.library.settings.hotkeys
        let entries: [(UInt32, String, () -> Void)] = [
            (Self.promptPanelHotkeyID, config.promptPanel, { [weak self] in self?.togglePanel() }),
            (Self.actionPanelHotkeyID, config.actionPanel, { [weak self] in self?.toggleActionPanel() }),
        ]
        for (id, text, action) in entries where registeredHotkeys[id] != text {
            do {
                let spec = try HotkeySpec.parse(text)
                hotkeyErrors[id] = hotkeys.register(id: id, spec: spec, action: action)
            } catch {
                hotkeys.unregister(id: id)
                hotkeyErrors[id] = "快捷键「\(text)」无效：\(error)"
            }
            registeredHotkeys[id] = text
            if let message = hotkeyErrors[id] { Log.error(message) } else { Log.info("已注册快捷键 \(text)") }
        }
    }

    private func openUsageStore() {
        do {
            let store = try UsageStore(path: Paths.usageDatabase.path)
            let removed = try store.purgeExpired()
            if removed > 0 { Log.info("清理过期使用记录 \(removed) 条") }
            usage = store
        } catch {
            Log.error("打开使用统计失败，排序将不考虑使用频率：\(error)")
        }
    }

    // MARK: - 面板

    private func togglePanel() {
        panel.isVisible ? panel.hide() : showPanel()
    }

    private func currentFrecency() -> [String: Double] {
        let now = Date()
        let since = now.addingTimeInterval(-Double(UsageStore.defaultRetentionDays) * 86_400)
        let events = (try? usage?.events(since: since)) ?? []
        return Frecency.scores(events: events, now: now)
    }

    private func showPanel() {
        var notices: [String] = []
        if state.error != nil { notices.append("配置文件有错误，当前使用上次加载成功的版本（详见菜单栏）") }
        if !PasteService.isTrusted { notices.append("未授予辅助功能权限：回车只会复制到剪贴板") }

        panel.show(mode: .prompts, prompts: state.library.prompts, frecency: currentFrecency(),
                   notice: notices.isEmpty ? nil : notices.joined(separator: "\n"))
    }

    private func toggleActionPanel() {
        if panel.isVisible { panel.hide(); return }
        Task { await showActionPanel() }
    }

    /// 先读取选区（此时焦点仍在原应用），再显示动作面板。
    private func showActionPanel() async {
        actionTarget = lastExternalApp
        var notices: [String] = []
        var selection = ""

        if PasteService.isTrusted {
            if let result = await SelectionService.read() {
                selection = result.text
                Log.info("读取选区：\(result.text.count) 字，来源 \(result.source.rawValue)，应用 \(actionTarget?.bundleIdentifier ?? "-")")
            } else {
                notices.append("未读取到选中文字：请先在应用中选中一段文字")
                Log.info("未读取到选区，应用 \(actionTarget?.bundleIdentifier ?? "-")")
            }
        } else {
            notices.append("需要辅助功能权限才能读取选中文字（菜单栏 → 辅助功能权限）")
        }
        let settings = state.library.settings
        if let provider = settings.providers[settings.llm.provider],
           provider.protocolType == .anthropic, !KeychainStore.hasAPIKey(provider: provider.name) {
            notices.append("默认服务「\(provider.name)」未设置 API Key：菜单栏 → API Key")
        }
        if state.error != nil { notices.append("配置文件有错误，当前使用上次加载成功的版本") }

        panel.show(mode: .actions(selection: selection), prompts: state.library.prompts,
                   frecency: currentFrecency(), notice: notices.isEmpty ? nil : notices.joined(separator: "\n"))
    }

    private func handlePanelCommand(_ command: PanelCommand) {
        let model = panel.model
        switch (model.mode, model.phase) {
        case (.prompts, _):
            guard let prompt = model.selected?.prompt else { return }
            panel.hide()
            performSnippet(command, prompt)
        case (.actions, .choosing):
            guard let prompt = model.selected?.prompt else { return }
            runAction(prompt)
        case (.actions, .running):
            break
        case (.actions, .failed):
            if command == .paste, let prompt = model.activePrompt { runAction(prompt) }
        case (.actions, .done):
            applyActionResult(command)
        }
    }

    private func performSnippet(_ command: PanelCommand, _ prompt: Prompt) {
        let rendered = SnippetTemplate.render(prompt.content)
        if command == .paste && PasteService.isTrusted {
            PasteService.paste(rendered.text, into: lastExternalApp, settings: state.library.settings.paste,
                               cursor: rendered.cursor)
            record(prompt, .paste)
        } else {
            PasteService.copy(rendered.text)
            Log.info("copy：\(prompt.id)")
            record(prompt, .copy)
        }
    }

    private func runAction(_ prompt: Prompt) {
        let model = panel.model
        let selection = model.selectionText
        guard !selection.isEmpty else {
            model.notice = "没有选中文字，无法执行。请关闭面板，选中文字后再按快捷键"
            return
        }

        let settings = state.library.settings
        let rendered = PromptRenderer.render(prompt, selection: selection)
        let target: LLMTarget
        let request: URLRequest
        do {
            target = try LLMTargetResolver.resolve(prompt: prompt, settings: settings)
            request = try LLMRequestBuilder.build(
                rendered, target: target,
                apiKey: KeychainStore.readAPIKey(provider: target.provider.name),
                defaultEffort: settings.llm.effort)
        } catch {
            // 请求发出前就失败（缺 Key、服务未定义）：切到结果区显示，避免只有一行小字像「没反应」
            let label = prompt.provider ?? settings.llm.provider
            model.beginAction(prompt, output: rendered.output, targetLabel: label)
            model.phase = .failed(error.localizedDescription
                + "\n\n可以在菜单栏 → API Key 中设置，或修改 prompts.yaml 中的 settings.llm.provider。")
            Log.error("动作未执行 \(prompt.id)：\(error.localizedDescription)")
            return
        }

        cancelAction()
        model.notice = nil
        model.beginAction(prompt, output: rendered.output, targetLabel: "\(target.provider.name) · \(target.model)")
        record(prompt, .action)

        let started = Date()
        Log.info("执行动作 \(prompt.id)：服务 \(target.provider.name)（\(target.provider.protocolType.rawValue)），模型 \(target.model)，输入 \(selection.count) 字")

        let proxy = settings.network.proxy
        let proto = target.provider.protocolType
        actionTask = Task { [weak self] in
            var stopReason: String?
            var firstTokenAt: Date?
            do {
                let stream = LLMClient.stream(request, protocol: proto) { LLMClient.sessionConfiguration(proxy: proxy) }
                for try await event in stream {
                    guard let self, !Task.isCancelled else { return }
                    switch event {
                    case .text(let text):
                        if firstTokenAt == nil { firstTokenAt = Date() }
                        self.panel.model.output += text
                    case .thinking:
                        if !self.panel.model.isThinking { self.panel.model.isThinking = true }
                    case .stop(let reason):
                        stopReason = reason
                    case .error(let type, let message):
                        throw LLMError("模型返回错误：\(message.isEmpty ? type : message)")
                    }
                }
                guard let self, !Task.isCancelled else { return }
                let elapsed = Date().timeIntervalSince(started)
                let ttft = firstTokenAt.map { String(format: "%.1fs", $0.timeIntervalSince(started)) } ?? "-"
                Log.info("动作完成 \(prompt.id)：stop_reason \(stopReason ?? "-")，首字 \(ttft)，总耗时 \(String(format: "%.1fs", elapsed))，输出 \(self.panel.model.output.count) 字")

                if stopReason == "refusal" {
                    self.panel.model.phase = .failed("模型拒绝处理该内容（refusal），结果不可用")
                } else if self.panel.model.output.isEmpty {
                    self.panel.model.phase = .failed("模型没有返回内容（stop_reason: \(stopReason ?? "-")）")
                } else {
                    if stopReason == "max_tokens" { self.panel.model.notice = "输出达到长度上限，结果可能不完整" }
                    self.panel.model.phase = .done
                    if rendered.output == .copy { PasteService.copy(self.cleanedOutput()) }
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                Log.error("动作失败 \(prompt.id)：\(error.localizedDescription)")
                self.panel.model.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func applyActionResult(_ command: PanelCommand) {
        let text = cleanedOutput()
        guard !text.isEmpty else { return }
        let mode = panel.model.activeOutputMode
        if command == .paste && mode == .replace && PasteService.isTrusted {
            panel.hide()
            PasteService.paste(text, into: actionTarget, settings: state.library.settings.paste)
            Log.info("已替换原文：\(text.count) 字")
        } else {
            PasteService.copy(text)
            panel.hide()
            Log.info("已复制结果：\(text.count) 字")
        }
    }

    /// 去掉模型输出首尾的空白与换行。
    private func cleanedOutput() -> String {
        panel.model.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancelAction() {
        actionTask?.cancel()
        actionTask = nil
    }

    private func record(_ prompt: Prompt, _ kind: UsageKind) {
        do { try usage?.record(promptID: prompt.id, kind: kind) }
        catch { Log.error("记录使用失败：\(error)") }
    }

    private func trackFrontmostApp() {
        let ownID = Bundle.main.bundleIdentifier
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != ownID {
            lastExternalApp = app
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated {
                if let app, app.bundleIdentifier != ownID { self?.lastExternalApp = app }
            }
        }
    }

    // MARK: - 菜单栏

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        updateStatusIcon()
    }

    private func updateStatusIcon() {
        let symbol = state.error == nil && hotkeyErrors.isEmpty ? "text.quote" : "exclamationmark.triangle"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "PromptDock")
        image?.isTemplate = true
        statusItem?.button?.image = image
    }

    /// 每次打开菜单时重建，保证权限、开机自启等状态是最新的。
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let hotkeys = state.library.settings.hotkeys
        let promptKey = (try? HotkeySpec.parse(hotkeys.promptPanel))?.displayString ?? ""
        let actionKey = (try? HotkeySpec.parse(hotkeys.actionPanel))?.displayString ?? ""
        menu.addItem(item("打开 Prompt 面板    \(promptKey)", #selector(menuShowPanel)))
        menu.addItem(disabled("选中文字动作    \(actionKey)"))
        menu.addItem(.separator())

        if let summary = state.errorSummary {
            menu.addItem(disabled("⚠️ 配置错误：\(summary)"))
        }
        for message in hotkeyErrors.values.sorted() {
            menu.addItem(disabled("⚠️ \(message)"))
        }
        if !state.warnings.isEmpty {
            let warningsItem = NSMenuItem(title: "配置警告 \(state.warnings.count) 条", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            state.warnings.forEach { sub.addItem(disabled($0.message)) }
            warningsItem.submenu = sub
            menu.addItem(warningsItem)
        }
        menu.addItem(disabled("已加载 \(state.library.prompts.count) 条提示词"))
        menu.addItem(.separator())

        menu.addItem(item("设置…", #selector(menuSettings)))
        menu.addItem(item("编辑提示词…", #selector(menuEdit)))
        menu.addItem(item("重新加载", #selector(menuReload)))
        menu.addItem(item("打开数据目录", #selector(menuReveal)))
        menu.addItem(.separator())

        menu.addItem(item(
            PasteService.isTrusted ? "辅助功能权限：已授权" : "辅助功能权限：未授权（点击设置）",
            #selector(menuAccessibility)
        ))
        let settings = state.library.settings
        let defaultItem = NSMenuItem(title: "默认服务：\(settings.llm.provider)", action: nil, keyEquivalent: "")
        let defaultMenu = NSMenu()
        for name in settings.providers.keys.sorted() {
            guard let provider = settings.providers[name] else { continue }
            let entry = item("\(name)（\(provider.model)）", #selector(menuSetDefaultProvider(_:)))
            entry.representedObject = name
            entry.state = name == settings.llm.provider ? .on : .off
            defaultMenu.addItem(entry)
        }
        defaultItem.submenu = defaultMenu
        menu.addItem(defaultItem)
        let keysItem = NSMenuItem(title: "API Key", action: nil, keyEquivalent: "")
        let keysMenu = NSMenu()
        for name in settings.providers.keys.sorted() {
            guard let provider = settings.providers[name] else { continue }
            let hasKey = KeychainStore.hasAPIKey(provider: name)
            let status = hasKey ? "已设置" : (provider.protocolType == .openai ? "未设置（本地服务可不填）" : "未设置")
            let isDefault = name == settings.llm.provider ? " · 默认" : ""
            let entry = item("\(name)（\(provider.protocolType.rawValue) · \(provider.model)\(isDefault)）：\(status)", #selector(menuAPIKey(_:)))
            entry.representedObject = name
            keysMenu.addItem(entry)
        }
        keysItem.submenu = keysMenu
        menu.addItem(keysItem)
        let login = item("开机自启", #selector(menuToggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        menu.addItem(disabled("PromptDock \(Self.appVersion)"))
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func menuShowPanel() { showPanel() }

    @objc private func menuSettings() { settingsWindow.show(library: state.library) }

    @objc private func menuSetDefaultProvider(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String, name != state.library.settings.llm.provider else { return }
        var target = state.library
        target.settings.llm.provider = name
        if let failure = saveLibrary(from: state.library, to: target) {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "切换默认服务失败"
            alert.informativeText = failure
            alert.runModal()
        }
    }

    @objc private func menuEdit() { NSWorkspace.shared.open(Paths.configFile) }

    @objc private func menuReload() { reload() }

    @objc private func menuReveal() {
        NSWorkspace.shared.activateFileViewerSelecting([Paths.configFile])
    }

    @objc private func menuAccessibility() {
        PasteService.requestTrust()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func menuAPIKey(_ sender: NSMenuItem) {
        guard let provider = sender.representedObject as? String else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "设置「\(provider)」的 API Key"
        alert.informativeText = "Key 保存在系统钥匙串中，不会写入配置文件或日志。留空并保存表示清除。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        field.placeholderString = "粘贴 API Key"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty {
            KeychainStore.deleteAPIKey(provider: provider)
            Log.info("已清除 \(provider) 的 API Key")
        } else {
            let status = KeychainStore.saveAPIKey(key, provider: provider)
            if status == errSecSuccess { Log.info("已保存 \(provider) 的 API Key") }
            else { Log.error("保存 \(provider) 的 API Key 失败：OSStatus \(status)") }
        }
    }

    @objc private func menuToggleLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.info("已关闭开机自启")
            } else {
                try service.register()
                Log.info("已开启开机自启")
            }
        } catch {
            Log.error("切换开机自启失败：\(error)")
        }
    }
}
