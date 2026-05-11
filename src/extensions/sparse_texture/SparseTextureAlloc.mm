#include "SparseTextureAlloc.h"

#include "../../../include/AppGL/glcorearb.h"

namespace appgl::extensions::sparse_texture {

bool isAllocationTarget(unsigned int target) {
    switch (target) {
        case GL_TEXTURE_2D:
        case GL_TEXTURE_2D_ARRAY:
        case GL_TEXTURE_CUBE_MAP:
        case GL_TEXTURE_CUBE_MAP_ARRAY:
        case GL_TEXTURE_3D:
        case GL_TEXTURE_RECTANGLE:
            return true;
        default:
            return false;
    }
}

}  // namespace appgl::extensions::sparse_texture

