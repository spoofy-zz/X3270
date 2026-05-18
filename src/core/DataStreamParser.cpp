#include "DataStreamParser.h"
#include <cstring>

namespace x3270 {

DataStreamParser::DataStreamParser(ScreenBuffer& screen, EbcdicCodec& codec)
    : screen_(screen), codec_(codec) {}

// ── Main entry point ──────────────────────────────────────────────────────────
void DataStreamParser::processRecord(const std::vector<uint8_t>& record) {
    if (record.empty()) return;

    // WSF records are handled separately (need full record to parse SFs)
    if (record[0] == CMD_WRITE_STRUCTURED_FIELD ||
        record[0] == CMD_WRITE_STRUCTURED_FIELD_SNA) {
        handleWSF(record);
        return;
    }

    // Reset FSM for each new record
    state_ = ParseState::Command;

    for (uint8_t b : record) {
        if (state_ == ParseState::SkipRecord) break;  // discard rest of WSF/unknown record
        switch (state_) {
        case ParseState::Command:
            handleCommand(b);
            break;
        case ParseState::WCC:
            handleWCC(b);
            break;
        case ParseState::Data:
            handleDataByte(b);
            break;
        case ParseState::SF_Attr:
            screen_.startField(b);
            state_ = ParseState::Data;
            break;
        case ParseState::SBA_Byte1:
            sbaByte1_ = b;
            state_ = ParseState::SBA_Byte2;
            break;
        case ParseState::SBA_Byte2:
            screen_.setBufferAddress(ScreenBuffer::decodeAddress(sbaByte1_, b));
            state_ = ParseState::Data;
            break;
        case ParseState::RA_Addr1:
            raAddr1_ = b;
            state_ = ParseState::RA_Addr2;
            break;
        case ParseState::RA_Addr2:
            sbaByte1_ = b; // reuse to store addr2
            state_ = ParseState::RA_Char;
            break;
        case ParseState::RA_Char:
            screen_.repeatToAddress(ScreenBuffer::decodeAddress(raAddr1_, sbaByte1_), b);
            state_ = ParseState::Data;
            break;
        case ParseState::EUA_Addr1:
            euaAddr1_ = b;
            state_ = ParseState::EUA_Addr2;
            break;
        case ParseState::EUA_Addr2:
            screen_.eraseUnprotectedToAddress(ScreenBuffer::decodeAddress(euaAddr1_, b));
            state_ = ParseState::Data;
            break;
        case ParseState::SFE_Count:
            sfeCount_ = b;
            sfeCurAttr_ = 0x00;
            if (sfeCount_ == 0) {
                screen_.startField(0x00);
                state_ = ParseState::Data;
            } else {
                state_ = ParseState::SFE_Type;
            }
            break;
        case ParseState::SFE_Type:
            sfeType_ = b;
            state_ = ParseState::SFE_Value;
            break;
        case ParseState::SFE_Value:
            // Type 0xC0 = field attribute (basic)
            if (sfeType_ == 0xC0) sfeCurAttr_ = b;
            --sfeCount_;
            if (sfeCount_ == 0) {
                screen_.startField(sfeCurAttr_);
                state_ = ParseState::Data;
            } else {
                state_ = ParseState::SFE_Type;
            }
            break;
        case ParseState::SA_Type:
            sfeType_ = b;
            state_ = ParseState::SA_Value;
            break;
        case ParseState::SA_Value:
            // Phase 1: ignore extended attributes (color, highlight)
            state_ = ParseState::Data;
            break;
        case ParseState::MF_Count:
            mfCount_ = b;
            if (mfCount_ == 0) state_ = ParseState::Data;
            else                state_ = ParseState::MF_Type;
            break;
        case ParseState::MF_Type:
            mfType_ = b;
            state_ = ParseState::MF_Value;
            break;
        case ParseState::MF_Value:
            // Phase 1: ignore MF (used to change attrs without rewriting field)
            --mfCount_;
            state_ = (mfCount_ > 0) ? ParseState::MF_Type : ParseState::Data;
            break;
        case ParseState::GE_Char:
            // Graphic Escape: display character from alternate code page
            // Phase 1: treat as normal EBCDIC character
            screen_.writeChar(b);
            state_ = ParseState::Data;
            break;
        case ParseState::SkipRecord:
            break; // unreachable — caught by early-exit before the switch
        }
    }
}

// ── Command dispatch ──────────────────────────────────────────────────────────
void DataStreamParser::handleCommand(uint8_t cmd) {
    switch (cmd) {
    case CMD_WRITE:
    case CMD_WRITE_SNA:
        doWrite(false, false);
        break;
    case CMD_ERASE_WRITE:
    case CMD_ERASE_WRITE_SNA:
        doWrite(true, false);
        break;
    case CMD_ERASE_WRITE_ALT:
    case CMD_ERASE_WRITE_ALT_SNA:
        doWrite(true, true);  // alternate size (Phase 1: same as default)
        break;
    case CMD_ERASE_ALL_UNPROTECTED:
    case CMD_ERASE_ALL_UNPROTECTED_SNA:
        screen_.eraseAllUnprotected();
        state_ = ParseState::Command; // no further data
        break;
    case CMD_READ_MODIFIED:
    case CMD_READ_MODIFIED_SNA:
    case CMD_READ_MODIFIED_ALL:
    case CMD_READ_MODIFIED_ALL_SNA:
        // Host requested data — respond (normally triggered by AID, but host
        // can also poll). We send an empty Read Modified response.
        if (sendCb_) {
            auto data = screen_.buildReadModifiedRecord(0x60 /*no-AID*/);
            sendCb_(data);
        }
        state_ = ParseState::Command;
        break;
    case CMD_WRITE_STRUCTURED_FIELD:
    case CMD_WRITE_STRUCTURED_FIELD_SNA:
        // Handled in processRecord before the FSM — should not reach here
        state_ = ParseState::SkipRecord;
        break;
    default:
        // Unknown command — skip to Data state
        state_ = ParseState::Data;
        break;
    }
}

void DataStreamParser::doWrite(bool eraseFirst, bool /*alternate*/) {
    if (eraseFirst) {
        screen_.eraseAll();          // also resets bufPtr_ and currentAttr_
    } else {
        screen_.setBufferAddress(0); // Write always restarts at buffer address 0
    }
    state_ = ParseState::WCC;
}

// ── Write Control Character ───────────────────────────────────────────────────
void DataStreamParser::handleWCC(uint8_t wcc) {
    if (wcc & WCC_RESET_MDT) screen_.resetAllMDT();
    if (wcc & WCC_ALARM)     { if (alarmCb_) alarmCb_(); }
    if (wcc & WCC_UNLOCK)    { if (unlockCb_) unlockCb_(); }
    state_ = ParseState::Data;
}

// ── Data / Order byte dispatch ────────────────────────────────────────────────
void DataStreamParser::handleDataByte(uint8_t b) {
    // Check if this byte is an order code
    switch (b) {
    case ORD_SF:   state_ = ParseState::SF_Attr;  break;
    case ORD_SFE:  state_ = ParseState::SFE_Count; break;
    case ORD_SBA:  state_ = ParseState::SBA_Byte1; break;
    case ORD_SA:   state_ = ParseState::SA_Type;   break;
    case ORD_IC:   screen_.insertCursorHere();     break; // IC: no params
    case ORD_PT:
        // Program Tab: advance bufPtr to next unprotected field
        // Phase 1 simplified: advance one cell at a time until FA that is not protected
        {
            int pos = screen_.bufferPointer();
            for (int i = 0; i < ScreenBuffer::SIZE; ++i) {
                pos = (pos + 1) % ScreenBuffer::SIZE;
                if (screen_.at(pos).isFA && !screen_.at(pos).isProtected()) {
                    screen_.setBufferAddress((pos + 1) % ScreenBuffer::SIZE);
                    break;
                }
            }
        }
        break;
    case ORD_RA:   state_ = ParseState::RA_Addr1;  break;
    case ORD_EUA:  state_ = ParseState::EUA_Addr1; break;
    case ORD_GE:   state_ = ParseState::GE_Char;   break;
    case ORD_MF:   state_ = ParseState::MF_Count;  break;
    default:
        // Plain data byte — write to buffer
        screen_.writeChar(b);
        break;
    }
}

// ── Write Structured Field ────────────────────────────────────────────────────
// Parse each SF in the record.  Respond to Read Partition Query with a minimal
// IBM-3278-2 Query Reply so ISPF can identify the terminal and paint its menu.
void DataStreamParser::handleWSF(const std::vector<uint8_t>& record) {
    size_t i = 1; // skip WSF command byte
    while (i + 2 < record.size()) {
        // Each SF: [length_hi][length_lo][type][data...]
        // Length field includes itself (min 3 bytes)
        uint16_t sfLen = (static_cast<uint16_t>(record[i]) << 8) | record[i + 1];
        if (sfLen < 3 || i + sfLen > record.size()) break;

        uint8_t sfType = record[i + 2];

        if (sfType == 0x01 && sfLen >= 5) {
            // Read Partition: [partition_id (1 byte)][query_type (1 byte)]
            // uint8_t partition = record[i + 3]; // 0xFF = all
            uint8_t queryType = record[i + 4];
            // 0x02 = Query, 0x03 = QueryList — both require a Query Reply
            if ((queryType == 0x02 || queryType == 0x03) && sendCb_) {
                sendCb_(buildQueryReply());
            }
        }
        i += sfLen;
    }
}

// ── Query Reply builder ───────────────────────────────────────────────────────
// Returns a minimal IBM-3278-2 (24×80) Query Reply:
//   AID 0x88 + Query Reply (Summary) + Query Reply (Usable Area)
// This satisfies ISPF's terminal identification before painting its menu.
std::vector<uint8_t> DataStreamParser::buildQueryReply() {
    std::vector<uint8_t> r;

    // AID byte: Query Reply
    r.push_back(0x88);

    // ── Query Reply (Summary) ────────────────────────────────────────────────
    // Lists all QR types being sent so the host knows what to expect.
    // Length=6: includes itself (2) + type (1) + two type codes (2) = 5 ... wait
    // Actually: length counts itself → 2 (len) + 1 (type=0x81) + N type bytes
    // Here N=1 (just Usable Area = 0x80)
    r.push_back(0x00); r.push_back(0x05); // length = 5
    r.push_back(0x81);                    // type: Query Reply (Summary)
    r.push_back(0x80);                    // list: Usable Area
    r.push_back(0x81);                    // list: Summary itself (required)

    // ── Query Reply (Usable Area) ────────────────────────────────────────────
    // 2 (len) + 1 (type) + 1 (flags) + 1 (flags2) + 2 (cols) + 2 (rows)
    // + 1 (unit) + 2 (Xr) + 2 (Yr) + 1 (AW) + 1 (AH) + 2 (bufsz) = 18 bytes
    r.push_back(0x00); r.push_back(0x12); // length = 18
    r.push_back(0x80);                    // type: Usable Area
    r.push_back(0x01);                    // 12-bit buffer addressing
    r.push_back(0x00);                    // flags
    r.push_back(0x00); r.push_back(0x50); // usable cols = 80
    r.push_back(0x00); r.push_back(0x18); // usable rows = 24
    r.push_back(0x01);                    // measurement unit: cells
    r.push_back(0x00); r.push_back(0x09); // cell X size
    r.push_back(0x00); r.push_back(0x0C); // cell Y size
    r.push_back(0x09);                    // AW (character cell X)
    r.push_back(0x0C);                    // AH (character cell Y)
    r.push_back(0x07); r.push_back(0x80); // buffer size = 1920 (24×80)

    return r;
}

} // namespace x3270
