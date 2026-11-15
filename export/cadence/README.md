# Cadence Capture 数据导出

本目录负责提取原理图信息，不执行离线检查。推荐将导出与 `check/generic`、`check/ci_excel` 中的检查分开运行。

| 文件 | 用途 |
| --- | --- |
| `capture_export_active.tcl` | 在已打开 DSN 的 Capture Tcl Command Window 中导出当前活动设计；推荐入口 |
| `capture_export_all.tcl` | Tcl/Dbo 导出核心，供入口脚本调用；不需要单独执行 |
| `Export-CadenceCheckData.ps1` | 可选的 PowerShell 自动导出入口；会另行启动 Capture 并打开指定 DSN |
| `capture_export_active_and_check.tcl` | 可选的一步导出并运行通用检查入口；需要已确认的电源/地清单 |

已在 Capture 中打开 DSN 时，在 Tcl Command Window 中执行：

```tcl
source {D:/GPTPRJ/DSNCheck/export/cadence/capture_export_active.tcl}
```

导出结果默认位于 DSN 所在目录的 `<设计名>_checkdata`，其中 `dbo/objects.jsonl` 是两套离线检查的主要输入。确认出现 `export.ok` 后，再到 [`../../check/generic/README.md`](../../check/generic/README.md) 或 [`../../check/ci_excel/README.md`](../../check/ci_excel/README.md) 运行对应检查。`capture_export_active.tcl` 不会自动运行检查，也不会替用户确认电源/地网络。
