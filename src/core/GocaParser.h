#pragma once
#include "GraphicsBuffer.h"
#include "EbcdicCodec.h"
#include <cstdint>
#include <vector>

namespace x3270 {

// ── GocaParser ────────────────────────────────────────────────────────────────
// Decodes a GOCA (Graphics Object Content Architecture) order stream and
// populates a GraphicsBuffer with typed drawing commands.
//
// GOCA order byte encoding (IBM SC31-6535):
//   Bytes 0x00–0xFE fall into two categories:
//   • Short orders (implied 1-byte param length, table-driven)
//   • Long orders — first byte 0xFF followed by a 2-byte length, then opcode
//
// This parser handles all orders encountered in typical GDDM/CMS applications.
// Unknown orders are skipped safely using the known-length tables below.
//
// Usage:
//   GocaParser p(graphicsBuffer, codec);
//   p.parseOrders(payload, len);  // call once per WSF payload; stateful
//   p.reset();                    // call on Erase/Begin events
class GocaParser {
public:
    GocaParser(GraphicsBuffer& buf, EbcdicCodec& codec);

    /// Feed a GOCA order stream payload.  May be called incrementally across
    /// multiple WSF records; FSM state persists between calls.
    void parseOrders(const uint8_t* data, size_t len);

    /// Reset FSM and clear current position / attribute state.
    void reset();

private:
    // ── Order byte constants (IBM SC31-6535 §5) ───────────────────────────────
    // Short orders (byte 0, implied param length in kShortOrderLen[])
    static constexpr uint8_t ORD_NOP    = 0x00; // No operation
    static constexpr uint8_t ORD_SCOL   = 0x0A; // Set Color (GDDM primary palette byte)
    static constexpr uint8_t ORD_SMIX   = 0x0C; // Set Mix (blend mode)
    static constexpr uint8_t ORD_SBMX   = 0x0D; // Set Background Mix
    static constexpr uint8_t ORD_SLIN   = 0x10; // Set Line Type
    static constexpr uint8_t ORD_SLNW   = 0x11; // Set Line Width
    static constexpr uint8_t ORD_SPAT   = 0x28; // Set Pattern (fill pattern index)
    static constexpr uint8_t ORD_SCPAT  = 0x29; // Set Current Pattern
    static constexpr uint8_t ORD_SFLT   = 0x18; // Set Fractional Line Type
    static constexpr uint8_t ORD_SFLW   = 0x19; // Set Fractional Line Width
    static constexpr uint8_t ORD_SBCOL  = 0x25; // Set Background Color
    static constexpr uint8_t ORD_SCPCOL = 0x26; // Set Current Position Color (alias SCOL)
    static constexpr uint8_t ORD_BSEG   = 0x70; // Begin Segment
    static constexpr uint8_t ORD_ESEG   = 0x71; // End Segment
    static constexpr uint8_t ORD_BPTH   = 0x7C; // Begin Path (treated as begin accumulation)
    static constexpr uint8_t ORD_EPTH   = 0x7D; // End Path

    // Orders with explicit length byte following the opcode:
    static constexpr uint8_t ORD_LNPOS  = 0x21; // Line to given position(s)
    static constexpr uint8_t ORD_LNAT   = 0x22; // Line to (relative) position(s)
    static constexpr uint8_t ORD_CNAT   = 0x23; // Cubic Bezier — skipped
    static constexpr uint8_t ORD_BCHNS  = 0x51; // Begin Chained Segment
    static constexpr uint8_t ORD_CBCHNS = 0x52; // Call Chained Segment
    static constexpr uint8_t ORD_FULLARC= 0x87; // Full Arc (circle/ellipse)
    static constexpr uint8_t ORD_FILRECT= 0xC0; // Filled Rectangle
    static constexpr uint8_t ORD_SPOS   = 0x21; // NOTE: SPOS reuses same byte as LNPOS in some docs
                                                  // — disambiguated by length==0 (no pts = move only)
    // Char string orders with explicit length:
    static constexpr uint8_t ORD_CLCS   = 0x83; // Character String at current position
    static constexpr uint8_t ORD_CGPOS  = 0xC3; // Character String at given position

    // Long-form prefix:
    static constexpr uint8_t ORD_LONG   = 0xFF; // next 2 bytes = length, then opcode

    // ── FSM state ─────────────────────────────────────────────────────────────
    enum class St {
        Order,           // expecting an order byte
        LongLen1,        // long form: expecting length high byte
        LongLen2,        // long form: expecting length low byte
        LongOpcode,      // long form: expecting opcode byte
        Params,          // consuming N param bytes for current order
    };

    // ── Per-order parameter parsing helpers ───────────────────────────────────
    void dispatchOrder(uint8_t opcode, const std::vector<uint8_t>& params);
    void handleLnPos(const std::vector<uint8_t>& p, bool absolute);
    void handleFullArc(const std::vector<uint8_t>& p);
    void handleFilRect(const std::vector<uint8_t>& p);
    void handleCharString(const std::vector<uint8_t>& p, bool withPos);

    // Decode a signed 16-bit big-endian value from two bytes.
    static int16_t be16s(uint8_t hi, uint8_t lo) {
        return static_cast<int16_t>((static_cast<uint16_t>(hi) << 8) | lo);
    }

    // ── State ─────────────────────────────────────────────────────────────────
    GraphicsBuffer& buf_;
    EbcdicCodec&    codec_;

    St       state_       { St::Order };
    uint8_t  curOpcode_   { 0 };
    uint16_t paramLen_    { 0 };    // expected param byte count for current order
    uint16_t longLen_     { 0 };    // long-form total length accumulator
    std::vector<uint8_t> params_;   // accumulated param bytes

    // Current GOCA drawing state (context carried across orders)
    int16_t  curX_  { 0 };
    int16_t  curY_  { 0 };
    uint8_t  curColor_ { 0x00 };    // 0x00 = default (green in IBM 3279)
    uint8_t  curMix_   { 0x02 };    // 0x02 = overpaint

    // Parameter length table for short orders (indexed by opcode byte).
    // -1 = has explicit length byte immediately following the opcode.
    //  0 = opcode-only (no params).
    // Populated in ctor.
    int8_t shortLen_[256] {};
};

} // namespace x3270
