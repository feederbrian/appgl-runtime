// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext debug-label-domain method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_DEBUG_MESSAGES)
void GLContext::setDebugCallback(GLDEBUGPROC callback, const void* userParam) {
    impl_->debugCallback = callback;
    impl_->debugUserParam = userParam;
}

void GLContext::emitDebugMessage(
    GLenum source,
    GLenum type,
    GLuint id,
    GLenum severity,
    std::string_view message
) {
    impl_->enqueueDebugMessage({source, type, id, severity, std::string(message)});
}

void GLContext::setDebugMessageControl(
    GLenum source,
    GLenum type,
    GLenum severity,
    GLsizei count,
    const GLuint* ids,
    GLboolean enabled
) {
    DebugControlRule rule;
    rule.source = source;
    rule.type = type;
    rule.severity = severity;
    rule.enabled = enabled == GL_TRUE;
    rule.hasIds = count > 0;
    for (GLsizei index = 0; index < count; ++index) {
        rule.ids.insert(ids[index]);
    }
    impl_->debugControlRules.push_back(std::move(rule));
}

void GLContext::insertDebugMessage(
    GLenum source,
    GLenum type,
    GLuint id,
    GLenum severity,
    std::string_view message
) {
    emitDebugMessage(source, type, id, severity, message);
}

GLuint GLContext::getDebugMessageLog(
    GLuint count,
    GLsizei bufSize,
    GLenum* sources,
    GLenum* types,
    GLuint* ids,
    GLenum* severities,
    GLsizei* lengths,
    GLchar* messageLog
) {
    if (bufSize < 0) {
        pushError(GL_INVALID_VALUE);
        return 0;
    }

    GLuint delivered = 0;
    GLsizei usedBytes = 0;
    while (delivered < count && !impl_->debugMessages.empty()) {
        const DebugMessageRecord& message = impl_->debugMessages.front();
        const GLsizei requiredBytes = static_cast<GLsizei>(message.message.size() + 1);
        if (messageLog != nullptr && usedBytes + requiredBytes > bufSize) {
            break;
        }

        if (sources != nullptr) {
            sources[delivered] = message.source;
        }
        if (types != nullptr) {
            types[delivered] = message.type;
        }
        if (ids != nullptr) {
            ids[delivered] = message.id;
        }
        if (severities != nullptr) {
            severities[delivered] = message.severity;
        }
        if (lengths != nullptr) {
            lengths[delivered] = requiredBytes;
        }
        if (messageLog != nullptr) {
            std::memcpy(messageLog + usedBytes, message.message.c_str(), static_cast<std::size_t>(requiredBytes));
            usedBytes += requiredBytes;
        }

        impl_->debugMessages.pop_front();
        ++delivered;
    }
    return delivered;
}

void GLContext::pushDebugGroup(GLenum source, GLuint id, std::string_view message) {
    if (impl_->debugGroupStack.size() >= kMaxDebugGroupDepth) {
        pushError(GL_STACK_OVERFLOW);
        return;
    }
    DebugMessageRecord record{source, GL_DEBUG_TYPE_PUSH_GROUP, id, GL_DEBUG_SEVERITY_NOTIFICATION, std::string(message)};
    impl_->debugGroupStack.push_back(record);
    impl_->enqueueDebugMessage(record);
}

bool GLContext::popDebugGroup() {
    if (impl_->debugGroupStack.empty()) {
        pushError(GL_STACK_UNDERFLOW);
        return false;
    }
    DebugMessageRecord record = impl_->debugGroupStack.back();
    impl_->debugGroupStack.pop_back();
    record.type = GL_DEBUG_TYPE_POP_GROUP;
    impl_->enqueueDebugMessage(std::move(record));
    return true;
}

#elif defined(APPGL_GLCONTEXT_DEBUG_LABELS)
void GLContext::setObjectLabel(GLenum identifier, GLuint name, std::string_view label) {
    const std::uint64_t key = objectLabelKey(identifier, name);
    if (label.empty()) {
        impl_->objectLabels.erase(key);
        return;
    }
    impl_->objectLabels[key] = trimDebugMessage(label);
}

void GLContext::getObjectLabel(GLenum identifier, GLuint name, GLsizei bufSize, GLsizei* length, GLchar* label) {
    if (bufSize < 0) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    const auto found = impl_->objectLabels.find(objectLabelKey(identifier, name));
    const std::string_view value = found == impl_->objectLabels.end() ? std::string_view{} : std::string_view(found->second);
    copyLabelString(value, bufSize, length, label);
}

void GLContext::setObjectPtrLabel(const void* ptr, std::string_view label) {
    if (label.empty()) {
        impl_->pointerLabels.erase(ptr);
        return;
    }
    impl_->pointerLabels[ptr] = trimDebugMessage(label);
}

void GLContext::getObjectPtrLabel(const void* ptr, GLsizei bufSize, GLsizei* length, GLchar* label) {
    if (bufSize < 0) {
        pushError(GL_INVALID_VALUE);
        return;
    }
    const auto found = impl_->pointerLabels.find(ptr);
    const std::string_view value = found == impl_->pointerLabels.end() ? std::string_view{} : std::string_view(found->second);
    copyLabelString(value, bufSize, length, label);
}

bool GLContext::getPointer(GLenum pname, void** params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
#ifndef GL_VERTEX_ARRAY_POINTER
#define GL_VERTEX_ARRAY_POINTER 0x808E
#endif
#ifndef GL_COLOR_ARRAY_POINTER
#define GL_COLOR_ARRAY_POINTER 0x8090
#endif
#ifndef GL_TEXTURE_COORD_ARRAY_POINTER
#define GL_TEXTURE_COORD_ARRAY_POINTER 0x8092
#endif
#ifndef GL_SECONDARY_COLOR_ARRAY_POINTER
#define GL_SECONDARY_COLOR_ARRAY_POINTER 0x845D
#endif
    switch (pname) {
        case GL_DEBUG_CALLBACK_FUNCTION:
            *params = reinterpret_cast<void*>(impl_->debugCallback);
            return true;
        case GL_DEBUG_CALLBACK_USER_PARAM:
            *params = const_cast<void*>(impl_->debugUserParam);
            return true;
        case GL_VERTEX_ARRAY_POINTER:
            *params = const_cast<void*>(impl_->legacyVertexArray.pointer);
            return true;
        case GL_COLOR_ARRAY_POINTER:
            *params = const_cast<void*>(impl_->legacyColorArray.pointer);
            return true;
        case GL_TEXTURE_COORD_ARRAY_POINTER:
            return getLegacyTextureCoordArrayPointerIndexed(
                impl_->state->activeTextureUnit(), params);
        case GL_SECONDARY_COLOR_ARRAY_POINTER:
            *params = const_cast<void*>(impl_->legacySecondaryColorArray.pointer);
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

#else
#error "GLContextDebug.inc.mm included without a debug section selector"
#endif
