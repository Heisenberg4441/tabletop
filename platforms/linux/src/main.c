#include <adwaita.h>
#include <math.h>
#include <pango/pangocairo.h>
#include "engine.h"

static AdwApplicationWindow *window;
static GtkWidget *page, *canvas, *actions;
static JsonObject *response;
static char *current;
static double pool_aim;
static guint bot_source;

static const char *suits[] = {"♣", "♦", "♥", "♠"};
static const char *ranks[] = {"A", "2", "3", "4", "5", "6", "7", "8", "9", "10", "J", "Q", "K"};
static const char *games[] = {"pool", "poker", "blackjack", "durak", "solitaire"};
static const char *titles[] = {"Pool", "Poker", "Blackjack", "Durak", "Solitaire"};
static void show_game(const char *game);
static void render(void);

static JsonObject *object(JsonObject *o, const char *key) { return o && json_object_has_member(o, key) ? json_object_get_object_member(o, key) : NULL; }
static JsonArray *array(JsonObject *o, const char *key) { return o && json_object_has_member(o, key) ? json_object_get_array_member(o, key) : NULL; }
static const char *string(JsonObject *o, const char *key) { return o && json_object_has_member(o, key) ? json_object_get_string_member(o, key) : ""; }
static int number(JsonObject *o, const char *key) { return o && json_object_has_member(o, key) ? (int)json_object_get_int_member(o, key) : 0; }
static int boolean(JsonObject *o, const char *key) { return o && json_object_has_member(o, key) ? json_object_get_boolean_member(o, key) : 0; }
static int card_code(JsonNode *node) {
    if (!node) return 0;
    if (JSON_NODE_HOLDS_VALUE(node)) return (int)json_node_get_int(node);
    return number(json_node_get_object(node), "code");
}
static JsonNode *member(JsonArray *a, guint i) { return i < json_array_get_length(a) ? json_array_get_element(a, i) : NULL; }
static JsonObject *member_object(JsonArray *a, guint i) { JsonNode *n = member(a, i); return n ? json_node_get_object(n) : NULL; }
static void clear_response(void) { if (response) json_object_unref(response); response = NULL; }

static void text(cairo_t *cr, const char *value, double x, double y, double size, double red, double green, double blue, int centre) {
    PangoLayout *layout = pango_cairo_create_layout(cr);
    char font[64]; g_snprintf(font, sizeof font, "Cantarell %.1fpx", size);
    PangoFontDescription *description = pango_font_description_from_string(font);
    pango_layout_set_font_description(layout, description); pango_font_description_free(description);
    pango_layout_set_text(layout, value, -1);
    int width, height; pango_layout_get_pixel_size(layout, &width, &height);
    cairo_set_source_rgb(cr, red, green, blue); cairo_move_to(cr, centre ? x - width / 2.0 : x, y); pango_cairo_show_layout(cr, layout);
    g_object_unref(layout);
}

static void rounded(cairo_t *cr, double x, double y, double w, double h, double r) {
    cairo_new_sub_path(cr); cairo_arc(cr, x + w - r, y + r, r, -G_PI_2, 0); cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI_2);
    cairo_arc(cr, x + r, y + h - r, r, G_PI_2, G_PI); cairo_arc(cr, x + r, y + r, r, G_PI, 3 * G_PI_2); cairo_close_path(cr);
}

static void draw_card(cairo_t *cr, int code, int down, double x, double y, double w) {
    double h = w * 1.4; rounded(cr, x, y, w, h, 7);
    cairo_set_source_rgb(cr, down ? 0.10 : 0.97, down ? 0.20 : 0.96, down ? 0.34 : 0.92); cairo_fill_preserve(cr);
    cairo_set_source_rgba(cr, 0.7, 0.7, 0.65, 1); cairo_set_line_width(cr, 1); cairo_stroke(cr);
    if (down) { text(cr, "◆", x + w / 2, y + h / 2 - 15, w * 0.38, 0.85, 0.72, 0.43, 1); return; }
    double red = code / 13 == 1 || code / 13 == 2; char corner[16]; g_snprintf(corner, sizeof corner, "%s\n%s", ranks[code % 13], suits[code / 13]);
    text(cr, corner, x + 6, y + 5, w * 0.20, red ? 0.7 : 0.06, red ? 0.08 : 0.08, red ? 0.12 : 0.07, 0);
    text(cr, suits[code / 13], x + w / 2, y + h / 2 - w * 0.20, w * 0.46, red ? 0.7 : 0.06, red ? 0.08 : 0.08, red ? 0.12 : 0.07, 1);
}

