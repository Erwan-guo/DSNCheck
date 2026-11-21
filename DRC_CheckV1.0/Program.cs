using System;
using System.Windows.Forms;

namespace DrcCheck
{
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            var form = new MainForm();
            if (args.Length == 1 && args[0].EndsWith(".dsn", StringComparison.OrdinalIgnoreCase))
                form.Shown += (sender, e) => form.OpenDesign(args[0]);
            else if (args.Length == 2 && args[0] == "--export")
                form.Shown += (sender, e) => form.OpenExistingExport(args[1]);
            Application.Run(form);
        }
    }
}
