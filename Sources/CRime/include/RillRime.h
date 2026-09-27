#pragma once
#include <stdint.h>

typedef uintptr_t RillRimeSession;
typedef struct {
    char *text;
    char *comment;
} RillRimeCandidate;
typedef struct {
    char *preedit;
    int cursor;
    int selected;
    int count;
    int page;
    int last_page;
    int ascii_mode;
    RillRimeCandidate *candidates;
} RillRimeState;

int rill_rime_open(const char *library, const char *user_data);
void rill_rime_close(void);
RillRimeSession rill_rime_create_session(void);
void rill_rime_destroy_session(RillRimeSession session);
int rill_rime_process_key(RillRimeSession session, int key, int modifiers);
int rill_rime_select(RillRimeSession session, int index);
void rill_rime_commit_composition(RillRimeSession session);
void rill_rime_clear(RillRimeSession session);
char *rill_rime_take_commit(RillRimeSession session);
RillRimeState *rill_rime_state(RillRimeSession session);
void rill_rime_free_state(RillRimeState *state);
void rill_rime_free_text(char *text);