static void call_game(const char *action, JsonObject *parameters) {
    if (!current) return;
    if (bot_source) { g_source_remove(bot_source); bot_source = 0; }
    JsonObject *next = engine_call(current, action, parameters);
    if (next) { clear_response(); response = next; }
    render();
}

static void library_clicked(GtkButton *button, gpointer game) { show_game(game); }

static void simple_action(GtkButton *button, gpointer action) {
    const char *name = action;
    if (!g_strcmp0(name, "take_special") || !g_strcmp0(name, "pass_special")) {
        JsonObject *p = json_object_new(); json_object_set_string_member(p, "kind", !g_strcmp0(name, "take_special") ? "take" : "pass"); call_game("play", p); return;
    }
    if (!g_strcmp0(name, "insurance_yes") || !g_strcmp0(name, "insurance_no")) {
        JsonObject *p = json_object_new(); json_object_set_boolean_member(p, "take", !g_strcmp0(name, "insurance_yes")); call_game("insurance", p); return;
    }
    if (g_str_has_prefix(name, "poker_")) {
        JsonObject *p = json_object_new(); json_object_set_string_member(p, "kind", name + 6);
        if (!g_strcmp0(name, "poker_raise")) {
            JsonObject *options = object(response, "options"); json_object_set_string_member(p, "kind", boolean(options, "canBet") ? "bet" : "raise"); json_object_set_int_member(p, "total", number(options, "minTotal"));
        }
        call_game("play", p); return;
    }
    if (!g_strcmp0(name, "pool_shoot")) {
        JsonObject *p = json_object_new(); json_object_set_double_member(p, "aim", pool_aim); json_object_set_double_member(p, "power", 0.65); call_game("shoot", p); return;
    }
    call_game(name, NULL);
}
static void add_action(const char *label, const char *action) {
    GtkWidget *button = gtk_button_new_with_label(label);
    if (g_strcmp0(action, "deal") == 0 || g_strcmp0(action, "startHand") == 0) gtk_widget_add_css_class(button, "suggested-action");
    g_signal_connect_data(button, "clicked", G_CALLBACK(simple_action), g_strdup(action), (GClosureNotify)g_free, 0);
    gtk_box_append(GTK_BOX(actions), button);
}

static void bet_action(GtkButton *button, gpointer amount) {
    JsonObject *p = json_object_new(); json_object_set_int_member(p, "amount", GPOINTER_TO_INT(amount)); call_game("bet", p);
}
static void add_bet(int amount) {
    char label[24]; g_snprintf(label, sizeof label, "%d", amount);
    GtkWidget *button = gtk_button_new_with_label(label); g_signal_connect_data(button, "clicked", G_CALLBACK(bet_action), GINT_TO_POINTER(amount), NULL, 0);
    gtk_box_append(GTK_BOX(actions), button);
}

static gboolean bot_tick(gpointer data) {
    bot_source = 0;
    if (!current || !response) return G_SOURCE_REMOVE;
    if (!g_strcmp0(current, "durak") && number(object(response, "state"), "actor") > 0) call_game("bot", NULL);
    else if (!g_strcmp0(current, "blackjack") && boolean(response, "needsAdvance")) call_game("advance", NULL);
    else if (!g_strcmp0(current, "poker")) {
        if (!g_strcmp0(string(response, "phase"), "streetComplete")) call_game("advance", NULL);
        else if (number(object(response, "options"), "seat") > 0) call_game("bot", NULL);
    } else if (!g_strcmp0(current, "pool") && boolean(response, "computer")) call_game("bot", NULL);
    return G_SOURCE_REMOVE;
}
static void schedule_bot(void) { if (!bot_source) bot_source = g_timeout_add(500, bot_tick, NULL); }

