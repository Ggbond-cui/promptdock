import Foundation
import Security

/// 各服务的 API Key 存放在系统钥匙串（spec 9.3），不写入 YAML 或日志。
/// 每个服务一条记录：service = local.jemry.promptdock，account = api-key:<服务名>。
enum KeychainStore {
    private static let service = "local.jemry.promptdock"

    private static func query(_ provider: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "api-key:\(provider)"]
    }

    /// 只查是否存在，不读取内容。读取属性不需要解密，不会触发钥匙串授权框，
    /// 菜单栏和面板提示只能用这个方法（菜单展开时弹授权框会导致无法输入密码）。
    static func hasAPIKey(provider: String) -> Bool {
        var q = query(provider)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    /// 读取内容。可能触发钥匙串授权框（例如重新编译后），只在真正发请求时调用。
    static func readAPIKey(provider: String) -> String? {
        var q = query(provider)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let key = String(data: data, encoding: .utf8), !key.isEmpty
        else { return nil }
        return key
    }

    static func saveAPIKey(_ key: String, provider: String) -> OSStatus {
        SecItemDelete(query(provider) as CFDictionary)
        var q = query(provider)
        q[kSecValueData as String] = Data(key.utf8)
        // 注意：记录存在传统的登录钥匙串（login.keychain-db），按 Apple 文档该属性只对「数据保护钥匙串」生效，
        // 这里实际不起作用。改用数据保护钥匙串需要开发者 Team ID，自签名证书做不到（spec 9.3）。
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(q as CFDictionary, nil)
    }

    static func deleteAPIKey(provider: String) {
        SecItemDelete(query(provider) as CFDictionary)
    }
}
