#include "engine.h"
#include <glib/gstdio.h>

static GSubprocess *process;
static GDataInputStream *output;

static char *save_path(const char *game) {
    return g_build_filename(g_get_user_data_dir(), "tabletop", game, NULL);
}

int engine_start(void) {
    const char *configured = g_getenv("TABLETOP_ENGINE");
    char *local = g_build_filename(g_get_current_dir(), "engine", "Tabletop", NULL);
    const char *executable = configured && *configured ? configured : local;
    GError *error = NULL;
    process = g_subprocess_new(G_SUBPROCESS_FLAGS_STDIN_PIPE | G_SUBPROCESS_FLAGS_STDOUT_PIPE | G_SUBPROCESS_FLAGS_STDERR_SILENCE, &error, executable, NULL);
    if (!process) {
        g_warning("Cannot start engine at %s: %s", executable, error->message);
        g_error_free(error); g_free(local); return 0;
    }
    output = g_data_input_stream_new(g_subprocess_get_stdout_pipe(process));
    g_free(local); return 1;
}

void engine_stop(void) {
    if (process) g_subprocess_force_exit(process);
    g_clear_object(&output); g_clear_object(&process);
}

static void save(const char *game, JsonNode *node) {
    if (!node) return;
    char *directory = save_path(game); char *file = g_build_filename(directory, "state.json", NULL);
    g_mkdir_with_parents(directory, 0700);
    gchar *text = json_to_string(node, FALSE);
    g_file_set_contents(file, text, -1, NULL);
    g_free(text); g_free(file); g_free(directory);
}

static void merge_member(JsonObject *parameters, const gchar *key, JsonNode *value, gpointer request) {
    json_object_set_member(request, key, json_node_copy(value));
}

JsonObject *engine_call(const char *game, const char *action, JsonObject *parameters) {
    if (!process) return NULL;
    JsonNode *root = json_node_new(JSON_NODE_OBJECT);
    JsonObject *request = json_object_new();
    json_object_set_string_member(request, "game", game);
    json_object_set_string_member(request, "action", action);
    if (parameters) json_object_foreach_member(parameters, merge_member, request);
    json_node_set_object(root, request);
    gchar *line = json_to_string(root, FALSE);
    GOutputStream *input = g_subprocess_get_stdin_pipe(process);
    GError *error = NULL;
    g_output_stream_write_all(input, line, strlen(line), NULL, NULL, &error);
    g_output_stream_write_all(input, "\n", 1, NULL, NULL, &error);
    g_output_stream_flush(input, NULL, &error);
    g_free(line); json_node_free(root); if (parameters) json_object_unref(parameters);
    if (error) { g_warning("Engine write: %s", error->message); g_error_free(error); return NULL; }
    char *answer = g_data_input_stream_read_line(output, NULL, NULL, &error);
    if (!answer) { if (error) g_error_free(error); return NULL; }
    JsonParser *parser = json_parser_new(); json_parser_load_from_data(parser, answer, -1, &error); g_free(answer);
    if (error) { g_warning("Engine response: %s", error->message); g_error_free(error); g_object_unref(parser); return NULL; }
    JsonObject *response = json_object_ref(json_node_get_object(json_parser_get_root(parser)));
    g_object_unref(parser);
    if (!json_object_get_boolean_member(response, "ok")) { json_object_unref(response); return NULL; }
    if (g_strcmp0(action, "state") && g_strcmp0(action, "restore")) save(game, json_object_get_member(response, "saved"));
    return response;
}

JsonObject *engine_restore(const char *game) {
    char *directory = save_path(game); char *file = g_build_filename(directory, "state.json", NULL);
    JsonObject *response = NULL;
    if (g_file_test(file, G_FILE_TEST_EXISTS)) {
        JsonParser *parser = json_parser_new(); GError *error = NULL;
        if (json_parser_load_from_file(parser, file, &error)) {
            JsonObject *parameters = json_object_new();
            json_object_set_member(parameters, "saved", json_node_copy(json_parser_get_root(parser)));
            response = engine_call(game, "restore", parameters);
        }
        if (error) g_error_free(error); g_object_unref(parser);
    }
    g_free(file); g_free(directory);
    return response ? response : engine_call(game, "state", NULL);
}
