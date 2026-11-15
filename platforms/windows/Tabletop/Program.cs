using Microsoft.UI.Xaml;
using System.Runtime.InteropServices;

namespace Tabletop;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        try
        {
            WinRT.ComWrappersSupport.InitializeComWrappers();
            Application.Start(_ =>
            {
                var context = new DispatcherQueueSynchronizationContext(DispatcherQueue.GetForCurrentThread());
                SynchronizationContext.SetSynchronizationContext(context);
                try { _ = new App(); }
                catch (Exception error) { Report(error); }
            });
        }
        catch (Exception error) { Report(error); }
    }

    internal static void Report(Exception error)
    {
        var text = error.ToString();
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tabletop");
        Directory.CreateDirectory(directory);
        File.WriteAllText(Path.Combine(directory, "startup-error.log"), text);
        MessageBoxW(IntPtr.Zero, text, "Tabletop startup error", 0x10);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr owner, string text, string caption, uint type);
}
