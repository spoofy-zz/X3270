#pragma once
#include <cstdint>
#include <vector>
#include <functional>

namespace x3270 {

// ── Field Attribute byte bit layout ──────────────────────────────────────────
// Bit 2: Protected  (1=output only, 0=input)
// Bit 3: Numeric    (1=numeric only; bits 2+3 both 1 → Skip)
// Bits 4-5: Display (00=normal, 01=normal+LP, 10=intensified, 11=non-display)
// Bit 7: MDT        (Modified Data Tag — set when user edits the field)
static constexpr uint8_t FA_PROTECTED   = 0x20;
static constexpr uint8_t FA_NUMERIC     = 0x10;
static constexpr uint8_t FA_DISP_NORMAL = 0x00;
static constexpr uint8_t FA_DISP_LP     = 0x08;  // normal + light-pen detect
static constexpr uint8_t FA_INTENSIFIED = 0x08;  // (bits 4-5 = 10) = 0x08 in 6-bit mapping
static constexpr uint8_t FA_NONDISPLAY  = 0x0C;
static constexpr uint8_t FA_MDT        = 0x01;

// ── Cell ─────────────────────────────────────────────────────────────────────
struct Cell {
    uint8_t  ch   { 0x00 }; // EBCDIC character byte (0x00 = empty/null)
    uint8_t  attr { 0x00 }; // Field attribute byte of the governing field
    bool     isFA { false }; // true if this cell IS a field attribute position

    bool isProtected()  const { return (attr & FA_PROTECTED) != 0; }
    bool isNumeric()    const { return (attr & FA_NUMERIC)   != 0; }
    bool isSkip()       const { return (attr & (FA_PROTECTED|FA_NUMERIC)) == (FA_PROTECTED|FA_NUMERIC); }
    bool isNonDisplay() const { return (attr & 0x0C) == FA_NONDISPLAY; }
    bool isIntensified()const { return (attr & 0x0C) == 0x08; }
    bool isMDT()        const { return (attr & FA_MDT) != 0; }
};

// ── ScreenBuffer ──────────────────────────────────────────────────────────────
class ScreenBuffer {
public:
    static constexpr int ROWS = 24;
    static constexpr int COLS = 80;
    static constexpr int SIZE = ROWS * COLS; // 1920

    ScreenBuffer();

    // ── Buffer access ─────────────────────────────────────────────────────────
    Cell&       at(int offset)       { return cells_[offset]; }
    const Cell& at(int offset) const { return cells_[offset]; }
    Cell&       at(int row, int col) { return cells_[row * COLS + col]; }

    int   cursorPos()  const { return cursorPos_; }
    void  setCursor(int pos) { cursorPos_ = clamp(pos); }

    // ── Screen operations (called by DataStreamParser) ────────────────────────

    /// Erase entire buffer and reset all fields (used by Erase/Write)
    void eraseAll();

    /// Erase all unprotected fields (Erase All Unprotected command)
    void eraseAllUnprotected();

    /// Write a character at bufferPointer_, then advance it
    void writeChar(uint8_t ebcdic);

    /// Start a new field at bufferPointer_ with given attribute byte
    void startField(uint8_t attrByte);

    /// Set buffer pointer (SetBufferAddress order)
    void setBufferAddress(int offset) { bufPtr_ = clamp(offset); }
    int  bufferPointer() const        { return bufPtr_; }

    /// Repeat character from current pointer to destOffset
    void repeatToAddress(int destOffset, uint8_t ebcdic);

    /// Erase unprotected characters from current pointer to destOffset
    void eraseUnprotectedToAddress(int destOffset);

    /// Insert cursor marker at current bufferPointer_
    void insertCursorHere() { cursorPos_ = bufPtr_; }

    // ── Read Modified (build client→host AID data) ────────────────────────────
    struct ModifiedField {
        int              startPos;
        uint8_t          attrByte;
        std::vector<uint8_t> data; // EBCDIC bytes (NUL stripped)
    };
    std::vector<ModifiedField> getModifiedFields() const;

    /// Build Read Modified data: SBA(cursor) + {SBA(field)+data} for each MDT field
    std::vector<uint8_t> buildReadModifiedRecord(int aidByte) const;

    /// Clear MDT bit on all unprotected fields
    void resetAllMDT();

    /// Set MDT on the field that owns the given buffer position
    void setMDT(int bufferPos);

    // ── 3270 Buffer Address encoding/decoding ────────────────────────────────
    static int  decodeAddress(uint8_t b0, uint8_t b1);
    static void encodeAddress(int offset, uint8_t out[2]);

    // ── Dirty tracking (for UI redraws) ──────────────────────────────────────
    bool isDirty() const  { return dirty_; }
    void clearDirty()     { dirty_ = false; }
    void markDirty()      { dirty_ = true; }

private:
    static int clamp(int pos) {
        if (pos < 0) pos = (pos % SIZE + SIZE) % SIZE;
        return pos % SIZE;
    }

    /// Find the field attribute cell that governs bufPos
    int findFieldStart(int bufPos) const;

    Cell    cells_[SIZE] {};
    int     cursorPos_     { 0 };
    int     bufPtr_        { 0 };
    bool    dirty_         { false };
    uint8_t currentAttr_   { 0x00 };  // attr of the most-recently opened field

    // Buffer address decode table (64 entries, 6-bit index → 8-bit wire byte)
    static const uint8_t kCodeTable[64];
};

} // namespace x3270
