# Cadence DSN 原理图检查数据导出器

## 目录分层

```text
DSNCheck/
  export/
    cadence/       Capture Tcl/Dbo 与 Cadence 导出入口
    python/        跨 EDA 导出数据包收集器
  normalize/       原始导出转统一数据包
  check/            离线检查规则与报告
  docs/             使用说明与技术方案
  tools/            文档/开发辅助工具
```

Python 导出层入口：

```powershell
python D:\GPTPRJ\DSNCheck\export\python\export_eda_package.py `
  D:\GPTPRJ\EXAMPLE_SCH\<DSN>_checkdata `
  --output D:\GPTPRJ\EXAMPLE_SCH\<DSN>_raw_package `
  --eda cadence_capture --format capture_tcl_dbo
```

该 Python 程序是“导出层编排器”，不直接解析 Cadence DSN；它收集适配器已生成的文件，计算 SHA-256，登记能力，并排除 `native_drc`/DRC 报告。后续可为 KiCad、Altium 等适配器复用相同入口。

该工具用一个入口完成两类输出：

1. 调用 Cadence Capture 16.6 自带的 ISCF 导出器和随安装提供的 Custom DRC。
2. 使用 Capture Tcl/Dbo API 补充页面坐标、导线、连接点、Junction、Off-page Connector、Bus Entry 和图形边界框。

它不直接解析 `.DSN` 二进制文件。

## 分离模式：先导出，再检查（推荐）

先在 Capture 中打开并激活要检查的 DSN，然后打开 Capture 的 Tcl Command Window，执行：

```tcl
source {D:/GPTPRJ/DSNCheck/export/cadence/capture_export_active.tcl}
```

该命令只做数据导出，不执行任何检查。导出完成后，关闭 Capture 也不会影响检查器；检查器只读取导出目录中的文件。

然后在 PowerShell 中运行：

```powershell
& 'D:\GPTPRJ\DSNCheck\check\Run-DSNCheck.ps1' `
  -InputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata'
```

滤波电容规则按器件逐个检查，要求电容与器件位于同一 page，并且电容一端接该器件供电网络、另一端接地；默认以 Power 引脚为中心搜索 250 个图纸坐标单位。可按原理图库调整：

```powershell
& 'D:\GPTPRJ\DSNCheck\check\Run-DSNCheck.ps1' `
  -InputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata' `
  -FilterCapDistance 300
```

电源网络只按以下命名模式识别：`数字V数字`（如 `3V75`）或 `数字.数字V`（如 `3.75VREF`）；名称可带任意前缀/后缀（如 `SYS_3V3`、`3.75V_Eth`）。孤立电源采用独立检查遍历，已识别的电源网络不会重复计入单节点网络。

检查器输入为：

```text
dbo/objects.jsonl
```

它不会读取 `.DSN`、不会连接 Capture，也不会修改原理图。输出为 `dsn_check_report.txt` 和 `dsn_check_report.json`。

## 生成完整离线数据包

如果还希望把 Dbo 导出的逻辑数据整理成 CSV/JSONL Netlist，可在导出完成后执行：

```powershell
& 'D:\GPTPRJ\DSNCheck\normalize\Export-DSNCheckPackage.ps1' `
  -InputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata'
```

未指定 `-OutputDirectory` 时，默认生成同级目录：

```text
AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata_package
```

该脚本只读取导出目录，不打开 DSN，也不连接 Capture。它会生成：

```text
native/design.iscf
dbo/objects.jsonl
dbo/properties.jsonl
dbo/errors.jsonl
netlist/parts.csv
netlist/pins.csv
netlist/nets.csv
netlist/logical_netlist.jsonl
package_manifest.json
```

如果通过 Capture 的 `Tools -> Create Netlist -> PCB Editor` 已经生成了
`pstxnet.dat`、`pstxprt.dat`、`pstchip.dat`，可一并收集：

