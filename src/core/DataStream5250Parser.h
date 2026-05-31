#pragma once
#include "ScreenBuffer.h"
#include "EbcdicCodec.h"
#include <cstdint>
#include <vector>
#include <functional>

namespace x3270 {

// ── 5250 Commands (first byte of GDS payload, i.e. after 10-byte GDS header) ─
static constexpr uint8_t CMD5250_WTD              = 0x11; ///< Write To Display
static constexpr uint8_t CMD5250_CLEAR_UNIT        = 0x40; ///< Clear Unit
static constexpr uint8_t CMD5250_CLEAR_UNIT_ALT    = 0x20; ///< Clear Unit Alternate
static constexpr uint8_t CMD5250_WRITE_ERROR_CODE  = 0x21; ///< Write Error Code
static constexpr uint8_t CMD5250_SAVE_SCREEN       = 0x04; ///< Save Screen (0x04 per IBM ref)
static constexpr uint8_t CMD5250_RESTORE_SCREEN    = 0x05; ///< Restore Screen (0x05 per IBM ref)
static constexpr uint8_t CMD5250_READ_FIELDS       = 0x42; ///< Read Input Fields
static constexpr uint8_t CMD5250_READ_MDT          = 0x52; ///< Read MDT Fields
static constexpr uint8_t CMD5250_READ_IMM          = 0x72; ///< Read Immediate
static constexpr uint8_t CMD5250_READ_SCREEN       = 0x62; ///< Read Screen
static constexpr uint8_t CMD5250_QUERY             = 0xF3; ///< Query Device
static constexpr uint8_t CMD5250_ROLL              = 0x23; ///< Roll
static constexpr uint8_t CMD5250_CLEAR_FMT         = 0x50; ///< Clear Format Table

// ── 5250 Orders (appear in WTD data stream) — values from IBM 5250 Data Stream ref
static constexpr uint8_t ORD5250_SOH   = 0x01; ///< Start of Header
static constexpr uint8_t ORD5250_RA    = 0x02; ///< Repeat to Address [row][col][char]
static constexpr uint8_t ORD5250_EA    = 0x03; ///< Erase to Address [row][col]
static constexpr uint8_t ORD5250_TD    = 0x10; ///< Transparent Data [len_hi][len_lo][data…]
static constexpr uint8_t ORD5250_SBA   = 0x11; ///< Set Buffer Address [row][col] 1-indexed
static constexpr uint8_t ORD5250_WEA   = 0x12; ///< Write Extended Attribute
static constexpr uint8_t ORD5250_IC    = 0x13; ///< Insert Cursor
static constexpr uint8_t ORD5250_MC    = 0x14; ///< Move Cursor [row][col]
static constexpr uint8_t ORD5250_WDSF  = 0x15; ///< Write Display Structured Field
static constexpr uint8_t ORD5250_SF    = 0x1D; ///< Start of Field
// Note: 0x20-0x3F are attribute bytes (colour/highlight); handled as data chars

// ── Field Format Word (FFW) — byte 0 (FFW1) bit masks (IBM 5250 ref) ──────────
static constexpr uint8_t FFW1_BYPASS      = 0x20; ///< Protected / bypass field (bit 5)
static constexpr uint8_t FFW1_DUP_ENABLE  = 0x10; ///< Allow dup key (bit 4)
static constexpr uint8_t FFW1_MDT         = 0x08; ///< Modified Data Tag (bit 3)
static constexpr uint8_t FFW1_SHIFT_MASK  = 0x07; ///< Shift type bits (bits 0-2)
static constexpr uint8_t FFW1_SHIFT_ALPHA = 0x00; ///< Alpha/shift
static constexpr uint8_t FFW1_SHIFT_NUM   = 0x01; ///< Numeric only

// ── DataStream5250Parser ──────────────────────────────────────────────────────
class DataStream5250Parser {
public:
    using AlarmCallback  = std::function<void()>;
    using UnlockCallback = std::function<void()>;
    using SendCallback   = std::function<void(const std::vector<uint8_t>&)>;

    DataStream5250Parser(ScreenBuffer& screen);

    void setAlarmCallback(AlarmCallback cb)  { alarmCb_  = std::move(cb); }
    void setUnlockCallback(UnlockCallback cb){ unlockCb_ = std::move(cb); }
    void setSendCallback(SendCallback cb)    { sendCb_   = std::move(cb); }

    /// Process a complete 5250 record from the host.
    /// The caller must strip the Telnet IAC EOR framing.
    /// This method handles GDS header stripping internally.
    void processRecord(const std::vector<uint8_t>& record);

private:
    enum class ParseState {
        Command,
        WCC1,
        WCC2,
        Data,
        SOH_Length,   SOH_Data,
        TD_LenHi,     TD_LenLo,   TD_Data,
        SBA_Row,
        SF_FFW1,      SF_FFW2,    SF_FCW_Hi, SF_FCW_Lo,
        SF_ScreenAttr, SF_LenHi,  SF_LenLo,
        WEA_Skip,
        MC_Row,       MC_Col,
        RA_Row,       RA_Col,     RA_Char,
        EA_Row,       EA_Col,
    };

    ScreenBuffer& screen_;

    AlarmCallback  alarmCb_;
    UnlockCallback unlockCb_;
    SendCallback   sendCb_;

    ParseState state_ { ParseState::Command };

    // Temporaries for multi-byte orders
    uint8_t  sohRemaining_  { 0 };
    uint16_t tdRemaining_   { 0 };
    uint8_t  raRow_         { 0 };
    uint8_t  raCol_         { 0 };

    // Active field attributes (accumulated from FFW)
    uint8_t  currentFFW1_   { 0 };
    uint8_t  currentFFW2_   { 0 };
    uint8_t  currentFgColor_{ 0 };

    void handleCommand(uint8_t cmd);
    void handleDataByte(uint8_t b);

    /// Map 5250 FFW bytes to a 3270-compatible ScreenBuffer attribute byte.
    uint8_t ffw1ToAttr(uint8_t ffw1) const;

    /// Map 5250 color attribute to IBM 3279 palette colour code.
    uint8_t mapColor(uint8_t colorAttr) const;

    /// Decode a 1-indexed 5250 [row][col] pair to a flat buffer offset.
    int rowColToOffset(uint8_t row, uint8_t col) const;
};

} // namespace x3270
