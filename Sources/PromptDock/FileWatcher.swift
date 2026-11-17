import Foundation

/// 监听配置文件变化（spec 8.4）。
/// 同时监听文件本身和所在目录：很多编辑器「写临时文件再重命名」只触发目录事件，
/// 而原地写入（如 vim backupcopy=yes、echo >>）只触发文件事件。
/// 配置文件若是软链接，监听的是链接指向的真实文件及其目录。
@MainActor
final class FileWatcher {
    private let link: URL
    private let onChange: @MainActor () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(file: URL, onChange: @escaping @MainActor () -> Void) {
        self.link = file
        self.onChange = onChange
        arm()
    }

    private func arm() {
        sources.forEach { $0.cancel() }
        sources = []
        let real = link.resolvingSymlinksInPath()
        var targets = [real.path, real.deletingLastPathComponent().path]
        if real != link { targets.append(link.deletingLastPathComponent().path) }
        for path in Set(targets) {
            let fd = open(path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete, .attrib], queue: .main
            )
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.schedule() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            sources.append(source)
        }
    }

    /// 防抖 300ms；触发后重新挂载监听（原子替换后文件 inode 已变化）。
    private func schedule() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.arm()
                self.onChange()
            }
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}
