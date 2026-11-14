using Microsoft.UI;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using System.Text.Json.Nodes;
using Windows.UI;

namespace Tabletop;

public static class Controls
{
    public static readonly string[] Suits = ["♣", "♦", "♥", "♠"];
    public static readonly string[] Ranks = ["A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"];
    public static int CardCode(JsonNode? node)
    {
        if (node is JsonValue value && value.TryGetValue<int>(out var raw)) return raw;
        return node?["code"]?.GetValue<int>() ?? 0;
    }
    public static TextBlock Text(string text, double size = 14, FontWeight? weight = null, Color? color = null) => new()
    {
        Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal,
        Foreground = new SolidColorBrush(color ?? Color.FromArgb(255, 242, 242, 238)),
        TextWrapping = TextWrapping.Wrap,
    };
    public static Button Button(string text, RoutedEventHandler click, bool primary = false)
    {
        var button = new Button { Content = text, MinHeight = 36, Padding = new Thickness(16, 7, 16, 7) };
        if (primary) button.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        button.Click += click;
        return button;
    }
    public static Button Card(int code, bool down, RoutedEventHandler? click = null, double width = 82)
    {
        var rank = Ranks[code % 13]; var suit = Suits[code / 13];
        var border = new Border
        {
            Width = width, Height = width * 1.4, CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(down ? Color.FromArgb(255, 34, 61, 94) : Colors.White),
            BorderBrush = new SolidColorBrush(Color.FromArgb(255, 202, 199, 189)), BorderThickness = new Thickness(1),
        };
        var grid = new Grid(); grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        if (down)
        {
            var mark = Text("◆", 30, FontWeights.SemiBold, Color.FromArgb(255, 213, 190, 126));
            mark.HorizontalAlignment = HorizontalAlignment.Center; mark.VerticalAlignment = VerticalAlignment.Center; Grid.SetRow(mark, 1); grid.Children.Add(mark);
        }
        else
        {
            var color = code / 13 is 1 or 2 ? Color.FromArgb(255, 183, 35, 48) : Color.FromArgb(255, 24, 30, 27);
            var top = Text($"{rank}\n{suit}", width * 0.21, FontWeights.SemiBold, color); top.Margin = new Thickness(7, 5, 0, 0); grid.Children.Add(top);
            var centre = Text(suit, width * 0.48, FontWeights.Normal, color); centre.HorizontalAlignment = HorizontalAlignment.Center; centre.VerticalAlignment = VerticalAlignment.Center; Grid.SetRow(centre, 1); grid.Children.Add(centre);
            var bottom = Text($"{suit}\n{rank}", width * 0.21, FontWeights.SemiBold, color);
            bottom.RenderTransform = new RotateTransform { Angle = 180 };
            bottom.RenderTransformOrigin = new Windows.Foundation.Point(0.5, 0.5);
            bottom.HorizontalAlignment = HorizontalAlignment.Right;
            bottom.Margin = new Thickness(0, 0, 7, 5); Grid.SetRow(bottom, 2); grid.Children.Add(bottom);
        }
        border.Child = grid;
        var button = new Button { Content = border, Width = width, Height = width * 1.4, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Colors.Transparent) };
        if (click is not null) button.Click += click;
        return button;
    }
    public static StackPanel Row(params UIElement[] children)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, HorizontalAlignment = HorizontalAlignment.Center };
        foreach (var child in children) panel.Children.Add(child);
        return panel;
    }
    public static Border Panel(UIElement child) => new()
    {
        Child = child, Padding = new Thickness(18), CornerRadius = new CornerRadius(8),
        Background = new SolidColorBrush(Color.FromArgb(220, 25, 34, 30)),
        BorderBrush = new SolidColorBrush(Color.FromArgb(35, 255, 255, 255)), BorderThickness = new Thickness(1),
    };
}
