using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;

namespace Perihel;

internal record QuotaWindow(double? UsedPercent, double? WindowDurationMins, long? ResetsAt)
{
    public DateTimeOffset? End => ResetsAt is >= -62135596800 and <= 253402300799
        ? DateTimeOffset.FromUnixTimeSeconds(ResetsAt.Value) : null;
    public DateTimeOffset? Start => End is { } end && WindowDurationMins is > 0 &&
        WindowDurationMins < (end - DateTimeOffset.MinValue).TotalMinutes
        ? end.AddMinutes(-WindowDurationMins.Value) : null;
    public double? Remaining => UsedPercent is double used ? Math.Clamp(100 - used, 0, 100) : null;
    public double? Theory(DateTimeOffset now) => Start is { } start && End is { } end && end > start
        ? Math.Clamp((now - start).TotalSeconds / (end - start).TotalSeconds * 100, 0, 100) : null;
    public string Duration => WindowDurationMins switch
    {
        double m when m > 0 && m % 1440 == 0 => $"{m / 1440} 天窗口",
        double m when m > 0 && m % 60 == 0 => $"{m / 60} 小时窗口",
        > 0 => $"{WindowDurationMins} 分钟窗口", _ => "额度窗口"
    };
    public string Countdown(DateTimeOffset now) => End is { } end ? CountdownUntil(end, now) : "暂无数据";
    public static string CountdownUntil(DateTimeOffset end, DateTimeOffset now)
    {
        var left = end - now;
        if (left <= TimeSpan.Zero) return "等待重置";
        if (left.TotalMinutes < 1) return "不到 1 分钟";
        if (left.Days > 0) return $"{left.Days} 天 {left.Hours} 小时 {left.Minutes} 分";
        return left.Hours > 0 ? $"{left.Hours} 小时 {left.Minutes} 分" : $"{left.Minutes} 分钟";
    }
    public string Budget(DateTimeOffset now) => (UsedPercent - Theory(now)) switch
    {
        null => "预算暂无数据", double d when Math.Abs(d) < 0.05 => "预算持平",
        double d => $"{(d > 0 ? "领先" : "落后")}预算 {Math.Abs(d):F1}%"
    };
}
internal record Bucket(string? LimitName, string? PlanType, QuotaWindow? Primary, QuotaWindow? Secondary);
internal record ResetCredit(double? ExpiresAt)
{
    public DateTimeOffset? Expiry => ExpiresAt is >= -62135596800 and <= 253402300799
        ? DateTimeOffset.UnixEpoch.AddSeconds(ExpiresAt.Value) : null;
    public static string Summary(DateTimeOffset expiry, DateTimeOffset now)
    {
        var local = expiry.LocalDateTime;
        string date = local.ToString(local.Year == now.LocalDateTime.Year ? "M/d HH:mm" : "yyyy/M/d HH:mm");
        var left = expiry - now;
        string relative = left.TotalSeconds switch {
            <= 0 => "已到期", < 60 => "不足1分钟", < 3600 => $"{left.Minutes}分后",
            < 86400 => $"{left.Hours}时{left.Minutes}分后", _ => $"{left.Days}天{left.Hours}时后"
        };
        return $"{date} · {relative}";
    }
    public static string Tooltip(DateTimeOffset expiry, DateTimeOffset now)
    {
        string remaining = expiry <= now ? "已到期" : "剩余 " + QuotaWindow.CountdownUntil(expiry, now);
        return $"到期时间：{expiry.LocalDateTime:yyyy/MM/dd HH:mm:ss}\n{remaining}";
    }
}
internal record ResetCredits(int? AvailableCount, ResetCredit[]? Credits)
{
    public DateTimeOffset?[] SortedExpiries() => (Credits ?? []).Select(c => c?.Expiry)
        .OrderBy(d => !d.HasValue).ThenBy(d => d).ToArray();
}
internal record Snapshot(Dictionary<string, Bucket>? RateLimitsByLimitId, Bucket? RateLimits, ResetCredits? RateLimitResetCredits)
{
    public static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);
    public IEnumerable<(string Bucket, int Slot, string Title, QuotaWindow Window)> Cards(string? accountPlan)
    {
        var buckets = RateLimitsByLimitId is { Count: > 0 } ? RateLimitsByLimitId : new();
        if (buckets.Count == 0 && RateLimits != null) buckets = new() { ["codex"] = RateLimits };
        foreach (var (key, bucket) in buckets.OrderBy(p => p.Key != "codex").ThenBy(p => p.Key, StringComparer.Ordinal))
        {
            var name = bucket.LimitName ?? (key == "codex" ? "Codex" : key);
            foreach (var (w, slot) in new[] { (bucket.Primary, 0), (bucket.Secondary, 1) }.Where(p => p.Item1 != null).OrderBy(p => p.Item1!.WindowDurationMins != 10080))
                yield return (key, slot, $"{name} · {Plan(bucket.PlanType ?? accountPlan)} · {w!.Duration}", w);
        }
    }
    private static string Plan(string? p) => p switch {
        "free" => "Free", "go" => "Go", "plus" => "Plus", "prolite" => "Pro 100", "pro" => "Pro 200", "promax" => "Pro 500",
        "team" or "self_serve_business_prolite" or "self_serve_business_usage_based" => "Business",
        "business" or "ent26" or "enterprise" or "enterprise_cbp_automation" or "enterprise_cbp_usage_based" => "Enterprise",
        "edu" => "Edu", _ => string.IsNullOrWhiteSpace(p) ? "套餐未知" : p
    };
}
