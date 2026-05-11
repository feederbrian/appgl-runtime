#include "SparseTextureBind.h"

#include "../../../include/AppGL/glcorearb.h"

namespace appgl::extensions::sparse_texture {

bool isTextureParameterPname(unsigned int pname) {
    return pname == GL_TEXTURE_SPARSE_ARB ||
           pname == GL_VIRTUAL_PAGE_SIZE_INDEX_ARB ||
           pname == GL_NUM_SPARSE_LEVELS_ARB;
}

bool isInternalFormatQueryPname(unsigned int pname) {
    return pname == GL_NUM_VIRTUAL_PAGE_SIZES_ARB ||
           pname == GL_VIRTUAL_PAGE_SIZE_X_ARB ||
           pname == GL_VIRTUAL_PAGE_SIZE_Y_ARB ||
           pname == GL_VIRTUAL_PAGE_SIZE_Z_ARB;
}

}  // namespace appgl::extensions::sparse_texture

