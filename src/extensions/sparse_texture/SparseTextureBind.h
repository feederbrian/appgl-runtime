#pragma once

#include "../../../include/AppGL/glcorearb.h"

namespace appgl {
class ExtensionContext;
}

namespace appgl::extensions::sparse_texture {

bool isTextureParameterPname(GLenum pname);
bool isInternalFormatQueryPname(GLenum pname);
bool shouldSkipDepthImageViewCast(GLenum textureInternalFormat, GLenum imageFormat);

bool handleTextureParameter(ExtensionContext& ctx,
                            GLenum target,
                            GLenum pname,
                            const GLint* params,
                            bool& handled);
bool handleTextureParameterQuery(ExtensionContext& ctx,
                                 GLenum target,
                                 GLenum pname,
                                 GLint* params,
                                 bool& handled);
bool handleInternalFormatQuery(ExtensionContext& ctx,
                               GLenum target,
                               GLenum internalformat,
                               GLenum pname,
                               GLsizei count,
                               GLint* params,
                               bool& handled);

}  // namespace appgl::extensions::sparse_texture
