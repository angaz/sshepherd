#include "engine.hpp"
#include <algorithm>
#include <stdexcept>
#include <utility>
#include <cstring>

namespace {
void check(GhosttyResult result) {
    if (result != GHOSTTY_SUCCESS) throw std::runtime_error("libghostty-vt operation failed");
}
uint32_t color(GhosttyColorRgb c) { return 0xff000000u | uint32_t(c.r) << 16 | uint32_t(c.g) << 8 | c.b; }
void word(std::vector<uint8_t>& out, uint32_t value) {
    for (int i = 0; i < 4; ++i) out.push_back(uint8_t(value >> (i * 8)));
}
GhosttyKey androidKey(int code) {
    // Android KeyEvent codes are stable platform constants, not scan codes.
    if (code >= 29 && code <= 54) return GhosttyKey(GHOSTTY_KEY_A + code - 29);
    if (code >= 7 && code <= 16) return GhosttyKey(GHOSTTY_KEY_DIGIT_0 + code - 7);
    if (code >= 131 && code <= 142) return GhosttyKey(GHOSTTY_KEY_F1 + code - 131);
    switch (code) {
        case 19: return GHOSTTY_KEY_ARROW_UP;
        case 20: return GHOSTTY_KEY_ARROW_DOWN;
        case 21: return GHOSTTY_KEY_ARROW_LEFT;
        case 22: return GHOSTTY_KEY_ARROW_RIGHT;
        case 61: return GHOSTTY_KEY_TAB;
        case 62: return GHOSTTY_KEY_SPACE;
        case 66: return GHOSTTY_KEY_ENTER;
        case 67: return GHOSTTY_KEY_BACKSPACE;
        case 92: return GHOSTTY_KEY_PAGE_UP;
        case 93: return GHOSTTY_KEY_PAGE_DOWN;
        case 111: return GHOSTTY_KEY_ESCAPE;
        case 112: return GHOSTTY_KEY_DELETE;
        case 122: return GHOSTTY_KEY_HOME;
        case 123: return GHOSTTY_KEY_END;
        case 124: return GHOSTTY_KEY_INSERT;
        case 68: return GHOSTTY_KEY_BACKQUOTE;
        case 69: return GHOSTTY_KEY_MINUS;
        case 70: return GHOSTTY_KEY_EQUAL;
        case 71: return GHOSTTY_KEY_BRACKET_LEFT;
        case 72: return GHOSTTY_KEY_BRACKET_RIGHT;
        case 73: return GHOSTTY_KEY_BACKSLASH;
        case 74: return GHOSTTY_KEY_SEMICOLON;
        case 75: return GHOSTTY_KEY_QUOTE;
        case 76: return GHOSTTY_KEY_SLASH;
        case 55: return GHOSTTY_KEY_COMMA;
        case 56: return GHOSTTY_KEY_PERIOD;
        default: return GHOSTTY_KEY_UNIDENTIFIED;
    }
}
bool device(GhosttyTerminal, void*, GhosttyDeviceAttributes* out) {
    *out = {};
    out->primary.conformance_level = GHOSTTY_DA_CONFORMANCE_VT220;
    out->primary.features[0] = GHOSTTY_DA_FEATURE_ANSI_COLOR;
    out->primary.num_features = 1;
    out->secondary.device_type = GHOSTTY_DA_DEVICE_TYPE_VT220;
    out->secondary.firmware_version = 1;
    return true;
}
bool scheme(GhosttyTerminal, void*, GhosttyColorScheme* out) { *out = GHOSTTY_COLOR_SCHEME_DARK; return true; }
GhosttyString version(GhosttyTerminal, void*) { static const char name[] = "SSHepherd native 0.2"; return {reinterpret_cast<const uint8_t*>(name), sizeof(name) - 1}; }
}

