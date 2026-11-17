# Cadence DSN 原理图检查数据导出器

## 目录分层

```text
DSNCheck/
  export/
    cadence/       Capture Tcl/Dbo 与 Cadence 导出入口
    python/        跨 EDA 导出数据包收集器
  normalize/       原始导出转统一数据包
  check/
    generic/       通用离线检查规则与报告
    ci_excel/      Excel 表格 CI 检查规则与报告
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

在 PowerShell 中先生成待审核的电源/地网络清单：

```powershell
& 'D:\GPTPRJ\DSNCheck\check\generic\Invoke-PowerNetReview.ps1' `
  -InputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata' `
  -Mode Draft
```

脚本生成 `power_nets.review.csv` 和 `power_nets.review.meta.json`。CSV 的 `kind` 是候选类别（`power`、`ground`、`conflict`），`voltage_v` 是候选电压，`source`/`evidence` 记录命名、符号、器件及跨网依据。逐行核对，将 `decision` 填为 `accept` 或 `reject`；需要修正时编辑 `kind`/`voltage_v`，漏掉的网络可按相同列格式追加一行并填 `accept`。冲突项必须先改为明确的电源或地，或拒绝。默认不覆盖已有审核 CSV；确需重建草稿时才使用 `-Force`，并先保存人工改动。

候选包括符合电压命名约定的网络、地名/全局符号、Power/地引脚线索，以及经两引脚 0Ω 电阻、电感、磁珠相连的网络。默认 100Ω 及以下的非零电阻只给出 `strong_pull_review` 候选，不递归传播，也不自动确认；串阻、终端电阻和分压可能产生误判。阈值可用 `-StrongPullMaxOhms` 调整。所有候选都必须由用户确认。

审核完 CSV 后执行：

```powershell
& 'D:\GPTPRJ\DSNCheck\check\generic\Invoke-PowerNetReview.ps1' `
  -InputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata' `
  -Mode Confirm
```

确认命令要求每条候选都有决定，拒绝不存在或重复的网络，生成 `power_nets.confirmed.json`。即使没有自动候选，也会生成可供手动追加网络的 CSV 表头。之后运行通用检查：

```powershell
& 'D:\GPTPRJ\DSNCheck\check\generic\Run-DSNCheck.ps1' `
  -InputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata'
```

滤波电容规则按器件逐个检查：器件所在 page 只要有一个已连接电容，一端接该器件的完整供电网络名、另一端接已确认的地网络，就满足检查。相同名称的独立电源符号通过导出的网络名关联；不要求电容与器件引脚在图纸上直接相连，也不限制图纸距离。不同 page 上的电容不计入。

自动候选的电压命名依据仍为 `数字V数字`（如 `3V75`）或 `数字.数字V`（如 `3.75VREF`），允许前后缀；但最终电源/地身份只取自用户确认清单。孤立电源采用独立检查遍历，已确认的电源网络不会重复计入单节点网络。若重新导出改变了 `dbo/objects.jsonl`，旧确认清单会因 SHA-256 不匹配而被拒绝，需重新审核。

检查器输入为：

```text
dbo/objects.jsonl
power_nets.confirmed.json
```

它不会读取 `.DSN`、不会连接 Capture，也不会修改原理图。输出为 `dsn_check_report.txt` 和 `dsn_check_report.json`。

## 通用检查扩展规则

在原有单节点网络、孤立电源、伪单节点网络、Power 引脚和就近滤波检查基础上，离线检查器还支持 15 项通用检查。第 7 项是 **OE 上拉检查**。默认只启用可由导出数据直接支持的检查；项目相关项需先按器件手册和设计要求编辑 `check/generic/additional.rules.example.json`，再传入规则文件：

```powershell
& 'D:\GPTPRJ\DSNCheck\check\generic\Run-DSNCheck.ps1' `
  -InputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata' `
  -RulesFile 'D:\GPTPRJ\DSNCheck\check\generic\additional.rules.example.json'