static void draw_solitaire(cairo_t *cr) {
    JsonObject *game = object(response, "state"); JsonArray *stock = array(game, "stock"), *waste = array(game, "waste"), *foundations = array(game, "foundations"), *tableau = array(game, "tableau");
    if (json_array_get_length(stock)) draw_card(cr, 0, 1, 30, 25, 78);
    if (json_array_get_length(waste)) draw_card(cr, card_code(member(waste, json_array_get_length(waste) - 1)), 0, 135, 25, 78);
    for (int i = 0; i < 4; i++) { int height = (int)json_node_get_int(member(foundations, i)); if (height) draw_card(cr, i * 13 + height - 1, 0, 510 + i * 110, 25, 78); }
    for (int col = 0; col < 7; col++) {
        JsonObject *column = member_object(tableau, col); JsonArray *down = array(column, "down"), *up = array(column, "up"); double y = 175;
        for (guint i = 0; i < json_array_get_length(down); i++, y += 12) draw_card(cr, 0, 1, 30 + col * 110, y, 78);
        for (guint i = 0; i < json_array_get_length(up); i++) { draw_card(cr, card_code(member(up, i)), 0, 30 + col * 110, y, 78); y += fmin(32, 280.0 / json_array_get_length(up)); }
    }
}

static void card_row(cairo_t *cr, JsonArray *cards, double centre, double y, int hidden) {
    guint count = json_array_get_length(cards); double start = centre - (count * 64 - 6) / 2;
    for (guint i = 0; i < count; i++) draw_card(cr, card_code(member(cards, i)), i == hidden, start + i * 64, y, 58);
}

static void draw_blackjack(cairo_t *cr) {
    JsonObject *round = object(object(response, "state"), "round");
    text(cr, "DEALER", 500, 35, 16, 1, 1, 1, 1);
    if (!round) { text(cr, "Place your bet", 500, 245, 28, 1, 1, 1, 1); return; }
    card_row(cr, array(round, "dealer"), 500, 70, boolean(round, "isHoleRevealed") ? -1 : 1);
    JsonArray *hands = array(round, "hands"); guint count = json_array_get_length(hands);
    for (guint i = 0; i < count; i++) {
        JsonObject *hand = member_object(hands, i); card_row(cr, array(hand, "cards"), 500 + ((int)i - ((int)count - 1) / 2.0) * 250, 330, -1);
        char label[80]; g_snprintf(label, sizeof label, "%s · bet %d", string(hand, "result"), number(hand, "bet")); text(cr, label, 500 + ((int)i - ((int)count - 1) / 2.0) * 250, 425, 14, 1, 1, 1, 1);
    }
}

static void draw_durak(cairo_t *cr) {
    JsonObject *game = object(response, "state"); JsonArray *hands = array(game, "hands");
    for (guint seat = 1; seat < json_array_get_length(hands); seat++) {
        JsonArray *hand = json_node_get_array(member(hands, seat));
        double x = 500 + ((int)seat - (int)json_array_get_length(hands) / 2.0) * 230; char label[60];
        g_snprintf(label, sizeof label, "Player %u · %u cards", seat + 1, json_array_get_length(hand)); text(cr, label, x, 20, 14, 1, 1, 1, 1);
        for (int i = 0; i < 5; i++) draw_card(cr, 0, 1, x - 70 + i * 28, 48, 42);
    }
    JsonArray *pairs = array(game, "table");
    for (guint i = 0; i < json_array_get_length(pairs); i++) {
        JsonObject *pair = member_object(pairs, i); double x = 180 + i * 112;
        draw_card(cr, card_code(json_object_get_member(pair, "attack")), 0, x, 185, 72);
        if (json_object_has_member(pair, "defence")) draw_card(cr, card_code(json_object_get_member(pair, "defence")), 0, x + 25, 220, 72);
    }
    JsonArray *hand = json_node_get_array(member(hands, 0));
    for (guint i = 0; i < json_array_get_length(hand); i++) draw_card(cr, card_code(member(hand, i)), 0, 110 + i * 78, 430, 66);
}

