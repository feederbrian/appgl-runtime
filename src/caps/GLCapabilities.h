#pragma once

#include <array>
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

    // Indexed integer queries (glGetIntegeri_v / glGetInteger64i_v). Only a
    // handful of cap enums have per-index semantics — chiefly the compute
    // work-group count/size/invocations tuples where each of x/y/z is
    // reported at index 0/1/2. Scalar query fallback still works if a caller
    // passes one of these via plain glGetIntegerv: queryInteger sees the
    // indexed entry and returns its index-0 value, which matches the Desktop
    // GL convention for compute cap queries via the scalar path.
    bool queryIntegerIndexed(GLenum pname, GLuint index, GLint* out) const;
    bool queryInteger64Indexed(GLenum pname, GLuint index, GLint64* out) const;

    std::optional<GLFormatCapability> format(GLenum internalFormat) const;

    // Returns true if the GL internal format has a Metal mapping registered
    // in the format table. The hardcoded texStorage / texImage validators in
    // GLContext.mm delegate here so that adding a new format to the format
    // table automatically unlocks the texture-allocation path.
    bool isSupportedInternalFormat(GLenum internalFormat) const;

private:
    void initializeFormatTable(void* metalDevice);
    void initializeLimits(void* metalDevice);
    void initializeExtensions();

    // Static scalar cap values keyed by GL enum. Populated once at context
    // creation from the Metal device feature set + AppGL's binding layout.
    std::unordered_map<GLenum, GLint64> integerLimits_;

    // Indexed cap tuples (x/y/z) for the compute work-group family. Stored
    // as 3-element arrays so queryIntegerIndexed and queryInteger64Indexed
    // can reach them with O(1) index math.
    std::unordered_map<GLenum, std::array<GLint64, 3>> indexedIntegerLimits_;

    std::unordered_map<GLenum, GLFormatCapability> formats_;
    std::string extensions_;
};

}  // namespace appgl
