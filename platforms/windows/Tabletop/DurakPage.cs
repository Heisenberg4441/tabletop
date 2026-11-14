using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json.Nodes;

namespace Tabletop;

public sealed partial class MainWindow
{
    private async Task NewDurak()
    {
        var players = await OptionDialog("Durak", ["2 players · Podkidnoy", "3 players · Podkidnoy", "4 players · Podkidnoy", "2 players · Perevodnoy"], 0);
        if (players is not null) await Run("new", r => { r["players"] = players.Value % 3 + 2; r["variant"] = players.Value == 3 ? "perevodnoy" : "podkidnoy"; });
    }

    private void RenderDurak()
    {
        var game = state!["state"]!.AsObject(); var hands = game["hands"]!.AsArray(); var actor = game["actor"]?.GetValue<int>() ?? -1;
        status.Text = $"Trump {Controls.Suits[Controls.CardCode(game["trumpCard"]) / 13]}  ·  Stock {game["stock"]!.AsArray().Count}";
        var page = new StackPanel { Spacing = 14, Margin = new Thickness(0, 16, 0, 10) };
        var opponents = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 35, HorizontalAlignment = HorizontalAlignment.Center };
        for (var seat = 1; seat < hands.Count; seat++)
        {
            var panel = new StackPanel { Spacing = 5 }; panel.Children.Add(Controls.Text($"Player {seat + 1}  ·  {hands[seat]!.AsArray().Count} cards{(seat == actor ? "  ·  thinking" : "")}", 12));
            var cards = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2, HorizontalAlignment = HorizontalAlignment.Center };
            for (var i = 0; i < Math.Min(6, hands[seat]!.AsArray().Count); i++) cards.Children.Add(Controls.Card(0, true, width: 45));
            panel.Children.Add(cards); opponents.Children.Add(panel);
        }
        page.Children.Add(opponents);
        var table = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        foreach (var pairNode in game["table"]!.AsArray())
        {
            var pair = pairNode!.AsObject(); var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            panel.Children.Add(Controls.Card(Controls.CardCode(pair["attack"]), false));
            if (pair["defence"] is not null) panel.Children.Add(Controls.Card(Controls.CardCode(pair["defence"]), false));
            table.Children.Add(panel);
        }
        page.Children.Add(table);
        var hand = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var card in hands[0]!.AsArray())
        {
            var code = Controls.CardCode(card);
            hand.Children.Add(Controls.Card(code, false, async (_, _) => await PlayDurak(code), width: 72));
        }
        page.Children.Add(hand);
        var phase = game["phase"]!.GetValue<string>(); var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        if (actor == 0 && phase == "defend") actions.Children.Add(Controls.Button("Take", async (_, _) => await Run("play", r => r["kind"] = "take")));
        if (actor == 0 && phase is "throwIn" or "pileOn") actions.Children.Add(Controls.Button(phase == "pileOn" ? "Done" : "Bito / Pass", async (_, _) => await Run("play", r => r["kind"] = "pass")));
        page.Children.Add(actions); content.Children.Add(page);
        if (game["result"] is not null) status.Text += "  ·  Game over";
        else if (actor > 0) { timer.Interval = TimeSpan.FromMilliseconds(500); timer.Start(); }
    }

    private async Task PlayDurak(int code)
    {
        if (state?["state"]?["actor"]?.GetValue<int>() != 0) return;
        var phase = state["state"]!["phase"]!.GetValue<string>();
        if (phase is "lead" or "throwIn" or "pileOn") { await Run("play", r => { r["kind"] = "attack"; r["card"] = code; }); return; }
        if (phase != "defend") return;
        foreach (var node in state["legalActions"]!.AsArray())
        {
            var action = node!.AsObject();
            if (action["defend"] is JsonObject defend && Controls.CardCode(defend["card"]) == code)
            {
                await Run("play", r => { r["kind"] = "defend"; r["card"] = code; r["on"] = Controls.CardCode(defend["on"]); }); return;
            }
            if (action["transfer"] is JsonObject transfer && Controls.CardCode(transfer["_0"]) == code)
            {
                await Run("play", r => { r["kind"] = "transfer"; r["card"] = code; }); return;
            }
        }
    }
}
