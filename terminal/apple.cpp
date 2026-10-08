#include "apple.h"
#include "engine.hpp"
#include <algorithm>
#include <cstdlib>
#include <functional>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <unordered_map>
#include <vector>

namespace {
std::mutex mutex;
std::unordered_map<SSAppleTerminal, std::unique_ptr<Engine>> engines;
SSAppleTerminal next_handle = 1;
constexpr size_t input_limit = 1024 * 1024;
int guarded(const std::function<void()>& fn) {
    try { fn(); return 0; } catch (const std::invalid_argument&) { return 2; }
      catch (const std::exception&) { return 3; } catch (...) { return 3; }
}
Engine& get(SSAppleTerminal handle) {
    auto it = engines.find(handle);
    if (it == engines.end()) throw std::invalid_argument("stale terminal handle");
    return *it->second;
}
void clear_buffer(SSAppleBuffer* out) {
    if (out) { out->data = nullptr; out->len = 0; }
}
void set_buffer(SSAppleBuffer* out, std::vector<uint8_t>&& bytes) {
    if (!out) throw std::invalid_argument("missing output buffer");
    clear_buffer(out);
    if (bytes.empty()) return;
    void* memory = std::malloc(bytes.size());
    if (!memory) throw std::runtime_error("buffer allocation failed");
    std::memcpy(memory, bytes.data(), bytes.size());
    out->data = static_cast<uint8_t*>(memory); out->len = bytes.size();
}
bool valid_utf8(const uint8_t* text, size_t length) {
    for (size_t i = 0; i < length;) { uint8_t c = text[i++]; if (c < 0x80) continue;
        int extra = (c >= 0xc2 && c <= 0xdf) ? 1 : (c >= 0xe0 && c <= 0xef) ? 2 : (c >= 0xf0 && c <= 0xf4) ? 3 : -1;
        if (extra < 0 || i + size_t(extra) > length) return false;
        for (int n = 0; n < extra; ++n) if ((text[i++] & 0xc0) != 0x80) return false;
    } return true;
}
GhosttyKey semantic_key(SSAppleKey key) {
    switch (key) { case SS_APPLE_KEY_TEXT: return GHOSTTY_KEY_UNIDENTIFIED; case SS_APPLE_KEY_ESCAPE: return GHOSTTY_KEY_ESCAPE; case SS_APPLE_KEY_TAB: return GHOSTTY_KEY_TAB; case SS_APPLE_KEY_ENTER: return GHOSTTY_KEY_ENTER; case SS_APPLE_KEY_BACKSPACE: return GHOSTTY_KEY_BACKSPACE; case SS_APPLE_KEY_DELETE: return GHOSTTY_KEY_DELETE; case SS_APPLE_KEY_UP: return GHOSTTY_KEY_ARROW_UP; case SS_APPLE_KEY_DOWN: return GHOSTTY_KEY_ARROW_DOWN; case SS_APPLE_KEY_LEFT: return GHOSTTY_KEY_ARROW_LEFT; case SS_APPLE_KEY_RIGHT: return GHOSTTY_KEY_ARROW_RIGHT; case SS_APPLE_KEY_HOME: return GHOSTTY_KEY_HOME; case SS_APPLE_KEY_END: return GHOSTTY_KEY_END; case SS_APPLE_KEY_PAGE_UP: return GHOSTTY_KEY_PAGE_UP; case SS_APPLE_KEY_PAGE_DOWN: return GHOSTTY_KEY_PAGE_DOWN; } throw std::invalid_argument("unsupported semantic key");
}
}

