using System;
using System.ComponentModel;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Win32;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.Storage.Pickers;
using Forms = System.Windows.Forms;

namespace Perihel;
public sealed partial class Panel : Window
{
    private Settings settings = Settings.Load();
    private string? temporaryCli;
    private readonly ResetFeed feed = new();
    private readonly string? newsFixture;
    private readonly DispatcherTimer newsTimer = new() { Interval = TimeSpan.FromSeconds(30) };
    private bool resizeQueued;
    private readonly CancellationTokenSource lifetime = new();
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromSeconds(1) };
    private readonly Tray tray;
    private readonly string version;
    private string? path, cliVersion, error;
    private Inspection? inspection;
    private DateTimeOffset lastAttempt = DateTimeOffset.MinValue;
    private DateTimeOffset? success;
    private bool guide, loading, picking, closing;
    private long hiddenAt;
    private readonly DispatcherTimer focusCheck = new() { Interval = TimeSpan.FromMilliseconds(120) };
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);
    private readonly nint hwnd;
    [DllImport("user32.dll")] private static extern bool SetForegroundWindow(nint hwnd);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint hwnd);
    [DllImport("shcore.dll")] private static extern int GetDpiForMonitor(nint monitor, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] private static extern nint MonitorFromPoint(System.Drawing.Point point, uint flags);

    public Panel()
    {
        var args = Environment.GetCommandLineArgs();
        var index = Array.IndexOf(args, "--cli-path");
        if (index >= 0 && index + 1 < args.Length) temporaryCli = Path.GetFullPath(args[index + 1]);
        var newsIndex = Array.IndexOf(args, "--news-fixture");
        if (newsIndex >= 0 && newsIndex + 1 < args.Length) newsFixture = Path.GetFullPath(args[newsIndex + 1]);
        InitializeComponent();
        using var metadata = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory,"version.json")));
        version = metadata.RootElement.GetProperty("version").GetString()!;
        InfoVersion.Text = $"近星点 {version}（构建 {metadata.RootElement.GetProperty("build").GetInt32()}） · 白星澈AstraWhite";
        hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        guide = !settings.HasCompletedSetup;
        ConfigureMenu();
        ApplyTheme();
        var presenter = (OverlappedPresenter)AppWindow.Presenter;
        presenter.SetBorderAndTitleBar(true, false);
        presenter.IsResizable = presenter.IsMaximizable = presenter.IsMinimizable = false;
        AppWindow.IsShownInSwitchers = false;
        tray = new Tray(() => DispatcherQueue.TryEnqueue(Toggle));
        tray.ImageChanged += ShowEnergyPreview;
        Root.ActualThemeChanged += (_, _) => { tray.InvalidateAppearance(); Tick(); };
        Tick();
        Activated += (_, args) => {
            if (args.WindowActivationState == WindowActivationState.Deactivated && AppWindow.IsVisible)
                focusCheck.Start();
        };
        focusCheck.Tick += (_, _) => {
            if (!AppWindow.IsVisible) { focusCheck.Stop(); return; }
            GetWindowThreadProcessId(GetForegroundWindow(), out var foreground);
            if (picking || foreground == 0 || foreground == Environment.ProcessId) return;
            SettingsMenu.Hide(); AppWindow.Hide(); hiddenAt = Environment.TickCount64; focusCheck.Stop();
        };
        AppWindow.Closing += (_, e) => { if (!closing) { e.Cancel = true; AppWindow.Hide(); } };
        Closed += (_, _) => { lifetime.Cancel(); focusCheck.Stop(); newsTimer.Stop(); feed.Dispose(); timer.Stop(); SystemEvents.PowerModeChanged -= PowerChanged; tray.Dispose(); };
        Body.SizeChanged += (_, _) => QueueLayout();
        Toolbar.SizeChanged += (_, _) => QueueLayout();
        Root.Loaded += (_, _) => { Root.XamlRoot.Changed += (_, _) => QueueLayout(); QueueLayout(); };
        newsTimer.Tick += (_, _) => _ = RefreshNews();
        SystemEvents.PowerModeChanged += PowerChanged;
        timer.Tick += (_, _) => {
            Tick();
            var expired = inspection?.Snapshot.Cards(inspection.Plan).Any(c => c.Window.End <= DateTimeOffset.Now) == true;
            if ((DateTimeOffset.Now - lastAttempt).TotalSeconds >= (expired ? 30 : 120)) _ = Refresh();
        };
    }
    internal void Begin()
    {
        timer.Start(); newsTimer.Start(); _ = RefreshNews();
        if (guide) Open();
        else { AppWindow.Hide(); _ = Refresh(); }
    }
    private void Toggle()
    {
        if (AppWindow.IsVisible) AppWindow.Hide();
        else if (hiddenAt == 0 || Environment.TickCount64 - hiddenAt > 250) Open();
    }
    private void Open()
    {
        foreach (var card in Cards.Children.OfType<QuotaCard>()) card.ResetExpansion();
        Scroller.ChangeView(null, 0, null, true);
        RenderState(); LayoutPanel(); AppWindow.Show(); Activate(); SetForegroundWindow(hwnd); _ = Refresh();
    }
    private async Task RefreshNews()
    {
        await feed.Refresh(newsFixture, lifetime.Token);
        if (!closing && AppWindow.IsVisible) Tick();
    }
    private void QueueLayout()
    {
        if (resizeQueued || !AppWindow.IsVisible || closing) return;
        resizeQueued = true;
        DispatcherQueue.TryEnqueue(() => { resizeQueued = false; if (AppWindow.IsVisible && !closing) LayoutPanel(); });
    }
    private void LayoutPanel()
    {
        var cursor = Forms.Cursor.Position;
        var screen = AppWindow.IsVisible ? Forms.Screen.FromHandle(hwnd) : Forms.Screen.FromPoint(cursor);
        var work = screen.WorkingArea;
        var anchor = AppWindow.IsVisible ? new System.Drawing.Point(work.Left,work.Top) : cursor;
        var monitor = MonitorFromPoint(anchor, 2);
        var dpi = GetDpiForMonitor(monitor, 0, out uint monitorDpi, out _) == 0 ? monitorDpi : GetDpiForWindow(hwnd);
        var scale = dpi / 96.0;
        int width = Math.Min(work.Width, (int)Math.Ceiling(400 * scale));
        // AppWindow sizes include the native frame; XAML measures the client area in DIPs.
        int frameWidth = Math.Max(0, AppWindow.Size.Width - AppWindow.ClientSize.Width);
        int frameHeight = Math.Max(0, AppWindow.Size.Height - AppWindow.ClientSize.Height);
        double contentWidth = Math.Max(1, (width - frameWidth) / scale - Root.Padding.Left - Root.Padding.Right);
        var available = new Windows.Foundation.Size(contentWidth, double.PositiveInfinity);
        Toolbar.Measure(available);
        Body.Measure(available);
        double fixedHeight = Root.Padding.Top + Toolbar.DesiredSize.Height + Root.RowSpacing + Root.Padding.Bottom;
        double bodyLimit = Math.Max(1, Math.Min(480, (work.Height - 16 - frameHeight) / scale - fixedHeight));
        double bodyHeight = Body.DesiredSize.Height;
        bool overflow = bodyHeight > bodyLimit;
        Scroller.VerticalScrollBarVisibility = overflow ? ScrollBarVisibility.Auto : ScrollBarVisibility.Disabled;
        int height = Math.Min(work.Height, frameHeight + (int)Math.Ceiling((fixedHeight + Math.Min(bodyHeight, bodyLimit)) * scale));
        var bounds = screen.Bounds;
        bool left = work.Left > bounds.Left, top = work.Top > bounds.Top;
        int x = left ? work.Left + 8 : work.Right - width - 8;
        int y = top ? work.Top + 8 : work.Bottom - height - 8;
        var placement = new RectInt32(Math.Max(work.Left,x), Math.Max(work.Top,y), width,height);
        if (AppWindow.Size.Width != width || AppWindow.Size.Height != height || AppWindow.Position.X != placement.X || AppWindow.Position.Y != placement.Y)
            AppWindow.MoveAndResize(placement);
    }
    private void PowerChanged(object sender, PowerModeChangedEventArgs args)
    { if (args.Mode == PowerModes.Resume) DispatcherQueue.TryEnqueue(() => _ = Refresh()); }
    private async Task Refresh()
    {
        if (loading || closing) return;
        loading = true; lastAttempt = DateTimeOffset.Now; RenderState();
        try
        {
            path = Cli.Locate(temporaryCli ?? settings.CliPath);
            cliVersion = null;
            if (path == null) throw new SetupIssue("尚未找到 Codex CLI，请安装或选择已有 CLI。");
            try { cliVersion = await Cli.Version(path,lifetime.Token); }
            catch (Win32Exception e) { throw new SetupIssue(e.Message); }
            inspection = await Cli.Read(path,version,lifetime.Token);
            success = DateTimeOffset.Now; error = null;
        }
        catch (OperationCanceledException) when (closing) { }
        catch (Exception e)
        {
            error = e.Message;
            if (e is SetupIssue) { guide = true; inspection = null; success = null; }
        }
        finally
        {
            loading = false;
            if (!closing) { RebuildCards(); RenderState(); if (AppWindow.IsVisible) LayoutPanel(); }
        }
    }
    private void RebuildCards()
    {
        var expanded = Cards.Children.OfType<QuotaCard>().Where(c => c.Expanded).Select(c => c.Key).ToHashSet();
        bool creditsExpanded = Cards.Children.OfType<CreditsFooter>().FirstOrDefault()?.Expanded == true;
        Cards.Children.Clear();
        if (inspection == null) return;
        var credits = inspection.Snapshot.RateLimitResetCredits;
        var expiries = credits?.SortedExpiries() ?? [];
        foreach (var (bucket, slot, title, w) in inspection.Snapshot.Cards(inspection.Plan))
            Cards.Children.Add(new QuotaCard((bucket, slot), title, w, expanded.Contains((bucket, slot)), expiries, settings.ProgressStyle));
        if (Cards.Children.Count == 0) Cards.Children.Add(new TextBlock { Text = "当前账户未返回额度窗口" });
        if (credits != null) Cards.Children.Add(new CreditsFooter(credits.AvailableCount, expiries, creditsExpanded));
    }
    private void RenderState()
    {
        Guide.Visibility = guide ? Visibility.Visible : Visibility.Collapsed;
        Cards.Visibility = guide ? Visibility.Collapsed : Visibility.Visible;
        Notice.IsOpen = error != null; Notice.Message = error ?? "";
        CliInfo.Text = cliVersion != null ? $"{cliVersion}\n{path}" : loading ? "正在检测…" : "安装命令：npm install -g @openai/codex";
        LoginButton.IsEnabled = cliVersion != null && !loading;
        StartButton.IsEnabled = inspection != null && error == null && !loading;
        RefreshButton.IsEnabled = PickMenu.IsEnabled = PickButton.IsEnabled = RetryButton.IsEnabled = !loading;
        Tick();
    }
    private void Tick()
    {
        var now = DateTimeOffset.Now;
        Status.Text = loading ? "更新中…" : success is not { } updated ? "尚未获取额度" :
            (now-updated).TotalMinutes < 1 ? "刚刚更新" : $"{(int)(now-updated).TotalMinutes} 分钟前更新";
        var first = inspection?.Snapshot.Cards(inspection.Plan).FirstOrDefault().Window;
        var remaining = first?.Remaining is double r ? $"{Math.Round(r, MidpointRounding.AwayFromZero)}%" : null;
        var difference = first?.UsedPercent - first?.Theory(now);
        var budget = difference is not double d ? null : Math.Abs(d) < 0.05 ? "0.0%" : d.ToString("+0.0;-0.0") + "%";
        var warning = error != null || inspection?.Snapshot.Cards(inspection.Plan).Any(c => c.Window.End <= now) == true;
        var value = settings.MenuBarDisplay switch {
            MenuBarDisplay.IconOnly => "", MenuBarDisplay.Budget => budget, _ => remaining
        } ?? (loading ? "…" : "—");
        if (warning && settings.MenuBarDisplay != MenuBarDisplay.IconOnly) value += " !";
        TrayValue.Text = value;
        TrayValue.Visibility = value.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        string summary = $"剩余 {remaining ?? "—"} · 预算偏差 {budget ?? "—"}";
        tray.Update(first?.Remaining, error ?? $"近星点 {value}\n{summary}", settings.DepletionDirection, value);
        if (!guide && AppWindow.IsVisible)
        {
            Cards.Children.OfType<CreditsFooter>().FirstOrDefault()?.Tick(now);
            var notice = feed.Notice(now);
            foreach (var c in Cards.Children.OfType<QuotaCard>()) c.Tick(now, notice);
        }
    }
    private void ConfigureMenu()
    {
        AddChoices(ThemeMenu, settings.Theme, (s,v) => s with { Theme = v },
            (Theme.System,"系统原生"), (Theme.Readable,"清晰底色"));
        AddChoices(DirectionMenu, settings.DepletionDirection, (s,v) => s with { DepletionDirection = v },
            (DepletionDirection.Counterclockwise,"逆时针熄灭"), (DepletionDirection.Clockwise,"顺时针熄灭"));
        AddChoices(DisplayMenu, settings.MenuBarDisplay, (s,v) => s with { MenuBarDisplay = v },
            (MenuBarDisplay.Remaining,"剩余百分比"), (MenuBarDisplay.Budget,"领先／落后百分比"), (MenuBarDisplay.IconOnly,"仅图标"));
        AddChoices(SegmentsMenu, settings.ProgressStyle, (s,v) => s with { ProgressStyle = v },
            (ProgressStyle.CalendarDays,"按自然时点分段"), (ProgressStyle.RollingDays,"按等分时长分段"), (ProgressStyle.Continuous,"不分段"));
    }
    private void AddChoices<T>(MenuFlyoutSubItem group, T selected, Func<Settings,T,Settings> change,
        params (T Value,string Label)[] choices) where T : struct, Enum
    {
        foreach (var (value,label) in choices)
        {
            var item = new RadioMenuFlyoutItem { Text = label, GroupName = group.Name, IsChecked = value.Equals(selected) };
            item.Click += (_, _) => {
                var old = settings;
                var next = change(old,value);
                if (!Save(next))
                {
                    foreach (var entry in group.Items.OfType<RadioMenuFlyoutItem>())
                        entry.IsChecked = entry.Tag is T v && change(old,v) == old;
                    return;
                }
                if (old.Theme != next.Theme) ApplyTheme();
                if (old.ProgressStyle != next.ProgressStyle)
                    foreach (var card in Cards.Children.OfType<QuotaCard>()) card.SetProgressStyle(next.ProgressStyle);
                Tick(); QueueLayout();
            };
            item.Tag = value;
            group.Items.Add(item);
        }
    }
    private void ApplyTheme()
    {
        bool system = settings.Theme == Theme.System;
        Root.Style = (Style)Root.Resources[system ? "SystemSurface" : "ReadableSurface"];
        SystemBackdrop = system ? new Microsoft.UI.Xaml.Media.MicaBackdrop() : null;
    }
    private void ShowEnergyPreview(System.Drawing.Bitmap bitmap)
    {

        using var buffer = new MemoryStream();
        using var tinted = new System.Drawing.Bitmap(bitmap.Width,bitmap.Height);
        using var graphics = System.Drawing.Graphics.FromImage(tinted);
        bool dark = Root.ActualTheme == ElementTheme.Dark;
        float ink = dark ? 0.96f : 0.14f;
        using var attributes = new System.Drawing.Imaging.ImageAttributes();
        attributes.SetColorMatrix(new System.Drawing.Imaging.ColorMatrix { Matrix00=0, Matrix11=0, Matrix22=0, Matrix40=ink, Matrix41=ink, Matrix42=ink });
        graphics.DrawImage(bitmap, new System.Drawing.Rectangle(0,0,bitmap.Width,bitmap.Height), 0,0,bitmap.Width,bitmap.Height,System.Drawing.GraphicsUnit.Pixel,attributes);
        tinted.Save(buffer, System.Drawing.Imaging.ImageFormat.Png);
        buffer.Position = 0;
        using var stream = buffer.AsRandomAccessStream();
        var image = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
        image.SetSource(stream);
        EnergyPreview.Source = image;
    }
    private void SetupClick(object sender, RoutedEventArgs e) { guide = true; RenderState(); LayoutPanel(); _ = Refresh(); }
    private void StartClick(object sender, RoutedEventArgs e)
    {
        if (inspection == null || !Save(settings with { HasCompletedSetup = true })) return;
        guide = false; RenderState(); LayoutPanel();
    }
    private bool Save(Settings next)
    {
        try { next.Save(); settings = next; return true; }
        catch (Exception e) { error = e.Message; RenderState(); return false; }
    }
    private async void PickClick(object sender, RoutedEventArgs e)
    {
        picking = true;
        try
        {
            var picker = new FileOpenPicker();
            picker.FileTypeFilter.Add(".exe"); picker.FileTypeFilter.Add(".cmd");
            WinRT.Interop.InitializeWithWindow.Initialize(picker, hwnd);
            if (await picker.PickSingleFileAsync() is { } file && Save(settings with { CliPath = file.Path }))
            { temporaryCli = null; inspection = null; success = null; await Refresh(); }
        }
        catch (Exception ex) { error = ex.Message; RenderState(); }
        finally { picking = false; }
    }
    private void CopyClick(object sender, RoutedEventArgs e)
    {
        var data = new DataPackage(); data.SetText("codex login"); Clipboard.SetContent(data);
    }
    private void LoginClick(object sender, RoutedEventArgs e)
    {
        try { if (path != null) Cli.Login(path); }
        catch (Exception ex) { error = ex.Message; RenderState(); }
    }
    private void RefreshClick(object sender, RoutedEventArgs e) => _ = Refresh();
    private void ExitClick(object sender, RoutedEventArgs e) { closing = true; Close(); }
}
