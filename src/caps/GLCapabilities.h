#pragma once

#include <array>
#include <cstdint>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

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

    // The GL_COMPRESSED_TEXTURE_FORMATS enum list. Its length is what
    // GL_NUM_COMPRESSED_TEXTURE_FORMATS reports, so a caller that probed
    // the count has exactly this many slots to fill.
    //
    // Exposed as a container rather than served through queryInteger
    // because queryInteger takes a bare pointer with no length: internal
    // callers reach it with single-element and 4-element scratch buffers,
    // and a variable-length write through that signature is a stack
    // overflow waiting for the list to grow. Only glGetIntegerv and
    // glGetInteger64v hold a buffer the caller sized from the count
    // probe, so only they write the list — via this accessor.
    const std::vector<GLenum>& compressedTextureFormats() const {
        return compressedTextureFormats_;
    }

    std::optional<GLFormatCapability> format(GLenum internalFormat) const;

    // Returns true if the GL internal format has a Metal mapping registered
    // in the format table. The hardcoded texStorage / texImage validators in
    // GLContext.mm delegate here so that adding a new format to the format
    // table automatically unlocks the texture-allocation path.
    bool isSupportedInternalFormat(GLenum internalFormat) const;

    // Sprint 3 [metal-mesh-GS]: device capability for Metal mesh
    // shaders. True when the device supports both
    // `MTLGPUFamilyMetal3` (full mesh shader feature set) and
    // `MTLGPUFamilyApple7` (tier-1 mesh shader). The tier-2 mesh
    // shader path is needed to translate GLSL geometry shaders to
    // Metal's `[[mesh]]` / `[[object]]` stage pair: GS's `EmitVertex`
    // / `EndPrimitive` map to mesh-stage's per-threadgroup primitive
    // emission, and GS's `gl_Layer` maps to
    // `[[render_target_array_index]]` per primitive.
    //
    // M1 Max (validated 2026-04-27): supports both Metal3 and Apple7.
    // Older M1 variants and earlier Apple Silicon report Apple7 = false
    // and route to the CPU GS interpreter fallback.
    bool meshShaderSupported() const { return meshShaderSupported_; }

private:
    void initializeFormatTable(void* metalDevice);
    void initializeLimits(void* metalDevice);

    // Static scalar cap values keyed by GL enum. Populated once at context
    // creation from the Metal device feature set + AppGL's binding layout.
    std::unordered_map<GLenum, GLint64> integerLimits_;

    // Float-valued limits that cannot be represented losslessly in the
    // int64 map (e.g. GL_MIN_FRAGMENT_INTERPOLATION_OFFSET = -0.5f).
    // queryFloat checks this map first before falling through to the
    // integer path.
    std::unordered_map<GLenum, GLfloat> floatLimits_;

    // Indexed cap tuples (x/y/z) for the compute work-group family. Stored
    // as 3-element arrays so queryIntegerIndexed and queryInteger64Indexed
    // can reach them with O(1) index math.
    std::unordered_map<GLenum, std::array<GLint64, 3>> indexedIntegerLimits_;

    std::unordered_map<GLenum, GLFormatCapability> formats_;

    // The enum list published through GL_COMPRESSED_TEXTURE_FORMATS, with
    // its length published through GL_NUM_COMPRESSED_TEXTURE_FORMATS.
    //
    // GL 4.6 §8.5.2 constrains this to formats "suitable for
    // general-purpose usage", explicitly excluding formats "with
    // restrictions that need to be specifically understood prior to use".
    // That is a narrower set than everything the format table can route:
    // it is the advertised menu a naive caller may pick blindly from, not
    // the list of enums glCompressedTexImage2D accepts. Populated in
    // initializeFormatTable so it can be gated on the same device probes
    // as the format entries themselves.
    std::vector<GLenum> compressedTextureFormats_;

    // Sprint 3 [metal-mesh-GS]: cached at format-table init time so
    // link-time GS tier classification doesn't repeat the family probe.
    bool meshShaderSupported_ = false;
};

}  // namespace appgl