```powershell
& 'D:\GPTPRJ\DSNCheck\normalize\Export-DSNCheckPackage.ps1' `
  -InputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata' `
  -NetlistDirectory 'D:\GPTPRJ\EXAMPLE_SCH\netlist'
```

脚本明确不会复制 `native_drc` 或任何 Cadence DRC 报告。这样检查器后续只需要读取这个离线数据包。

如果希望临时一条命令完成“导出后检查”，可使用：

```tcl
source {D:/GPTPRJ/DSNCheck/export/cadence/capture_export_active_and_check.tcl}
```

但后续开发和回归测试建议使用前面的两个独立步骤。

导出入口使用 `GetActivePMDesign` 读取当前设计，并调用 Cadence 自带的：

```tcl
::capISCFExport::ExportDesign $design $iscfPath $logPath
```

它不会启动 Capture、不会重新打开 DSN、不会创建独立 Dbo Session，也不会关闭设计或退出 Capture。默认输出到活动 DSN 同目录下的：

```text
<DSN文件名>_checkdata
```

例如本项目默认输出：

```text
D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata
```

如需指定输出目录，在 `source` 之前设置：

```tcl
set ::CAPCHECK_OUTPUT_DIR {D:/GPTPRJ/EXAMPLE_SCH/check-data}
source {D:/GPTPRJ/DSNCheck/export/cadence/capture_export_active.tcl}
```

Capture 16.6 的 Tcl 8.4 对中文脚本路径兼容性较差，因此项目和运行脚本统一放在纯 ASCII 路径 `D:\GPTPRJ\DSNCheck`。

## 独立批处理导出（可选）

在 PowerShell 中执行：

```powershell
.\export\cadence\Export-CadenceCheckData.ps1 `
  -Dsn 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST.DSN' `
  -OutputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\check-data'
```

默认从 `PATH` 查找 `Capture.exe`。也可以明确指定：

```powershell
.\export\cadence\Export-CadenceCheckData.ps1 `
  -Dsn 'D:\project\board.dsn' `
  -CaptureExe 'D:\Cadence\SPB_16.6\tools\capture\Capture.exe'