extern "C" int ss_apple_create(uint32_t cols, uint32_t rows, SSAppleTerminal* out) {
    if (!out) return 2;
    *out = 0;
    std::lock_guard lock(mutex);
    return guarded([&] { auto engine = std::make_unique<Engine>(int(cols), int(rows));
        SSAppleTerminal handle = next_handle++; if (handle == 0) throw std::runtime_error("handle exhausted");
        engines.emplace(handle, std::move(engine)); *out = handle; });
}
extern "C" int ss_apple_destroy(SSAppleTerminal handle) {
    std::lock_guard lock(mutex); return guarded([&] { if (!engines.erase(handle)) throw std::invalid_argument("stale terminal handle"); });
}
extern "C" int ss_apple_write(SSAppleTerminal handle, const uint8_t* data, size_t len) {
    if (!data && len) return 2; if (len > input_limit) return 2;
    std::lock_guard lock(mutex); return guarded([&] { get(handle).write(data, len); });
}
extern "C" int ss_apple_resize(SSAppleTerminal handle, uint32_t cols, uint32_t rows, uint32_t width, uint32_t height) {
    std::lock_guard lock(mutex); return guarded([&] { get(handle).resize(int(cols), int(rows), int(width), int(height)); });
}
extern "C" int ss_apple_frame(SSAppleTerminal handle, SSAppleBuffer* out) {
    if (!out) return 2; clear_buffer(out);
    std::lock_guard lock(mutex); return guarded([&] { set_buffer(out, get(handle).frame()); });
}
extern "C" int ss_apple_replies(SSAppleTerminal handle, SSAppleBuffer* out) {
    if (!out) return 2; clear_buffer(out);
    std::lock_guard lock(mutex); return guarded([&] { set_buffer(out, get(handle).takeReplies()); });
}
extern "C" int ss_apple_key(SSAppleTerminal handle, int key, int mods, int action, const uint8_t* utf8, size_t len, int consumed, SSAppleBuffer* out) {
    if (!out) return 2; clear_buffer(out);
    if (!utf8 && len) return 2; if (len > 64) return 2;
    std::lock_guard lock(mutex); return guarded([&] {
        const std::string text = len ? std::string(reinterpret_cast<const char*>(utf8), len) : std::string();
        set_buffer(out, get(handle).platformKey(key, mods, action, text, consumed));
    });
}
extern "C" int ss_apple_semantic_key(SSAppleTerminal handle, SSAppleKey key, int modifiers, SSAppleKeyAction action, const uint8_t* utf8, size_t len, SSAppleBuffer* out) {
    if (!out) return 2; clear_buffer(out);
    constexpr int allowed = SS_APPLE_MOD_SHIFT | SS_APPLE_MOD_CONTROL | SS_APPLE_MOD_OPTION | SS_APPLE_MOD_COMMAND;
    if ((!utf8 && len) || len > 64 || !valid_utf8(utf8, len) || (modifiers & ~allowed) || action < SS_APPLE_KEY_PRESS || action > SS_APPLE_KEY_RELEASE) return 2;
    if (key != SS_APPLE_KEY_TEXT && len != 0) return 2;
    std::lock_guard lock(mutex); return guarded([&] {
        int ghostty_mods = 0;
        if (modifiers & SS_APPLE_MOD_SHIFT) ghostty_mods |= GHOSTTY_MODS_SHIFT;
        if (modifiers & SS_APPLE_MOD_CONTROL) ghostty_mods |= GHOSTTY_MODS_CTRL;
        if (modifiers & SS_APPLE_MOD_OPTION) ghostty_mods |= GHOSTTY_MODS_ALT;
        if (modifiers & SS_APPLE_MOD_COMMAND) ghostty_mods |= GHOSTTY_MODS_SUPER;
        int ghostty_action = action == SS_APPLE_KEY_PRESS ? GHOSTTY_KEY_ACTION_PRESS : action == SS_APPLE_KEY_REPEAT ? GHOSTTY_KEY_ACTION_REPEAT : GHOSTTY_KEY_ACTION_RELEASE;
        const std::string text = len ? std::string(reinterpret_cast<const char*>(utf8), len) : std::string();
        auto physical = semantic_key(key);
        uint32_t unshifted = 0;
        // Kitty keyboard mode needs a key identity, not just UTF-8 text. Without
        // it, Ghostty emits plain "c" for Ctrl-C and plain "b" for Herdr's prefix.
        if (key == SS_APPLE_KEY_TEXT && text.size() == 1) {
            const auto character = static_cast<uint8_t>(text[0]);
            unshifted = character >= 'A' && character <= 'Z' ? character + ('a' - 'A') : character;
            if (unshifted >= 'a' && unshifted <= 'z')
                physical = GhosttyKey(GHOSTTY_KEY_A + unshifted - 'a');
            else if (unshifted >= '0' && unshifted <= '9')
                physical = GhosttyKey(GHOSTTY_KEY_DIGIT_0 + unshifted - '0');
        }
        set_buffer(out, get(handle).platformKey(physical, ghostty_mods, ghostty_action, text, 0, unshifted));
    });
}
extern "C" int ss_apple_mouse(SSAppleTerminal handle, int action, int button, double x, double y, int mods, SSAppleBuffer* out) {
    if (!out) return 2; clear_buffer(out);
    std::lock_guard lock(mutex); return guarded([&] { set_buffer(out, get(handle).mouse(action, button, x, y, mods)); });
}
extern "C" int ss_apple_mode(SSAppleTerminal handle, int number, int* out) {
    if (!out) return 2; *out = 0;
    std::lock_guard lock(mutex); return guarded([&] { *out = get(handle).mode(number) ? 1 : 0; });
}
extern "C" void ss_apple_free(SSAppleBuffer* buffer) {
    if (!buffer) return; std::free(buffer->data); buffer->data = nullptr; buffer->len = 0;
}
