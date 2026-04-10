#pragma once

#include <deque>
#include <mutex>
#include <string>
#include <vector>

namespace appgl {

class TraceLog {
public:
    void append(std::string message);
    std::vector<std::string> snapshot() const;

private:
    static constexpr std::size_t kMaxEntries = 64;

    mutable std::mutex mutex_;
    std::deque<std::string> entries_;
};

}  // namespace appgl
