#include "DataStream5250Parser.h"
#include <algorithm>

namespace x3270 {

DataStream5250Parser::DataStream5250Parser(ScreenBuffer& screen)
    : screen_(screen) {}

// ── Public entry point ────────────────────────────────────────────────────────

void DataStream5250Parser::processRecord(const std::vector<uint8_t>& record) {
    if (record.empty()) return;

    const uint8_t* data = record.data();
    size_t         len  = record.size();

    // Reset FSM for each new record; may be adjusted by opcode below.
    state_ = ParseState::Command;
    sohRemaining_ = 0;
    tdRemaining_  = 0;

    // Detect and strip GDS header.
    // Java-confirmed format (XI5250Emulator.receivedEOR):
    //   [0-1] = total len (big-endian)
    //   [2]   = 0x12
    //   [3]   = 0xA0
    //   [4-5] = 0x00 0x00 (reserved)
    //   [6]   = varHdrLen (typically 0x04)
    //   [7]   = flags
    //   [8]   = 0x00
    //   [9]   = opcode  (OUTPUT_ONLY=0x02, PUT_GET=0x03, etc.)
    //   [10+] = 5250 data payload (first byte = 5250 command, e.g. WTD=0x11)
    // Total header = 6 + varHdrLen bytes (= 10 when varHdrLen=4).
    if (len >= 10) {
        uint16_t encoded = (static_cast<uint16_t>(data[0]) << 8) | data[1];
        if (data[2] == 0x12 && data[3] == 0xA0 &&
            encoded == static_cast<uint16_t>(len))
        {
            uint8_t varHdrLen = data[6];
            size_t  hdrLen    = 6 + static_cast<size_t>(varHdrLen);
            if (len <= hdrLen) return; // header only, no payload
            data += hdrLen;
            len  -= hdrLen;
            // Payload first byte is the 5250 command byte — leave state_=Command
            // so handleCommand() processes it normally.
        }
    }

    for (size_t i = 0; i < len; ++i) {
        uint8_t b = data[i];
        switch (state_) {
        case ParseState::Command:
            handleCommand(b);
            break;
        case ParseState::WCC1:
            // WCC1: bit 7 = lock keyboard, bit 2 = reset MDT
            state_ = ParseState::WCC2;
            break;
        case ParseState::WCC2:
            if (b & 0x80) {
                // Alarm bit in WCC2 bit 7 (some implementations)
                if (alarmCb_) alarmCb_();
            }
            // After WCC bytes, signal unlock and enter data stream
            if (unlockCb_) unlockCb_();
            state_ = ParseState::Data;
            break;
        case ParseState::Data:
            handleDataByte(b);
            break;

        case ParseState::SOH_Length:
            sohRemaining_ = b;  // number of bytes to skip
            state_ = (b > 0) ? ParseState::SOH_Data : ParseState::Data;
            break;
        case ParseState::SOH_Data:
            if (--sohRemaining_ == 0) state_ = ParseState::Data;
            break;

        case ParseState::TD_LenHi:
            tdRemaining_ = static_cast<uint16_t>(b) << 8;
            state_ = ParseState::TD_LenLo;
            break;
        case ParseState::TD_LenLo:
            tdRemaining_ |= b;
            state_ = (tdRemaining_ > 0) ? ParseState::TD_Data : ParseState::Data;
            break;
        case ParseState::TD_Data:
            screen_.writeChar(b);
            if (--tdRemaining_ == 0) state_ = ParseState::Data;
            break;

        case ParseState::SBA_Row: {
            uint8_t row = b;
            // Peek at next byte for col
            if (i + 1 < len) {
                uint8_t col = data[++i];
                int offset = rowColToOffset(row, col);
                if (offset >= 0) screen_.setBufferAddress(offset);
            }
            state_ = ParseState::Data;
            break;
        }

        case ParseState::SF_FFW1:
            currentFFW1_ = b;
            state_ = ParseState::SF_FFW2;
            break;
        case ParseState::SF_FFW2:
            currentFFW2_ = b;
            // After FFW2, check if FCW pair follows (FCW[0] has 0x80 marker).
            // We peek ahead: if next byte has (byte & 0xC0)==0x80, it's FCW.
            // For simplicity, use bit 0 of FFW2 as FCW-present indicator per IBM ref.
            if (currentFFW2_ & 0x01) {
                state_ = ParseState::SF_FCW_Hi;
            } else {
                state_ = ParseState::SF_ScreenAttr;
            }
            break;
        case ParseState::SF_FCW_Hi:
            state_ = ParseState::SF_FCW_Lo;
            break;
        case ParseState::SF_FCW_Lo:
            state_ = ParseState::SF_ScreenAttr;
            break;
        case ParseState::SF_ScreenAttr:
            // Screen attribute byte — consumed, colour applied later
            state_ = ParseState::SF_LenHi;
            break;
        case ParseState::SF_LenHi:
            // High byte of field length — stash for future use
            state_ = ParseState::SF_LenLo;
            break;
        case ParseState::SF_LenLo: {
            // Low byte of field length. Now emit the field into ScreenBuffer.
            uint8_t attr = ffw1ToAttr(currentFFW1_);
            screen_.startField(attr, 0x00, 0x00, 0x00);
            if (currentFFW1_ & FFW1_MDT) {
                int bp = screen_.bufferPointer();
                int fa = (bp > 0) ? bp - 1 : 0;
                screen_.at(fa).attr |= 0x01; // FA_MDT
            }
            state_ = ParseState::Data;
            break;
        }

        case ParseState::RA_Row:
            raRow_ = b;
            state_ = ParseState::RA_Col;
            break;
        case ParseState::RA_Col:
            raCol_ = b;
            state_ = ParseState::RA_Char;
            break;
        case ParseState::RA_Char: {
            int dest = rowColToOffset(raRow_, raCol_);
            if (dest >= 0) screen_.repeatToAddress(dest, b);
            state_ = ParseState::Data;
            break;
        }

        case ParseState::EA_Row:
            raRow_ = b;
            state_ = ParseState::EA_Col;
            break;
        case ParseState::EA_Col: {
            int dest = rowColToOffset(raRow_, b);
            if (dest >= 0) screen_.eraseUnprotectedToAddress(dest);
            state_ = ParseState::Data;
            break;
        }

        case ParseState::WEA_Skip:
            // WEA has 2 bytes following (type + value); consume both by
            // re-using sohRemaining_ as a 2-byte counter.
            // On entry, sohRemaining_ is pre-set to 1 by handleDataByte (below).
            if (--sohRemaining_ == 0) state_ = ParseState::Data;
            break;

        case ParseState::MC_Row:
            raRow_ = b;
            state_ = ParseState::MC_Col;
            break;
        case ParseState::MC_Col: {
            int dest = rowColToOffset(raRow_, b);
            if (dest >= 0) screen_.setBufferAddress(dest);
            state_ = ParseState::Data;
            break;
        }
        }
    }
}

// ── Command dispatch ──────────────────────────────────────────────────────────

void DataStream5250Parser::handleCommand(uint8_t cmd) {
    switch (cmd) {
    case CMD5250_WTD:
        state_ = ParseState::WCC1;
        break;

    case CMD5250_CLEAR_UNIT:
    case CMD5250_CLEAR_UNIT_ALT:
        screen_.eraseAll();
        if (unlockCb_) unlockCb_();
        state_ = ParseState::Command; // no further data expected
        break;

    case CMD5250_WRITE_ERROR_CODE:
        // Phase 1: ignore — host is sending an error indicator
        // (typically followed by a subsequent WTD to redraw the screen)
        state_ = ParseState::Command;
        break;

    case CMD5250_SAVE_SCREEN:
    case CMD5250_RESTORE_SCREEN:
        // Phase 1: not supported — treat as no-op
        state_ = ParseState::Command;
        break;

    default:
        // Unknown command: skip
        state_ = ParseState::Command;
        break;
    }
}

// ── Order dispatch inside WTD data stream ────────────────────────────────────

void DataStream5250Parser::handleDataByte(uint8_t b) {
    // Order bytes 0x01-0x1F per IBM 5250 Data Stream Programmer's Reference.
    // Bytes 0x20-0x3F are colour/attribute bytes (treated as data chars).
    // Bytes 0x40+ are displayable EBCDIC.
    switch (b) {
    case ORD5250_SOH:
        state_ = ParseState::SOH_Length;
        break;
    case ORD5250_RA:
        state_ = ParseState::RA_Row;
        break;
    case ORD5250_EA:
        state_ = ParseState::EA_Row;
        break;
    case ORD5250_TD:
        state_ = ParseState::TD_LenHi;
        break;
    case ORD5250_SBA:
        state_ = ParseState::SBA_Row;
        break;
    case ORD5250_WEA:
        // Write Extended Attribute: 2 bytes follow (type + value), skip them
        sohRemaining_ = 2;
        state_ = ParseState::WEA_Skip;
        break;
    case ORD5250_IC:
        screen_.insertCursorHere();
        // state_ stays Data
        break;
    case ORD5250_MC:
        state_ = ParseState::MC_Row;
        break;
    case ORD5250_WDSF:
        // Write Display Structured Field: length-prefixed block (like SOH)
        state_ = ParseState::SOH_Length;
        break;
    case ORD5250_SF:
        state_ = ParseState::SF_FFW1;
        break;
    default:
        if (b >= 0x40) {
            // Normal EBCDIC display character
            screen_.writeChar(b);
        } else if (b >= 0x20) {
            // Colour/attribute byte in range 0x20-0x3F.
            // These are 5250 attribute characters that occupy a buffer position.
            // For now write them as the attribute byte (renderer will color-map).
            screen_.writeChar(b);
        }
        // else: unrecognised control byte < 0x20 — skip silently
        break;
    }
}

// ── Attribute mapping ─────────────────────────────────────────────────────────

uint8_t DataStream5250Parser::ffw1ToAttr(uint8_t ffw1) const {
    uint8_t attr = 0x00;

    // Protected / bypass field
    if (ffw1 & FFW1_BYPASS) {
        attr |= FA_PROTECTED | FA_NUMERIC; // bypass = protected skip field
    } else if (ffw1 & FFW1_SHIFT_NUM) {
        attr |= FA_NUMERIC;
    }

    // MDT
    if (ffw1 & FFW1_MDT) {
        attr |= FA_MDT;
    }

    return attr;
}

uint8_t DataStream5250Parser::mapColor(uint8_t c3) const {
    // 5250 colour nibble (3 bits) → IBM 3279 palette code
    // AS/400 colour table per IBM 5250 Data Stream Programmer's Reference:
    // 0=Green, 1=Green/Reverse, 2=White, 3=White/Reverse,
    // 4=Green/Underline, 5=Green/Reverse/Underline, 6=NonDisplay, 7=NonDisplay
    static constexpr uint8_t kColorMap[8] = {
        0xF4, // 0 → Green
        0xF4, // 1 → Green (reverse handled via highlight)
        0xF7, // 2 → White
        0xF7, // 3 → White (reverse)
        0xF4, // 4 → Green (underline)
        0xF4, // 5 → Green (reverse+underline)
        0x00, // 6 → NonDisplay
        0x00, // 7 → NonDisplay
    };
    return kColorMap[c3 & 0x07];
}

int DataStream5250Parser::rowColToOffset(uint8_t row, uint8_t col) const {
    // 5250 addresses are 1-indexed.  Row 0 or col 0 means "no change" (keep current).
    if (row == 0 || col == 0) return -1;
    int r = static_cast<int>(row) - 1;
    int c = static_cast<int>(col) - 1;
    if (r >= screen_.rows() || c >= screen_.cols()) return -1;
    return r * screen_.cols() + c;
}

} // namespace x3270
