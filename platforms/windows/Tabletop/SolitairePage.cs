using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using System.Text.Json.Nodes;

namespace Tabletop;

public sealed partial class MainWindow
{
    private async Task NewSolitaire()
    {
        var draw = await OptionDialog("Klondike", ["Draw one", "Draw three"], 0);
        if (draw is not null) await Run("new", r => r["drawCount"] = draw + 1);
    }

    private void RenderSolitaire()
    {
        var game = state!["state"]!.AsObject();
        status.Text = $"Score {state!["score"]}  ·  Moves {state!["moves"]}";
        var page = new StackPanel();
        var canvas = new Canvas { Width = 1000, Height = 590, HorizontalAlignment = HorizontalAlignment.Center };
        var stock = game["stock"]!.AsArray(); var waste = game["waste"]!.AsArray();
        PlaceCard(canvas, stock.Count > 0 ? Controls.Card(0, true, async (_, _) => await Run(stock.Count > 0 ? "draw" : "recycle")) : Controls.Card(0, true), 20, 15);
        if (waste.Count > 0) PlaceCard(canvas, Controls.Card(Controls.CardCode(waste[^1]), false, async (_, _) => await Run("click", r => r["target"] = "waste")), 135, 15);
        var foundations = game["foundations"]!.AsArray();
        for (var i = 0; i < 4; i++)
        {
            var height = foundations[i]!.GetValue<int>();
            if (height > 0) PlaceCard(canvas, Controls.Card(i * 13 + height - 1, false), 485 + i * 115, 15);
        }
        var tableau = game["tableau"]!.AsArray();
        for (var col = 0; col < tableau.Count; col++)
        {
            var column = tableau[col]!.AsObject(); var down = column["down"]!.AsArray(); var up = column["up"]!.AsArray(); var y = 165.0;
            for (var i = 0; i < down.Count; i++) { PlaceCard(canvas, Controls.Card(0, true), 20 + col * 115, y); y += 12; }
            for (var i = 0; i < up.Count; i++)
            {
                var depth = up.Count - 1 - i;
                PlaceCard(canvas, Controls.Card(Controls.CardCode(up[i]), false, async (_, _) => await Run("click", r => { r["target"] = "tableau"; r["column"] = col; r["depth"] = depth; })), 20 + col * 115, y);
                y += Math.Min(34, 260.0 / Math.Max(1, up.Count));
            }
        }
        page.Children.Add(canvas);
        page.Children.Add(Controls.Row(
            Controls.Button("Undo", async (_, _) => await Run("undo")),
            Controls.Button("Redo", async (_, _) => await Run("redo")),
            Controls.Button("Hint", async (_, _) => await Run("hint")),
            Controls.Button("Auto finish", async (_, _) => await Run("autoFinish"))));
        content.Children.Add(page);
        if (state!["won"]?.GetValue<bool>() == true) status.Text += "  ·  You win!";
    }

    private static void PlaceCard(Canvas canvas, UIElement card, double x, double y)
    {
        Canvas.SetLeft(card, x); Canvas.SetTop(card, y); canvas.Children.Add(card);
    }
}