static void draw_poker(cairo_t *cr) {
    JsonObject *game = object(response, "state"); JsonArray *players = array(game, "players");
    for (guint i = 1; i < json_array_get_length(players); i++) {
        JsonObject *p = member_object(players, i); double x = 100 + (i - 1) * 195;
        char label[80]; g_snprintf(label, sizeof label, "%s · %d", string(p, "name"), number(p, "stack")); text(cr, label, x + 65, 25, 13, 1, 1, 1, 1);
        JsonArray *cards = array(p, "holeCards"); for (guint k = 0; k < json_array_get_length(cards); k++) draw_card(cr, 0, 1, x + k * 46, 55, 42);
    }
    card_row(cr, array(game, "board"), 500, 205, -1);
    if (json_array_get_length(players)) {
        JsonObject *p = member_object(players, 0); JsonArray *cards = array(p, "holeCards"); card_row(cr, cards, 500, 390, -1);
        char label[80]; g_snprintf(label, sizeof label, "You · %d chips · bet %d", number(p, "stack"), number(p, "bet")); text(cr, label, 500, 510, 15, 1, 1, 1, 1);
    }
}

static void pool_xy(double x, double y, double *px, double *py) { *px = (x + 1.27) / 2.54 * 850 + 75; *py = (y + 0.635) / 1.27 * 420 + 80; }
static double position_component(JsonNode *position, int component) {
    if (JSON_NODE_HOLDS_OBJECT(position)) return json_object_get_double_member(json_node_get_object(position), component ? "y" : "x");
    return json_array_get_double_element(json_node_get_array(position), component);
}
static void draw_pool(cairo_t *cr) {
    cairo_set_source_rgb(cr, 0.24, 0.12, 0.06); rounded(cr, 50, 55, 900, 470, 12); cairo_fill(cr);
    cairo_set_source_rgb(cr, 0.08, 0.38, 0.25); cairo_rectangle(cr, 70, 75, 860, 430); cairo_fill(cr);
    JsonObject *table = object(object(response, "state"), "table");
    JsonArray *balls = array(table, "balls");
    double colors[16][3] = {{0.95,0.94,0.86},{0.9,0.73,0.14},{0.14,0.35,0.65},{0.77,0.23,0.2},{0.4,0.2,0.55},{0.87,0.46,0.16},{0.15,0.44,0.3},{0.48,0.13,0.15},{0.08,0.08,0.08},{0.9,0.73,0.14},{0.14,0.35,0.65},{0.77,0.23,0.2},{0.4,0.2,0.55},{0.87,0.46,0.16},{0.15,0.44,0.3},{0.48,0.13,0.15}};
    for (guint i = 0; i < json_array_get_length(balls); i++) {
        JsonObject *ball = member_object(balls, i); if (json_object_has_member(ball, "pocket")) continue;
        int n = number(ball, "number"); JsonNode *position = json_object_get_member(ball, "position");
        double x, y; pool_xy(position_component(position, 0), position_component(position, 1), &x, &y);
        cairo_set_source_rgb(cr, colors[n][0], colors[n][1], colors[n][2]); cairo_arc(cr, x, y, 12, 0, 2 * G_PI); cairo_fill(cr);
        if (n) { char label[4]; g_snprintf(label, sizeof label, "%d", n); text(cr, label, x, y - 6, 10, n == 8, n == 8, n == 8, 1); }
    }
    JsonObject *cue = NULL; for (guint i = 0; i < json_array_get_length(balls); i++) if (number(member_object(balls, i), "number") == 0) cue = member_object(balls, i);
    if (cue && !json_object_has_member(cue, "pocket")) {
        JsonNode *position = json_object_get_member(cue, "position"); double x, y;
        pool_xy(position_component(position, 0), position_component(position, 1), &x, &y);
        cairo_set_source_rgba(cr, 1, 1, 0.85, 0.6); cairo_set_line_width(cr, 1.5); cairo_move_to(cr, x, y); cairo_line_to(cr, x + cos(pool_aim) * 230, y + sin(pool_aim) * 230); cairo_stroke(cr);
    }
}

static void draw(GtkDrawingArea *area, cairo_t *cr, int width, int height, gpointer data) {
    cairo_scale(cr, width / 1000.0, height / 600.0);
    cairo_set_source_rgb(cr, 0.06, 0.29, 0.20); cairo_paint(cr);
    if (!response || !current) return;
    if (!g_strcmp0(current, "solitaire")) draw_solitaire(cr);
    else if (!g_strcmp0(current, "blackjack")) draw_blackjack(cr);
    else if (!g_strcmp0(current, "durak")) draw_durak(cr);
    else if (!g_strcmp0(current, "poker")) draw_poker(cr);
    else if (!g_strcmp0(current, "pool")) draw_pool(cr);
}

