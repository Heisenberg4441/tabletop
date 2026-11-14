#pragma once
#include <json-glib/json-glib.h>

int engine_start(void);
void engine_stop(void);
JsonObject *engine_call(const char *game, const char *action, JsonObject *parameters);
JsonObject *engine_restore(const char *game);
