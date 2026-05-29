#include "GocaParser.h"
#include <cstring>

namespace x3270 {

// ── Constructor — build the short-order parameter-length table ─────────────────
// GOCA short orders either carry a fixed param count implied by the opcode, or
// carry an explicit length byte directly after the opcode (marked -1 here).
// All unrecognised opcodes default to -1 (explicit length) so the parser can
// skip them safely rather than getting out of sync.
GocaParser::GocaParser(GraphicsBuffer& buf, EbcdicCodec& codec)
    : buf_(buf), codec_(codec)
{
    // Default: treat all opcodes as having an explicit length byte following.
    std::memset(shortLen_, -1, sizeof(shortLen_));

    // Zero-param (opcode only) short orders:
    shortLen_[ORD_NOP]   = 0;
    shortLen_[ORD_ESEG]  = 0;
    shortLen_[ORD_EPTH]  = 0;

    // 1-param short orders:
    shortLen_[ORD_SCOL]  = 1;  // Set Color: 1 palette index byte
    shortLen_[ORD_SMIX]  = 1;  // Set Mix: 1 mode byte
    shortLen_[ORD_SBMX]  = 1;  // Set Background Mix: 1 mode byte
    shortLen_[ORD_SLIN]  = 1;  // Set Line Type: 1 byte
    shortLen_[ORD_SLNW]  = 1;  // Set Line Width: 1 byte
    shortLen_[ORD_SPAT]  = 1;  // Set Pattern: 1 byte
    shortLen_[ORD_SCPAT] = 1;  // Set Current Pattern: 1 byte
    shortLen_[ORD_SFLT]  = 1;
    shortLen_[ORD_SFLW]  = 1;

    // 2-param short orders:
    shortLen_[ORD_SBCOL]  = 2; // Set Background Color: 2 bytes
    shortLen_[ORD_SCPCOL] = 2;

    // 4-byte fixed-param orders (2× int16 position):
    // BSEG — Begin Segment: 2-byte segment ID
    shortLen_[ORD_BSEG]  = 2;

    // BPTH — Begin Path: no params in common use
    shortLen_[ORD_BPTH]  = 0;
}

void GocaParser::reset() {
    state_    = St::Order;
    curX_     = 0;
    curY_     = 0;
    curColor_ = 0x00;
    curMix_   = 0x02;
    params_.clear();
    paramLen_ = 0;
}

// ── Main parse loop ────────────────────────────────────────────────────────────
void GocaParser::parseOrders(const uint8_t* data, size_t len) {
    for (size_t i = 0; i < len; ++i) {
        uint8_t b = data[i];

        switch (state_) {

        case St::Order:
            if (b == ORD_LONG) {
                state_ = St::LongLen1;
                break;
            }
            curOpcode_ = b;
            params_.clear();
            {
                int8_t sl = shortLen_[b];
                if (sl == 0) {
                    // Opcode with no params — dispatch immediately.
                    dispatchOrder(b, {});
                    // state_ stays Order
                } else if (sl > 0) {
                    paramLen_ = static_cast<uint16_t>(sl);
                    state_    = St::Params;
                } else {
                    // sl == -1: next byte is explicit parameter length.
                    // We'll read it in the next byte as part of St::Params setup.
                    // Reuse LongLen1 semantics: read one length byte.
                    state_ = St::LongLen2; // reusing LongLen2 as "short explicit-len byte"
                    longLen_ = 0;
                }
            }
            break;

        case St::LongLen1:
            // Long form — high byte of 2-byte length (includes opcode byte).
            longLen_ = static_cast<uint16_t>(b) << 8;
            state_   = St::LongLen2;
            break;

        case St::LongLen2:
            if (curOpcode_ == ORD_LONG) {
                // True long form: this is low byte of 2-byte length.
                longLen_ |= b;
                state_ = St::LongOpcode;
            } else {
                // Short explicit-length form: this byte IS the param length.
                paramLen_ = b;
                params_.clear();
                if (paramLen_ == 0) {
                    dispatchOrder(curOpcode_, {});
                    state_ = St::Order;
                } else {
                    state_ = St::Params;
                }
            }
            break;

        case St::LongOpcode:
            // Long form: this byte is the actual order opcode; params follow for
            // (longLen_ - 3) bytes (length includes the 2-byte length field + opcode).
            curOpcode_ = b;
            paramLen_  = (longLen_ >= 3) ? static_cast<uint16_t>(longLen_ - 3) : 0;
            params_.clear();
            if (paramLen_ == 0) {
                dispatchOrder(curOpcode_, {});
                state_ = St::Order;
                // Reset long-form tracking
                curOpcode_ = 0;
                longLen_   = 0;
            } else {
                state_ = St::Params;
            }
            break;

        case St::Params:
            params_.push_back(b);
            if (params_.size() >= static_cast<size_t>(paramLen_)) {
                dispatchOrder(curOpcode_, params_);
                params_.clear();
                paramLen_  = 0;
                curOpcode_ = 0;
                longLen_   = 0;
                state_     = St::Order;
            }
            break;
        }
    }
}

// ── Order dispatch ─────────────────────────────────────────────────────────────
void GocaParser::dispatchOrder(uint8_t opcode, const std::vector<uint8_t>& p) {
    switch (opcode) {

    case ORD_NOP:
        break;

    // ── Set Color ─────────────────────────────────────────────────────────────
    // GDDM maps its palette index to IBM 3270 extended colour codes (0xF1–0xF7).
    // A value < 0x10 is a raw GDDM palette index; map it to the 3270 code range.
    case ORD_SCOL:
    case ORD_SCPCOL:
        if (!p.empty()) {
            uint8_t idx = p[0];
            // GDDM colour indices 1–7 map directly to 0xF1–0xF7.
            if (idx >= 1 && idx <= 7)
                curColor_ = static_cast<uint8_t>(0xF0 + idx);
            else
                curColor_ = 0x00; // default (green)
            buf_.addCommand(GocaSetColor{ curColor_ });
        }
        break;

    case ORD_SBCOL:
        // Background colour — not yet rendered, accepted without error.
        break;

    // ── Set Mix ───────────────────────────────────────────────────────────────
    case ORD_SMIX:
    case ORD_SBMX:
        if (!p.empty()) {
            curMix_ = p[0];
            buf_.addCommand(GocaSetMix{ curMix_ });
        }
        break;

    // ── Set Line Width / Type ─────────────────────────────────────────────────
    case ORD_SLIN:
    case ORD_SLNW:
    case ORD_SFLT:
    case ORD_SFLW:
    case ORD_SPAT:
    case ORD_SCPAT:
        // Accepted, not yet mapped to CoreGraphics.
        break;

    // ── Begin / End Segment ───────────────────────────────────────────────────
    case ORD_BSEG:
    case ORD_BCHNS:
    case ORD_CBCHNS: {
        uint16_t segId = (p.size() >= 2)
            ? static_cast<uint16_t>((p[0] << 8) | p[1])
            : 0;
        buf_.addCommand(GocaBeginSegment{ segId });
        break;
    }
    case ORD_ESEG:
        buf_.addCommand(GocaEndSegment{});
        break;

    case ORD_BPTH:
    case ORD_EPTH:
        // Path begin/end — treated as no-ops for now.
        break;

    // ── Line to given position(s) — LNPOS (absolute) / LNAT (relative) ───────
    // ORD_LNPOS == ORD_SPOS byte value (0x21). Disambiguate by param count:
    //   0 params → just a current-position update (SPOS with no coords).
    //   N×4 bytes → N destination pairs, each 2× int16 big-endian.
    case ORD_LNPOS:
        handleLnPos(p, /*absolute=*/true);
        break;

    case ORD_LNAT:
        handleLnPos(p, /*absolute=*/false);
        break;

    case ORD_CNAT:
        // Cubic Bezier — skip (params already consumed).
        break;

    // ── Full Arc (circle) ─────────────────────────────────────────────────────
    case ORD_FULLARC:
        handleFullArc(p);
        break;

    // ── Filled Rectangle ──────────────────────────────────────────────────────
    case ORD_FILRECT:
        handleFilRect(p);
        break;

    // ── Character strings ─────────────────────────────────────────────────────
    case ORD_CLCS:
        // Character string at current position.
        handleCharString(p, /*withPos=*/false);
        break;

    case ORD_CGPOS:
        // Character string at given position.
        handleCharString(p, /*withPos=*/true);
        break;

    default:
        // Unknown order — params already consumed by FSM; safe to ignore.
        break;
    }
}

// ── Line helpers ───────────────────────────────────────────────────────────────
void GocaParser::handleLnPos(const std::vector<uint8_t>& p, bool absolute) {
    if (p.empty()) {
        // Zero params → position-only (Set Current Position equivalent).
        // Nothing to draw.
        return;
    }
    if (p.size() == 4 && !absolute) {
        // Might be SPOS (2 abs coords used as a Move): treat first 4 bytes as
        // an absolute move to (x,y) with no line.  This variant is emitted by
        // some GDDM versions as a position-only order with zero-length line list.
        int16_t nx = be16s(p[0], p[1]);
        int16_t ny = be16s(p[2], p[3]);
        buf_.addCommand(GocaMoveTo{ nx, ny });
        curX_ = nx;
        curY_ = ny;
        return;
    }

    GocaLineTo cmd;
    cmd.absolute = absolute;

    for (size_t i = 0; i + 3 < p.size(); i += 4) {
        int16_t x = be16s(p[i],     p[i + 1]);
        int16_t y = be16s(p[i + 2], p[i + 3]);
        cmd.pts.emplace_back(x, y);
    }

    if (!cmd.pts.empty()) {
        // Implicit MoveTo the first point of a line sequence if no prior position.
        if (cmd.pts.size() == 1 && absolute) {
            // Single destination: a move with no prior context.
            curX_ = cmd.pts[0].first;
            curY_ = cmd.pts[0].second;
            buf_.addCommand(GocaMoveTo{ curX_, curY_ });
        } else {
            // Update current position to last point.
            if (absolute) {
                curX_ = cmd.pts.back().first;
                curY_ = cmd.pts.back().second;
            } else {
                curX_ = static_cast<int16_t>(curX_ + cmd.pts.back().first);
                curY_ = static_cast<int16_t>(curY_ + cmd.pts.back().second);
            }
            buf_.addCommand(std::move(cmd));
        }
    }
}

void GocaParser::handleFullArc(const std::vector<uint8_t>& p) {
    // IBM SC31-6535: FULLARC params — 4-byte center (2× int16), 2-byte radius int16,
    // optional 2-byte multiplier (ignored).
    if (p.size() < 6) return;
    int16_t cx     = be16s(p[0], p[1]);
    int16_t cy     = be16s(p[2], p[3]);
    int16_t radius = be16s(p[4], p[5]);
    buf_.addCommand(GocaArc{ cx, cy, radius });
    curX_ = cx;
    curY_ = cy;
}

void GocaParser::handleFilRect(const std::vector<uint8_t>& p) {
    // FILRECT: 4× int16 (x1,y1,x2,y2) big-endian.
    if (p.size() < 8) return;
    int16_t x1 = be16s(p[0], p[1]);
    int16_t y1 = be16s(p[2], p[3]);
    int16_t x2 = be16s(p[4], p[5]);
    int16_t y2 = be16s(p[6], p[7]);
    buf_.addCommand(GocaFilledRect{ x1, y1, x2, y2 });
    curX_ = x1;
    curY_ = y1;
}

void GocaParser::handleCharString(const std::vector<uint8_t>& p, bool withPos) {
    size_t off = 0;
    int16_t x = curX_, y = curY_;

    if (withPos) {
        // CGPOS: 4-byte position (2× int16) followed by character data.
        if (p.size() < 4) return;
        x   = be16s(p[0], p[1]);
        y   = be16s(p[2], p[3]);
        off = 4;
    }

    // Character data is EBCDIC; convert to UTF-8 via EbcdicCodec.
    std::string utf8;
    for (size_t i = off; i < p.size(); ++i) {
        uint16_t uni = codec_.toUnicode(p[i]);
        if (uni >= 0x20) {
            // Encode unicode codepoint as UTF-8.
            if (uni < 0x80) {
                utf8.push_back(static_cast<char>(uni));
            } else if (uni < 0x800) {
                utf8.push_back(static_cast<char>(0xC0 | (uni >> 6)));
                utf8.push_back(static_cast<char>(0x80 | (uni & 0x3F)));
            } else {
                utf8.push_back(static_cast<char>(0xE0 | (uni >> 12)));
                utf8.push_back(static_cast<char>(0x80 | ((uni >> 6) & 0x3F)));
                utf8.push_back(static_cast<char>(0x80 | (uni & 0x3F)));
            }
        }
    }

    if (!utf8.empty()) {
        buf_.addCommand(GocaCharString{ x, y, std::move(utf8) });
        curX_ = x;
        curY_ = y;
    }
}

} // namespace x3270
