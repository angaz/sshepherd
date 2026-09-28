#include "engine.hpp"
#include <cassert>
#include <iostream>
#include <stdexcept>

struct Cell { uint32_t width, flags, fg, bg; std::string text; };
struct Frame { uint32_t cols, rows, x, y; std::vector<Cell> cells; };
uint32_t read(const std::vector<uint8_t>& bytes, size_t& offset) {
    assert(offset + 4 <= bytes.size());
    uint32_t value = 0;
    for (int i = 0; i < 4; ++i) value |= uint32_t(bytes[offset++]) << (i * 8);
    return value;
}
Frame frame(Engine& engine) {
    auto bytes = engine.frame(); size_t p = 0;
    Frame result{};
    result.cols = read(bytes, p); result.rows = read(bytes, p);
    result.x = read(bytes, p); result.y = read(bytes, p);
    for (int i = 0; i < 5; ++i) read(bytes, p);
    for (size_t i = 0; i < result.cols * result.rows; ++i) {
        Cell cell{}; cell.width = read(bytes, p); cell.flags = read(bytes, p);
        cell.fg = read(bytes, p); cell.bg = read(bytes, p);
        auto len = read(bytes, p); assert(p + len <= bytes.size());
        cell.text.assign(bytes.begin() + p, bytes.begin() + p + len); p += len;
        result.cells.push_back(cell);
    }
    assert(p == bytes.size()); return result;
}
void write(Engine& engine, const std::string& text) { engine.write(reinterpret_cast<const uint8_t*>(text.data()), text.size()); }
std::string string(const std::vector<uint8_t>& bytes) { return {bytes.begin(), bytes.end()}; }
int main() {
    {
        Engine engine(80, 24);
        write(engine, "hello\x1b[1;38;2;12;34;56;48;2;65;43;21mX\x1b[0m");
        auto f = frame(engine);
        assert(f.cols == 80 && f.rows == 24 && f.x == 6);
        assert(f.cells[0].text == "h" && f.cells[0].fg == 0xffe6edf3 && f.cells[0].bg == 0xff10141c);
        assert(f.cells[5].fg == 0xff0c2238 && f.cells[5].bg == 0xff412b15 && (f.cells[5].flags & 1));
        write(engine, "\x1b[?1049h\x1b[HALT");
        assert(frame(engine).cells[0].text == "A");
        write(engine, "\x1b[?1049l");
        assert(frame(engine).cells[0].text == "h");
        engine.resize(42, 15, 9, 18);
        f = frame(engine); assert(f.cols == 42 && f.rows == 15);
        std::cout << "PASS colors, attributes, alternate screen, resize\n";
    }
    {
        Engine engine(20, 4);
        std::string text = "e\xcc\x81\xf0\x9f\x90\x91"; // combining acute + sheep
        for (auto c : text) engine.write(reinterpret_cast<const uint8_t*>(&c), 1);
        auto f = frame(engine);
        assert(f.cells[0].text == "e\xcc\x81");
        assert(f.cells[1].text == "\xf0\x9f\x90\x91" && f.cells[1].width == 2 && f.cells[2].width == 0);
        std::cout << "PASS fragmented UTF-8, graphemes, wide glyphs\n";
    }
    {
        Engine engine(80, 24); engine.resize(80, 24, 9, 18);
        write(engine, "abc\x1b[6n\x1b[c\x1b[18t");
        auto replies = string(engine.takeReplies());
        assert(replies.find("\x1b[1;4R") != std::string::npos);
        assert(replies.find("\x1b[?62;22c") != std::string::npos);
        assert(replies.find("\x1b[8;24;80t") != std::string::npos);
        assert(engine.takeReplies().empty());
        assert(string(engine.key(31, 2, 1, "c")) == "\x03");
        assert(string(engine.key(45, 6, 1, "@", 6)) == "@"); // layout-consumed Ctrl+AltGr
        assert(string(engine.key(45, 4, 1, "q", 0)) == "\x1bq"); // terminal Alt
        assert(string(engine.key(19, 0, 1, "")) == "\x1b[A");
        write(engine, "\x1b[?1h");
        assert(string(engine.key(19, 0, 1, "")) == "\x1bOA");
        assert(engine.key(19, 0, 0, "").empty());
        assert(engine.mouse(0, 1, 0, 0, 0).empty());
        write(engine, "\x1b[?1000h\x1b[?1006h\x1b[?2004h");
        assert(engine.mode(2004));
        assert(string(engine.mouse(0, 1, 20, 40, 0)) == "\x1b[<0;3;3M");
        assert(string(engine.mouse(1, 1, 20, 40, 0)) == "\x1b[<0;3;3m");
        std::cout << "PASS PTY replies, key modes, Ctrl+C, mouse press/release, bracketed paste\n";
    }
    {
        bool rejected = false;
        try { Engine engine(0, 24); } catch (const std::invalid_argument&) { rejected = true; }
        assert(rejected);
        Engine engine(40, 12);
        std::vector<uint8_t> noise(32000);
        uint32_t state = 42;
        for (auto& byte : noise) { state = state * 1664525 + 1013904223; byte = uint8_t(state >> 24); }
        engine.write(noise.data(), noise.size());
        assert(frame(engine).cells.size() == 480);
        std::cout << "PASS bounds and malformed stream resilience\n";
    }
}