static void render_actions(void) {
    GtkWidget *child; while ((child = gtk_widget_get_first_child(actions))) gtk_box_remove(GTK_BOX(actions), child);
    if (!response || !current) return;
    if (!g_strcmp0(current, "solitaire")) { add_action("Undo", "undo"); add_action("Redo", "redo"); add_action("Hint", "hint"); add_action("Auto finish", "autoFinish"); }
    else if (!g_strcmp0(current, "blackjack")) {
        const char *phase = string(response, "phase");
        if (!g_strcmp0(phase, "betting") || !g_strcmp0(phase, "settled")) { add_bet(5); add_bet(25); add_bet(100); add_bet(500); add_action("Deal", "deal"); add_action("Rebet", "rebet"); add_action("Clear", "clearBet"); }
        else if (!g_strcmp0(phase, "insurance")) { add_action("Insurance", "insurance_yes"); add_action("Decline", "insurance_no"); }
        else { JsonArray *legal = array(response, "legalActions"); for (guint i = 0; i < json_array_get_length(legal); i++) add_action(json_node_get_string(member(legal, i)), json_node_get_string(member(legal, i))); }
        if (boolean(response, "needsAdvance")) schedule_bot();
    } else if (!g_strcmp0(current, "durak")) {
        JsonObject *game = object(response, "state"); if (number(game, "actor") > 0) schedule_bot();
        else if (!g_strcmp0(string(game, "phase"), "defend")) add_action("Take", "take_special");
        else if (!g_strcmp0(string(game, "phase"), "throwIn") || !g_strcmp0(string(game, "phase"), "pileOn")) add_action("Bito / Pass / Done", "pass_special");
    } else if (!g_strcmp0(current, "poker")) {
        JsonObject *options = object(response, "options");
        if (options && number(options, "seat") == 0) {
            if (boolean(options, "canFold")) add_action("Fold", "poker_fold"); if (boolean(options, "canCheck")) add_action("Check", "poker_check");
            if (boolean(options, "canCall")) add_action("Call", "poker_call"); if (boolean(options, "canRaise") || boolean(options, "canBet")) add_action("Bet / raise", "poker_raise"); add_action("All-in", "poker_allIn");
        } else if (!g_strcmp0(string(response, "phase"), "betweenHands")) add_action("Next hand", "startHand"); else schedule_bot();
    } else if (!g_strcmp0(current, "pool")) { add_action("Shoot", "pool_shoot"); if (boolean(response, "computer")) schedule_bot(); }
}

static void render(void) { render_actions(); gtk_widget_queue_draw(canvas); }

