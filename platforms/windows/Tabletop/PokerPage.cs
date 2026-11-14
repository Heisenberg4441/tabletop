using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json.Nodes;

namespace Tabletop;

public sealed partial class MainWindow
{
    private async Task NewPoker()
    {
        var opponents = await OptionDialog("Texas Hold’em", ["Tournament · 1 opponent", "Tournament · 3 opponents", "Tournament · 5 opponents", "Cash game · 5 opponents"], 2);
        if (opponents is not null) await Run("new", r => { r["opponents"] = new[] { 1, 3, 5, 5 }[opponents.Value]; r["mode"] = opponents.Value == 3 ? "cash" : "tournament"; });
    }

    private void RenderPoker()
    {
        var game = state!["state"]!.AsObject(); var players = game["players"]!.AsArray(); var options = state["options"]?.AsObject();
        status.Text = $"{state["street"]}  ·  Pot {state["pot"]}";
        var page = new StackPanel { Spacing = 12, Margin = new Thickness(0, 12, 0, 8) };
        var seats = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        for (var i = 1; i < players.Count; i++) seats.Children.Add(PokerSeat(players[i]!.AsObject(), game, i));
        page.Children.Add(seats);
        page.Children.Add(Controls.Text("COMMUNITY CARDS", 11, FontWeights.SemiBold));
        page.Children.Add(CardRow(game["board"]!.AsArray()));
        page.Children.Add(PokerSeat(players[0]!.AsObject(), game, 0));
        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        if (options is not null && options["seat"]!.GetValue<int>() == 0)
        {
            if (options["canFold"]!.GetValue<bool>()) actions.Children.Add(Controls.Button("Fold", async (_, _) => await Run("play", r => r["kind"] = "fold")));
            if (options["canCheck"]!.GetValue<bool>()) actions.Children.Add(Controls.Button("Check", async (_, _) => await Run("play", r => r["kind"] = "check")));
            if (options["canCall"]!.GetValue<bool>()) actions.Children.Add(Controls.Button($"Call {options["callAmount"]}", async (_, _) => await Run("play", r => r["kind"] = "call"), true));
            if (options["canBet"]!.GetValue<bool>() || options["canRaise"]!.GetValue<bool>())
            {
                var min = options["minTotal"]!.GetValue<int>(); var max = options["maxTotal"]!.GetValue<int>();
                var slider = new Slider { Minimum = min, Maximum = max, Value = Math.Min(max, Math.Max(min, options["pot"]!.GetValue<int>())), Width = 180, StepFrequency = 1 };
                actions.Children.Add(slider);
                actions.Children.Add(Controls.Button("Bet / Raise", async (_, _) => await Run("play", r => { r["kind"] = options["canBet"]!.GetValue<bool>() ? "bet" : "raise"; r["total"] = (int)slider.Value; })));
                actions.Children.Add(Controls.Button("All-in", async (_, _) => await Run("play", r => r["kind"] = "allIn")));
            }
        }
        else if (state["phase"]!.GetValue<string>() == "betweenHands")
        {
            actions.Children.Add(Controls.Button("Next hand", async (_, _) => await Run("startHand"), true));
            actions.Children.Add(Controls.Button("Top up", async (_, _) => await Run("topUp")));
        }
        page.Children.Add(actions); content.Children.Add(page);
        if (state["phase"]!.GetValue<string>() == "streetComplete" || options?["seat"]?.GetValue<int>() > 0)
        { timer.Interval = TimeSpan.FromMilliseconds(500); timer.Start(); }
    }

    private static Border PokerSeat(JsonObject player, JsonObject game, int seat)
    {
        var panel = new StackPanel { Spacing = 5 };
        panel.Children.Add(Controls.Text(seat == 0 ? "You" : player["name"]!.GetValue<string>(), 13, FontWeights.SemiBold));
        panel.Children.Add(Controls.Text($"{player["stack"]} chips  ·  bet {player["bet"]}", 11));
        var show = seat == 0 || game["handsAreRevealed"]?.GetValue<bool>() == true || game["street"]?.GetValue<string>() == "showdown";
        var cards = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 3, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var card in player["holeCards"]!.AsArray()) cards.Children.Add(Controls.Card(Controls.CardCode(card), !show, width: 43));
        panel.Children.Add(cards);
        panel.Children.Add(Controls.Text(player["lastAction"]?["kind"]?.GetValue<string>() ?? player["status"]!.GetValue<string>(), 10));
        return Controls.Panel(panel);
    }
}