```

示例中的 `U100` 等位号仅为占位示例，不能直接代表当前设计的规则。`part_pattern` 匹配“位号 值 源器件名”，`pin_pattern` 匹配引脚名，`net_pattern` 匹配网络名，均为 PowerShell 正则表达式。偏置检查按外部电阻另一端连接到已确认的电源或地网络判断；电阻值支持 `10K`、`4K7`、`33R`、`4.7K` 等写法。网络命名检查即使不传规则文件也会运行；`net_naming.auto_net_max_pins` 可调整自动命名网络的有效引脚数阈值，默认 8。

| 检查项 | 实现范围 |
|---|---|
| 单节点网络、电源管脚检查 | 原有自动检查，保持原判定逻辑 |
| 管脚悬空检查 | 未连接且未标 No Connect 的输入脚列为人工复核候选；是否允许悬空需查手册 |
| 压摆率较低器件限制 | 按规则给出的实际/允许上升时间比较；数据需来自手册或实测 |
| 电容耐压降额检查 | 自动检查全部 C 位号；按原理图属性 `cap` / `cap_polar` 区分类型，按已确认电源/地电位计算两端电压；缺失信息列为人工复核 |
| 网络命名检查 | 可选的项目正则规则；自动检查不同名 Off-page/电源符号直连，并给出疑似漏放符号、差分命名遗漏、自动网络连接数过多的人工复核候选 |
| OE 初始无效检查 | 对配置的总线驱动器 OE 引脚，识别直连或单个串阻后的外部芯片引脚；按 OE 名称推断低/高有效并检查 OE 侧上拉/下拉 |
| 复位信号上拉或下拉检查 | 自动识别 `RESET`、`RST`、`RSTN` 等引脚或网络名，按有效电平推断使复位默认无效的偏置方向 |
| 中断信号上拉或下拉检查 | 自动识别带 `IRQ`/`INT` 命名段的引脚或网络，推断有效电平；反向偏置报错，无外部偏置默认人工复核 |
| 特定芯片时钟/锁存信号处理 | 自动识别 273/373/573 类芯片的 CLK/CP 或 LE 输入，建议输入侧串接 33Ω、并联 33pF 到同页地网 |
| OC/OD 门上拉检查 | 自动按导出的引脚类型识别开集/开漏输出，检查其网络是否经电阻上拉至已确认电源；可用规则限定目标与阻值 |
| 普通网络偏置检查 | 自动检查单驱动、多接收的板内网络是否存在重复或跨电源/地网络的偏置；指定网络还可按规则检查所需方向、供电轨和阻值 |
| Bus-hold 器件输入管脚检查 | 按规则指定有内部保持或需要外部偏置；需要外部偏置时检查目标输入脚 |
| 差分管脚连接检查 | 检查 P/N 脚唯一性、是否悬空/短接及配置的网络极性；不推断阻抗与布局 |
| 时钟信号串阻检查 | 从目标时钟引脚沿电阻跨网络追踪到其他器件引脚；零只或多只串阻报 error，恰好一只且大于 33Ω 报 warning |

电容类型在器件 `value`、`source_part` 和导出的 `user_property`/`display_property` 中按完整标记 `cap` 或 `cap_polar` 匹配；缺失或冲突会提示人工复核。额定耐压优先取 `Rated Voltage`、`Voltage Rating`、`RatedVoltage`、`VoltageRating`，没有时仅接受其他属性中唯一的独立电压值（如 `TEN=10V`），不从 `Description` 中猜测。已确认电源映射的 `voltage_v` 和地电位 0V 给出电容两端外部电压；任何一端电位未知，或额定耐压缺失/冲突，均列为“无法识别本体耐压、外部电压的电容”。

非极性电容分别按工作电压不超过额定耐压的 50%（一级）、60%（二级）、70%（三级）检查，可同时报告多个未满足等级。极性电容要求额定耐压至少为两端电压的三倍；引脚名 `P/N`、`POS/NEG`、`PLUS/MINUS`、`+/-` 或 `ANODE/CATHODE` 用于判断是否反接，引脚极性不可辨时提示人工复核。此处计算的是原理图标注的直流电位差，不能替代最大瞬态、纹波、启动过程和器件规格的复核。

网络命名检查用导出的 `wire`、`net_alias`、`offpage_connector`、`global` 和引脚数据。同页同网的 Off-page/电源符号出现不同名称时判为错误。符号的 `net_name` 在部分 Cadence 导出中为空，脚本仅在同页导线端点能唯一关联符号时使用该关联。对“其他页有同名符号，本页只有同名别名或自动网络引脚”的情况，仅报疑似漏放；本页已有同名符号，或已有覆盖该位的总线连接器（如 `PA[0..31]` 覆盖 `PA21`）则不报。差分引脚对依据同一器件上的 `P/N`、`DP/DN`、`DP/DM`、`+/-` 等名称识别；一侧仍为 `N123` 之类自动名或两侧后缀不匹配，列为人工复核。自动网络的连接数按不同有效引脚计数，超过阈值才提示。以上规则不判断驱动源、电气引脚类型或连接器是否真正接触导线；这些仍应运行 Cadence 的 `Check no driving source and pin type conflict` 和 `Check off-page connector connect`，避免把命名启发式结果当成原生 DRC 结论。

OE 专项仍使用历史报告分类名 `OE上拉检查`，但现在也检查高有效 OE 的下拉。配置 `part_pattern` 和 `pin_pattern` 指定总线驱动器及其 OE 引脚，`driver_part_pattern` 指定外部驱动芯片的位号模式（默认 `U`/`IC`/`MN`），`max_series_ohms` 限制可追踪的单个串阻（默认 100Ω）。`/OE`、`OE_N`、`OE#` 及 Capture 反斜杠上划线写法判为低有效，初始无效要求上拉；普通 `OE` 判为高有效，要求下拉。脚本优先要求偏置在 OE 侧；仅驱动侧有偏置，或串阻驱动侧还有相反偏置时提示人工复核。另一芯片引脚的输出属性、上电高阻状态和复位默认态无法证实时也提示复核；原理图中的电阻不能单独证明上电期间 OE 必然无效。配置的 `direction` 可省略；如与名称推断相反，会提示冲突并按名称推断检查。

