#pragma once

#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>

#include "../../include/AppGL/glcorearb.h"

namespace appgl {

struct GLFormatCapability {
    GLenum internalFormat = 0;
    std::uint64_t metalPixelFormat = 0;
    bool renderable = false;
    bool filterable = false;
    bool blendable = false;
    bool srgbCapable = false;
    bool compressed = false;
};

class GLCapabilities {
public:
    explicit GLCapabilities(void* metalDevice);

    const std::string& extensionString() const;

    bool queryInteger(GLenum pname, GLint* out) const;
    bool queryInteger64(GLenum pname, GLint64* out) const;
    bool queryFloat(GLenum pname, GLfloat* out) const;

    std::optional<GLFormatCapability> format(GLenum internalFormat) const;

private:
    void initializeFormatTable();
    void initializeLimits(void* metalDevice);
    void initializeExtensions();

    std::unordered_map<GLenum, GLFormatCapability> formats_;
    std::unordered_map<GLenum, GLint64> integerLimits_;
    std::string extensions_;
};

}  // namespace appgl
