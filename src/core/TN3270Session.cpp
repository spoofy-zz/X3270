#include "TN3270Session.h"
#include <cstring>
#include <stdexcept>

namespace x3270 {

TN3270Session::TN3270Session() = default;
TN3270Session::~TN3270Session() { disconnect(); }

// ── Public interface ──────────────────────────────────────────────────────────
bool TN3270Session::connect(const std::string& host, uint16_t port,
                             bool useTLS, const std::string& caBundle) {
    state_ = State::Connecting;
    std::string errMsg;
    if (!transport_.connect(host, port, useTLS, caBundle, errMsg)) {
        state_ = State::Disconnected;
        if (errorCb_) errorCb_(errMsg);
        return false;
    }
    state_ = State::NegotiatingTelnet;

    // RFC 2355: offer TN3270E first; server may accept or reject.
    // We also proactively offer the classic options in case server goes
    // straight to the traditional path.
    sendWill(OPT_TN3270E);
    sendDo(OPT_TN3270E);
    sendWill(OPT_TERMINAL_TYPE);
    sendWill(OPT_EOR);
    sendWill(OPT_BINARY);
    sendDo(OPT_BINARY);
    sendDo(OPT_EOR);

    return true;
}

void TN3270Session::disconnect() {
    state_ = State::Disconnected;
    transport_.disconnect();
}

bool TN3270Session::send3270Record(const std::vector<uint8_t>& record) {
    if (state_ != State::Connected) return false;

    std::vector<uint8_t> payload;
    if (tn3270eMode_) {
        // TN3270E: prepend 5-byte header [data-type, request, response, seq_hi, seq_lo]
        uint16_t seq = sendSeqNum_++;
        payload = { DT_3270_DATA, 0x00, 0x00,
                    static_cast<uint8_t>(seq >> 8),
                    static_cast<uint8_t>(seq & 0xFF) };
        payload.insert(payload.end(), record.begin(), record.end());
    } else {
        payload = record;
    }
    auto escaped = escapeRecord(payload);
    return transport_.send(escaped);
}

bool TN3270Session::sendATTN() {
    if (!transport_.isConnected()) return false;
    const std::vector<uint8_t> attn = { IAC, IP };
    return transport_.send(attn);
}

// ── Read loop ─────────────────────────────────────────────────────────────────
void TN3270Session::readLoop() {
    uint8_t buf[4096];
    while (transport_.isConnected()) {
        int n = transport_.recv(buf, sizeof(buf));
        if (n <= 0) break;
        for (int i = 0; i < n; ++i) {
            processByte(buf[i]);
        }
    }
    state_ = State::Disconnected;
    if (errorCb_) errorCb_("Connection closed");
}

// ── Telnet IAC finite state machine ──────────────────────────────────────────
void TN3270Session::processByte(uint8_t byte) {
    switch (telnetState_) {
    case TelnetState::Normal:
        if (byte == IAC) {
            telnetState_ = TelnetState::IacSeen;
        } else {
            // Normal data byte (inside record or NVT)
            currentRecord_.push_back(byte);
        }
        break;

    case TelnetState::IacSeen:
        switch (byte) {
        case IAC:
            // Escaped IAC — literal 0xFF in data stream
            currentRecord_.push_back(0xFF);
            telnetState_ = TelnetState::Normal;
            break;
        case EOR:
            // End of Record — deliver accumulated record
            if (!currentRecord_.empty()) {
                if (dataCb_) dataCb_(currentRecord_);
                currentRecord_.clear();
            }
            telnetState_ = TelnetState::Normal;
            break;
        case WILL: telnetState_ = TelnetState::Will;  break;
        case WONT: telnetState_ = TelnetState::Wont;  break;
        case DO:   telnetState_ = TelnetState::Do;    break;
        case DONT: telnetState_ = TelnetState::Dont;  break;
        case SB:
            subnegBuf_.clear();
            telnetState_ = TelnetState::Sb;
            break;
        case NOP:
            telnetState_ = TelnetState::Normal;
            break;
        default:
            // Ignore other IAC commands
            telnetState_ = TelnetState::Normal;
            break;
        }
        break;

    case TelnetState::Will:
        processIacCommand(WILL, byte);
        telnetState_ = TelnetState::Normal;
        break;
    case TelnetState::Wont:
        processIacCommand(WONT, byte);
        telnetState_ = TelnetState::Normal;
        break;
    case TelnetState::Do:
        processIacCommand(DO, byte);
        telnetState_ = TelnetState::Normal;
        break;
    case TelnetState::Dont:
        processIacCommand(DONT, byte);
        telnetState_ = TelnetState::Normal;
        break;

    case TelnetState::Sb:
        if (byte == IAC) {
            telnetState_ = TelnetState::SbIac;
        } else {
            subnegBuf_.push_back(byte);
        }
        break;
    case TelnetState::SbIac:
        if (byte == SE) {
            processSubneg(subnegBuf_);
            subnegBuf_.clear();
            telnetState_ = TelnetState::Normal;
        } else if (byte == IAC) {
            subnegBuf_.push_back(IAC); // escaped IAC inside SB
            telnetState_ = TelnetState::Sb;
        } else {
            telnetState_ = TelnetState::Sb;
        }
        break;
    }
}

// ── IAC option commands ───────────────────────────────────────────────────────
void TN3270Session::processIacCommand(uint8_t cmd, uint8_t opt) {
    switch (opt) {
    case OPT_BINARY:
        if (cmd == DO)   { doBinary_ = true;  sendWill(OPT_BINARY); }
        else if (cmd == WILL) { willBinary_ = true; sendDo(OPT_BINARY); }
        else if (cmd == DONT) { doBinary_ = false; }
        else if (cmd == WONT) { willBinary_ = false; }
        break;

    case OPT_EOR:
        if (cmd == DO)   { doEOR_ = true;  sendWill(OPT_EOR); }
        else if (cmd == WILL) { willEOR_ = true; sendDo(OPT_EOR); }
        else if (cmd == DONT) { doEOR_ = false; }
        else if (cmd == WONT) { willEOR_ = false; }
        break;

    case OPT_TERMINAL_TYPE:
        if (cmd == DO) {
            doTermType_ = true;
            sendWill(OPT_TERMINAL_TYPE);
        } else if (cmd == WILL) {
            // Server wants to know our type — it will SB TERMINAL-TYPE SEND
            willTermType_ = true;
        }
        break;

    case OPT_TN3270E:
        if (cmd == DO) {
            // Server accepts TN3270E
            tn3270eOffered_ = true;
            sendWill(OPT_TN3270E);
            // Start TN3270E device-type negotiation
            state_ = State::NegotiatingTN3270E;
            // Send DEVICE-TYPE REQUEST
            std::vector<uint8_t> payload = {
                OPT_TN3270E,
                TN3270E_DEVICE_TYPE, TN3270E_REQUEST
            };
            const char* dtype = "IBM-3278-2-E";
            for (const char* p = dtype; *p; ++p)
                payload.push_back(static_cast<uint8_t>(*p));
            sendSb(payload);
        } else if (cmd == WONT || cmd == DONT) {
            // Server rejected TN3270E — fall back to traditional TN3270
            tn3270eOffered_ = false;
            // Traditional path: wait for server to DO TERMINAL-TYPE
        }
        break;

    default:
        // Reject unknown options
        if (cmd == DO)   sendWont(opt);
        if (cmd == WILL) sendDont(opt);
        break;
    }

    // Check if traditional TN3270 negotiation is complete
    if (!tn3270eOffered_ && !tn3270eMode_) {
        if (doBinary_ && willBinary_ && doEOR_ && willEOR_ && doTermType_) {
            enterDataMode();
        }
    }
}

// ── Sub-negotiation ───────────────────────────────────────────────────────────
void TN3270Session::processSubneg(const std::vector<uint8_t>& sb) {
    if (sb.empty()) return;

    uint8_t opt = sb[0];

    if (opt == OPT_TERMINAL_TYPE && sb.size() >= 2 && sb[1] == 0x01 /* SEND */) {
        sendTerminalType();
    } else if (opt == OPT_TN3270E) {
        handleTN3270eSb(sb);
    }
}

void TN3270Session::handleTN3270eSb(const std::vector<uint8_t>& sb) {
    if (sb.size() < 2) return;
    // sb[0] == OPT_TN3270E, sb[1] == function code
    uint8_t func = sb[1];

    if (func == TN3270E_DEVICE_TYPE && sb.size() >= 3) {
        uint8_t sub = sb[2];
        if (sub == TN3270E_IS) {
            // Server confirmed device type — now negotiate functions
            std::vector<uint8_t> payload = {
                OPT_TN3270E,
                TN3270E_FUNCTIONS, TN3270E_REQUEST
                // No special functions for Phase 1
            };
            sendSb(payload);
        } else if (sub == TN3270E_REJECT) {
            // Server rejected our device type — fall back to classic TN3270
            tn3270eOffered_ = false;
            sendWill(OPT_TERMINAL_TYPE);
        }
    } else if (func == TN3270E_FUNCTIONS && sb.size() >= 3) {
        uint8_t sub = sb[2];
        if (sub == TN3270E_IS) {
            // Functions agreed — we are in TN3270E mode
            tn3270eMode_ = true;
            enterDataMode();
        }
    }
}

void TN3270Session::sendTerminalType() {
    // IBM-3278-2-E for extended data stream
    const char* term = "IBM-3278-2-E";
    std::vector<uint8_t> payload = { OPT_TERMINAL_TYPE, 0x00 /* IS */ };
    for (const char* p = term; *p; ++p)
        payload.push_back(static_cast<uint8_t>(*p));
    sendSb(payload);
}

void TN3270Session::enterDataMode() {
    if (state_ == State::Connected) return;
    state_ = State::Connected;
    if (connectedCb_) connectedCb_();
}

// ── Wire helpers ──────────────────────────────────────────────────────────────
void TN3270Session::sendWill(uint8_t opt) {
    sendRaw({ IAC, WILL, opt });
}
void TN3270Session::sendWont(uint8_t opt) {
    sendRaw({ IAC, WONT, opt });
}
void TN3270Session::sendDo(uint8_t opt) {
    sendRaw({ IAC, DO, opt });
}
void TN3270Session::sendDont(uint8_t opt) {
    sendRaw({ IAC, DONT, opt });
}

void TN3270Session::sendSb(const std::vector<uint8_t>& payload) {
    std::vector<uint8_t> msg;
    msg.reserve(payload.size() + 4);
    msg.push_back(IAC);
    msg.push_back(SB);
    for (uint8_t b : payload) {
        if (b == IAC) msg.push_back(IAC); // escape
        msg.push_back(b);
    }
    msg.push_back(IAC);
    msg.push_back(SE);
    sendRaw(msg);
}

void TN3270Session::sendRaw(const std::vector<uint8_t>& data) {
    transport_.send(data);
}

// ── Record encoding ───────────────────────────────────────────────────────────
std::vector<uint8_t> TN3270Session::escapeRecord(const std::vector<uint8_t>& raw) {
    std::vector<uint8_t> out;
    out.reserve(raw.size() + 4);
    for (uint8_t b : raw) {
        out.push_back(b);
        if (b == IAC) out.push_back(IAC); // double 0xFF
    }
    out.push_back(IAC);
    out.push_back(EOR);
    return out;
}

} // namespace x3270