复位检查不再要求事先配置规则。引脚名 `RESET`、`RST` 视为高有效，默认无效状态要求下拉；`RSTN`、`RESETN`、`RST_N`、`RESET_N`、`NRST`、`/RST`、`RESET#` 以及 Capture 反斜杠上划线写法视为低有效，要求上拉。引脚名不含复位标记时，可由网络名识别；同一网络的复位引脚标记冲突，或引脚与网络名极性不一致，报告人工复核。每个网络只检查一次。仍可添加 `bias_rules` 限定器件、引脚、供电轨或电阻范围；若旧配置的 `direction` 与名称推断相反，报告冲突并按名称检查。这里检查的是静态默认偏置，不推断复位时序、上电期间是否保持复位，或复位芯片的内部输出状态。

中断检查也无需预先配置规则。`IRQ`、`INT`、`INTR`、`PHY_INT`、`IRQ0` 等独立命名段按高有效处理，默认无效方向为下拉；`/IRQ`、`INT_N`、`IRQ#`、`NIRQ` 及 Capture 反斜杠上划线写法按低有效处理，默认无效方向为上拉。`GPIO2/IRQ` 等复用功能名以及上划线 `M\D\I\N\T\R\` 也作为候选；复用功能是否启用会额外提示人工确认。先看引脚名，没有标记时可从网络名识别；同网引脚或引脚/网络名标记冲突时提示人工复核。使用命名段边界避免把 `PRINT`、`INTERFACE` 误识别成中断；无分隔符的非标准合成名称应通过项目规则指定。明确的中断引脚若找到相反方向的外部偏置则报 `error`；自动发现的复用引脚仅报 `manual_review`。完全没有外部偏置也只报 `manual_review`，因为推挽中断输出可能不需要上下拉。已知开漏/开集等必须外拉的网络，可在 `bias_rules` 中设置 `require_external_bias: true`，再用 `part_pattern`、`pin_pattern` 或 `net_pattern` 限定目标；旧规则 `direction` 与名称推断不同时提示冲突并按名称检查。名称推断不能证明芯片手册规定的真实有效电平或上电默认状态。

OC/OD 门上拉检查使用导出的 `pin_type`，Capture 数值 `3`（Open Collector）或文本 `Open Collector`/`Open Drain` 作为候选，不按引脚名猜测；Capture 没有独立的 Open Drain 类型，OD 引脚需在器件库中标为 Open Collector。默认排除 `Q` 等离散元件位号，避免把晶体管漏极误作逻辑门输出。未配置该类别规则时自动扫描；配置后可用 `part_pattern`、`pin_pattern`、`net_pattern` 缩小范围，并用 `rail_pattern`、`min_ohms`、`max_ohms` 约束上拉。配置规则也必须匹配 OC/OD 引脚类型，`direction` 只能为 `up`。检查依赖已确认的电源网络；引脚类型标错或未导出时不能可靠自动识别，需修正器件库或导出数据。

普通网络偏置的自动检查只选择非电源/地网络，且要求恰好一个输出或 OC/OD 驱动引脚、至少两个输入引脚；有双向、三态、Power、连接器或晶体管等方向不明确的引脚时跳过。电阻、电容、电感、磁珠、二极管和测试点不计为驱动/接收。对目标网络按独立电阻位号统计直连至已确认电源/地网络的上拉、下拉：两个及以上连接同一轨报 `warning`，连接不同电源/地网络报 `error`，报告电阻和目标轨。零个偏置不自动报错，因为普通推挽网络可能无需偏置；设计要求必须偏置时，仍用 `bias_rules` 指定网络、方向及阻值。这里仅依据导出的拓扑与引脚类型判断，不计算电阻并联值、实际静态功耗或芯片内部上拉。

时钟串阻规则用 `part_pattern` 和 `pin_pattern` 选定待检查的时钟引脚。脚本从该引脚网络沿两端已连接的电阻穿透，遇到其他器件引脚即停止该路径；电源/地网络不作为时钟路径，电阻、电容、电感及磁珠引脚不作为终点。到达器件引脚的路径若没有串阻、经过两只及以上串阻，或分支中存在不同串阻，报 `error`；仅有一只且阻值大于 `max_ohms`（默认 33Ω）报 `warning`，等于 33Ω 正常。找不到对端器件引脚报 `error`；电阻值不可解析或路径遍历超限报 `manual_review`。旧规则的 `source_net_pattern` 可选，用来限定对端网络；不配置时不依赖预先指定的源网。

273/373/573 类器件的 RC 滤波建议无需额外规则也会检查：按器件 `value` 或 `source_part` 中的型号数字识别，273 的 `CLK`/`CK`/`CP`/`CLOCK` 与 373/573 的 `LE`/`LAT`/`LATCH`/`LATCH_EN` 作为输入候选。要求同页电阻跨接输入网与另一非电源/地网络，标称 33Ω；同页电容从输入网接到已确认的地网，标称 33pF（支持 `33pF`、`33p`、`0.033nF` 等写法）。缺少元件或数值不符报 `warning`；阻值/容量无法解析、多个串阻候选、串阻另一端没有可识别器件引脚或目标引脚无法识别报 `manual_review`。输入网若还直连已标为输出/双向的其他器件引脚，会提示绕过串阻。其他器件可用 `latch_rc_filter` 中的 `part_pattern`、`pin_pattern`、`series_ohms`、`shunt_pf` 扩展。该规则只检查导出的网络拓扑和标称值，不判断滤波效果、信号完整性、图上距离或布局位置；与普通时钟串阻规则应避免选中同一引脚，以免报告重复。

报告中的 `rule_coverage` 有 `automatic`、`automatic_candidates`、`not_configured`、`configured`、`no_targets` 和 `partial_no_targets` 状态；`configured_rule_targets` 记录规则命中的目标数量。`no_targets` 不等于检查通过。报告中的 `manual_review` 也不是已确认的电气错误。没有器件手册、BOM/额定参数、信号默认态或实际工作条件时，脚本不会推断这些约束。

可运行 `& 'D:\GPTPRJ\DSNCheck\tests\Test-PowerNetReview.ps1'`、`& 'D:\GPTPRJ\DSNCheck\tests\Test-Additional.ps1'`、`& 'D:\GPTPRJ\DSNCheck\tests\Test-CapacitorDerating.ps1'`、`& 'D:\GPTPRJ\DSNCheck\tests\Test-NetworkNaming.ps1'`、`& 'D:\GPTPRJ\DSNCheck\tests\Test-OECheck.ps1'`、`& 'D:\GPTPRJ\DSNCheck\tests\Test-ClockSeries.ps1'`、`& 'D:\GPTPRJ\DSNCheck\tests\Test-ResetBias.ps1'`、`& 'D:\GPTPRJ\DSNCheck\tests\Test-InterruptBias.ps1'` 和 `& 'D:\GPTPRJ\DSNCheck\tests\Test-LatchFilter.ps1'` 验证审核流程与新增规则。检查器只读 Capture 的导出数据，绝不修改 DSN。

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
| 电源与地网络 | 已审核 `power_nets.confirmed.json` | 候选来自命名、Global、Pin 与两端器件连通关系 |
| 电源命名识别 | Dbo 网络名 | `数字V数字` 或 `数字.数字V` 是自动候选规则，不是最终判定 |
| Power 引脚外部供电 | Dbo `pin` + 已确认电源网络 | `pin.pin_type=7`、`pin.net_name`、确认映射 |
| 供电器件就近滤波 | Dbo `part`、`pin` | 同页电容、完整供电网络名及接地网络；不检查图纸距离 |
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

## CI5.1 引脚位号核对

Excel 表格 CI 检查与通用检查分别运行，当前 CI 入口覆盖 CI4.1、CI4.5、CI5.1、CI5.6：

```powershell
& 'D:\GPTPRJ\DSNCheck\check\ci_excel\Run-DSNCheck-CI4-CI5.ps1' `
  -InputDirectory 'D:\GPTPRJ\EXAMPLE_SCH\AT91SAM9M10-G45-EK_REVA2-TOOL-TEST_checkdata' `
  -RulesFile 'D:\GPTPRJ\DSNCheck\check\ci_excel\CI4-CI5.rules.example.json'