```

调试时使用 `-ShowCapture` 显示 Capture 窗口。此旧入口会启动 Capture，并在导出结束后由 Tcl 脚本退出；当 DSN 已经手动打开时，请使用上面的活动设计入口。

## Cadence 自带的导出方法

### 已集成：ISCF Export

本机 Capture 16.6 自带：

```text
tools/capture/tclscripts/capISCFExport/tcl/capISCFExport.tcl
```

独立批处理入口调用：

```tcl
::capISCFExport::ExportDesignInBatch $dsn $iscfPath $logPath
```

活动设计入口调用 `::capISCFExport::ExportDesign`，从而避免重新打开当前 DSN。

输出 `native/design.iscf`，包含：

- `BEGIN_COMPPROPS`：元件属性
- `BEGIN_COMPPINS`：引脚编号、名称及引脚属性
- `BEGIN_NETS`：普通网络与连接的 RefDes/Pin
- `BEGIN_POWER`、`BEGIN_GROUND`：电源和地
- `BEGIN_BUSES`：总线成员

### 已集成：Cadence 随安装提供的 Custom DRC

统一脚本以“不创建 Marker”的只读方式运行：

- Hanging Wires
- Overlapping Wires
- Invalid Pin Number
- Part Reference Prefix Mismatch

结果位于 `native_drc/*.drc.log`。

### Cadence 标准 GUI 输出

Capture 还提供以下标准菜单输出，但这些命令依赖版本、Capture.ini 配置和模态对话框，不在批处理脚本中模拟鼠标操作：

- `Tools -> Design Rules Check`：标准 `.DRC` 报告
- `Tools -> Create Netlist -> PCB Editor`：`pstxnet.dat`、`pstxprt.dat`、`pstchip.dat`
- `Tools -> Bill of Materials`：BOM 文本/CSV
- `Tools -> Export Properties`：属性表
- `Tools -> Cross Reference`：位号与页面交叉索引

自动检查的主要数据已经由 ISCF + Dbo JSONL 覆盖。如果需要把 Cadence 标准 DRC 当作基线，可将 GUI 生成的 `.DRC` 一并交给后续规则引擎。

## Tcl/Dbo 补充输出

`dbo/objects.jsonl` 每行是一个 JSON 对象，记录类型包括：

- `design`、`schematic`、`page`
- `part`、`pin`
- `wire`、`wire_point`、`net_alias`
- `global`、`port`、`offpage_connector`
- `bus_entry`
- `graphic`

`dbo/properties.jsonl` 包含：

- 所有可读取的 User Property
- Display Property 的名称、值、位置和边界框

`dbo/errors.jsonl` 记录非致命的版本兼容性或单对象读取错误。

## 检查项与数据来源

| 检查项 | 首选数据 | Dbo 补充字段 |
|---|---|---|
| 元件属性检查 | ISCF `COMPPROPS` | `part`、`user_property`、`display_property` |
| 位号与封装检查 | ISCF + Bundled DRC | `part.reference`、`part.pcb_footprint` |
| 引脚连接检查 | ISCF `COMPPINS/NETS` | `pin.connected`、`pin.net_name`、`pin.no_connect` |
| 单端网络、悬空网络 | ISCF `NETS` | `pin`、`wire.net_name` |
| 电源与地网络 | ISCF `POWER/GROUND` | `global`、`pin.pin_type` |
| 电源命名识别 | Dbo 网络名 | 必须包含 `数字V数字` 或 `数字.数字V`，允许前后缀 |
| 地符号名称 | Dbo `global` | `global.name`（空名称报告为未标注） |
| Power 引脚外部供电 | Dbo `pin` + 网络成员 | `pin.pin_type=7`、`pin.net_name`、同网有源器件 |
| 供电器件就近滤波 | Dbo `part`、`pin` | 同页电容、电源/地两端网络、引脚坐标 |
| 悬空导线 | Bundled Hanging Wires DRC | `wire.start_object_count/end_object_count` |
| Junction 正确性 | 无完整通用导出 | `wire_point.is_junction`、导线坐标和网络名 |
| Off-page 放置与匹配 | 网表只含部分逻辑关系 | `offpage_connector` 的页面、网络、热点和边界框 |
| 总线入口 | ISCF 只含总线逻辑 | `bus_entry` 两端坐标、两端网络和 Bus/Bundle 标志 |
| 图形重叠 | 无标准结构化导出 | 所有对象及 Display Property 的边界框 |

## 输出目录

```text
check-data/
  manifest.json
  export.ok
  capture_export.log
  native/
    design.iscf
    design.iscf.log
  native_drc/
    hanging_wires.drc.log
    overlapping_wires.drc.log
    invalid_pin_number.drc.log
    reference_prefix.drc.log
  dbo/
    objects.jsonl
    properties.jsonl
    errors.jsonl
```

`manifest.json` 中记录 ISCF、Bundled DRC 的状态及各 JSONL 记录数量。只有出现 `export.ok` 才表示整套导出完成。

## 兼容性说明

- 当前按 OrCAD Capture 16.6 的 Tcl/Dbo API 编写。
- 17.x/23.x 通常保留这些 Dbo 对象，但应先用样例工程做回归验证。
- Capture 16.6 在部分新版 Windows 11 上可能在 `combase.dll` 中崩溃；这属于 Capture 启动兼容性问题。应使用企业实际支持的 Windows/Capture 组合，或升级 Cadence 后再运行同一导出器。
- ISCF 和 Custom DRC 文件是 Cadence 安装包随附 Tcl 工具，文件头注明为无支持示例工具；生产环境应保留 Dbo JSONL 作为稳定的内部交换格式。
- 活动设计入口直接只读遍历 `GetActivePMDesign` 返回的设计；独立批处理入口才创建 Dbo Session。两者都不保存或修改 DSN，也不创建 DRC Marker。