static void show_library(void) {
    current = NULL; clear_response(); if (bot_source) { g_source_remove(bot_source); bot_source = 0; }
    adw_application_window_set_content(window, NULL);
    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 24); gtk_widget_set_margin_top(root, 38); gtk_widget_set_margin_bottom(root, 30); gtk_widget_set_margin_start(root, 35); gtk_widget_set_margin_end(root, 35);
    GtkWidget *title = gtk_label_new("Tabletop"); gtk_widget_add_css_class(title, "title-1"); gtk_box_append(GTK_BOX(root), title);
    GtkWidget *subtitle = gtk_label_new("A quiet room for classic games"); gtk_widget_add_css_class(subtitle, "dim-label"); gtk_box_append(GTK_BOX(root), subtitle);
    GtkWidget *grid = gtk_grid_new(); gtk_grid_set_column_spacing(GTK_GRID(grid), 14); gtk_grid_set_row_spacing(GTK_GRID(grid), 14); gtk_widget_set_hexpand(grid, TRUE); gtk_widget_set_vexpand(grid, TRUE);
    const char *subtitles[] = {"Eight-ball and nine-ball", "No-limit Texas Hold’em", "Beat the dealer to twenty-one", "The classic Russian card game", "Klondike, draw one or three"};
    for (int i = 0; i < 5; i++) {
        GtkWidget *button = gtk_button_new(); gtk_widget_add_css_class(button, "card"); gtk_widget_add_css_class(button, "game-tile"); gtk_widget_set_size_request(button, 170, 260);
        GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 10); gtk_widget_set_margin_top(box, 30); gtk_widget_set_margin_bottom(box, 18); gtk_widget_set_margin_start(box, 14); gtk_widget_set_margin_end(box, 14);
        GtkWidget *symbol = gtk_label_new(i == 0 ? "8" : i == 1 ? "♠" : i == 2 ? "♦" : i == 3 ? "♣" : "♥"); gtk_widget_add_css_class(symbol, "game-symbol");
        GtkWidget *name = gtk_label_new(titles[i]); gtk_widget_add_css_class(name, "title-2"); GtkWidget *sub = gtk_label_new(subtitles[i]); gtk_label_set_wrap(GTK_LABEL(sub), TRUE); gtk_widget_add_css_class(sub, "dim-label");
        gtk_box_append(GTK_BOX(box), symbol); gtk_box_append(GTK_BOX(box), name); gtk_box_append(GTK_BOX(box), sub); gtk_button_set_child(GTK_BUTTON(button), box);
        g_signal_connect_data(button, "clicked", G_CALLBACK(library_clicked), g_strdup(games[i]), (GClosureNotify)g_free, 0);
        gtk_grid_attach(GTK_GRID(grid), button, i, 0, 1, 1);
    }
    gtk_box_append(GTK_BOX(root), grid); adw_application_window_set_content(window, root);
}

static void back_clicked(GtkButton *button, gpointer data) { show_library(); }
static void new_clicked(GtkButton *button, gpointer data) { if (current) call_game("new", NULL); }

static void durak_play_card(int code) {
    JsonObject *game = object(response, "state"); if (number(game, "actor") != 0) return;
    const char *phase = string(game, "phase"); JsonObject *p = json_object_new(); json_object_set_int_member(p, "card", code);
    if (!g_strcmp0(phase, "lead") || !g_strcmp0(phase, "throwIn") || !g_strcmp0(phase, "pileOn")) {
        json_object_set_string_member(p, "kind", "attack"); call_game("play", p); return;
    }
    JsonArray *legal = array(response, "legalActions");
    for (guint i = 0; i < json_array_get_length(legal); i++) {
        JsonObject *action = member_object(legal, i); JsonObject *defend = object(action, "defend"), *transfer = object(action, "transfer");
        if (defend && card_code(json_object_get_member(defend, "card")) == code) {
            json_object_set_string_member(p, "kind", "defend"); json_object_set_int_member(p, "on", card_code(json_object_get_member(defend, "on"))); call_game("play", p); return;
        }
        if (transfer && card_code(json_object_get_member(transfer, "_0")) == code) {
            json_object_set_string_member(p, "kind", "transfer"); call_game("play", p); return;
        }
    }
    json_object_unref(p);
}

static void canvas_click(GtkGestureClick *gesture, int n_press, double x, double y, gpointer data) {
    if (!response || !current) return;
    double lx = x / gtk_widget_get_width(canvas) * 1000, ly = y / gtk_widget_get_height(canvas) * 600;
    if (!g_strcmp0(current, "solitaire")) {
        JsonObject *p = json_object_new();
        if (ly < 155 && lx < 110) { json_object_unref(p); call_game(json_array_get_length(array(object(response, "state"), "stock")) ? "draw" : "recycle", NULL); return; }
        json_object_set_string_member(p, "target", ly < 155 && lx < 240 ? "waste" : "tableau");
        if (ly >= 155) { json_object_set_int_member(p, "column", CLAMP((int)(lx - 30) / 110, 0, 6)); json_object_set_int_member(p, "depth", 0); }
        call_game("click", p);
    } else if (!g_strcmp0(current, "durak") && ly >= 420) {
        JsonArray *hands = array(object(response, "state"), "hands"); JsonArray *hand = json_node_get_array(member(hands, 0));
        int index = (int)(lx - 110) / 78; if (index >= 0 && index < (int)json_array_get_length(hand)) durak_play_card(card_code(member(hand, index)));
    } else if (!g_strcmp0(current, "pool")) {
        JsonObject *rules = object(object(response, "state"), "rules");
        if (json_object_has_member(rules, "ballInHand")) {
            JsonObject *p = json_object_new(); json_object_set_double_member(p, "x", (lx - 75) / 850 * 2.54 - 1.27); json_object_set_double_member(p, "y", (ly - 80) / 420 * 1.27 - 0.635); call_game("place", p);
        }
    }
}

