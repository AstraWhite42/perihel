using System;
using System.Collections.Generic;
using System.Linq;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Perihel;
public sealed partial class QuotaCard : UserControl
{
    internal QuotaWindow Model { get; private set; }
    private DateTimeOffset?[] creditExpiries = [];
    internal (string Bucket, int Slot) Key { get; }
    internal bool Expanded { get; private set; }
    private bool originalExpanded;
    private ProgressStyle progressStyle;
    private ResetNotice? notice;
    private double? theory, forecastPercent;
    private readonly TextBlock[][] cells = new TextBlock[5][];
    private Grid? forecastRow;
    private readonly List<(DateTimeOffset Time, int Count, TextBlock Mark)> expiryMarks = new();
    internal QuotaCard((string, int) key, string accountLabel, QuotaWindow window, DateTimeOffset?[] expiries, ProgressStyle style)
    {
        progressStyle = style;
        Key = key; Model = window;
        InitializeComponent();
        BuildTable();
        SetWindow(accountLabel, window, expiries);
        Tick(DateTimeOffset.Now, null);
    }
    internal void UpdateWindow(string accountLabel, QuotaWindow window, DateTimeOffset?[] expiries)
    {
        if (Model == window && AccountLabel.Text == accountLabel && creditExpiries.SequenceEqual(expiries)) return;
        SetWindow(accountLabel, window, expiries);
        Tick(DateTimeOffset.Now, notice);
    }
    private void SetWindow(string accountLabel, QuotaWindow window, DateTimeOffset?[] expiries)
    {
        bool markersChanged = Model.Start != window.Start || Model.End != window.End || !creditExpiries.SequenceEqual(expiries);
        bool timelineChanged = Model != window;
        Model = window;
        creditExpiries = expiries;
        Heading.Text = window.Duration;
        AccountLabel.Text = accountLabel;
        ToolTipService.SetToolTip(AccountLabel, accountLabel);
        Zone.Text = TimeZoneInfo.TryConvertWindowsIdToIanaId(TimeZoneInfo.Local.Id, out var zone) ? zone : TimeZoneInfo.Local.Id;
        Remaining.Text = window.Remaining is double r ? $"{r:F1}" : "暂无数据";
        PercentSign.Visibility = Visible(window.Remaining.HasValue);
        Remaining.FontSize = window.Remaining.HasValue ? 38 : 22;

        StartTime.Text = "开始 " + Date(window.Start);
        EndTime.Text = "重置 " + Date(window.End);
        if (markersChanged || expiryMarks.Count == 0) BuildExpiryMarks(expiries);
        if (timelineChanged) DrawSegments();
    }
    private static string Date(DateTimeOffset? t) => t?.LocalDateTime.ToString(t?.LocalDateTime.Year == DateTime.Now.Year ? "M/d HH:mm" : "yyyy/M/d HH:mm") ?? "暂无数据";
    private void BuildExpiryMarks(DateTimeOffset?[] expiries)
    {
        expiryMarks.Clear();
        ExpiryMarks.Children.Clear();
        var orange = new Microsoft.UI.Xaml.Media.SolidColorBrush(Windows.UI.Color.FromArgb(255, 242, 139, 50));
        foreach (var group in expiries.OfType<DateTimeOffset>().Where(t => t >= Model.Start && t <= Model.End).GroupBy(t => t))
        {
            var mark = new TextBlock { Text = "◆", Width = 16, Height = 16, FontSize = 12,
                TextAlignment = TextAlignment.Center, Foreground = orange };
            expiryMarks.Add((group.Key, group.Count(), mark));
            ExpiryMarks.Children.Add(mark);
            Canvas.SetLeft(mark, Timeline.ActualWidth * Model.Theory(group.Key)!.Value / 100 - mark.Width / 2);
        }
        ExpiryLegend.Visibility = Visible(expiryMarks.Count > 0);
    }
    private void BuildTable()
    {
        string[] labels = ["用量", "实际", "当前理论", "今晚24时理论", "预告时点理论"];
        for (int row = 0; row < labels.Length; row++)
        {
            var grid = new Grid();
            cells[row] = new TextBlock[4];
            for (int col = 0; col < 4; col++)
            {
                grid.ColumnDefinitions.Add(new ColumnDefinition { Width = col == 0 ? new GridLength(1, GridUnitType.Star) : new GridLength(60) });
                var cell = new TextBlock {
                    Style = row == 0 ? (Style)Application.Current.Resources["Meta"] : null,
                    FontSize = row == 0 ? 12 : 13, TextAlignment = col == 0 ? TextAlignment.Left : TextAlignment.Right,
                    Text = col == 0 ? labels[row] : row == 0 ? new[] { "", "已用", "剩余", "差值 ⓘ" }[col] : ""
                };
                if (col > 0) Microsoft.UI.Xaml.Documents.Typography.SetNumeralAlignment(cell, Microsoft.UI.Xaml.FontNumeralAlignment.Tabular);
                Grid.SetColumn(cell, col); grid.Children.Add(cell); cells[row][col] = cell;
            }
            Details.Children.Add(grid);
            if (row == 4) forecastRow = grid;
        }
        ToolTipService.SetToolTip(cells[0][3], "差值 = 当前实际已用 − 该行理论已用，单位为百分点。");
        ToolTipService.SetToolTip(cells[3][0], "按系统时区计算今晚 24 时。窗口提前结束时，理论已用为 100%。");
        ToolTipService.SetToolTip(cells[4][0], "按公告参考时间计算当前窗口的理论用量。");
    }
    private void SetRow(int row, double? used, double? remaining, double? delta)
    {
        cells[row][1].Text = used is double u ? $"{u:F1}%" : "—";
        cells[row][2].Text = remaining is double r ? $"{r:F1}%" : "—";
        cells[row][3].Text = delta is not double d ? "—" : Math.Abs(d) < 0.05 ? "0.0%" : d.ToString("+0.0;-0.0") + "%";
    }
    private static Visibility Visible(bool show) => show ? Visibility.Visible : Visibility.Collapsed;
    internal void ResetExpansion(DateTimeOffset now, ResetNotice? currentNotice)
    {
        Expanded = false;
        Tick(now, currentNotice);
    }
    private void ToggleBudget(object sender, RoutedEventArgs args)
    {
        Expanded = !Expanded;
        Tick(DateTimeOffset.Now, notice);
    }
    private void NewsTrimChanged(TextBlock sender, IsTextTrimmedChangedEventArgs args)
    {
        OriginalToggle.Visibility = Visible(originalExpanded || sender.IsTextTrimmed);
    }
    private void ToggleOriginal(object sender, RoutedEventArgs args)
    {
        originalExpanded = !originalExpanded;
        NewsText.MaxLines = originalExpanded ? 0 : 3;
        OriginalToggle.Content = originalExpanded ? "收起原文" : "展开原文";
    }
    internal void Tick(DateTimeOffset now, ResetNotice? incoming)
    {
        var previous = notice;
        notice = Key.Bucket == "codex" && Model.WindowDurationMins == 10080 ? incoming : null;
        var target = notice?.Reference(Model, now);
        forecastPercent = target is { } time ? Model.Theory(time) : null;
        Countdown.Text = Model.Countdown(now);
        Budget.Text = Model.Budget(now);
        theory = Model.Theory(now);
        bool expandable = Model.WindowDurationMins != 300 && Model.UsedPercent.HasValue && theory.HasValue;
        Budget.Visibility = Visible(!expandable); BudgetToggle.Visibility = Visible(expandable);
        BudgetLabel.Text = Budget.Text;
        BudgetChevron.Glyph = Expanded ? "\uE70E" : "\uE70D";
        AutomationProperties.SetName(BudgetToggle, Budget.Text + (Expanded ? "，收起明细" : "，展开明细"));
        Details.Visibility = Visible(expandable && Expanded);
        forecastRow!.Visibility = Flag.Visibility = Visible(forecastPercent.HasValue);
        if (target.HasValue && (previous != notice || ToolTipService.GetToolTip(Flag) == null)) ToolTipService.SetToolTip(Flag, $"{notice!.TimeLabel} · {Date(target)}");
        if (expandable && Expanded)
        {
            var midnight = Model.Theory(NextMidnight(now.LocalDateTime.Date, TimeZoneInfo.Local));
            SetRow(1, Model.UsedPercent, Model.Remaining, null);
            SetRow(2, theory, 100 - theory, Model.UsedPercent - theory);
            SetRow(3, midnight, 100 - midnight, Model.UsedPercent - midnight);
            if (forecastPercent.HasValue)
            {
                cells[4][0].Text = notice!.TheoryLabel;
                SetRow(4, forecastPercent, 100 - forecastPercent, Model.UsedPercent - forecastPercent);
            }
        }
        NewsBox.Visibility = Visible(notice != null);
        if (notice is { } n)
        {
            NewsTitle.Text = n.Title; NewsText.Text = n.Text;
            OriginalToggle.Visibility = Visible(originalExpanded || NewsText.IsTextTrimmed);
            SourceLink.NavigateUri = n.Link; SourceLink.Visibility = Visible(n.Link != null);
            NewsTime.Text = n.Target is { } t ? t <= now ? "公告时间已过，等待确认" :
                $"{n.TimeLabel} · {Date(t)} · 距今 {QuotaWindow.CountdownUntil(t, now)}" :
                n.Title == "重置预告" ? "时间待定" : "";
            NewsTime.Visibility = Visible(NewsTime.Text.Length > 0);
            Published.Visibility = Visible(n.Published.HasValue); Published.Text = "发布于 " + Date(n.Published);
            Delayed.Visibility = Visible(n.Stale);
        }
        foreach (var (expiry, count, mark) in expiryMarks)
        {
            var hint = $"{count} 次重置机会到期\n{ResetCredit.Tooltip(expiry, now)}";
            CreditsFooter.SetHint(mark, hint);
            AutomationProperties.SetName(mark, hint);
        }
        Marker.Visibility = Visible(theory.HasValue);
        Position();
    }
    private void ResizeBar(object sender, SizeChangedEventArgs args)
    {
        Position();
        foreach (var (expiry, _, mark) in expiryMarks)
            Canvas.SetLeft(mark, Timeline.ActualWidth * Model.Theory(expiry)!.Value / 100 - mark.Width / 2);
        DrawSegments();
    }
    internal void SetProgressStyle(ProgressStyle style)
    {
        progressStyle = style;
        DrawSegments();
    }
    private List<DateTimeOffset> Boundaries(DateTimeOffset start, DateTimeOffset end, bool hourly)
    {
        if (progressStyle == ProgressStyle.Continuous) return [start, end];
        List<DateTimeOffset> points = [start];
        var current = start;
        while (points.Count <= 512)
        {
            var local = current.LocalDateTime;
            var step = hourly ? TimeSpan.FromHours(1) : TimeSpan.FromDays(1);
            if (progressStyle == ProgressStyle.CalendarDays)
                step = hourly ? TimeSpan.FromHours(1) - (TimeSpan.FromTicks(local.TimeOfDay.Ticks % TimeSpan.TicksPerHour)) :
                    local.Date == DateTime.MaxValue.Date ? end - current : NextMidnight(local.Date, TimeZoneInfo.Local) - current;
            if (step <= TimeSpan.Zero) return [];
            if (step >= end - current) { points.Add(end); return points; }
            current += step;
            points.Add(current);
        }
        return [];
    }
    private void DrawSegments()
    {
        if (Track == null || SegmentLabels == null) return;
        Track.Children.Clear(); SegmentLabels.Children.Clear();
        SegmentLabels.Visibility = Visibility.Collapsed;
        double width = Timeline.ActualWidth;
        if (width <= 0) return;
        double actual = width * Math.Clamp(Model.UsedPercent ?? 0, 0, 100) / 100;
        void DrawSpan(double left, double right)
        {
            double length = Math.Max(0,right-left);
            var track = new Grid { Style = (Style)Resources["TrackStyle"], Width = length,
                HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(left,0,0,0) };
            track.Children.Add(new Border { Style = (Style)Resources["ActualStyle"], HorizontalAlignment = HorizontalAlignment.Left,
                Width = Math.Clamp(actual-left,0,length) });
            Track.Children.Add(track);
        }
        if (Model.Start is not { } start || Model.End is not { } end || end <= start || progressStyle == ProgressStyle.Continuous)
        { DrawSpan(0,width); return; }
        bool hourly = end - start <= TimeSpan.FromDays(1);
        var points = Boundaries(start,end,hourly);
        if (points.Count < 2) { DrawSpan(0,width); return; }
        SegmentLabels.Visibility = Visibility.Visible;
        bool sameMonth = start.LocalDateTime.Year == end.LocalDateTime.Year && start.LocalDateTime.Month == end.LocalDateTime.Month;
        for (int i = 0; i < points.Count-1; i++)
        {
            var from = points[i]; var to = points[i+1];
            double left = width * ((from-start)/(end-start)), right = width * ((to-start)/(end-start));
            DrawSpan(left + (i == 0 ? 0 : 1), right - (i == points.Count-2 ? 0 : 1));
            if (right-left < 20) continue;
            string text = progressStyle == ProgressStyle.CalendarDays ? from.LocalDateTime.ToString(hourly ? "HH:mm" : sameMonth ? "d日" : "M/d") :
                hourly ? $"第{i+1}小时" : (to-from).TotalHours < 24 ? $"{(to-from).TotalHours:0.##}小时" : $"第{i+1}天";
            var label = new TextBlock { Text = text, Style = (Style)Application.Current.Resources["Meta"], FontSize = 11, Width = right-left, TextAlignment = TextAlignment.Center };
            ToolTipService.SetToolTip(label, $"开始：{from.LocalDateTime:yyyy/MM/dd HH:mm:ss}\n结束：{to.LocalDateTime:yyyy/MM/dd HH:mm:ss}");
            Canvas.SetLeft(label,left); SegmentLabels.Children.Add(label);
        }
    }
    private static DateTimeOffset NextMidnight(DateTime day, TimeZoneInfo zone)
    {
        var midnight = DateTime.SpecifyKind(day.AddDays(1), DateTimeKind.Unspecified);
        while (zone.IsInvalidTime(midnight)) midnight = midnight.AddMinutes(1);
        return TimeZoneInfo.ConvertTimeToUtc(midnight, zone);
    }
    private void Position()
    {
        if (FlagOffset != null)
            FlagOffset.X = Math.Clamp(Timeline.ActualWidth * (forecastPercent ?? 0) / 100 - 1, 0, Math.Max(0, Timeline.ActualWidth - 10));
        if (Offset != null)
            Offset.X = Math.Max(0, Timeline.ActualWidth - 2) * (theory ?? 0) / 100;
    }
}
