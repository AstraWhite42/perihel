using System;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Perihel;

internal class SetupIssue(string message) : Exception(message);
internal record Inspection(Snapshot Snapshot, string? Plan);
internal static class Cli
{
    public static string? Locate(string? selected)
    {
        if (!string.IsNullOrWhiteSpace(selected)) return File.Exists(selected) ? selected : null;
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var dirs = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator)
            .Concat([Path.Combine(local, @"Programs\OpenAI\Codex\bin"),
                     Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "npm")]);
        return dirs.Where(d => Path.IsPathFullyQualified(d.Trim('"')))
            .SelectMany(d => new[] { "codex.exe", "codex.cmd" }.Select(f => Path.Combine(d.Trim('"'), f)))
            .FirstOrDefault(File.Exists);
    }

    private static ProcessStartInfo Command(string path, string argument, bool interactive = false)
    {
        var shell = interactive || path.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase);
        var info = new ProcessStartInfo(shell ? Path.Combine(Environment.SystemDirectory, "cmd.exe") : path)
        {
            UseShellExecute = false, CreateNoWindow = !interactive,
            RedirectStandardOutput = !interactive, RedirectStandardInput = !interactive
        };
        if (shell)
        {
            info.Environment["PERIHEL_CLI_ENTRY"] = Path.GetFullPath(path);
            info.Arguments = $"/d /v:off /s {(interactive ? "/k" : "/c")} \"\"%PERIHEL_CLI_ENTRY%\" {argument}\"";
        }
        else info.ArgumentList.Add(argument);
        return info;
    }
    public static void Login(string path) => Process.Start(Command(path, "login", true))?.Dispose();

    private static void Stop(Process p)
    {
        if (!p.HasExited) { try { p.Kill(entireProcessTree: true); } catch (InvalidOperationException) { } }
    }
    public static async Task<string> Version(string path, CancellationToken stop)
    {
        using var p = Process.Start(Command(path, "--version")) ?? throw new SetupIssue("无法启动 CLI。");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop);
        timeout.CancelAfter(TimeSpan.FromSeconds(5));
        try
        {
            var line = await p.StandardOutput.ReadLineAsync(timeout.Token);
            await p.WaitForExitAsync(timeout.Token);
            if (p.ExitCode != 0 || line?.StartsWith("codex-cli ", StringComparison.Ordinal) != true)
                throw new SetupIssue("无法识别 CLI 版本，请更新或重新选择 Codex CLI。");
            return line;
        }
        catch (OperationCanceledException) when (!stop.IsCancellationRequested) { throw new SetupIssue("检测 CLI 版本超时。"); }
        finally { Stop(p); }
    }

    public static async Task<Inspection> Read(string path, string version, CancellationToken stop)
    {
        using var p = Process.Start(Command(path, "app-server")) ?? throw new SetupIssue("无法启动 CLI。");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stop);
        timeout.CancelAfter(TimeSpan.FromSeconds(25));
        var token = timeout.Token;
        var output = p.StandardOutput.BaseStream;
        var chunk = new byte[8192];
        using var line = new MemoryStream();
        string? plan = null;
        async Task Send(object obj)
        {
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(obj) + "\n");
            await p.StandardInput.BaseStream.WriteAsync(bytes, token);
            await p.StandardInput.BaseStream.FlushAsync(token);
        }
        try
        {
            await Send(new { id = 1, method = "initialize", @params = new { clientInfo = new { name = "perihel", title = "近星点", version } } });
            var expected = 1;
            while (true)
            {
                var count = await output.ReadAsync(chunk, token);
                if (count == 0) throw new IOException("CLI 已退出，请重新检测。");
                for (int i = 0; i < count; i++)
                {
                    if (chunk[i] != 10)
                    {
                        if (line.Length >= 4_000_000) throw new IOException("CLI 响应过大。");
                        line.WriteByte(chunk[i]); continue;
                    }
                    if (line.Length == 0) continue;
                    using var doc = JsonDocument.Parse(line.GetBuffer().AsMemory(0, (int)line.Length));
                    line.SetLength(0);
                    var msg = doc.RootElement;
                    if (!msg.TryGetProperty("id", out var id) || id.ValueKind != JsonValueKind.Number || !id.TryGetInt32(out int value) || value != expected) continue;
                    if (msg.TryGetProperty("error", out var error))
                    {
                        var message = error.TryGetProperty("message", out var m) ? m.GetString() ?? "查询失败" : "查询失败";
                        if (error.TryGetProperty("code", out var code) && code.TryGetInt32(out int c) && c == -32601)
                            throw new SetupIssue("此版本缺少额度接口，请更新 CLI。");
                        if (new[] {"401","unauthorized","not authenticated","not logged","login","sign in","token expired","requires chatgpt"}
                            .Any(s => message.Contains(s, StringComparison.OrdinalIgnoreCase))) throw new SetupIssue("登录已失效，请重新登录 ChatGPT 账户。");
                        throw new IOException(message);
                    }
                    var result = msg.GetProperty("result");
                    if (expected == 1)
                    {
                        await Send(new { method = "initialized" });
                        await Send(new { id = 2, method = "account/read", @params = new { refreshToken = false } });
                    }
                    else if (expected == 2)
                    {
                        if (!result.TryGetProperty("account", out var a) || a.ValueKind != JsonValueKind.Object ||
                            !a.TryGetProperty("type", out var type) || type.GetString() is not ("chatgpt" or "chatgptAuthTokens"))
                            throw new SetupIssue("请使用 ChatGPT 账户登录 Codex CLI。");
                        plan = a.TryGetProperty("planType", out var field) ? field.GetString() : null;
                        await Send(new { id = 3, method = "account/rateLimits/read" });
                    }
                    else return new(result.Deserialize<Snapshot>(Snapshot.Json) ?? throw new IOException("额度响应为空。"), plan);
                    expected++;
                }
            }
        }
        catch (OperationCanceledException) when (!stop.IsCancellationRequested) { throw new IOException("额度查询超时，请检查网络后重试。"); }
        finally { Stop(p); }
    }
}
