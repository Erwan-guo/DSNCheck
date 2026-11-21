using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;
using Microsoft.VisualBasic.FileIO;

namespace DrcCheck
{
    public sealed class ReviewRow
    {
        public string Net { get; set; }
        public string Kind { get; set; }
        public string Voltage { get; set; }
        public string Decision { get; set; }
        public string Source { get; set; }
        public string Evidence { get; set; }
    }

    public sealed class CheckIssue
    {
        public string Category { get; set; }
        public string Severity { get; set; }
        public string Rule { get; set; }
        public string Page { get; set; }
        public string Part { get; set; }
        public string Pin { get; set; }
        public string Net { get; set; }
        public string Details { get; set; }
    }

    public interface IEdaNavigator
    {
        bool TryNavigate(string dsnPath, CheckIssue issue);
    }

    public sealed class UnconfiguredEdaNavigator : IEdaNavigator
    {
        public bool TryNavigate(string dsnPath, CheckIssue issue) { return false; }
    }

    internal static class Workflow
    {
        private static readonly JavaScriptSerializer Json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue, RecursionLimit = 100 };
        public static readonly string RepoRoot = Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, ".."));

        public static string Script(string relative)
        {
            string path = Path.Combine(RepoRoot, relative);
            if (!File.Exists(path)) throw new FileNotFoundException("缺少检查脚本。请将软件放在 DSNCheck/DRC_CheckV1.0 目录。", path);
            return path;
        }

        private static string Q(string value) { return "\"" + value + "\""; }

        public static string RunScript(string relative, params string[] arguments)
        {
            var start = new ProcessStartInfo(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell", "v1.0", "powershell.exe"));
            start.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Q(Script(relative)) +
                " " + string.Join(" ", arguments.Select(Q).ToArray());
            string[] modulePaths = {
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "WindowsPowerShell", "Modules"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "WindowsPowerShell", "Modules"),
                Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "WindowsPowerShell", "v1.0", "Modules"),
                Environment.GetEnvironmentVariable("PSModulePath") ?? ""
            };
            start.EnvironmentVariables["PSModulePath"] = string.Join(";", modulePaths);
            start.UseShellExecute = false;
            start.CreateNoWindow = true;
            start.RedirectStandardOutput = true;
            start.RedirectStandardError = true;
            var outputEncoding = Encoding.GetEncoding(CultureInfo.CurrentCulture.TextInfo.OEMCodePage);
            start.StandardOutputEncoding = outputEncoding;
            start.StandardErrorEncoding = outputEncoding;
            var output = new StringBuilder();
            using (var process = new Process { StartInfo = start })
            {
                process.OutputDataReceived += (sender, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
                process.ErrorDataReceived += (sender, e) => { if (e.Data != null) lock (output) output.AppendLine(e.Data); };
                process.Start();
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                process.WaitForExit();
                if (process.ExitCode != 0) throw new InvalidOperationException(relative + " 执行失败：\r\n" + output);
            }
            return output.ToString();
        }

        public static string OutputFor(string dsnPath)
        {
            return Path.Combine(Path.GetDirectoryName(dsnPath), Path.GetFileNameWithoutExtension(dsnPath) + "_checkdata");
        }

        public static bool IsValidExport(string dsnPath, string directory)
        {
            string objects = Path.Combine(directory, "dbo", "objects.jsonl");
            string manifest = Path.Combine(directory, "manifest.json");
            if (!File.Exists(Path.Combine(directory, "export.ok")) || !File.Exists(objects) || !File.Exists(manifest)) return false;
            try
            {
                var data = Json.DeserializeObject(File.ReadAllText(manifest, Encoding.UTF8)) as Dictionary<string, object>;
                string source = Get(data, "source_dsn");
                return string.Equals(Path.GetFullPath(source), Path.GetFullPath(dsnPath), StringComparison.OrdinalIgnoreCase)
                    && File.GetLastWriteTimeUtc(objects) >= File.GetLastWriteTimeUtc(dsnPath);
            }
            catch { return false; }
        }

        public static string SourceOfExport(string directory)
        {
            var data = Json.DeserializeObject(File.ReadAllText(Path.Combine(directory, "manifest.json"), Encoding.UTF8)) as Dictionary<string, object>;
            return Path.GetFullPath(Get(data, "source_dsn"));
        }

        public static void PrepareReview(string directory)
        {
            string review = Path.Combine(directory, "power_nets.review.csv");
            string meta = Path.Combine(directory, "power_nets.review.meta.json");
            string objects = Path.Combine(directory, "dbo", "objects.jsonl");
            bool current = false;
            if (File.Exists(review) && File.Exists(meta))
            {
                try
                {
                    var data = Json.DeserializeObject(File.ReadAllText(meta, Encoding.UTF8)) as Dictionary<string, object>;
                    current = string.Equals(Get(data, "source_sha256"), Sha256(objects), StringComparison.OrdinalIgnoreCase);
                }
                catch { current = false; }
            }
            if (current) return;
            string stamp = DateTime.Now.ToString("yyyyMMdd-HHmmss");
            if (File.Exists(review)) File.Copy(review, review + ".backup-" + stamp, true);
            if (File.Exists(meta)) File.Copy(meta, meta + ".backup-" + stamp, true);
            RunScript("check\\generic\\Invoke-PowerNetReview.ps1", "-InputDirectory", directory, "-Mode", "Draft", "-Force");
        }

        private static string Sha256(string path)
        {
            using (var stream = File.OpenRead(path))
            using (var sha = SHA256.Create())
                return BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
        }

        public static List<ReviewRow> ReadReview(string directory)
        {
            var rows = new List<ReviewRow>();
            using (var parser = new TextFieldParser(Path.Combine(directory, "power_nets.review.csv"), Encoding.UTF8))
            {
                parser.SetDelimiters(",");
                parser.HasFieldsEnclosedInQuotes = true;
                string[] headings = parser.ReadFields();
                if (headings == null || headings.Length < 6 || headings[0].TrimStart('\uFEFF') != "net") throw new InvalidDataException("电源候选 CSV 格式不正确。 ");
                while (!parser.EndOfData)
                {
                    string[] values = parser.ReadFields();
                    if (values == null || values.Length < 6) throw new InvalidDataException("电源候选 CSV 行缺少字段。");
                    rows.Add(new ReviewRow { Net = values[0], Kind = values[1], Voltage = values[2], Decision = values[3], Source = values[4], Evidence = values[5] });
                }
            }
            return rows;
        }

        private static string Csv(string value)
        {
            return "\"" + (value ?? "").Replace("\"", "\"\"") + "\"";
        }

        public static void SaveReview(string directory, IList<ReviewRow> rows)
        {
            string path = Path.Combine(directory, "power_nets.review.csv");
            string temporary = path + ".gui-tmp";
            using (var writer = new StreamWriter(temporary, false, new UTF8Encoding(true)))
            {
                writer.WriteLine("\"net\",\"kind\",\"voltage_v\",\"decision\",\"source\",\"evidence\"");
                foreach (var row in rows)
                    writer.WriteLine(string.Join(",", new[] { Csv(row.Net), Csv(row.Kind), Csv(row.Voltage), Csv(row.Decision), Csv(row.Source), Csv(row.Evidence) }));
            }
            if (File.Exists(path)) File.Replace(temporary, path, path + ".gui-backup", true);
            else File.Move(temporary, path);
        }

        public static HashSet<string> ExportedNets(string directory)
        {
            var nets = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string line in File.ReadLines(Path.Combine(directory, "dbo", "objects.jsonl"), Encoding.UTF8))
            {
                var data = Json.DeserializeObject(line) as Dictionary<string, object>;
                string net = Get(data, "net_name");
                if (net.Length > 0 && !net.Equals("NULL", StringComparison.OrdinalIgnoreCase)) nets.Add(net);
            }
            return nets;
        }

        public static List<CheckIssue> ReadReport(string directory)
        {
            string path = Path.Combine(directory, "dsn_check_report.json");
            var root = Json.DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
            var raw = (object[])root["errors"];
            var issues = new List<CheckIssue>();
            foreach (object item in raw)
            {
                var data = item as Dictionary<string, object>;
                string severity = Get(data, "status");
                if (severity.Length == 0) severity = "error";
                string rule = Get(data, "rule");
                string details = Get(data, "details");
                string part = Get(data, "part");
                if (part.Length == 0) part = Get(data, "parts");
                issues.Add(new CheckIssue {
                    Category = Get(data, "category"), Severity = severity, Rule = rule,
                    Page = Get(data, "page"), Part = part, Pin = Get(data, "pin"),
                    Net = Get(data, "net"), Details = details
                });
            }
            return issues;
        }

        private static string Get(IDictionary<string, object> data, string key)
        {
            object value;
            return data != null && data.TryGetValue(key, out value) && value != null ? Convert.ToString(value) : "";
        }
    }
}
