using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Tabletop;

public sealed class EngineClient : IDisposable
{
    private readonly Process process;
    private readonly SemaphoreSlim gate = new(1, 1);
    private readonly string saves = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Tabletop");

    public EngineClient()
    {
        Directory.CreateDirectory(saves);
        var executable = Environment.GetEnvironmentVariable("TABLETOP_ENGINE")
            ?? Path.Combine(AppContext.BaseDirectory, "engine", "Tabletop.exe");
        process = new Process
        {
            StartInfo = new ProcessStartInfo(executable)
            {
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true,
                StandardOutputEncoding = Encoding.UTF8,
                StandardInputEncoding = Encoding.UTF8,
            },
            EnableRaisingEvents = true,
        };
        process.Start();
    }

    public async Task<JsonObject> Send(string game, string action, Action<JsonObject>? configure = null)
    {
        var request = new JsonObject { ["game"] = game, ["action"] = action };
        configure?.Invoke(request);
        await gate.WaitAsync();
        try
        {
            await process.StandardInput.WriteLineAsync(request.ToJsonString());
            await process.StandardInput.FlushAsync();
            var line = await process.StandardOutput.ReadLineAsync();
            if (line is null) throw new InvalidOperationException("The Tabletop engine stopped unexpectedly.");
            var response = JsonNode.Parse(line)!.AsObject();
            if (response["ok"]?.GetValue<bool>() != true)
                throw new InvalidOperationException(response["error"]?.ToJsonString() ?? "Engine error");
            if (action is not "state" and not "restore") Save(game, response["saved"]?.ToJsonString());
            return response;
        }
        finally { gate.Release(); }
    }

    public async Task<JsonObject> RestoreOrState(string game)
    {
        var file = Path.Combine(saves, game + ".json");
        if (File.Exists(file))
        {
            try
            {
                var saved = JsonNode.Parse(await File.ReadAllTextAsync(file));
                return await Send(game, "restore", r => r["saved"] = saved);
            }
            catch { File.Delete(file); }
        }
        return await Send(game, "state");
    }

    private void Save(string game, string? state)
    {
        if (state is not null) File.WriteAllText(Path.Combine(saves, game + ".json"), state);
    }

    public void Dispose()
    {
        try { process.Kill(true); } catch { }
        process.Dispose(); gate.Dispose();
    }
}
