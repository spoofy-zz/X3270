#include "GraphicsBuffer.h"

namespace x3270 {

void GraphicsBuffer::clear() {
    commands_.clear();
    dirty_ = false;
}

void GraphicsBuffer::addCommand(GocaCommand cmd) {
    commands_.push_back(std::move(cmd));
}

void GraphicsBuffer::markDirty() {
    dirty_ = true;
    if (updateCb_) updateCb_();
}

} // namespace x3270
