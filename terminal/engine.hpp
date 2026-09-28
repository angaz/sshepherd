#pragma once
#include <ghostty/vt.h>
#include <cstdint>
#include <string>
#include <vector>

// All ownership stays on the calling thread. No Android/JNI dependency here:
// the same core is exercised by Linux tests against the real native library.
class Engine {
public:
    Engine(int cols, int rows);
    ~Engine();
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;
    void write(const uint8_t* bytes, size_t len);
    void resize(int cols, int rows, int cellWidth, int cellHeight);
    std::vector<uint8_t> frame();
    std::vector<uint8_t> takeReplies();
    std::vector<uint8_t> key(int androidCode, int mods, int action, const std::string& utf8, int consumedMods = 0);
    std::vector<uint8_t> mouse(int action, int button, double x, double y, int mods);
    bool mode(int number);
private:
    GhosttyTerminal terminal = nullptr;
    GhosttyRenderState render = nullptr;
    GhosttyRenderStateRowIterator iterator = nullptr;
    GhosttyRenderStateRowCells cells = nullptr;
    GhosttyKeyEncoder keyEncoder = nullptr;
    GhosttyKeyEvent keyEvent = nullptr;
    GhosttyMouseEncoder mouseEncoder = nullptr;
    GhosttyMouseEvent mouseEvent = nullptr;
    int cols, rows, cellWidth = 1, cellHeight = 1;
    std::vector<uint8_t> replies;
    bool replyOverflow = false;
    void cleanup();
    static void writeReply(GhosttyTerminal, void*, const uint8_t*, size_t);
    static bool reportSize(GhosttyTerminal, void*, GhosttySizeReportSize*);
};
