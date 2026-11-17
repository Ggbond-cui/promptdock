## 安装

1. 下载下方的 `PromptDock-x.y.z.dmg`，打开后把 PromptDock 拖进「应用程序」
2. **首次打开**：本应用未经 Apple 公证，双击会提示「无法验证开发者」。请任选一种方式放行：
   - 系统设置 → 隐私与安全性 → 页面底部找到 PromptDock → 点「仍要打开」
   - 或在终端执行：`xattr -dr com.apple.quarantine /Applications/PromptDock.app`
3. 按提示授予「辅助功能」权限（系统设置 → 隐私与安全性 → 辅助功能）
4. 按 ⌥Space 开始使用；使用选中文字动作前，在菜单栏 → 设置… → 模型服务 中填入 API Key

升级到新版本后需要重新授予辅助功能权限（未公证应用的签名每个版本都不同）：在辅助功能列表中先删除旧的 PromptDock，再重新添加。

系统要求：macOS 15 及以上，Apple 芯片与 Intel 均可。
