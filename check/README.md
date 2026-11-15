# 检查器分层

| 目录 | 范围 | 入口 | 报告 |
| --- | --- | --- | --- |
| `generic/` | 通用电气与网络检查，包括电源/地确认、OC/OD 上拉和单驱动多接收网络偏置 | `generic/Run-DSNCheck.ps1` | `dsn_check_report.json`、`dsn_check_report.txt` |
| `ci_excel/` | 依据 Excel 检查表实现的 CI4.1、CI4.5、CI5.1、CI5.6 | `ci_excel/Run-DSNCheck-CI4-CI5.ps1` | `dsn_check_ci4_ci5_report.json`、`dsn_check_ci4_ci5_report.txt` |

两套检查器独立读取 Capture 导出的数据，不修改 DSN，也不将通用检查结果混入 CI 检查报告。通用检查运行前需先用 `generic/Invoke-PowerNetReview.ps1` 确认电源和地网络。完整用法见 [`../docs/README.md`](../docs/README.md)。
