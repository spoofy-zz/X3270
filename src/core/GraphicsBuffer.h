#pragma once
#include <cstdint>
#include <functional>
#include <string>
#include <utility>
#include <variant>
#include <vector>

namespace x3270 {

// ── GOCA Drawing Command types ────────────────────────────────────────────────
// Each struct maps one GOCA drawing order to a typed, host-independent value.
// Coordinates are in GOCA device units (cell-based: 1 unit = 1/9 char width,
// 1/12 char height, matching the AW/AH values in the Usable Area Query Reply).

struct GocaMoveTo {
    int16_t x, y;                                 // absolute position
};

struct GocaLineTo {
    std::vector<std::pair<int16_t, int16_t>> pts; // destination points
    bool absolute;                                 // true=LNPOS, false=LNAT (relative)
};

struct GocaArc {
    int16_t cx, cy;                               // center
    int16_t radius;
};

struct GocaFilledRect {
    int16_t x1, y1, x2, y2;
};

struct GocaSetColor {
    uint8_t index;   // IBM 3270 extended colour code (0xF1–0xF7) or 0x00 = default
};

struct GocaSetMix {
    uint8_t mode;    // 0x02 = overpaint (default); 0x04 = XOR
};

struct GocaCharString {
    int16_t x, y;
    std::string text; // already converted to UTF-8 by GocaParser
};

struct GocaBeginSegment {
    uint16_t id;
};

struct GocaEndSegment {};

// Discriminated union of all supported drawing commands.
using GocaCommand = std::variant<
    GocaMoveTo,
    GocaLineTo,
    GocaArc,
    GocaFilledRect,
    GocaSetColor,
    GocaSetMix,
    GocaCharString,
    GocaBeginSegment,
    GocaEndSegment
>;

// ── GraphicsBuffer ────────────────────────────────────────────────────────────
// Holds the ordered list of GOCA drawing commands for the current screen frame.
// Thread-safety note: GocaParser writes from the network thread; TerminalView
// reads from the main thread.  The caller (TerminalWindowController) must not
// mix reads and writes concurrently.  In practice, TerminalView reads only
// during drawRect: which is serialized with the update callback dispatch via
// the main queue — exactly the same model used by ScreenBuffer.
class GraphicsBuffer {
public:
    using UpdateCallback = std::function<void()>;

    GraphicsBuffer() = default;

    // ── Write side (called from GocaParser / DataStreamParser) ───────────────

    /// Discard all drawing commands and reset state (Erase/Begin events).
    void clear();

    /// Append a decoded drawing command.
    void addCommand(GocaCommand cmd);

    /// Signal that the current batch is complete — fires the update callback.
    void markDirty();

    // ── Read side (called from TerminalView on main thread) ──────────────────

    const std::vector<GocaCommand>& commands() const { return commands_; }
    bool dirty()     const { return dirty_; }
    void clearDirty()      { dirty_ = false; }

    // ── Wiring ────────────────────────────────────────────────────────────────
    void setUpdateCallback(UpdateCallback cb) { updateCb_ = std::move(cb); }

private:
    std::vector<GocaCommand> commands_;
    bool                     dirty_    { false };
    UpdateCallback           updateCb_;
};

} // namespace x3270
