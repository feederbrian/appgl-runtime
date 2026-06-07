#pragma once

#include <cstdlib>

namespace appgl {

inline bool appglEnvEnabledDefaultOn(const char* name) {
    const char* value = std::getenv(name);
    return value == nullptr || (value[0] != '0' && value[0] != '\0');
}

inline bool appglEnvEnabledDefaultOff(const char* name) {
    const char* value = std::getenv(name);
    return value != nullptr && value[0] != '0' && value[0] != '\0';
}

}  // namespace appgl
