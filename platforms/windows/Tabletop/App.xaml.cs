using Microsoft.UI.Xaml;

namespace Tabletop;

public partial class App : Application
{
    private Window? window;
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        window = new MainWindow();
        window.Activate();
    }
}
