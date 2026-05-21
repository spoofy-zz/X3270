#include "ScreenBuffer.h"
#include <cstring>
#include <algorithm>

namespace x3270 {

// ── Buffer address code table (RFC 1576 / IBM GA23-0059) ─────────────────────
const uint8_t ScreenBuffer::kCodeTable[64] = {
    0x40,0xC1,0xC2,0xC3,0xC4,0xC5,0xC6,0xC7,
    0xC8,0xC9,0x4A,0x4B,0x4C,0x4D,0x4E,0x4F,
    0x50,0xD1,0xD2,0xD3,0xD4,0xD5,0xD6,0xD7,
    0xD8,0xD9,0x5A,0x5B,0x5C,0x5D,0x5E,0x5F,
    0x60,0x61,0xE2,0xE3,0xE4,0xE5,0xE6,0xE7,
    0xE8,0xE9,0x6A,0x6B,0x6C,0x6D,0x6E,0x6F,
    0xF0,0xF1,0xF2,0xF3,0xF4,0xF5,0xF6,0xF7,
    0xF8,0xF9,0x7A,0x7B,0x7C,0x7D,0x7E,0x7F
};

ScreenBuffer::ScreenBuffer() {
    eraseAll();
}

// ── Buffer operations ─────────────────────────────────────────────────────────
void ScreenBuffer::eraseAll() {
    for (auto& c : cells_) {
        c.ch   = 0x00;
        c.attr = 0x00;
        c.isFA = false;
    }
    cursorPos_   = 0;
    bufPtr_      = 0;
    currentAttr_ = 0x00;
    dirty_       = true;
}

void ScreenBuffer::eraseAllUnprotected() {
    for (int i = 0; i < SIZE; ++i) {
        if (!cells_[i].isFA && !cells_[i].isProtected()) {
            cells_[i].ch = 0x00;
        }
    }
    // Clear MDT on all unprotected field attrs
    for (int i = 0; i < SIZE; ++i) {
        if (cells_[i].isFA && !cells_[i].isProtected()) {
            cells_[i].attr &= ~FA_MDT;
        }
    }
    dirty_ = true;
}

void ScreenBuffer::writeChar(uint8_t ebcdic) {
    cells_[bufPtr_].ch   = ebcdic;
    cells_[bufPtr_].attr = currentAttr_;  // inherit governing field's attribute
    cells_[bufPtr_].isFA = false;
    bufPtr_ = clamp(bufPtr_ + 1);
    dirty_ = true;
}

void ScreenBuffer::startField(uint8_t attrByte) {
    cells_[bufPtr_].ch   = 0x00;
    cells_[bufPtr_].attr = attrByte;
    cells_[bufPtr_].isFA = true;
    currentAttr_ = attrByte;   // subsequent writeChar calls inherit this field's attr
    bufPtr_ = clamp(bufPtr_ + 1);
    dirty_ = true;
}

void ScreenBuffer::repeatToAddress(int destOffset, uint8_t ebcdic) {
    int dest = clamp(destOffset);
    while (bufPtr_ != dest) {
        cells_[bufPtr_].ch   = ebcdic;
        cells_[bufPtr_].attr = currentAttr_;
        cells_[bufPtr_].isFA = false;
        bufPtr_ = clamp(bufPtr_ + 1);
    }
    dirty_ = true;
}

void ScreenBuffer::eraseUnprotectedToAddress(int destOffset) {
    int dest = clamp(destOffset);
    int pos  = bufPtr_;
    while (pos != dest) {
        if (!cells_[pos].isFA && !cells_[pos].isProtected()) {
            cells_[pos].ch = 0x00;
        }
        pos = clamp(pos + 1);
    }
    dirty_ = true;
}

// ── Field attribute resolution ────────────────────────────────────────────────
// Walk backwards from bufPos to find the governing FA cell.
// The cell's .attr field on FA cells holds the raw attribute byte.
// For non-FA cells, we need to look up the nearest preceding FA.
// We also propagate attrs to all cells during this scan.
int ScreenBuffer::findFieldStart(int bufPos) const {
    for (int i = 1; i <= SIZE; ++i) {
        int pos = (bufPos - i + SIZE) % SIZE;
        if (cells_[pos].isFA) return pos;
    }
    return -1; // no FA found (entire screen is unformatted)
}

// ── MDT operations ────────────────────────────────────────────────────────────
void ScreenBuffer::setMDT(int bufferPos) {
    int fa = findFieldStart(bufferPos);
    if (fa >= 0) {
        cells_[fa].attr |= FA_MDT;
    }
}

void ScreenBuffer::resetAllMDT() {
    for (int i = 0; i < SIZE; ++i) {
        if (cells_[i].isFA) {
            cells_[i].attr &= ~FA_MDT;
        }
    }
    dirty_ = true;
}

// ── Read Modified ─────────────────────────────────────────────────────────────
std::vector<ScreenBuffer::ModifiedField> ScreenBuffer::getModifiedFields(bool includeProtected) const {
    std::vector<ModifiedField> result;
    for (int i = 0; i < SIZE; ++i) {
        if (!cells_[i].isFA) continue;
        if (!(cells_[i].attr & FA_MDT)) continue;
        // IBM GA23-0059: Read Modified returns only unprotected (input) fields.
        // Protected fields with MDT set are host-placed data, not user input;
        // sending them causes ISPF screen input error code 23.
        // Read Modified All (includeProtected=true) returns every MDT field.
        if (!includeProtected && (cells_[i].attr & FA_PROTECTED)) continue;
        // Collect data from this FA+1 to next FA
        ModifiedField mf;
        mf.startPos = i;
        mf.attrByte = cells_[i].attr;
        int pos = clamp(i + 1);
        while (pos != i && !cells_[pos].isFA) {
            if (cells_[pos].ch != 0x00) { // strip NUL
                mf.data.push_back(cells_[pos].ch);
            }
            pos = clamp(pos + 1);
        }
        result.push_back(std::move(mf));
    }
    return result;
}

std::vector<uint8_t> ScreenBuffer::buildReadModifiedRecord(int aidByte, bool includeProtected) const {
    std::vector<uint8_t> rec;
    // AID byte
    rec.push_back(static_cast<uint8_t>(aidByte));
    // Cursor address (2 bytes encoded)
    uint8_t cursorAddr[2];
    encodeAddress(cursorPos_, cursorAddr);
    rec.push_back(cursorAddr[0]);
    rec.push_back(cursorAddr[1]);

    // Each modified field: SBA(addr) + data
    auto fields = getModifiedFields(includeProtected);
    // SBA order code
    static constexpr uint8_t SBA_ORDER = 0x11;
    for (const auto& mf : fields) {
        uint8_t addr[2];
        // Data starts at FA+1
        encodeAddress(clamp(mf.startPos + 1), addr);
        rec.push_back(SBA_ORDER);
        rec.push_back(addr[0]);
        rec.push_back(addr[1]);
        for (uint8_t b : mf.data) rec.push_back(b);
    }
    return rec;
}

// ── Address encoding/decoding ─────────────────────────────────────────────────
int ScreenBuffer::decodeAddress(uint8_t b0, uint8_t b1) {
    // Strip top 2 bits and reassemble 12-bit offset
    return ((b0 & 0x3F) << 6) | (b1 & 0x3F);
}

void ScreenBuffer::encodeAddress(int offset, uint8_t out[2]) {
    out[0] = kCodeTable[(offset >> 6) & 0x3F];
    out[1] = kCodeTable[offset & 0x3F];
}

} // namespace x3270
