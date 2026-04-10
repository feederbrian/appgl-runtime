#include "TraceLog.h"

namespace appgl {

void TraceLog::append(std::string message) {
    std::lock_guard lock(mutex_);
    if (entries_.size() == kMaxEntries) {
        entries_.pop_front();
    }
    entries_.push_back(std::move(message));
}

std::vector<std::string> TraceLog::snapshot() const {
    std::lock_guard lock(mutex_);
    return {entries_.begin(), entries_.end()};
}

}  // namespace appgl
