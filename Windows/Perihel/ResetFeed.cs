using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace Perihel;

internal record FeedSource(string? Url = null)
{
    public Uri? Link => Uri.TryCreate(Url, UriKind.Absolute, out var uri) && uri.Scheme == "https" ? uri : null;
}
internal record Announcement(string Id, string ResetType, string AnnouncedAt, string Text, FeedSource Source, string? ScheduledFor = null);
internal record Watch(string ObservedAt, string ExpiresAt, string Text, FeedSource Source);
internal record FeedData(Announcement? ScheduledReset = null, Watch? ActiveWatch = null, Announcement? LatestReset = null);
internal record FeedMeta(DateTimeOffset GeneratedAt);
internal record FeedResponse(FeedData Data, FeedMeta Meta);

internal record ResetNotice(string Title, string Text, Uri? Link, DateTimeOffset? Published,
    DateTimeOffset? Target, bool Regular, bool Stale)
{
    public bool Deadline { get; } = Regex.IsMatch(Text, @"\b(before|by|no later than)\b|之前|不晚于|最晚", RegexOptions.IgnoreCase);
    public string TimeLabel => Deadline ? "预告时间上限" : "预告参考时间";
    public string TheoryLabel => Deadline ? "预告上限理论" : "预告时点理论";
    public DateTimeOffset? Reference(QuotaWindow window, DateTimeOffset now) =>
        Regular && !Stale && Target > now && Target >= window.Start && Target <= window.End ? Target : null;
}

internal sealed class ResetFeed : IDisposable
{
    private static readonly JsonSerializerOptions Json = new() {
        PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower, RespectRequiredConstructorParameters = true,
        RespectNullableAnnotations = true
    };
    private readonly HttpClient http = new(new HttpClientHandler { UseCookies = false }) {
        Timeout = TimeSpan.FromSeconds(15), MaxResponseContentBufferSize = 1_000_000
    };
    private FeedData? data;
    private Announcement? completed;
    private string? etag;
    private DateTimeOffset checkedAt, nextAttempt;
    private bool failed, busy;
    private static DateTimeOffset? Date(string? value) =>
        value != null && DateTimeOffset.TryParse(value, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal, out var date) ? date : null;

    internal ResetNotice? Notice(DateTimeOffset now)
    {
        bool stale = failed || now - checkedAt > TimeSpan.FromMinutes(30);
        if (data?.ScheduledReset is { } a)
            return new(a.ResetType == "banked" ? "重置机会发放预告" : "重置预告", a.Text, a.Source.Link,
                Date(a.AnnouncedAt), Date(a.ScheduledFor), a.ResetType == "regular", stale);
        if (data?.ActiveWatch is { } watch && Date(watch.ExpiresAt) > now)
            return new("重置动向 · 尚未确认", watch.Text, watch.Source.Link, Date(watch.ObservedAt), null, false, stale);
        if (completed is { } c && Date(c.AnnouncedAt) is { } published && now >= published && now - published < TimeSpan.FromDays(1))
            return new("公开消息称已完成", "个人额度是否恢复，请以当前账户数据为准。", c.Source.Link, published, null, false, stale);
        return null;
    }
    internal async Task Refresh(string? fixture, CancellationToken token)
    {
        if (busy || DateTimeOffset.UtcNow < nextAttempt) return;
        busy = true;
        nextAttempt = DateTimeOffset.UtcNow.AddMinutes(5);
        try
        {
            byte[] bytes;
            string? nextTag = null;
            if (fixture != null) bytes = await File.ReadAllBytesAsync(fixture, token);
            else
            {
                using var request = new HttpRequestMessage(HttpMethod.Get, "https://codex-resets.com/api/v1/status");
                request.Headers.Accept.ParseAdd("application/json");
                if (etag != null) request.Headers.IfNoneMatch.ParseAdd(etag);
                using var response = await http.SendAsync(request, token);
                if (response.StatusCode == HttpStatusCode.NotModified && data != null)
                { checkedAt = DateTimeOffset.UtcNow; failed = false; return; }
                if (response.StatusCode == HttpStatusCode.TooManyRequests && response.Headers.RetryAfter?.Delta is { } delay && delay > TimeSpan.FromMinutes(5))
                    nextAttempt = DateTimeOffset.UtcNow + delay;
                if (response.StatusCode != HttpStatusCode.OK) throw new HttpRequestException();
                bytes = await response.Content.ReadAsByteArrayAsync(token);
                nextTag = response.Headers.ETag?.ToString();
            }
            var decoded = JsonSerializer.Deserialize<FeedResponse>(bytes, Json) ?? throw new JsonException();
            if (data?.ScheduledReset is { } prior && decoded.Data.LatestReset is { } latest &&
                prior.Id == latest.Id && decoded.Data.ScheduledReset?.Id != prior.Id) completed = latest;
            data = decoded.Data; checkedAt = DateTimeOffset.UtcNow; failed = false; etag = nextTag;
        }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException or JsonException or IOException or UnauthorizedAccessException)
        { failed = true; }
        finally { busy = false; }
    }
    public void Dispose() => http.Dispose();
}
