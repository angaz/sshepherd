#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef uint64_t SSAppleTerminal;
typedef struct { uint8_t *data; size_t len; } SSAppleBuffer;

/* Stable semantic input values; these deliberately do not expose Ghostty enum ordinals. */
typedef enum { SS_APPLE_KEY_TEXT = 0, SS_APPLE_KEY_ESCAPE, SS_APPLE_KEY_TAB, SS_APPLE_KEY_ENTER, SS_APPLE_KEY_BACKSPACE, SS_APPLE_KEY_DELETE, SS_APPLE_KEY_UP, SS_APPLE_KEY_DOWN, SS_APPLE_KEY_LEFT, SS_APPLE_KEY_RIGHT, SS_APPLE_KEY_HOME, SS_APPLE_KEY_END, SS_APPLE_KEY_PAGE_UP, SS_APPLE_KEY_PAGE_DOWN } SSAppleKey;
typedef enum { SS_APPLE_MOD_SHIFT = 1, SS_APPLE_MOD_CONTROL = 2, SS_APPLE_MOD_OPTION = 4, SS_APPLE_MOD_COMMAND = 8 } SSAppleModifier;
typedef enum { SS_APPLE_KEY_PRESS = 0, SS_APPLE_KEY_REPEAT = 1, SS_APPLE_KEY_RELEASE = 2 } SSAppleKeyAction;

int ss_apple_create(uint32_t cols, uint32_t rows, SSAppleTerminal *out);
int ss_apple_destroy(SSAppleTerminal handle);
int ss_apple_write(SSAppleTerminal handle, const uint8_t *data, size_t len);
int ss_apple_resize(SSAppleTerminal handle, uint32_t cols, uint32_t rows, uint32_t cell_width, uint32_t cell_height);
int ss_apple_frame(SSAppleTerminal handle, SSAppleBuffer *out);
int ss_apple_replies(SSAppleTerminal handle, SSAppleBuffer *out);
int ss_apple_key(SSAppleTerminal handle, int key, int mods, int action, const uint8_t *utf8, size_t len, int consumed_mods, SSAppleBuffer *out);
/* Validates stable semantic input then maps it to pinned Ghostty key/modifier/action values. */
int ss_apple_semantic_key(SSAppleTerminal handle, SSAppleKey key, int modifiers, SSAppleKeyAction action, const uint8_t *utf8, size_t len, SSAppleBuffer *out);
int ss_apple_mouse(SSAppleTerminal handle, int action, int button, double x, double y, int mods, SSAppleBuffer *out);
int ss_apple_mode(SSAppleTerminal handle, int number, int *out);
void ss_apple_free(SSAppleBuffer *buffer);

#ifdef __cplusplus
}
#endif
