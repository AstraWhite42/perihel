using System.Threading;
using Microsoft.UI.Xaml;

namespace Perihel;

public partial class App : Application
{
    private Mutex? instance;
    private Panel? panel;
    public App() { InitializeComponent(); }
    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        instance = new Mutex(true, @"Local\Perihel.Windows.Tray", out var first);
        if (!first) { Exit(); return; }
        panel = new Panel();
        panel.Begin();
    }
}
