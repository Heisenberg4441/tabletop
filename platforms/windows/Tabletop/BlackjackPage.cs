using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json.Nodes;

namespace Tabletop;

public sealed partial class MainWindow
{
    private async Task NewBlackjack()
    {
        var decks = await OptionDialog("Blackjack shoe", ["1 deck", "2 decks", "6 decks", "8 decks"], 2);
        if (decks is not null) await Run("new", r => r["decks"] = new[] { 1, 2, 6, 8 }[decks.Value]);
    }

    private void RenderBlackjack()
    {
        var game = state!["state"]!.AsObject(); var round = game["round"]?.AsObject();
        status.Text = $"Bankroll {state!["bankroll"]}  ·  Bet {state!["pendingBet"]}";
        var page = new StackPanel { Spacing = 12, Margin = new Thickness(0, 20, 0, 12) };
        page.Children.Add(Controls.Text("DEALER", 13, FontWeights.SemiBold));
        if (round is not null)
        {
            page.Children.Add(CardRow(round["dealer"]!.AsArray(), round["isHoleRevealed"]?.GetValue<bool>() != true ? 1 : -1));
            var hands = round["hands"]!.AsArray();
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 28, HorizontalAlignment = HorizontalAlignment.Center };
            foreach (var hand in hands)
            {
                var panel = new StackPanel { Spacing = 6 }; panel.Children.Add(CardRow(hand!["cards"]!.AsArray()));
                panel.Children.Add(Controls.Text($"{hand["result"]?.GetValue<string>() ?? "Playing"}  ·  Bet {hand["bet"]}", 12)); row.Children.Add(panel);
            }
            page.Children.Add(row);
        }
        else
        {
            page.Children.Add(Controls.Text("Place your bet", 24, FontWeights.SemiBold));
        }
        var phase = state!["phase"]!.GetValue<string>();
        var controls = new StackPanel { Spacing = 12 };
        if (phase is "betting" or "settled")
        {
            var chips = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
            foreach (var amount in new[] { 5, 25, 100, 500, 1000 }) chips.Children.Add(Controls.Button(amount.ToString(), async (_, _) => await Run("bet", r => r["amount"] = amount)));
            controls.Children.Add(chips);
            controls.Children.Add(Controls.Row(Controls.Button("Deal", async (_, _) => await Run("deal"), true), Controls.Button("Rebet", async (_, _) => await Run("rebet")), Controls.Button("Clear", async (_, _) => await Run("clearBet"))));
        }
        else if (phase == "insurance")
        {
            controls.Children.Add(Controls.Row(Controls.Button("Insurance", async (_, _) => await Run("insurance", r => r["take"] = true), true), Controls.Button("Decline", async (_, _) => await Run("insurance", r => r["take"] = false))));
        }
        else
        {
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 9, HorizontalAlignment = HorizontalAlignment.Center };
            foreach (var action in state!["legalActions"]!.AsArray()) actions.Children.Add(Controls.Button(action!.GetValue<string>(), async (_, _) => await Run(action.GetValue<string>())));
            controls.Children.Add(actions);
        }
        if (state!["isBroke"]?.GetValue<bool>() == true) controls.Children.Add(Controls.Button("New bankroll", async (_, _) => await Run("resetBankroll")));
        page.Children.Add(controls); content.Children.Add(page);
        if (state!["needsAdvance"]?.GetValue<bool>() == true) { timer.Interval = TimeSpan.FromMilliseconds(350); timer.Start(); }
    }

    private static StackPanel CardRow(JsonArray cards, int hidden = -1)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Center };
        for (var i = 0; i < cards.Count; i++) panel.Children.Add(Controls.Card(Controls.CardCode(cards[i]), i == hidden));
        return panel;
    }
}
