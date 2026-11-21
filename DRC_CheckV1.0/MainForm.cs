using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace DrcCheck
{
    public sealed class MainForm : Form
    {
        private readonly Color ink = Color.FromArgb(31, 45, 53);
        private readonly Color muted = Color.FromArgb(93, 109, 116);
        private readonly Color accent = Color.FromArgb(0, 111, 104);
        private readonly Label fileLabel = new Label();
        private readonly Label stateLabel = new Label();
        private readonly Label reviewCount = new Label();
        private readonly Label resultCount = new Label();
        private readonly Panel dropZone = new Panel();
        private readonly TabControl tabs = new TabControl();
        private readonly DataGridView reviewGrid = new DataGridView();
        private readonly DataGridView resultGrid = new DataGridView();
        private readonly ListBox categories = new ListBox();
        private readonly ComboBox severityFilter = new ComboBox();
        private readonly TextBox detailBox = new TextBox();
        private readonly Button startButton = new Button();
        private readonly Button reportButton = new Button();
        private readonly IEdaNavigator navigator = new UnconfiguredEdaNavigator();
        private BindingList<ReviewRow> reviewRows = new BindingList<ReviewRow>();
        private List<CheckIssue> issues = new List<CheckIssue>();
        private HashSet<string> exportedNets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private string dsnPath = "";
        private string outputDirectory = "";
        private bool busy;

        public MainForm()
        {
            Text = "DRC Check 1.0  |  原理图通用检查";
            MinimumSize = new Size(950, 650);
            Size = new Size(1260, 800);
            StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(247, 249, 249);
            Font = new Font("Microsoft YaHei UI", 9F);
            ForeColor = ink;
            BuildLayout();
            SetState("拖入 .DSN 文件，或点击“选择 DSN”开始。", false);
        }

        private Button Button(string text, EventHandler click, bool primary)
        {
            var button = new Button { Text = text, AutoSize = true, MinimumSize = new Size(104, 34),
                FlatStyle = FlatStyle.Flat, Margin = new Padding(0, 0, 8, 0), Cursor = Cursors.Hand };
            button.FlatAppearance.BorderColor = primary ? accent : Color.FromArgb(198, 210, 211);
            button.BackColor = primary ? accent : Color.White;
            button.ForeColor = primary ? Color.White : ink;
            button.Click += click;
            return button;
        }

        private void BuildLayout()
        {
            var root = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 4,
                Padding = new Padding(18), BackColor = BackColor };
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 56));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 126));
            root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            root.RowStyles.Add(new RowStyle(SizeType.Absolute, 34));
            Controls.Add(root);

            var header = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2 };
            header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            var title = new Label { Text = "DRC CHECK", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft,
                Font = new Font("Microsoft YaHei UI", 16F, FontStyle.Bold), ForeColor = ink };
            header.Controls.Add(title, 0, 0);
            var fileActions = new FlowLayoutPanel { AutoSize = true, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };
            fileActions.Controls.Add(Button("打开导出数据", (s, e) => ChooseExport(), false));
            fileActions.Controls.Add(Button("选择 DSN", (s, e) => ChooseDsn(), false));
            header.Controls.Add(fileActions, 1, 0);
            root.Controls.Add(header, 0, 0);

            dropZone.Dock = DockStyle.Fill;
            dropZone.Margin = new Padding(0, 2, 0, 12);
            dropZone.BackColor = Color.White;
            dropZone.AllowDrop = true;
            dropZone.Paint += (s, e) => {
                using (var pen = new Pen(Color.FromArgb(135, 175, 174), 1.5F) { DashStyle = System.Drawing.Drawing2D.DashStyle.Dash })
                    e.Graphics.DrawRectangle(pen, 2, 2, dropZone.Width - 5, dropZone.Height - 5);
            };
            var dropContent = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 2, ColumnCount = 1, Padding = new Padding(22, 14, 22, 14) };
            dropContent.RowStyles.Add(new RowStyle(SizeType.Absolute, 32));
            dropContent.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            var dropTitle = new Label { Text = "将 .DSN 文件拖到这里", Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleCenter,
                Font = new Font("Microsoft YaHei UI", 11F, FontStyle.Bold), ForeColor = accent };
            fileLabel.Text = "Cadence Capture 文件 · 导出后先审核电源与地网络";
            fileLabel.Dock = DockStyle.Fill; fileLabel.TextAlign = ContentAlignment.MiddleCenter;
            fileLabel.ForeColor = muted; fileLabel.AutoEllipsis = true;
            dropContent.Controls.Add(dropTitle, 0, 0);
            dropContent.Controls.Add(fileLabel, 0, 1);
            dropZone.Controls.Add(dropContent);
            AttachDrop(dropZone); AttachDrop(dropContent); AttachDrop(dropTitle); AttachDrop(fileLabel);
            root.Controls.Add(dropZone, 0, 1);

            tabs.Dock = DockStyle.Fill;
            tabs.Font = new Font("Microsoft YaHei UI", 9.5F);
            var reviewTab = new TabPage("  1  电源 / 地审核  ") { BackColor = Color.White, Padding = new Padding(12) };
            var resultTab = new TabPage("  2  检查结果  ") { BackColor = Color.White, Padding = new Padding(12) };
            tabs.TabPages.Add(reviewTab); tabs.TabPages.Add(resultTab);
            root.Controls.Add(tabs, 0, 2);
            BuildReview(reviewTab);
            BuildResults(resultTab);

            stateLabel.Dock = DockStyle.Fill; stateLabel.TextAlign = ContentAlignment.MiddleLeft;
            stateLabel.ForeColor = muted; stateLabel.AutoEllipsis = true;
            root.Controls.Add(stateLabel, 0, 3);
        }

        private void BuildReview(TabPage page)
        {
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1 };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 45));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 54));
            page.Controls.Add(layout);
            var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.LeftToRight, WrapContents = false };
            reviewCount.AutoSize = true; reviewCount.MinimumSize = new Size(175, 34);
            reviewCount.TextAlign = ContentAlignment.MiddleLeft;
            reviewCount.Text = "等待导出数据";
            toolbar.Controls.Add(reviewCount);
            toolbar.Controls.Add(Button("接受选中", (s, e) => SetSelectedDecision("accept"), false));
            toolbar.Controls.Add(Button("拒绝选中", (s, e) => SetSelectedDecision("reject"), false));
            toolbar.Controls.Add(Button("补充网络", (s, e) => AddNetwork(), false));
            toolbar.Controls.Add(Button("移除补充项", (s, e) => RemoveManualRow(), false));
            layout.Controls.Add(toolbar, 0, 0);

            ConfigureGrid(reviewGrid);
            reviewGrid.AutoGenerateColumns = false;
            reviewGrid.AllowUserToAddRows = false;
            reviewGrid.Columns.Add(new DataGridViewTextBoxColumn { DataPropertyName = "Net", HeaderText = "网络名", Width = 180, ReadOnly = true });
            var kind = new DataGridViewComboBoxColumn { DataPropertyName = "Kind", HeaderText = "类型", Width = 105, FlatStyle = FlatStyle.Flat };
            kind.Items.AddRange("power", "ground", "conflict"); reviewGrid.Columns.Add(kind);
            reviewGrid.Columns.Add(new DataGridViewTextBoxColumn { DataPropertyName = "Voltage", HeaderText = "电压 / V", Width = 95 });
            var decision = new DataGridViewComboBoxColumn { DataPropertyName = "Decision", HeaderText = "决定", Width = 105, FlatStyle = FlatStyle.Flat };
            decision.Items.AddRange("", "accept", "reject"); reviewGrid.Columns.Add(decision);
            reviewGrid.Columns.Add(new DataGridViewTextBoxColumn { DataPropertyName = "Source", HeaderText = "来源", Width = 145, ReadOnly = true });
            reviewGrid.Columns.Add(new DataGridViewTextBoxColumn { DataPropertyName = "Evidence", HeaderText = "识别依据", AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill, ReadOnly = true });
            reviewGrid.DataError += (s, e) => { e.ThrowException = false; };
            reviewGrid.CellValueChanged += (s, e) => UpdateReviewCount();
            reviewGrid.CurrentCellDirtyStateChanged += (s, e) => { if (reviewGrid.IsCurrentCellDirty) reviewGrid.CommitEdit(DataGridViewDataErrorContexts.Commit); };
            layout.Controls.Add(reviewGrid, 0, 1);

            var footer = new TableLayoutPanel { Dock = DockStyle.Fill, ColumnCount = 2 };
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
            footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
            var note = new Label { Text = "每条候选需选择接受或拒绝；可修订类型、电压并补充遗漏网络。", Dock = DockStyle.Fill,
                TextAlign = ContentAlignment.MiddleLeft, ForeColor = muted, AutoEllipsis = true };
            footer.Controls.Add(note, 0, 0);
            startButton.Text = "确认网络并开始检查"; startButton.MinimumSize = new Size(186, 38);
            startButton.FlatStyle = FlatStyle.Flat; startButton.FlatAppearance.BorderColor = accent;
            startButton.BackColor = accent; startButton.ForeColor = Color.White;
            startButton.Enabled = false; startButton.Click += async (s, e) => await StartCheck();
            footer.Controls.Add(startButton, 1, 0);
            layout.Controls.Add(footer, 0, 2);
        }

        private void BuildResults(TabPage page)
        {
            var layout = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1 };
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 42));
            layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
            layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 128));
            page.Controls.Add(layout);
            var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill, WrapContents = false };
            resultCount.AutoSize = true; resultCount.MinimumSize = new Size(315, 34);
            resultCount.Text = "检查完成后显示结果"; resultCount.TextAlign = ContentAlignment.MiddleLeft;
            toolbar.Controls.Add(resultCount);
            severityFilter.DropDownStyle = ComboBoxStyle.DropDownList;
            severityFilter.Width = 148; severityFilter.Height = 34;
            severityFilter.Items.AddRange(new object[] { "全部级别", "错误", "警告", "人工确认" });
            severityFilter.SelectedIndex = 0;
            severityFilter.SelectedIndexChanged += (s, e) => RefreshResults();
            toolbar.Controls.Add(severityFilter);
            reportButton.Text = "打开完整报告"; reportButton.AutoSize = true; reportButton.Enabled = false;
            reportButton.Click += (s, e) => {
                string path = Path.Combine(outputDirectory, "dsn_check_report.txt");
                if (File.Exists(path)) ProcessFile(path);
            };
            toolbar.Controls.Add(reportButton);
            layout.Controls.Add(toolbar, 0, 0);

            var split = new SplitContainer { Dock = DockStyle.Fill };
            Shown += (s, e) => {
                split.Panel1MinSize = 190;
                split.Panel2MinSize = 430;
                split.SplitterDistance = 265;
            };
            categories.Dock = DockStyle.Fill; categories.BorderStyle = BorderStyle.FixedSingle;
            categories.SelectedIndexChanged += (s, e) => RefreshResults();
            split.Panel1.Controls.Add(categories);
            ConfigureGrid(resultGrid);
            resultGrid.ReadOnly = true; resultGrid.MultiSelect = false;
            resultGrid.Columns.Add("severity", "级别"); resultGrid.Columns[0].Width = 90;
            resultGrid.Columns.Add("rule", "检查项"); resultGrid.Columns[1].Width = 240;
            resultGrid.Columns.Add("page", "页面"); resultGrid.Columns[2].Width = 190;
            resultGrid.Columns.Add("part", "器件"); resultGrid.Columns[3].Width = 95;
            resultGrid.Columns.Add("pin", "引脚"); resultGrid.Columns[4].Width = 115;
            resultGrid.Columns.Add("net", "网络"); resultGrid.Columns[5].AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill;
            resultGrid.SelectionChanged += (s, e) => ShowDetail();
            resultGrid.CellDoubleClick += (s, e) => {
                if (e.RowIndex < 0) return;
                var issue = resultGrid.Rows[e.RowIndex].Tag as CheckIssue;
                if (issue != null && !navigator.TryNavigate(dsnPath, issue))
                    SetState("EDA 页面跳转接口已预留；尚未配置当前工具的导航适配器。", false);
            };
            split.Panel2.Controls.Add(resultGrid);
            layout.Controls.Add(split, 0, 1);
            detailBox.Dock = DockStyle.Fill; detailBox.Multiline = true; detailBox.ReadOnly = true;
            detailBox.ScrollBars = ScrollBars.Vertical; detailBox.BackColor = Color.FromArgb(249, 251, 251);
            detailBox.BorderStyle = BorderStyle.FixedSingle;
            layout.Controls.Add(detailBox, 0, 2);
        }

        private static void ConfigureGrid(DataGridView grid)
        {
            grid.Dock = DockStyle.Fill;
            grid.AllowUserToAddRows = false;
            grid.AllowUserToDeleteRows = false; grid.AllowUserToResizeRows = false;
            grid.RowHeadersVisible = false; grid.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
            grid.BackgroundColor = Color.White; grid.BorderStyle = BorderStyle.FixedSingle;
            grid.EnableHeadersVisualStyles = false;
            grid.ColumnHeadersDefaultCellStyle.BackColor = Color.FromArgb(235, 242, 241);
            grid.ColumnHeadersDefaultCellStyle.ForeColor = Color.FromArgb(31, 45, 53);
            grid.ColumnHeadersHeight = 34; grid.RowTemplate.Height = 31;
            grid.AlternatingRowsDefaultCellStyle.BackColor = Color.FromArgb(248, 250, 250);
        }

        private void AttachDrop(Control control)
        {
            control.AllowDrop = true;
            control.DragEnter += (s, e) => {
                var files = e.Data.GetData(DataFormats.FileDrop) as string[];
                e.Effect = files != null && files.Length == 1 && files[0].EndsWith(".dsn", StringComparison.OrdinalIgnoreCase)
                    ? DragDropEffects.Copy : DragDropEffects.None;
            };
            control.DragDrop += (s, e) => {
                var files = e.Data.GetData(DataFormats.FileDrop) as string[];
                if (files != null && files.Length == 1) OpenDesign(files[0]);
            };
        }

        private void ChooseDsn()
        {
            using (var dialog = new OpenFileDialog { Filter = "Cadence DSN (*.dsn)|*.dsn", Title = "选择原理图 DSN" })
                if (dialog.ShowDialog(this) == DialogResult.OK) OpenDesign(dialog.FileName);
        }

        private void ChooseExport()
        {
            if (busy) return;
            using (var dialog = new FolderBrowserDialog { Description = "选择包含 manifest.json 和 dbo 数据的导出目录" })
                if (dialog.ShowDialog(this) == DialogResult.OK) OpenExistingExport(dialog.SelectedPath);
        }

        private async Task RunBusy(string message, Action work, Action completed)
        {
            busy = true; startButton.Enabled = false;
            reviewGrid.ReadOnly = true;
            SetState(message, true);
            try
            {
                await Task.Run(work);
                completed();
            }
            catch (Exception ex)
            {
                SetState("操作失败：" + ex.Message.Split('\n')[0], false);
                MessageBox.Show(this, ex.Message, "检查未完成", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally {
                busy = false;
                reviewGrid.ReadOnly = false;
                startButton.Enabled = reviewRows.Count > 0 && outputDirectory.Length > 0;
            }
        }

        public async void OpenDesign(string path)
        {
            if (busy) return;
            if (!File.Exists(path) || !path.EndsWith(".dsn", StringComparison.OrdinalIgnoreCase))
            {
                MessageBox.Show(this, "请选择存在的 .DSN 文件。", "文件无效", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }
            dsnPath = Path.GetFullPath(path);
            outputDirectory = Workflow.OutputFor(dsnPath);
            fileLabel.Text = dsnPath;
            tabs.SelectedIndex = 0;
            reportButton.Enabled = false;
            issues.Clear(); categories.Items.Clear(); resultGrid.Rows.Clear(); detailBox.Clear();
            reviewRows = new BindingList<ReviewRow>(); reviewGrid.DataSource = reviewRows;
            await RunBusy("正在准备 Capture 导出及电源/地候选…", () => {
                if (!Workflow.IsValidExport(dsnPath, outputDirectory))
                    Workflow.RunScript("export\\cadence\\Export-CadenceCheckData.ps1", "-Dsn", dsnPath, "-OutputDirectory", outputDirectory, "-SkipNativeIscf", "-SkipBundledDrc");
                Workflow.PrepareReview(outputDirectory);
                exportedNets = Workflow.ExportedNets(outputDirectory);
                reviewRows = new BindingList<ReviewRow>(Workflow.ReadReview(outputDirectory));
            }, () => {
                reviewGrid.DataSource = reviewRows;
                UpdateReviewCount();
                SetState("候选已加载。请逐条确认电源、地及电压，然后开始检查。", false);
            });
        }

        public async void OpenExistingExport(string directory)
        {
            if (busy) return;
            if (!Directory.Exists(directory)) { MessageBox.Show(this, "导出目录不存在。"); return; }
            outputDirectory = Path.GetFullPath(directory);
            await RunBusy("正在载入已有导出数据…", () => {
                dsnPath = Workflow.SourceOfExport(outputDirectory);
                if (!Workflow.IsValidExport(dsnPath, outputDirectory)) throw new InvalidDataException("导出数据与 DSN 不匹配或已过期。");
                Workflow.PrepareReview(outputDirectory);
                exportedNets = Workflow.ExportedNets(outputDirectory);
                reviewRows = new BindingList<ReviewRow>(Workflow.ReadReview(outputDirectory));
            }, () => {
                fileLabel.Text = dsnPath;
                reviewGrid.DataSource = reviewRows;
                UpdateReviewCount();
                SetState("已有导出数据已加载。请审核网络。", false);
            });
        }

        private void UpdateReviewCount()
        {
            int pending = reviewRows.Count(r => string.IsNullOrEmpty(r.Decision));
            reviewCount.Text = string.Format("候选 {0}  ·  待决定 {1}", reviewRows.Count, pending);
            startButton.Enabled = !busy && reviewRows.Count > 0 && outputDirectory.Length > 0;
        }

        private void SetSelectedDecision(string decision)
        {
            if (busy) return;
            foreach (DataGridViewRow selected in reviewGrid.SelectedRows)
            {
                var row = selected.DataBoundItem as ReviewRow;
                if (row != null) row.Decision = decision;
            }
            reviewGrid.Refresh(); UpdateReviewCount();
        }

        private void AddNetwork()
        {
            if (busy || outputDirectory.Length == 0) return;
            using (var dialog = new Form { Text = "补充电源或地网络", Size = new Size(440, 200),
                StartPosition = FormStartPosition.CenterParent, FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false, MinimizeBox = false, Font = Font })
            {
                var net = new ComboBox { Left = 22, Top = 25, Width = 378, DropDownStyle = ComboBoxStyle.DropDown };
                net.AutoCompleteMode = AutoCompleteMode.SuggestAppend; net.AutoCompleteSource = AutoCompleteSource.ListItems;
                net.Items.AddRange(exportedNets.OrderBy(x => x).Cast<object>().ToArray());
                var kind = new ComboBox { Left = 22, Top = 69, Width = 170, DropDownStyle = ComboBoxStyle.DropDownList };
                kind.Items.AddRange(new object[] { "power", "ground" }); kind.SelectedIndex = 0;
                var voltage = new TextBox { Left = 208, Top = 69, Width = 192 };
                var ok = Button("添加", (s, e) => {
                    string name = net.Text.Trim();
                    if (!exportedNets.Contains(name) || reviewRows.Any(r => r.Net.Equals(name, StringComparison.OrdinalIgnoreCase)))
                    { MessageBox.Show(dialog, "请选择导出数据中存在、且尚未列出的网络。", "无法添加"); return; }
                    reviewRows.Add(new ReviewRow { Net = name, Kind = kind.Text, Voltage = kind.Text == "ground" ? "" : voltage.Text.Trim(),
                        Decision = "accept", Source = "manual", Evidence = "用户在图形界面补充" });
                    UpdateReviewCount(); dialog.DialogResult = DialogResult.OK;
                }, true);
                ok.Left = 296; ok.Top = 111;
                dialog.Controls.Add(new Label { Text = "网络名", Left = 22, Top = 7, AutoSize = true });
                dialog.Controls.Add(new Label { Text = "类型", Left = 22, Top = 52, AutoSize = true });
                dialog.Controls.Add(new Label { Text = "电压 / V（电源可选）", Left = 208, Top = 52, AutoSize = true });
                dialog.Controls.Add(net); dialog.Controls.Add(kind); dialog.Controls.Add(voltage); dialog.Controls.Add(ok);
                dialog.ShowDialog(this);
            }
        }

        private void RemoveManualRow()
        {
            if (busy || reviewGrid.SelectedRows.Count != 1) return;
            var row = reviewGrid.SelectedRows[0].DataBoundItem as ReviewRow;
            if (row != null && row.Source == "manual") { reviewRows.Remove(row); UpdateReviewCount(); }
            else MessageBox.Show(this, "自动候选需选择“reject”，只有手动补充项可以移除。", "不能移除");
        }

        private bool ValidateReview()
        {
            if (reviewRows.Count == 0) { MessageBox.Show(this, "没有候选网络，请先补充电源或地网络。"); return false; }
            var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int accepted = 0;
            foreach (var row in reviewRows)
            {
                if (!names.Add(row.Net) || !exportedNets.Contains(row.Net)) { MessageBox.Show(this, "网络名不存在或重复：" + row.Net); return false; }
                if (row.Decision != "accept" && row.Decision != "reject") { MessageBox.Show(this, "尚未决定网络：" + row.Net); return false; }
                if (row.Decision == "reject") continue;
                accepted++;
                if (row.Kind != "power" && row.Kind != "ground") { MessageBox.Show(this, "请修订网络类型：" + row.Net); return false; }
                if (row.Kind == "ground" && !string.IsNullOrWhiteSpace(row.Voltage)) { MessageBox.Show(this, "地网络不能填写电压：" + row.Net); return false; }
                if (!string.IsNullOrWhiteSpace(row.Voltage) && !Regex.IsMatch(row.Voltage, @"^-?\d+(?:\.\d+)?$"))
                { MessageBox.Show(this, "电压格式无效：" + row.Net); return false; }
            }
            if (accepted == 0) { MessageBox.Show(this, "至少接受一条电源或地网络。"); return false; }
            return true;
        }

        private async Task StartCheck()
        {
            if (busy) return;
            reviewGrid.EndEdit();
            if (!ValidateReview()) return;
            var snapshot = reviewRows.ToList();
            await RunBusy("正在确认网络并执行通用检查…", () => {
                Workflow.SaveReview(outputDirectory, snapshot);
                Workflow.RunScript("check\\generic\\Invoke-PowerNetReview.ps1", "-InputDirectory", outputDirectory, "-Mode", "Confirm");
                Workflow.RunScript("check\\generic\\Run-DSNCheck.ps1", "-InputDirectory", outputDirectory);
                issues = Workflow.ReadReport(outputDirectory);
            }, () => {
                categories.Items.Clear();
                categories.Items.Add("全部检查项");
                foreach (var group in issues.GroupBy(i => i.Category).OrderBy(g => g.Key))
                    categories.Items.Add(string.Format("{0}  ({1})", group.Key, group.Count()));
                categories.SelectedIndex = 0;
                reportButton.Enabled = true;
                tabs.SelectedIndex = 1;
                RefreshResults();
                SetState("检查完成 · 报告已保存至 " + outputDirectory, false);
            });
        }

        private void RefreshResults()
        {
            if (resultGrid == null || resultCount == null) return;
            string category = categories.SelectedIndex <= 0 ? "" : categories.SelectedItem.ToString().Split(new[] { "  (" }, StringSplitOptions.None)[0];
            string severity = severityFilter.SelectedIndex == 1 ? "error" : severityFilter.SelectedIndex == 2 ? "warning" : severityFilter.SelectedIndex == 3 ? "manual_review" : "";
            resultGrid.Rows.Clear();
            foreach (var issue in issues.Where(i => (category == "" || i.Category == category) && (severity == "" || i.Severity == severity)))
            {
                string label = issue.Severity == "error" ? "错误" : issue.Severity == "manual_review" ? "人工确认" : "警告";
                int index = resultGrid.Rows.Add(label, issue.Rule, issue.Page, issue.Part, issue.Pin, issue.Net);
                var row = resultGrid.Rows[index]; row.Tag = issue;
                row.Cells[0].Style.ForeColor = issue.Severity == "error" ? Color.FromArgb(177, 56, 49) :
                    issue.Severity == "manual_review" ? Color.FromArgb(151, 100, 22) : muted;
            }
            resultCount.Text = string.Format("错误 {0}   警告 {1}   人工确认 {2}   |   当前 {3}",
                issues.Count(i => i.Severity == "error"), issues.Count(i => i.Severity == "warning"),
                issues.Count(i => i.Severity == "manual_review"), resultGrid.Rows.Count);
            ShowDetail();
        }

        private void ShowDetail()
        {
            var row = resultGrid.SelectedRows.Count > 0 ? resultGrid.SelectedRows[0] : null;
            var issue = row == null ? null : row.Tag as CheckIssue;
            detailBox.Text = issue == null ? "" : string.Format("{0} · {1}\r\n页面：{2}\r\n器件：{3}   引脚：{4}   网络：{5}\r\n{6}",
                issue.Category, issue.Rule, issue.Page, issue.Part, issue.Pin, issue.Net, issue.Details);
        }

        private void SetState(string message, bool working)
        {
            stateLabel.Text = (working ? "●  " : "") + message;
            stateLabel.ForeColor = working ? accent : muted;
            Cursor = working ? Cursors.WaitCursor : Cursors.Default;
        }

        private void ProcessFile(string path)
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true }); }
            catch (Exception ex) { MessageBox.Show(this, ex.Message, "无法打开报告"); }
        }
    }
}
