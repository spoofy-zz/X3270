#include "FileTransfer.h"
#include <algorithm>
#include <cstring>

namespace x3270 {

uint16_t FileTransfer::get16(const uint8_t* p) {
    return (static_cast<uint16_t>(p[0]) << 8) | p[1];
}

void FileTransfer::put16(std::vector<uint8_t>& out, uint16_t value) {
    out.push_back(static_cast<uint8_t>(value >> 8));
    out.push_back(static_cast<uint8_t>(value & 0xFF));
}

void FileTransfer::put32(std::vector<uint8_t>& out, uint32_t value) {
    out.push_back(static_cast<uint8_t>((value >> 24) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 16) & 0xFF));
    out.push_back(static_cast<uint8_t>((value >> 8) & 0xFF));
    out.push_back(static_cast<uint8_t>(value & 0xFF));
}

bool FileTransfer::beginDownload(const std::string& localPath, bool asciiMode, std::string& error) {
    reset();
    out_.open(localPath, std::ios::binary | std::ios::trunc);
    if (!out_) {
        error = "Cannot open local file for writing.";
        return false;
    }
    active_ = true;
    asciiMode_ = asciiMode;
    localPath_ = localPath;
    recordNumber_ = 1;
    bytesTransferred_ = 0;
    if (statusCb_) statusCb_("Waiting for host IND$FILE data...");
    return true;
}

void FileTransfer::cancel() {
    if (active_) {
        sendError(TR_DATA_INSERT);
    }
    complete(false, "Transfer cancelled.");
}

void FileTransfer::reset() {
    if (out_.is_open()) out_.close();
    active_ = false;
    messageStream_ = false;
    asciiMode_ = true;
    recordNumber_ = 1;
    bytesTransferred_ = 0;
    localPath_.clear();
}

bool FileTransfer::processStructuredField(const uint8_t* data, size_t length) {
    if (length < 5 || data[2] != SF_TRANSFER_DATA) return false;

    uint16_t requestType = get16(data + 3);
    switch (requestType) {
    case TR_OPEN_REQ:
        handleOpenRequest(data, length);
        return true;
    case TR_INSERT_REQ:
    case TR_SET_CUR_REQ:
        return true;
    case TR_DATA_INSERT:
        handleDataInsert(data, length);
        return true;
    case TR_CLOSE_REQ:
        sendCloseAck();
        return true;
    case TR_GET_REQ:
        sendError(TR_GET_REQ);
        complete(false, "Upload is not implemented yet.");
        return true;
    default:
        return true;
    }
}

void FileTransfer::sendOpenAck() {
    std::vector<uint8_t> record;
    record.push_back(AID_SF);
    put16(record, 5);
    record.push_back(SF_TRANSFER_DATA);
    put16(record, 9);
    if (sendCb_) sendCb_(record);
}

void FileTransfer::sendDataAck() {
    std::vector<uint8_t> record;
    record.push_back(AID_SF);
    put16(record, 11);
    record.push_back(SF_TRANSFER_DATA);
    put16(record, TR_NORMAL_REPLY);
    put16(record, TR_RECNUM_HDR);
    put32(record, recordNumber_++);
    if (sendCb_) sendCb_(record);
}

void FileTransfer::sendCloseAck() {
    std::vector<uint8_t> record;
    record.push_back(AID_SF);
    put16(record, 5);
    record.push_back(SF_TRANSFER_DATA);
    put16(record, TR_CLOSE_REPLY);
    if (sendCb_) sendCb_(record);
}

void FileTransfer::sendError(uint16_t requestType) {
    std::vector<uint8_t> record;
    record.push_back(AID_SF);
    put16(record, 9);
    record.push_back(SF_TRANSFER_DATA);
    record.push_back(static_cast<uint8_t>(requestType >> 8));
    record.push_back(0x08);
    put16(record, TR_ERROR_HDR);
    put16(record, TR_ERR_CMDFAIL);
    if (sendCb_) sendCb_(record);
}

void FileTransfer::complete(bool ok, const std::string& message) {
    if (out_.is_open()) out_.close();
    active_ = false;
    messageStream_ = false;
    if (completeCb_) completeCb_(ok, message);
}

void FileTransfer::handleOpenRequest(const uint8_t* data, size_t length) {
    std::string name;
    if (length >= 7) {
        for (size_t i = 0; i + 2 < length; ++i) {
            if (data[i] == 'F' && data[i + 1] == 'T' && data[i + 2] == ':') {
                size_t n = std::min<size_t>(7, length - i);
                name.assign(reinterpret_cast<const char*>(data + i), n);
                while (!name.empty() && name.back() == ' ') name.pop_back();
                break;
            }
        }
    }

    messageStream_ = (name == "FT:MSG");
    recordNumber_ = 1;
    sendOpenAck();

    if (!messageStream_ && !active_) {
        sendError(TR_OPEN_REQ);
        complete(false, "Host started IND$FILE data, but no local file is selected.");
    }
}

void FileTransfer::handleDataInsert(const uint8_t* data, size_t length) {
    if (length < 10) {
        sendError(TR_DATA_INSERT);
        complete(false, "Malformed IND$FILE data block.");
        return;
    }

    int dataLength = static_cast<int>(get16(data + 8)) - 5;
    if (dataLength < 0 || static_cast<size_t>(10 + dataLength) > length) {
        sendError(TR_DATA_INSERT);
        complete(false, "Malformed IND$FILE data length.");
        return;
    }

    const uint8_t* payload = data + 10;
    if (messageStream_) {
        sendDataAck();
        std::string msg(reinterpret_cast<const char*>(payload), dataLength);
        size_t dollar = msg.find('$');
        if (dollar != std::string::npos) msg.resize(dollar);
        if (msg.rfind("TRANS03", 0) == 0) {
            complete(true, "Download complete: " + std::to_string(bytesTransferred_) + " bytes.");
        } else if (!msg.empty()) {
            complete(false, msg);
        }
        return;
    }

    if (!active_ || !out_) {
        sendError(TR_DATA_INSERT);
        complete(false, "Local output file is not open.");
        return;
    }

    out_.write(reinterpret_cast<const char*>(payload), dataLength);
    if (!out_) {
        sendError(TR_DATA_INSERT);
        complete(false, "Write failed: " + localPath_);
        return;
    }

    bytesTransferred_ += static_cast<uint64_t>(dataLength);
    if (statusCb_) statusCb_("Downloaded " + std::to_string(bytesTransferred_) + " bytes...");
    sendDataAck();
}

} // namespace x3270
