#include "RillRime.h"
#include "rime_api.h"
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// One library instance, serialized by the input method's main thread.
static RimeApi *api;
static int initialized;
static void *library_handle;
static void *plugins[3];

int rill_rime_open(const char *library, const char *user_data) {
    if (api) return 0;
    library_handle = dlopen(library, RTLD_NOW | RTLD_GLOBAL);
    if (!library_handle) return 0;
    RimeApi *(*get_api)(void) = dlsym(library_handle, "rime_get_api");
    if (!get_api) { rill_rime_close(); return 0; }
    api = get_api();
    const char *names[] = {"lua", "octagram", "predict"};
    const char *slash = strrchr(library, '/');
    if (!slash) { rill_rime_close(); return 0; }
    for (int i = 0; i < 3; ++i) {
        char path[4096];
        int length = snprintf(path, sizeof(path), "%.*s/rime-plugins/librime-%s.dylib",
                              (int)(slash - library), library, names[i]);
        if (length < 0 || length >= sizeof(path)) { rill_rime_close(); return 0; }
        plugins[i] = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
        if (!plugins[i]) { rill_rime_close(); return 0; }
    }
    RIME_STRUCT(RimeTraits, traits);
    const char *modules[] = {"default", "lua", "octagram", "predict", NULL};
    traits.shared_data_dir = user_data;
    traits.user_data_dir = user_data;
    traits.distribution_name = "Rill";
    traits.distribution_code_name = "rill";
    traits.distribution_version = "1";
    traits.app_name = "rime.rill";
    traits.modules = modules;
    traits.min_log_level = 2;
    traits.log_dir = "";
    api->setup(&traits);
    api->initialize(&traits);
    initialized = 1;
    for (int i = 0; i < 3; ++i) {
        if (!api->find_module(names[i])) { rill_rime_close(); return 0; }
    }
    return 1;
}

void rill_rime_close(void) {
    if (api && initialized) api->finalize();
    initialized = 0;
    api = NULL;
    // Rime registers plugin function pointers globally; unloading a plugin leaves dangling pointers.
    // The input method terminates after finalization and never reinitializes this instance.
}

RillRimeSession rill_rime_create_session(void) { return api ? api->create_session() : 0; }
void rill_rime_destroy_session(RillRimeSession s) { if (api && s) api->destroy_session(s); }
int rill_rime_process_key(RillRimeSession s, int k, int m) { return api && api->process_key(s, k, m); }
int rill_rime_select(RillRimeSession s, int i) {
    return api && i >= 0 && api->select_candidate_on_current_page(s, (size_t)i);
}
void rill_rime_commit_composition(RillRimeSession s) { if (api) api->commit_composition(s); }
void rill_rime_clear(RillRimeSession s) { if (api) api->clear_composition(s); }
char *rill_rime_take_commit(RillRimeSession s) {
    if (!api) return NULL;
    RIME_STRUCT(RimeCommit, commit);
    if (!api->get_commit(s, &commit)) return NULL;
    char *text = strdup(commit.text ? commit.text : "");
    api->free_commit(&commit);
    return text;
}
void rill_rime_free_text(char *text) { free(text); }
RillRimeState *rill_rime_state(RillRimeSession s) {
    if (!api) return NULL;
    RIME_STRUCT(RimeContext, context);
    if (!api->get_context(s, &context)) return NULL;
    RillRimeState *state = calloc(1, sizeof(*state));
    if (!state) { api->free_context(&context); return NULL; }
    state->preedit = strdup(context.composition.preedit ? context.composition.preedit : "");
    if (!state->preedit) { api->free_context(&context); free(state); return NULL; }
    state->cursor = context.composition.cursor_pos;
    state->selected = context.menu.highlighted_candidate_index;
    state->count = context.menu.num_candidates;
    state->page = context.menu.page_no;
    state->last_page = context.menu.is_last_page;
    state->candidates = calloc((size_t)state->count, sizeof(RillRimeCandidate));
    if (state->count && !state->candidates) {
        state->count = 0; api->free_context(&context); rill_rime_free_state(state); return NULL;
    }
    for (int i = 0; i < state->count; ++i) {
        state->candidates[i].text = strdup(context.menu.candidates[i].text);
        state->candidates[i].comment = strdup(context.menu.candidates[i].comment ? context.menu.candidates[i].comment : "");
        if (!state->candidates[i].text || !state->candidates[i].comment) {
            api->free_context(&context); rill_rime_free_state(state); return NULL;
        }
    }
    RIME_STRUCT(RimeStatus, status);
    if (api->get_status(s, &status)) {
        state->ascii_mode = status.is_ascii_mode;
        api->free_status(&status);
    }
    api->free_context(&context);
    return state;
}
void rill_rime_free_state(RillRimeState *state) {
    if (!state) return;
    for (int i = 0; i < state->count; ++i) {
        free(state->candidates[i].text);
        free(state->candidates[i].comment);
    }
    free(state->candidates);
    free(state->preedit);
    free(state);
}