```

两组检查只共享离线导出数据，分别生成独立报告；示例规则需要按实际工程调整。

`check/ci_excel/Run-DSNCheck-CI4-CI5.ps1` 默认读取器件引脚名中的位号，例如 `XD0`、`XD1` 或 `A0`、`A1`，并与总线成员网络的位号比较。位宽来自 Bus 范围，不限于 8 位；`DATA[0..n]` 可与 `XD0..XDn` 比较。比较按同一 Page、同一器件、同一引脚名前缀分组，不判断总线电气方向。

- 同组引脚位号只有个别不一致时，报告疑似位序错接。
- 整组存在相同的非零偏移时，列为人工确认；地址线偏移可能是有意设计。
- 没有足够的带位号引脚可比较时，列为人工确认，不视为通过。
- 引脚名与网络名不遵循这些规则时，可在 `check/ci_excel/CI4-CI5.rules.example.json` 所示的 `bus_mappings` 中提供明确映射。

当前的自动位号核对依据导出的成员网络和器件 Pin。跨 Page 导线、别名及连接器的完整路径仍需结合导出数据另行复核。

## 兼容性说明

- 当前按 OrCAD Capture 16.6 的 Tcl/Dbo API 编写。
- 17.x/23.x 通常保留这些 Dbo 对象，但应先用样例工程做回归验证。
- Capture 16.6 在部分新版 Windows 11 上可能在 `combase.dll` 中崩溃；这属于 Capture 启动兼容性问题。应使用企业实际支持的 Windows/Capture 组合，或升级 Cadence 后再运行同一导出器。
- ISCF 和 Custom DRC 文件是 Cadence 安装包随附 Tcl 工具，文件头注明为无支持示例工具；生产环境应保留 Dbo JSONL 作为稳定的内部交换格式。
- 活动设计入口直接只读遍历 `GetActivePMDesign` 返回的设计；独立批处理入口才创建 Dbo Session。两者都不保存或修改 DSN，也不创建 DRC Marker。
