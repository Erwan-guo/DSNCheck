# DRC Check 1.0

双击 `DRC_CheckV1.0.exe` 启动 Windows 图形界面。软件应保留在 `DSNCheck/DRC_CheckV1.0` 目录；检查逻辑调用上级目录中的 `export/cadence` 与 `check/generic` 脚本。运行机器需要 Cadence Capture 16.6（或已配置的 `Capture.exe`）、Windows PowerShell 5.1 和 .NET Framework 4.7.2 或更高版本。

1. 将 `.DSN` 文件拖入界面顶部，或点击“选择 DSN”。软件会复用与 DSN 匹配且未过期的 `<文件名>_checkdata` 导出；否则调用 Capture 导出。Capture 的许可证和版本选择由本机环境提供。
2. 程序生成电源/地候选。逐行选择 `accept` 或 `reject`；可修改类型、电压，或补充导出数据中存在的网络。`conflict` 候选必须先修订或拒绝。
3. 点击“确认网络并开始检查”。软件将审核结果保存为 `power_nets.review.csv`，调用现有确认脚本生成 `power_nets.confirmed.json`，再运行通用检查。
4. 在“检查结果”中按类型和级别筛选，查看器件、引脚、网络和详细说明；完整 JSON/TXT 报告保存在导出目录。没有显式严重级别的基础网络问题按“错误”显示。

如果本机 Capture 无法启动，但已有与当前 DSN 匹配且未过期的导出，可点击顶部“打开导出数据”选择该目录，继续进行网络审核与检查。过期导出不会被复用。

双击检查条目会调用 `IEdaNavigator.TryNavigate` 接口。当前提供 `UnconfiguredEdaNavigator`，仅提示尚未配置导航，不会控制 EDA。后续可替换为 Cadence 或其他工具的适配器。

编译：在本目录运行 `powershell.exe -NoProfile -ExecutionPolicy Bypass -File Build.ps1`。项目使用 Windows 自带的 .NET Framework C# 编译器，不需要安装 .NET SDK。

测试已有导出数据时，可从命令行运行 `DRC_CheckV1.0.exe --export <导出目录>`；该目录的 `manifest.json` 必须指向存在的 DSN，且导出数据不能早于 DSN。正式使用时直接拖入 DSN。
