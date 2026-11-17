import Foundation

/// 定位本机 Obsidian 仓库（vault）：按常见位置找含 `.obsidian` 的目录。
/// iCloud 同步的 vault 优先（用户多数走这条路），其次 ~/Documents 和家目录。
enum ObsidianVaultLocator {

    static func locate() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let bases = [
            home.appendingPathComponent("Library/Mobile Documents/iCloud~md~obsidian/Documents"),
            home.appendingPathComponent("Documents"),
            home,
        ]
        for base in bases {
            let children = (try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
            // 名字排序只为结果稳定；多 vault 时取字典序第一个，失败提示让用户知道没找对
            for dir in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where FileManager.default.fileExists(atPath: dir.appendingPathComponent(".obsidian").path) {
                return dir
            }
        }
        return nil
    }
}
