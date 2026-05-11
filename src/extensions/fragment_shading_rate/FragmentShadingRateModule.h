#pragma once

#include "../../../include/AppGL/glcorearb.h"

namespace appgl {
class ExtensionContext;
}

namespace appgl::extensions::fragment_shading_rate {

struct State {
    GLenum rate = GL_SHADING_RATE_1X1_PIXELS_EXT;
    GLenum combinerOp0 = GL_FRAGMENT_SHADING_RATE_COMBINER_OP_KEEP_EXT;
    GLenum combinerOp1 = GL_FRAGMENT_SHADING_RATE_COMBINER_OP_KEEP_EXT;
};

const char* extensionString();
const char* attachmentExtensionString();
bool isAvailable(ExtensionContext& ctx);
void initialize(ExtensionContext& ctx);
void shutdown();
bool isActive();
void destroyContext(ExtensionContext& ctx);

bool isFragmentShadingRateEnum(GLenum rate);
bool isFragmentShadingRateCombinerOp(GLenum op);
bool isTrivialFragmentShadingRateCombinerOp(GLenum op);

State currentState(ExtensionContext& ctx);
GLenum currentDrawRate(ExtensionContext& ctx);
void setDrawRate(ExtensionContext& ctx, GLenum rate);
void setCombinerOps(ExtensionContext& ctx, GLenum combinerOp0, GLenum combinerOp1);
void setFramebufferAttachment(ExtensionContext& ctx,
                              GLuint framebuffer,
                              GLuint texture,
                              GLint baseLayer,
                              GLsizei numLayers,
                              GLsizei texelWidth,
                              GLsizei texelHeight);
void clearFramebufferAttachment(ExtensionContext& ctx, GLuint framebuffer);

bool queryBoolean(ExtensionContext& ctx, GLenum pname, GLboolean* data, bool& handled);
bool queryInteger(ExtensionContext& ctx, GLenum pname, GLint* data, bool& handled);
bool queryInteger64(ExtensionContext& ctx, GLenum pname, GLint64* data, bool& handled);
bool queryFloat(ExtensionContext& ctx, GLenum pname, GLfloat* data, bool& handled);
bool queryDouble(ExtensionContext& ctx, GLenum pname, GLdouble* data, bool& handled);

bool getFragmentShadingRates(ExtensionContext& ctx,
                             GLsizei samples,
                             GLsizei maxCount,
                             GLsizei* count,
                             GLenum* shadingRates);
bool shadingRate(ExtensionContext& ctx, GLenum rate);
bool shadingRateCombinerOps(ExtensionContext& ctx, GLenum combinerOp0, GLenum combinerOp1);
bool framebufferShadingRate(ExtensionContext& ctx,
                            GLenum target,
                            GLenum attachment,
                            GLuint texture,
                            GLint baseLayer,
                            GLsizei numLayers,
                            GLsizei texelWidth,
                            GLsizei texelHeight);

}  // namespace appgl::extensions::fragment_shading_rate
