#pragma once
#include <cstdint>
#include <functional>
#include <fstream>
#include <string>
#include <vector>

namespace x3270 {

class FileTransfer {
public:
    enum class Direction { Download, Upload };

    using SendRecordCallback = std::function<bool(const std::vector<uint8_t>&)>;
    using StatusCallback = std::function<void(const std::string&)>;
    using CompleteCallback = std::function<void(bool ok, const std::string& message)>;

    void setSendCallback(SendRecordCallback cb) { sendCb_ = std::move(cb); }
    void setStatusCallback(StatusCallback cb) { statusCb_ = std::move(cb); }
    void setCompleteCallback(CompleteCallback cb) { completeCb_ = std::move(cb); }

    bool beginDownload(const std::string& localPath, bool asciiMode, std::string& error);
    void cancel();
    bool active() const { return active_; }

    bool processStructuredField(const uint8_t* data, size_t length);

private:
    static constexpr uint8_t AID_SF = 0x88;
    static constexpr uint8_t SF_TRANSFER_DATA = 0xD0;

    static constexpr uint16_t TR_OPEN_REQ = 0x0012;
    static constexpr uint16_t TR_CLOSE_REQ = 0x4112;
    static constexpr uint16_t TR_SET_CUR_REQ = 0x4511;
    static constexpr uint16_t TR_GET_REQ = 0x4611;
    static constexpr uint16_t TR_INSERT_REQ = 0x4711;
    static constexpr uint16_t TR_DATA_INSERT = 0x4704;
    static constexpr uint16_t TR_NORMAL_REPLY = 0x4705;
    static constexpr uint16_t TR_CLOSE_REPLY = 0x4109;
    static constexpr uint16_t TR_RECNUM_HDR = 0x6306;
    static constexpr uint16_t TR_ERROR_HDR = 0x6904;
    static constexpr uint16_t TR_ERR_CMDFAIL = 0x0100;

    static uint16_t get16(const uint8_t* p);
    static void put16(std::vector<uint8_t>& out, uint16_t value);
    static void put32(std::vector<uint8_t>& out, uint32_t value);

    void reset();
    void sendOpenAck();
    void sendDataAck();
    void sendCloseAck();
    void sendError(uint16_t requestType);
    void complete(bool ok, const std::string& message);
    void handleOpenRequest(const uint8_t* data, size_t length);
    void handleDataInsert(const uint8_t* data, size_t length);

    bool active_ { false };
    bool messageStream_ { false };
    bool asciiMode_ { true };
    uint32_t recordNumber_ { 1 };
    uint64_t bytesTransferred_ { 0 };
    std::string localPath_;
    std::ofstream out_;

    SendRecordCallback sendCb_;
    StatusCallback statusCb_;
    CompleteCallback completeCb_;
};

} // namespace x3270
