#include "apple.h"
#include <ghostty/vt.h>
#include <atomic>
#include <cassert>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

namespace {
uint32_t word(const uint8_t* data, size_t& offset, size_t len) {
    assert(offset + 4 <= len);
    uint32_t value = 0;
    for (int i = 0; i < 4; ++i) value |= uint32_t(data[offset++]) << (8 * i);
    return value;
}
void empty(SSAppleBuffer& buffer) { assert(buffer.data == nullptr && buffer.len == 0); }
std::vector<uint8_t> bytes(SSAppleBuffer& buffer) {
    std::vector<uint8_t> result(buffer.data, buffer.data + buffer.len);
    ss_apple_free(&buffer);
    empty(buffer);
    return result;
}
bool frame_has_wide_sheep(const std::vector<uint8_t>& frame) {
    size_t p = 0;
    const uint32_t cols = word(frame.data(), p, frame.size());
    const uint32_t rows = word(frame.data(), p, frame.size());
    for (int i = 0; i < 7; ++i) (void)word(frame.data(), p, frame.size());
    bool sheep = false, continuation = false;
    for (uint64_t i = 0; i < uint64_t(cols) * rows; ++i) {
        const uint32_t width = word(frame.data(), p, frame.size());
        for (int ignored = 0; ignored < 3; ++ignored) (void)word(frame.data(), p, frame.size());
        const uint32_t text_len = word(frame.data(), p, frame.size());
        assert(p + text_len <= frame.size());
        sheep |= width == 2 && text_len == 4 && std::memcmp(frame.data() + p, "\xf0\x9f\x90\x91", 4) == 0;
        continuation |= width == 0;
        p += text_len;
    }
    assert(p == frame.size());
    return sheep && continuation;
}
}

int main() {
    SSAppleTerminal terminal = 99;
    assert(ss_apple_create(0, 24, &terminal) == 2 && terminal == 0);
    assert(ss_apple_create(20, 4, &terminal) == 0 && terminal != 0);

    SSAppleBuffer output{reinterpret_cast<uint8_t*>(1), 1};
    assert(ss_apple_frame(0, &output) == 2); empty(output);
    assert(ss_apple_frame(terminal, nullptr) == 2);
    output = {reinterpret_cast<uint8_t*>(1), 1};
    assert(ss_apple_key(terminal, GHOSTTY_KEY_Q, 0, GHOSTTY_KEY_ACTION_PRESS, nullptr, 1, 0, &output) == 2); empty(output);
    assert(ss_apple_key(terminal, GHOSTTY_KEY_Q, 0, GHOSTTY_KEY_ACTION_PRESS, nullptr, 0, 0, &output) == 0); empty(output);
    assert(ss_apple_write(terminal, nullptr, 1) == 2);
    std::vector<uint8_t> oversized(1024 * 1024 + 1);
    assert(ss_apple_write(terminal, oversized.data(), oversized.size()) == 2);

    const uint8_t unicode[] = "e\xcc\x81\xf0\x9f\x90\x91";
    assert(ss_apple_write(terminal, unicode, sizeof(unicode) - 1) == 0);
    assert(ss_apple_frame(terminal, &output) == 0);
    assert(frame_has_wide_sheep(bytes(output)));

    const uint8_t query[] = "\x1b[6n";
    assert(ss_apple_write(terminal, query, sizeof(query) - 1) == 0);
    assert(ss_apple_replies(terminal, &output) == 0);
    const auto replies = bytes(output);
    assert(replies == std::vector<uint8_t>({'\x1b', '[', '1', ';', '4', 'R'}));

    assert(ss_apple_key(terminal, GHOSTTY_KEY_ARROW_UP, 0, GHOSTTY_KEY_ACTION_PRESS, nullptr, 0, 0, &output) == 0);
    assert(bytes(output) == std::vector<uint8_t>({'\x1b', '[', 'A'})); ss_apple_free(&output);
    assert(ss_apple_semantic_key(terminal, SS_APPLE_KEY_UP, 0, SS_APPLE_KEY_PRESS, nullptr, 0, &output) == 0); ss_apple_free(&output); empty(output);
    const uint8_t text[] = {'q'};
    assert(ss_apple_semantic_key(terminal, SS_APPLE_KEY_TEXT, SS_APPLE_MOD_CONTROL, SS_APPLE_KEY_PRESS, text, 1, &output) == 0); ss_apple_free(&output); empty(output);
    assert(ss_apple_semantic_key(terminal, SS_APPLE_KEY_UP, 0, SS_APPLE_KEY_PRESS, text, 1, &output) == 2); empty(output);
    for (const char* mode : {"\x1b[>1u", "\x1b[>3u", "\x1b[>31u"}) {
        SSAppleTerminal kitty = 0;
        assert(ss_apple_create(80, 24, &kitty) == 0);
        assert(ss_apple_write(kitty, reinterpret_cast<const uint8_t*>(mode), std::strlen(mode)) == 0);
        for (char character : {'c', 'b', 'u', 'w'}) {
            assert(ss_apple_semantic_key(kitty, SS_APPLE_KEY_TEXT, SS_APPLE_MOD_CONTROL, SS_APPLE_KEY_PRESS,
                                         reinterpret_cast<const uint8_t*>(&character), 1, &output) == 0);
            const std::string expected = "\x1b[" + std::to_string(int(character)) + ";5u";
            assert(bytes(output) == std::vector<uint8_t>(expected.begin(), expected.end()));
        }
        assert(ss_apple_destroy(kitty) == 0);
    }
    assert(ss_apple_mouse(terminal, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, 1, 1, 0, &output) == 0);
    empty(output);
    const uint8_t mouse_mode[] = "\x1b[?1000h\x1b[?1006h";
    assert(ss_apple_write(terminal, mouse_mode, sizeof(mouse_mode) - 1) == 0);
    assert(ss_apple_mouse(terminal, GHOSTTY_MOUSE_ACTION_PRESS, GHOSTTY_MOUSE_BUTTON_LEFT, 1, 1, 0, &output) == 0);
    assert(bytes(output) == std::vector<uint8_t>({'\x1b', '[', '<', '0', ';', '2', ';', '2', 'M'}));

    int mode = 7;
    assert(ss_apple_mode(0, 1000, &mode) == 2 && mode == 0);
    assert(ss_apple_mode(terminal, 1000, &mode) == 0 && mode == 1);
    assert(ss_apple_destroy(terminal) == 0);
    output = {reinterpret_cast<uint8_t*>(1), 1};
    assert(ss_apple_replies(terminal, &output) == 2); empty(output);
    assert(ss_apple_destroy(terminal) == 2);

    std::atomic<bool> ok{true};
    std::vector<std::thread> workers;
    for (int worker = 0; worker < 4; ++worker) workers.emplace_back([&] {
        for (int iteration = 0; iteration < 25; ++iteration) {
            SSAppleTerminal handle = 0;
            if (ss_apple_create(8, 3, &handle) != 0) { ok = false; return; }
            const uint8_t text[] = "x";
            SSAppleBuffer snapshot{};
            if (ss_apple_write(handle, text, 1) != 0 || ss_apple_frame(handle, &snapshot) != 0 || snapshot.len == 0 || ss_apple_destroy(handle) != 0) ok = false;
            ss_apple_free(&snapshot);
        }
    });
    for (auto& worker : workers) worker.join();
    assert(ok.load());
    std::cout << "PASS Apple C ABI lifecycle, buffers, Unicode, input, replies, bounds, and concurrency\n";
}
