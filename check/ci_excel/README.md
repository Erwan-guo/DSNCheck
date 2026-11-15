# Excel CI 检查项

本目录只实现 Excel 检查表中的 CI4.1、CI4.5、CI5.1、CI5.6；不运行 `check/generic` 中的通用检查，也不修改 DSN。

| 文件 | 用途 |
| --- | --- |
| `Run-DSNCheck-CI4-CI5.ps1` | CI4/CI5 检查的命令行入口 |
| `Invoke-DSNCheck-CI4-CI5.ps1` | 读取 Capture 离线导出数据并执行检查 |
| `CI4-CI5.rules.example.json` | 电源输入、PGOOD、总线位号和下载模式等项目规则示例 |

先从 Capture 导出数据，再在 PowerShell 中运行：

```powershell
& 'D:\GPTPRJ\DSNCheck\check\ci_excel\Run-DSNCheck-CI4-CI5.ps1' `
  -InputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata'
```

需要项目约束时，复制并修改 `CI4-CI5.rules.example.json`，再通过 `-RulesFile` 指定修改后的文件。报告输出到导出目录的 `dsn_check_ci4_ci5_report.json` 和 `dsn_check_ci4_ci5_report.txt`，与通用检查报告分开。没有器件手册或时序参数的判断可能标为人工复核；CI4.5 的第 3 步目前未启用。详细说明见 [`../../docs/README.md`](../../docs/README.md)。
