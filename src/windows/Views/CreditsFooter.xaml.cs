using System;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Perihel;
public sealed partial class CreditsFooter : UserControl
{
    private readonly DateTimeOffset?[] expiries;
    private readonly TextBlock[] values;
    internal bool Expanded { get; private set; }

    internal CreditsFooter(int? count, DateTimeOffset?[] expiries, bool expanded)
    {
        InitializeComponent();
        this.expiries = expiries;
        values = new TextBlock[expiries.Length];
        Count.Text = count.HasValue ? $"可用重置 {count} 次" : "可用重置 暂无数据";
        Arrow.Visibility = CreditsToggle.Visibility = expiries.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        for (int i = 0; i < expiries.Length; i++)
        {
            var row = new Grid { ColumnSpacing = 8 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.Children.Add(new TextBlock { Text = $"重置机会 {i + 1}", FontSize = 12 });
            var value = new TextBlock { FontSize = 12, HorizontalAlignment = HorizontalAlignment.Right, TextTrimming = TextTrimming.CharacterEllipsis };
            Grid.SetColumn(value, 1);
            row.Children.Add(value); Details.Children.Add(row); values[i] = value;
        }
        SetExpanded(expanded && expiries.Length > 0);
        Tick(DateTimeOffset.Now);
    }
    private void Toggle(object sender, RoutedEventArgs e) => SetExpanded(!Expanded);
    private void SetExpanded(bool expanded)
    {
        Expanded = expanded;
        Details.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        Arrow.Glyph = expanded ? "\uE70E" : "\uE70D";
        Tick(DateTimeOffset.Now);
    }
    internal void Tick(DateTimeOffset now)
    {
        if (expiries.Length > 0 && expiries[0] is { } nearest)
        {
            Nearest.Text = "最近到期 " + ResetCredit.Summary(nearest, now);
            SetHint(CreditsToggle, ResetCredit.Tooltip(nearest, now));
        }
        AutomationProperties.SetName(CreditsToggle, $"{Count.Text} {Nearest.Text}，{(Expanded ? "收起" : "展开")}到期明细");
        if (!Expanded) return;
        for (int i = 0; i < expiries.Length; i++)
        {
            if (expiries[i] is { } expiry)
            {
                values[i].Text = ResetCredit.Summary(expiry, now);
                SetHint(values[i], ResetCredit.Tooltip(expiry, now));
            }
            else values[i].Text = "未提供到期时间";
        }
    }
    internal static void SetHint(FrameworkElement element, string text)
    {
        if (ToolTipService.GetToolTip(element) as string != text) ToolTipService.SetToolTip(element, text);
    }
}
