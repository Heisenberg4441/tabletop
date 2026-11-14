using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using System.Text.Json.Nodes;
using Windows.UI;

namespace Tabletop;

public sealed partial class MainWindow
{
    private double poolAim;
    private Canvas? poolCanvas;
    private Line? poolAimLine;
    private readonly Dictionary<int, UIElement> poolBallViews = new();
    private readonly DispatcherTimer poolAnimation = new() { Interval = TimeSpan.FromMilliseconds(16) };
    private JsonArray? replayTracks;
    private DateTime replayStarted;
    private double replayDuration;

    private async Task NewPool()
    {
        var mode = await OptionDialog("Pool", ["Eight-ball", "Nine-ball", "Practice"], 0);
        if (mode is not null) await Run("new", r => r["mode"] = new[] { "eightBall", "nineBall", "practice" }[mode.Value]);
    }

    private void RenderPool()
    {
        poolAnimation.Stop();
        var saved = state!["state"]!.AsObject(); var table = saved["table"]!.AsObject();
        status.Text = saved["rules"]!["winner"] is not null ? "Game over" : saved["rules"]!["ballInHand"] is not null ? "Ball in hand" : saved["options"]!["mode"]!.GetValue<string>();
        var page = new Grid(); page.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); page.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        var frame = new Border { Width = 1040, Height = 540, Margin = new Thickness(10), Padding = new Thickness(20), Background = new SolidColorBrush(Color.FromArgb(255, 76, 44, 26)), CornerRadius = new CornerRadius(10) };
        poolCanvas = new Canvas { Width = 1000, Height = 500, Background = new SolidColorBrush(Color.FromArgb(255, 25, 100, 72)) };
        poolCanvas.PointerMoved += PoolPointer;
        poolCanvas.PointerPressed += PoolPlace;
        frame.Child = poolCanvas; page.Children.Add(frame);
        poolBallViews.Clear();
        foreach (var ballNode in table["balls"]!.AsArray())
        {
            var ball = ballNode!.AsObject(); if (ball["pocket"] is not null) continue;
            var number = ball["number"]!.GetValue<int>(); var view = PoolBall(number);
            poolBallViews[number] = view; poolCanvas.Children.Add(view); SetPoolPosition(view, PoolPoint(ball["position"]));
        }
        poolAimLine = new Line { Stroke = new SolidColorBrush(Color.FromArgb(170, 255, 245, 205)), StrokeThickness = 1.5 };
        poolCanvas.Children.Add(poolAimLine); UpdatePoolAim();
        var power = new Slider { Minimum = 0.05, Maximum = 1, Value = 0.65, Width = 220 };
        var controls = Controls.Row(Controls.Text("Power"), power, Controls.Button("Shoot", async (_, _) => await ShootPool(power.Value), true));
        Grid.SetRow(controls, 1); page.Children.Add(controls); content.Children.Add(page);
        if (state!["computer"]?.GetValue<bool>() == true) { timer.Interval = TimeSpan.FromMilliseconds(700); timer.Start(); }
    }

    private async Task ShootPool(double power)
    {
        timer.Stop();
        try
        {
            state = await engine.Send("pool", "shoot", r => { r["aim"] = poolAim; r["power"] = power; });
            PlayPoolReplay();
        }
        catch (Exception error) { await Error(error); }
    }

    private void PoolPointer(object sender, PointerRoutedEventArgs args)
    {
        if (poolCanvas is null || state?["state"]?["rules"]?["ballInHand"] is not null) return;
        var cue = state!["state"]!["table"]!["balls"]!.AsArray().FirstOrDefault(b => b!["number"]!.GetValue<int>() == 0);
        if (cue is null) return;
        var point = args.GetCurrentPoint(poolCanvas).Position; var cuePoint = PoolPoint(cue["position"]);
        poolAim = Math.Atan2(point.Y - cuePoint.Y, point.X - cuePoint.X); UpdatePoolAim();
    }

    private async void PoolPlace(object sender, PointerRoutedEventArgs args)
    {
        if (poolCanvas is null || state?["state"]?["rules"]?["ballInHand"] is null) return;
        var point = args.GetCurrentPoint(poolCanvas).Position;
        await Run("place", r => { r["x"] = (point.X - 30) / 940 * 2.54 - 1.27; r["y"] = (point.Y - 30) / 440 * 1.27 - 0.635; });
    }

    private void UpdatePoolAim()
    {
        if (poolAimLine is null || state?["state"]?["table"]?["balls"] is null) return;
        var cue = state!["state"]!["table"]!["balls"]!.AsArray().FirstOrDefault(b => b!["number"]!.GetValue<int>() == 0);
        if (cue is null) return;
        var point = PoolPoint(cue["position"]); poolAimLine.X1 = point.X; poolAimLine.Y1 = point.Y;
        poolAimLine.X2 = point.X + Math.Cos(poolAim) * 250; poolAimLine.Y2 = point.Y + Math.Sin(poolAim) * 250;
    }

    private void PlayPoolReplay()
    {
        replayTracks = state?["replay"]?["tracks"]?.AsArray(); replayDuration = state?["replay"]?["duration"]?.GetValue<double>() ?? 0;
        RenderPool();
        if (replayTracks is null || replayTracks.Count == 0) return;
        timer.Stop(); replayStarted = DateTime.UtcNow;
        poolAnimation.Tick -= ReplayTick; poolAnimation.Tick += ReplayTick; poolAnimation.Start();
    }

    private void ReplayTick(object? sender, object e)
    {
        if (replayTracks is null) return;
        var time = (DateTime.UtcNow - replayStarted).TotalSeconds;
        foreach (var trackNode in replayTracks)
        {
            var track = trackNode!.AsObject(); var number = track["number"]!.GetValue<int>(); if (!poolBallViews.TryGetValue(number, out var view)) continue;
            var keys = track["keys"]!.AsArray(); if (keys.Count == 0) continue;
            var next = keys.FirstOrDefault(k => k!["time"]!.GetValue<double>() >= time) ?? keys[^1];
            SetPoolPosition(view, new Windows.Foundation.Point((next!["x"]!.GetValue<double>() + 1.27) / 2.54 * 940 + 30, (next["y"]!.GetValue<double>() + 0.635) / 1.27 * 440 + 30));
            if (next["drop"]?.GetValue<double>() >= 1) view.Visibility = Visibility.Collapsed;
        }
        if (time >= replayDuration) { poolAnimation.Stop(); RenderPool(); }
    }

    private static Windows.Foundation.Point PoolPoint(JsonNode? position)
    {
        var x = position?["x"]?.GetValue<double>() ?? position?[0]?.GetValue<double>() ?? 0;
        var y = position?["y"]?.GetValue<double>() ?? position?[1]?.GetValue<double>() ?? 0;
        return new Windows.Foundation.Point((x + 1.27) / 2.54 * 940 + 30, (y + 0.635) / 1.27 * 440 + 30);
    }
    private static void SetPoolPosition(UIElement view, Windows.Foundation.Point point)
    { Canvas.SetLeft(view, point.X - 14); Canvas.SetTop(view, point.Y - 14); }
    private static Grid PoolBall(int number)
    {
        var colors = new[] { "#F4F0DD", "#E5BC23", "#2459A5", "#C43B32", "#66348C", "#DF7628", "#27704C", "#7B2025", "#151515", "#E5BC23", "#2459A5", "#C43B32", "#66348C", "#DF7628", "#27704C", "#7B2025" };
        var grid = new Grid { Width = 28, Height = 28 };
        grid.Children.Add(new Ellipse { Width = 28, Height = 28, Fill = new SolidColorBrush(Color.FromArgb(255, 250, 250, 245)) });
        var ball = new Ellipse { Width = 24, Height = 24, Fill = new SolidColorBrush((Color)Microsoft.UI.Xaml.Markup.XamlBindingHelper.ConvertValue(typeof(Color), colors[number])) };
        grid.Children.Add(ball);
        if (number > 0) { var text = Controls.Text(number.ToString(), 10, FontWeights.Bold, Colors.Black); text.HorizontalAlignment = HorizontalAlignment.Center; text.VerticalAlignment = VerticalAlignment.Center; grid.Children.Add(text); }
        return grid;
    }
}
