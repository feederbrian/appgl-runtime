// This file is textually included by GLContextTexture.inc.mm. Do not compile it directly.
// It contains the GLContext texture samplers method definitions split out for navigation only.

#line 7 "src/context/GLContextTexture.inc.mm" // Preserve source identity so this relocation stays codegen-neutral; __FILE__/__LINE__/debug-info intentionally report the original GLContextTexture.inc.mm.
bool GLContext::genSamplers(GLsizei count, GLuint* samplers) {
    if (count < 0 || (count > 0 && samplers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = impl_->objects->samplers().reserveName();
        samplers[index] = name;
        if (GLSamplerObject* object = impl_->objects->samplers().get(name); object != nullptr) {
            object->instantiated = true;
            (void)impl_->rebuildSamplerState(*object);
        }
    }
    return true;
}

bool GLContext::deleteSamplers(GLsizei count, const GLuint* samplers) {
    if (count < 0 || (count > 0 && samplers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = samplers[index];
        if (name == 0) {
            continue;
        }
        if (GLSamplerObject* object = impl_->objects->samplers().get(name); object != nullptr) {
            impl_->releaseSamplerState(*object);
        }
        if (impl_->objects->samplers().erase(name)) {
            impl_->state->deleteSamplerBindings(name);
            impl_->objects->deferDelete("sampler " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isSampler(GLuint sampler) const {
    const GLSamplerObject* object = impl_->objects->samplers().get(sampler);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindSampler(GLuint unit, GLuint sampler) {
    // Must match GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS in GLCapabilities.
    GLint maxUnits = 144;
    if (impl_->capabilities != nullptr) {
        impl_->capabilities->queryInteger(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, &maxUnits);
    }
    if (static_cast<GLint>(unit) >= maxUnits) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (sampler != 0 && !isSampler(sampler)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    impl_->state->bindSampler(unit, sampler);
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::SamplerBind);
    return true;
}

bool GLContext::samplerParameterInteger(GLuint sampler, GLenum pname, const GLint* params) {
    GLSamplerObject* object = impl_->objects->samplers().get(sampler);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!setTextureParameterInteger(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    object->dirty = true;
    if (!impl_->rebuildSamplerState(*object)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::samplerParameterUnsignedInteger(GLuint sampler, GLenum pname, const GLuint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint converted[4] = {
        static_cast<GLint>(params[0]),
        0,
        0,
        0
    };
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        converted[1] = static_cast<GLint>(params[1]);
        converted[2] = static_cast<GLint>(params[2]);
        converted[3] = static_cast<GLint>(params[3]);
    }
    return samplerParameterInteger(sampler, pname, converted);
}

bool GLContext::samplerParameterFloat(GLuint sampler, GLenum pname, const GLfloat* params) {
    GLSamplerObject* object = impl_->objects->samplers().get(sampler);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!setTextureParameterFloat(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    object->dirty = true;
    if (!impl_->rebuildSamplerState(*object)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::getSamplerParameterInteger(GLuint sampler, GLenum pname, GLint* params) {
    const GLSamplerObject* object = impl_->objects->samplers().get(sampler);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!getTextureParameterInteger(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    return true;
}

bool GLContext::getSamplerParameterUnsignedInteger(GLuint sampler, GLenum pname, GLuint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint values[4] = {};
    if (!getSamplerParameterInteger(sampler, pname, values)) {
        return false;
    }
    params[0] = static_cast<GLuint>(values[0]);
    if (pname == GL_TEXTURE_BORDER_COLOR || pname == GL_TEXTURE_SWIZZLE_RGBA) {
        params[1] = static_cast<GLuint>(values[1]);
        params[2] = static_cast<GLuint>(values[2]);
        params[3] = static_cast<GLuint>(values[3]);
    }
    return true;
}

bool GLContext::getSamplerParameterFloat(GLuint sampler, GLenum pname, GLfloat* params) {
    const GLSamplerObject* object = impl_->objects->samplers().get(sampler);
    if (object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (!getTextureParameterFloat(object->params, pname, params)) {
        pushError(params == nullptr ? GL_INVALID_VALUE : GL_INVALID_ENUM);
        return false;
    }
    return true;
}

