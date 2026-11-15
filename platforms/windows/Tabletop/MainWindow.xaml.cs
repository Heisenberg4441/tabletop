using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using System.Text.Json.Nodes;
using Windows.Graphics;
using Windows.UI;

namespace Tabletop;

public sealed class MainWindow : Window
{
    private EngineClient? engine;
    private EngineClient Engine => engine ??= new EngineClient();
    private Grid RootGrid { get; } = new();
    private readonly Grid content = new();
    private readonly TextBlock status = Controls.Text("", 12);
    private string? current;
    private JsonObject? state;
    private readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(450) };

    public MainWindow()
    {
        Content = RootGrid;
        Title = "Tabletop";
        AppWindow.Resize(new SizeInt32(1280, 840));
        timer.Tick += BotTick;
        Closed += (_, _) => { timer.Stop(); engine?.Dispose(); };
        ShowLibrary();
    }

    private void ShowLibrary()
    {
        timer.Stop(); current = null; state = null;
        var root = PageShell(null, out _);
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        var page = new StackPanel { Spacing = 24, Margin = new Thickness(46, 38, 46, 30) };
        var title = Controls.Text("Tabletop", 38, FontWeights.SemiBold); title.HorizontalAlignment = HorizontalAlignment.Center;
        var subtitle = Controls.Text("A quiet room for classic games", 15, color: Color.FromArgb(255, 169, 180, 172)); subtitle.HorizontalAlignment = HorizontalAlignment.Center;
        page.Children.Add(title); page.Children.Add(subtitle);
        var grid = new Grid { ColumnSpacing = 18 }; for (var i = 0; i < 5; i++) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        var games = new (string id, string title, string subtitle, string symbol, Color color)[]
        {
            ("pool", "Pool", "Eight-ball and nine-ball", "8", Color.FromArgb(255, 35, 104, 100)),
            ("poker", "Poker", "No-limit Texas Hold’em", "♠", Color.FromArgb(255, 43, 81, 124)),
            ("blackjack", "Blackjack", "Beat the dealer to twenty-one", "♦", Color.FromArgb(255, 125, 45, 57)),
            ("durak", "Durak", "The classic Russian card game", "♣", Color.FromArgb(255, 67, 75, 111)),
            ("solitaire", "Solitaire", "Klondike, draw one or three", "♥", Color.FromArgb(255, 44, 105, 72)),
        };
        for (var i = 0; i < games.Length; i++)
        {
            var game = games[i]; var tile = new Button { Padding = new Thickness(0), HorizontalContentAlignment = HorizontalAlignment.Stretch, VerticalContentAlignment = VerticalAlignment.Stretch };
            var panel = new StackPanel();
            var art = new Border { Height = 175, Background = new SolidColorBrush(game.color) };
            var symbol = Controls.Text(game.symbol, 64, FontWeights.SemiBold); symbol.HorizontalAlignment = HorizontalAlignment.Center; symbol.VerticalAlignment = VerticalAlignment.Center; art.Child = symbol;
            panel.Children.Add(art);
            var copy = new StackPanel { Spacing = 7, Margin = new Thickness(16, 16, 16, 20) };
            copy.Children.Add(Controls.Text(game.title, 21, FontWeights.SemiBold)); copy.Children.Add(Controls.Text(game.subtitle, 12)); copy.Children.Add(Controls.Text(game.id == "solitaire" ? "1 player" : "1 player · vs computer", 11, color: Color.FromArgb(255, 196, 174, 125)));
            panel.Children.Add(copy); tile.Content = panel; tile.Click += async (_, _) => await ShowGame(game.id); Grid.SetColumn(tile, i); grid.Children.Add(tile);
        }
        page.Children.Add(grid); scroll.Content = page; root.Children.Add(scroll);
    }

    private Grid PageShell(string? title, out Grid body)
    {
        RootGrid.Children.Clear(); RootGrid.Background = new SolidColorBrush(Color.FromArgb(255, 15, 21, 18));
        RootGrid.RowDefinitions.Clear(); RootGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); RootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        if (title is null) { body = new Grid(); RootGrid.Children.Add(body); Grid.SetRowSpan(body, 2); return body; }
        var bar = new Grid { Margin = new Thickness(16, 10, 16, 10), ColumnSpacing = 12 };
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        bar.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) }); bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto }); bar.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var back = Controls.Button("‹", (_, _) => ShowLibrary()); back.FontSize = 26; back.Width = 46;
        var heading = Controls.Text(title, 19, FontWeights.SemiBold); heading.VerticalAlignment = VerticalAlignment.Center;
        var newGame = Controls.Button("New game", async (_, _) => await NewGame());
        status.VerticalAlignment = VerticalAlignment.Center;
        bar.Children.Add(back); Grid.SetColumn(heading, 1); bar.Children.Add(heading); Grid.SetColumn(status, 2); bar.Children.Add(status);
        Grid.SetColumn(newGame, 3); bar.Children.Add(newGame); RootGrid.Children.Add(bar);
        content.Children.Clear(); content.Background = new SolidColorBrush(Color.FromArgb(255, 19, 76, 57)); RootGrid.Children.Add(content); Grid.SetRow(content, 1);
        body = content; return body;
    }

    private async Task ShowGame(string game)
    {
        current = game; PageShell(GameTitle(game), out _);
        try { state = await Engine.RestoreOrState(game); RenderCurrent(); }
        catch (Exception error) { await Error(error); }
    }

    private async Task Run(string action, Action<JsonObject>? configure = null)
    {
        if (current is null) return;
        timer.Stop();
        try { state = await Engine.Send(current, action, configure); RenderCurrent(); }
        catch (Exception error) { await Error(error); }
    }

    private void RenderCurrent()
    {
        content.Children.Clear(); if (state is null || current is null) return;
        switch (current)
        {
            case "solitaire": RenderSolitaire(); break;
            case "blackjack": RenderBlackjack(); break;
            case "durak": RenderDurak(); break;
            case "poker": RenderPoker(); break;
            case "pool": RenderPool(); break;
        }
    }

    private async Task NewGame()
    {
        if (current is null) return;
        switch (current)
        {
            case "solitaire": await NewSolitaire(); break;
            case "blackjack": await NewBlackjack(); break;
            case "durak": await NewDurak(); break;
            case "poker": await NewPoker(); break;
            case "pool": await NewPool(); break;
        }
    }

    private async Task<int?> OptionDialog(string title, string[] choices, int selected = 0)
    {
        var combo = new ComboBox { Width = 260, SelectedIndex = selected };
        foreach (var choice in choices) combo.Items.Add(choice);
        var dialog = new ContentDialog { Title = title, Content = combo, PrimaryButtonText = "Start", CloseButtonText = "Cancel", XamlRoot = RootGrid.XamlRoot };
        return await dialog.ShowAsync() == ContentDialogResult.Primary ? combo.SelectedIndex : null;
    }

    private async Task Error(Exception error)
    {
        timer.Stop(); var dialog = new ContentDialog { Title = "Tabletop engine", Content = error.Message, CloseButtonText = "Close", XamlRoot = RootGrid.XamlRoot };
        await dialog.ShowAsync();
    }

    private static string GameTitle(string game) => game switch
    {
        "pool" => "Pool", "poker" => "Poker", "blackjack" => "Blackjack", "durak" => "Durak", _ => "Solitaire",
    };

    private void BotTick(object? sender, object e)
    {
        timer.Stop(); if (current is null || state is null) return;
        _ = BotStep();
    }
    private async Task BotStep()
    {
        if (current == "durak" && state?["state"]?["actor"]?.GetValue<int>() is > 0) await Run("bot");
        else if (current == "poker")
        {
            if (state?["phase"]?.GetValue<string>() == "streetComplete") await Run("advance");
            else if (state?["options"]?["seat"]?.GetValue<int>() is > 0) await Run("bot");
        }
        else if (current == "blackjack" && state?["needsAdvance"]?.GetValue<bool>() == true) await Run("advance");
        else if (current == "pool" && state?["computer"]?.GetValue<bool>() == true) await Run("bot");
    }
}