Engine::Engine(int columns, int lines) : cols(columns), rows(lines) {
    if (cols < 2 || cols > 500 || rows < 2 || rows > 300) throw std::invalid_argument("Invalid terminal size");
    try {
        check(ghostty_terminal_new(nullptr, &terminal, cols, rows));
        check(ghostty_render_state_new(nullptr, &render));
        check(ghostty_render_state_row_iterator_new(nullptr, &iterator));
        check(ghostty_render_state_row_cells_new(nullptr, &cells));
        check(ghostty_key_encoder_new(nullptr, &keyEncoder));
        check(ghostty_key_event_new(nullptr, &keyEvent));
        check(ghostty_mouse_encoder_new(nullptr, &mouseEncoder));
        check(ghostty_mouse_event_new(nullptr, &mouseEvent));
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_USERDATA, this));
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void*>(writeReply)));
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SIZE, reinterpret_cast<const void*>(reportSize)));
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES, reinterpret_cast<const void*>(device)));
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, reinterpret_cast<const void*>(scheme)));
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_XTVERSION, reinterpret_cast<const void*>(version)));
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, reinterpret_cast<const void*>(writeClipboard)));
        size_t clipboardLimit = 60000;
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE_MAX_BYTES, &clipboardLimit));
        // Clipboard reads remain unregistered: remote queries cannot retrieve
        // phone clipboard contents. Only bounded standard text writes queue.
        GhosttyColorRgb fg{230, 237, 243}, bg{16, 20, 28};
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg));
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg));
        size_t limit = 8 * 1024 * 1024;
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &limit));
        // This renderer does not advertise or store inline graphics.
        size_t graphics = 0;
        check(ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &graphics));
    } catch (...) { cleanup(); throw; }
}
void Engine::cleanup() {
    ghostty_mouse_event_free(mouseEvent);
    ghostty_mouse_encoder_free(mouseEncoder);
    ghostty_key_event_free(keyEvent);
    ghostty_key_encoder_free(keyEncoder);
    ghostty_render_state_row_cells_free(cells);
    ghostty_render_state_row_iterator_free(iterator);
    ghostty_render_state_free(render);
    ghostty_terminal_free(terminal);
}
Engine::~Engine() { cleanup(); }
void Engine::writeReply(GhosttyTerminal, void* user, const uint8_t* data, size_t len) {
    auto& self = *static_cast<Engine*>(user);
    // Never throw across Zig's callback stack.
    if (len > 65536 - self.replies.size()) { self.replyOverflow = true; return; }
    try { self.replies.insert(self.replies.end(), data, data + len); }
    catch (...) { self.replyOverflow = true; }
}
void Engine::writeClipboard(GhosttyTerminal, void* user, const GhosttyClipboardWrite* request) {
    // Borrowed callback data must be copied before returning; never unwind into Zig.
    if (!request || request->size < sizeof(GhosttyClipboardWrite)) return;
    GhosttyClipboardWriteReply reply = GHOSTTY_INIT_SIZED(GhosttyClipboardWriteReply);
    reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
    if (request->location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD && request->contents_len == 1 && request->contents) {
        const auto& content = request->contents[0];
        static const char mime[] = "text/plain";
        if (content.mime.len == sizeof(mime) - 1 && content.mime.ptr &&
            std::memcmp(content.mime.ptr, mime, sizeof(mime) - 1) == 0 &&
            content.data.len <= 60000 && (content.data.ptr || content.data.len == 0)) {
            try {
                std::vector<uint8_t> text;
                if (content.data.len) text.assign(content.data.ptr, content.data.ptr + content.data.len);
                // Coalesce to the latest value rather than growing an unbounded
                // queue when remote output contains many clipboard operations.
                static_cast<Engine*>(user)->clipboard = std::move(text);
                reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS;
            } catch (...) { reply.result = GHOSTTY_CLIPBOARD_WRITE_RESULT_IO_ERROR; }
        }
    }
    if (request->reply) request->reply(request, &reply);
}
std::optional<std::vector<uint8_t>> Engine::takeClipboard() {
    auto result = std::move(clipboard);
    clipboard.reset();
    return result;
}
bool Engine::reportSize(GhosttyTerminal, void* user, GhosttySizeReportSize* out) {
    auto& self = *static_cast<Engine*>(user);
    *out = {uint16_t(self.rows), uint16_t(self.cols), uint32_t(self.cellWidth), uint32_t(self.cellHeight)};
    return true;
}
void Engine::write(const uint8_t* bytes, size_t len) {
    if (len > 1024 * 1024) throw std::invalid_argument("Oversized terminal write");
    ghostty_terminal_vt_write(terminal, bytes, len);
}
void Engine::resize(int columns, int lines, int cw, int ch) {
    if (columns < 2 || columns > 500 || lines < 2 || lines > 300 || cw < 1 || ch < 1 || cw > 1024 || ch > 1024)
        throw std::invalid_argument("Invalid terminal geometry");
    cols = columns; rows = lines; cellWidth = cw; cellHeight = ch;
    check(ghostty_terminal_resize(terminal, cols, rows, cw, ch));
}
std::vector<uint8_t> Engine::takeReplies() {
    if (replyOverflow) { replyOverflow = false; replies.clear(); throw std::runtime_error("Terminal response backlog exceeded"); }
    std::vector<uint8_t> result;
    result.swap(replies);
    return result;
}
bool Engine::mode(int number) {
    GhosttyTerminalModeConfig value{ghostty_mode_new(uint16_t(number), false), false};
    return ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MODE, &value) == GHOSTTY_SUCCESS && value.value;
}
std::vector<uint8_t> Engine::hyperlink(int x, int y) {
    if (x < 0 || x >= cols || y < 0 || y >= rows) return {};
    GhosttyPoint point{};
    point.tag = GHOSTTY_POINT_TAG_VIEWPORT;
    point.value.coordinate = {uint16_t(x), uint32_t(y)};
    GhosttyGridRef ref = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    check(ghostty_terminal_grid_ref(terminal, point, &ref));
    std::vector<uint8_t> uri(8192);
    size_t len = 0;
    auto rc = ghostty_grid_ref_hyperlink_uri(&ref, uri.data(), uri.size(), &len);
    if (rc == GHOSTTY_OUT_OF_SPACE) return {}; // Untrusted, bounded URI.
    check(rc);
    uri.resize(len);
    return uri;
}
std::vector<uint8_t> Engine::frame() {
    check(ghostty_render_state_update(render, terminal));
    GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
    GhosttyRenderStateCursor cursor = GHOSTTY_INIT_SIZED(GhosttyRenderStateCursor);
    check(ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors));
    check(ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor));
    std::vector<uint8_t> result;
    result.reserve(36 + cols * rows * 24);
    word(result, cols); word(result, rows);
    word(result, cursor.viewport_has_value ? cursor.viewport_x : 0);
    word(result, cursor.viewport_has_value ? cursor.viewport_y : 0);
    word(result, cursor.visual_style);
    word(result, (cursor.visible && cursor.viewport_has_value ? 1 : 0) | (cursor.blinking ? 2 : 0));
    word(result, color(colors.foreground)); word(result, color(colors.background));
    word(result, color(colors.cursor_has_value ? colors.cursor : colors.foreground));
    check(ghostty_render_state_get(render, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator));
    while (ghostty_render_state_row_iterator_next(iterator)) {
        GhosttyRow row{};
        bool wrapped = false;
        check(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_RAW, &row));
        check(ghostty_row_get(row, GHOSTTY_ROW_DATA_WRAP, &wrapped));
        check(ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells));
        while (ghostty_render_state_row_cells_next(cells)) {
            GhosttyCell raw{};
            GhosttyCellWide wide{};
            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            check(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw));
            check(ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide));
            check(ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style));
            GhosttyColorRgb fg = colors.foreground, bg = colors.background;
            (void)ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
            (void)ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg);
            if (style.inverse) std::swap(fg, bg);
            uint32_t flags = (style.bold ? 1 : 0) | (style.italic ? 2 : 0) | (style.underline ? 4 : 0)
                | (style.strikethrough ? 8 : 0) | (style.invisible ? 16 : 0) | (style.faint ? 32 : 0) | (style.overline ? 64 : 0) | (wrapped ? 128 : 0);
            char text[1024];
            GhosttyBuffer buffer{reinterpret_cast<uint8_t*>(text), sizeof(text), 0};
            auto rc = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8, &buffer);
            if (rc == GHOSTTY_OUT_OF_SPACE) { text[0] = '?'; buffer.len = 1; } else check(rc);
            word(result, wide == GHOSTTY_CELL_WIDE_WIDE ? 2 : wide == GHOSTTY_CELL_WIDE_NARROW ? 1 : 0);
            word(result, flags); word(result, color(fg)); word(result, color(bg)); word(result, uint32_t(buffer.len));
            result.insert(result.end(), text, text + buffer.len);
            if (result.size() > 4 * 1024 * 1024) throw std::runtime_error("Render snapshot exceeds limit");
        }
    }
    check(ghostty_render_state_clean(render));
    return result;
}
std::vector<uint8_t> Engine::key(int code, int mods, int action, const std::string& utf8, int consumedMods) {
    if (utf8.size() > 64 || action < 0 || action > 2) throw std::invalid_argument("Invalid key event");
    ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal);
    ghostty_key_event_set_action(keyEvent, GhosttyKeyAction(action));
    ghostty_key_event_set_key(keyEvent, androidKey(code));
    // AltGr's synthetic Ctrl/Alt are layout selectors, not terminal chords.
    // Ghostty's legacy Ctrl path intentionally consults raw modifiers, so
    // normalize these selectors as well as recording consumed modifiers.
    auto effective = mods & ~(consumedMods & (GHOSTTY_MODS_CTRL | GHOSTTY_MODS_ALT));
    ghostty_key_event_set_mods(keyEvent, GhosttyMods(effective));
    ghostty_key_event_set_consumed_mods(keyEvent, GhosttyMods(consumedMods));
    ghostty_key_event_set_utf8(keyEvent, utf8.data(), utf8.size());
    uint32_t unshifted = code >= 29 && code <= 54 ? uint32_t('a' + code - 29) : 0;
    ghostty_key_event_set_unshifted_codepoint(keyEvent, unshifted);
    char bytes[512]; size_t count = 0;
    check(ghostty_key_encoder_encode(keyEncoder, keyEvent, bytes, sizeof(bytes), &count));
    return {bytes, bytes + count};
}
std::vector<uint8_t> Engine::mouse(int action, int button, double x, double y, int mods) {
    if (action < 0 || action > 2 || button < 1 || button > 5) throw std::invalid_argument("Invalid mouse event");
    ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal);
    GhosttyMouseEncoderSize size = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
    size.screen_width = cols * cellWidth; size.screen_height = rows * cellHeight;
    size.cell_width = cellWidth; size.cell_height = cellHeight;
    ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size);
    bool pressed = action != GHOSTTY_MOUSE_ACTION_RELEASE;
    ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed);
    ghostty_mouse_event_set_action(mouseEvent, GhosttyMouseAction(action));
    ghostty_mouse_event_set_button(mouseEvent, GhosttyMouseButton(button));
    ghostty_mouse_event_set_mods(mouseEvent, GhosttyMods(mods));
    GhosttyMousePosition position{float(std::clamp(x, 0.0, double(size.screen_width - 1))), float(std::clamp(y, 0.0, double(size.screen_height - 1)))};
    ghostty_mouse_event_set_position(mouseEvent, position);
    char bytes[128]; size_t count = 0;
    check(ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, bytes, sizeof(bytes), &count));
    return {bytes, bytes + count};
}
