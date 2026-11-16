# 通用原理图检查

本目录只放通用检查，不包含 Excel 表格中的 CI4/CI5 专项检查。检查器读取 Capture 导出目录，不打开或修改 DSN。

电源/地候选按网络名或全局符号名中的片段识别：包含 `V` 的名称作为电源候选，包含 `GND`、`GROUND`、`VSS` 或 `EARTH` 的名称作为地候选；名称中的 `50V`、`3V3` 等片段可提取电压。电容额定耐压也可从 Description 等属性中的 `50V` 片段提取。候选仍需审核；实际网络连接、跨页同名和电位映射始终使用完整网名。

| 文件 | 用途 |
| --- | --- |
| `Invoke-PowerNetReview.ps1` | 自动生成电源/地候选清单，供用户审核并确认 |
| `Run-DSNCheck.ps1` | 通用检查的命令行入口 |
| `Invoke-DSNCheck.ps1` | 读取离线数据、执行基础检查并生成报告 |
| `Invoke-DSNCheck-Additional.ps1` | 引脚、偏置、电容耐压、时钟等扩展规则 |
| `Invoke-DSNCheck-Naming.ps1` | 网络命名与跨页符号相关规则 |
| `Invoke-DSNCheck-LatchFilter.ps1` | 273/373/573 等时钟/锁存输入 RC 滤波规则 |
| `additional.rules.example.json` | 项目规则示例；位号和网络名需按实际工程修改 |

先用 `export/cadence/capture_export_active.tcl` 导出数据。然后在 PowerShell 中运行（把路径换成实际导出目录）：

```powershell
$dataDir = 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata'
& 'D:\GPTPRJ\DSNCheck\check\generic\Invoke-PowerNetReview.ps1' -InputDirectory $dataDir -Mode Draft
```

审核导出目录中的 `power_nets.review.csv`，填写 `decision` 并补充遗漏网络，再确认、检查：

```powershell
& 'D:\GPTPRJ\DSNCheck\check\generic\Invoke-PowerNetReview.ps1' -InputDirectory $dataDir -Mode Confirm
& 'D:\GPTPRJ\DSNCheck\check\generic\Run-DSNCheck.ps1' -InputDirectory $dataDir
```

可通过 `-RulesFile` 传入按工程修改的规则文件。报告输出到导出目录的 `dsn_check_report.json` 和 `dsn_check_report.txt`。重新导出后，如源数据变化，需重新审核电源/地网络。完整规则说明见 [`../../docs/README.md`](../../docs/README.md)。

多份设计可使用 `Run-DSNCheck-Batch.ps1`。清单每行采用 `DSN绝对路径|导出目录绝对路径`，与 Cadence 批量导出清单相同。`-Mode Draft` 为每份生成待审核的电源/地 CSV；人工审核并分别运行 `Invoke-PowerNetReview.ps1 -Mode Confirm` 后，使用 `-Mode Check` 生成正式报告。`-Mode ProvisionalCheck` 只用于测试或快速预览：它采用保守的自动候选生成 `power_nets.provisional.json`，并在报告中标记 `power_map_review_status=provisional`，不能替代人工确认。