static void pool_motion(GtkEventControllerMotion *controller, double x, double y, gpointer data) {
    if (!response || !current || g_strcmp0(current, "pool")) return;
    JsonArray *balls = array(object(object(response, "state"), "table"), "balls");
    for (guint i = 0; i < json_array_get_length(balls); i++) {
        JsonObject *cue = member_object(balls, i); if (number(cue, "number") || json_object_has_member(cue, "pocket")) continue;
        JsonNode *position = json_object_get_member(cue, "position"); double cx, cy;
        pool_xy(position_component(position, 0), position_component(position, 1), &cx, &cy);
        pool_aim = atan2(y / gtk_widget_get_height(canvas) * 600 - cy, x / gtk_widget_get_width(canvas) * 1000 - cx); gtk_widget_queue_draw(canvas); return;
    }
}

static void show_game(const char *game) {
    g_free(current); current = g_strdup(game); clear_response(); response = engine_restore(game);
    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    GtkWidget *header = adw_header_bar_new(); GtkWidget *back = gtk_button_new_with_label("‹ Library"); g_signal_connect(back, "clicked", G_CALLBACK(back_clicked), NULL);
    GtkWidget *newgame = gtk_button_new_with_label("New game"); g_signal_connect(newgame, "clicked", G_CALLBACK(new_clicked), NULL);
    adw_header_bar_pack_start(ADW_HEADER_BAR(header), back); adw_header_bar_pack_end(ADW_HEADER_BAR(header), newgame);
    gtk_box_append(GTK_BOX(root), header);
    canvas = gtk_drawing_area_new(); gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(canvas), draw, NULL, NULL); gtk_widget_set_size_request(canvas, 1000, 600); gtk_widget_set_hexpand(canvas, TRUE); gtk_widget_set_vexpand(canvas, TRUE);
    GtkGesture *click = gtk_gesture_click_new(); g_signal_connect(click, "pressed", G_CALLBACK(canvas_click), NULL); gtk_widget_add_controller(canvas, GTK_EVENT_CONTROLLER(click));
    GtkEventController *motion = gtk_event_controller_motion_new(); g_signal_connect(motion, "motion", G_CALLBACK(pool_motion), NULL); gtk_widget_add_controller(canvas, motion);
    gtk_box_append(GTK_BOX(root), canvas);
    actions = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 8); gtk_widget_set_halign(actions, GTK_ALIGN_CENTER); gtk_widget_set_margin_top(actions, 8); gtk_widget_set_margin_bottom(actions, 12); gtk_box_append(GTK_BOX(root), actions);
    adw_application_window_set_content(window, root); render();
}

static void activate(AdwApplication *app, gpointer data) {
    window = ADW_APPLICATION_WINDOW(adw_application_window_new(GTK_APPLICATION(app)));
    gtk_window_set_default_size(GTK_WINDOW(window), 1180, 780); gtk_window_set_title(GTK_WINDOW(window), "Tabletop");
    GtkCssProvider *css = gtk_css_provider_new();
    gtk_css_provider_load_from_string(css, ".game-tile{padding:0;border-radius:16px;background:#202b27;color:#f2f0e8}.game-symbol{font-size:64px;color:#d4b46a}button{border-radius:8px}canvas{background:#175640}");
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(css), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    if (!engine_start()) { GtkWidget *label = gtk_label_new("Tabletop engine was not found. Set TABLETOP_ENGINE to the Swift executable."); adw_application_window_set_content(window, label); }
    else show_library();
    gtk_window_present(GTK_WINDOW(window));
}

int main(int argc, char **argv) {
    AdwApplication *app = adw_application_new("com.tabletop.games", G_APPLICATION_DEFAULT_FLAGS);
    g_signal_connect(app, "activate", G_CALLBACK(activate), NULL);
    int status = g_application_run(G_APPLICATION(app), argc, argv);
    engine_stop(); g_object_unref(app); return status;
}
