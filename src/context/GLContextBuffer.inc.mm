// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext buffer-domain method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_BUFFER_CORE_A)
bool GLContext::genBuffers(GLsizei count, GLuint* buffers) {
    if (count < 0 || (count > 0 && buffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        buffers[index] = impl_->objects->buffers().reserveName();
    }
    return true;
}

bool GLContext::deleteBuffers(GLsizei count, const GLuint* buffers) {
    if (count < 0 || (count > 0 && buffers == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // S25 Rung 1.5 note: deletion stays UNCONDITIONAL — it frees the CPU
    // shadow and drops the runtime's Metal retain (storage-replacement
    // class; narrowing it needs the Rung-2 record-payload retain design).
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = buffers[index];
        if (name == 0) {
            continue;
        }
        if (GLBufferObject* object = impl_->objects->buffers().get(name); object != nullptr) {
            impl_->releaseBufferStorage(*object);
        }
        if (impl_->objects->buffers().erase(name)) {
            impl_->state->deleteBufferBindings(name);
            impl_->deleteBufferReferencesFromVertexArrays(name);
            impl_->objects->deferDelete("buffer " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isBuffer(GLuint buffer) const {
    const GLBufferObject* object = impl_->objects->buffers().get(buffer);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindBuffer(GLenum target, GLuint buffer) {
    if (buffer == 0) {
        impl_->state->bindBuffer(target, 0);
        if (target == GL_ELEMENT_ARRAY_BUFFER) {
            GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
            if (vertexArray == nullptr && appglCompatProfileEnabled()) {
                vertexArray = impl_->currentVertexArrayOrDefault();
            }
            if (vertexArray != nullptr) {
                vertexArray->elementArrayBuffer = 0;
            }
        }
        impl_->touchR5Residency(MetalR5ResidencyTouchKind::BufferBind);
        return true;
    }
    GLBufferObject* object = impl_->objects->buffers().get(buffer);
    if (object == nullptr) {
        if (!appglCompatProfileEnabled()) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        object = impl_->objects->buffers().insertAt(buffer);
        if (object == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    object->instantiated = true;
    impl_->state->bindBuffer(target, buffer);
    if (target == GL_ELEMENT_ARRAY_BUFFER) {
        GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
        if (vertexArray == nullptr && appglCompatProfileEnabled()) {
            vertexArray = impl_->currentVertexArrayOrDefault();
        }
        if (vertexArray != nullptr) {
            vertexArray->elementArrayBuffer = buffer;
        }
    }
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::BufferBind);
    return true;
}

bool GLContext::bindBufferRange(GLenum target, GLuint index, GLuint buffer, GLintptr offset, GLsizeiptr size) {
    // GL 4.6 §6.1.1 validation order — the offset/size/alignment
    // checks apply regardless of whether `buffer == 0`. CTS
    // `shader_storage_buffer_object.negative-api-bind` plants
    // `glBindBufferRange(GL_SHADER_STORAGE_BUFFER, 0, 0, 31, 0)`
    // with offset=31 against OFFSET_ALIGNMENT=32 and expects
    // INVALID_VALUE; previously we short-circuited the buffer==0
    // case to "success" and skipped the alignment check.
    if (offset < 0 || size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    {
        GLint64 alignment = 1;
        auto queryAlignment = [this](GLenum pname) -> GLint64 {
            GLint64 v = 1;
            if (impl_->capabilities != nullptr) {
                impl_->capabilities->queryInteger64(pname, &v);
            }
            return v;
        };
        switch (target) {
            case GL_UNIFORM_BUFFER:
                alignment = queryAlignment(GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT);
                break;
            case GL_SHADER_STORAGE_BUFFER:
                alignment = queryAlignment(GL_SHADER_STORAGE_BUFFER_OFFSET_ALIGNMENT);
                break;
            case GL_ATOMIC_COUNTER_BUFFER:
            case GL_TRANSFORM_FEEDBACK_BUFFER:
                alignment = 4;
                break;
            default:
                break;
        }
        if (alignment > 1 && (offset % alignment) != 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        // XFB: size must also be a multiple of 4.
        if (target == GL_TRANSFORM_FEEDBACK_BUFFER && (size % 4) != 0) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    auto recordTfBinding = [&](GLuint boundBuffer,
                               GLintptr boundOffset,
                               GLsizeiptr boundSize) {
        if (target == GL_TRANSFORM_FEEDBACK_BUFFER &&
            index < GLTransformFeedbackObject::kMaxTfBuffers &&
            impl_->boundTransformFeedbackId != 0) {
            if (auto* tf = impl_->objects->transformFeedbacks().get(
                    impl_->boundTransformFeedbackId)) {
                tf->bufferBindings[index] = {boundBuffer, boundOffset, boundSize};
            }
        }
    };
    if (buffer == 0) {
        impl_->state->bindIndexedBuffer(target, index, 0, 0, 0);
        recordTfBinding(0, 0, 0);
        // Spec: bind* with buffer == 0 also resets the generic target binding.
        impl_->state->bindBuffer(target, 0);
        impl_->touchR5Residency(MetalR5ResidencyTouchKind::BufferBind);
        return true;
    }
    GLBufferObject* object = impl_->objects->buffers().get(buffer);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    object->instantiated = true;
    impl_->state->bindIndexedBuffer(target, index, buffer, offset, size);
    recordTfBinding(buffer, offset, size);
    // Spec (4.6 §6.1.1): BindBufferRange additionally binds buffer to the generic
    // buffer binding point specified by target. Without this the generic UBO/SSBO
    // bindings would silently desync from the indexed table after a per-index bind.
    impl_->state->bindBuffer(target, buffer);
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::BufferBind);
    return true;
}

bool GLContext::bindBufferOffset(GLenum target, GLuint index, GLuint buffer, GLintptr offset) {
    if (offset < 0 || (target == GL_TRANSFORM_FEEDBACK_BUFFER && (offset % 4) != 0)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (buffer == 0) {
        return bindBufferRange(target, index, 0, 0, 0);
    }
    auto* object = impl_->objects->buffers().get(buffer);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset > object->size) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    object->instantiated = true;
    // Preserve the live-size sentinel used by BindBufferBase. EXT offset
    // bindings are offset-to-end, so a later BufferData resize must update
    // the effective capacity instead of retaining the bind-time size.
    impl_->state->bindIndexedBuffer(target, index, buffer, offset, 0);
    if (target == GL_TRANSFORM_FEEDBACK_BUFFER &&
        index < GLTransformFeedbackObject::kMaxTfBuffers &&
        impl_->boundTransformFeedbackId != 0) {
        if (auto* tf = impl_->objects->transformFeedbacks().get(
                impl_->boundTransformFeedbackId)) {
            tf->bufferBindings[index] = {buffer, offset, 0};
        }
    }
    impl_->state->bindBuffer(target, buffer);
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::BufferBind);
    return true;
}

bool GLContext::bindBufferBase(GLenum target, GLuint index, GLuint buffer) {
    if (buffer != 0) {
        GLBufferObject* object = impl_->objects->buffers().get(buffer);
        if (object == nullptr) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        object->instantiated = true;
    }
    // GL 4.6 §6.1.1: bindBufferBase = bindBufferRange with offset=0
    // and size = sizeof(buffer). The buffer size is resolved at
    // draw time, not bind time — otherwise a subsequent bufferData
    // resize leaves the binding reporting a stale length. Sentinel
    // value 0 means "whole buffer, live size"; consumers
    // (writeTessTFAndUpdateCounters, primFits, …) already fall back
    // to the live `GLBufferObject::shadowBytes.size()` when
    // rangeSize==0.
    impl_->state->bindIndexedBuffer(target, index, buffer, 0, 0);
    if (target == GL_TRANSFORM_FEEDBACK_BUFFER &&
        index < GLTransformFeedbackObject::kMaxTfBuffers &&
        impl_->boundTransformFeedbackId != 0) {
        if (auto* tf = impl_->objects->transformFeedbacks().get(
                impl_->boundTransformFeedbackId)) {
            tf->bufferBindings[index] = {buffer, 0, 0};
        }
    }
    // Spec (4.6 §6.1.1): BindBufferBase also binds buffer to the generic target.
    impl_->state->bindBuffer(target, buffer);
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::BufferBind);
    return true;
}

bool GLContext::bufferData(GLenum target, GLsizeiptr size, const void* data, GLenum usage) {
    // GL 4.4 §6.2: usage must be one of the 9 accepted tokens.
    switch (usage) {
        case GL_STREAM_DRAW: case GL_STREAM_READ: case GL_STREAM_COPY:
        case GL_STATIC_DRAW: case GL_STATIC_READ: case GL_STATIC_COPY:
        case GL_DYNAMIC_DRAW: case GL_DYNAMIC_READ: case GL_DYNAMIC_COPY:
            break;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
    if (size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 §6.2: BUFFER_IMMUTABLE_STORAGE=TRUE rejects bufferData
    // regardless of storage flags. CTS
    // `direct_state_access.buffers_errors` asserts INVALID_OPERATION.
    if (object->immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // S25 Rung 1.5 note: respecification stays UNCONDITIONAL — it can
    // reallocate the CPU shadow and replace the Metal backing outside the
    // rename path (storage-replacement class; Rung-2 territory).
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    if (!impl_->replaceBufferStorage(*object, size, data, usage)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::bufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, const void* data) {
    if (offset < 0 || size < 0 || (size > 0 && data == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 §6.3: bufferSubData is legal on a mapped buffer as
    // long as the write region doesn't overlap the mapped region
    // — unless the mapping uses MAP_PERSISTENT_BIT, in which case
    // any overlap is also legal. CTS `buffer_storage.
    // map_persistent_buffer_sub_data` exercises both cases: the
    // persistent-map section expects all sub-writes to succeed,
    // the non-persistent-map section expects INVALID_OPERATION
    // only for writes that cross the mapped extent.
    if (object->mapped && (object->mapAccessFlags & GL_MAP_PERSISTENT_BIT) == 0) {
        const GLintptr mapStart = object->mapOffset;
        const GLintptr mapEnd = mapStart + static_cast<GLintptr>(object->mapLength);
        const GLintptr opStart = offset;
        const GLintptr opEnd = offset + static_cast<GLintptr>(size);
        const bool overlaps = (opStart < mapEnd) && (opEnd > mapStart);
        if (overlaps) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    // GL 4.4 §6.2 / §6.3: immutable-storage buffers require the
    // GL_DYNAMIC_STORAGE_BIT flag to accept {Named,}BufferSubData writes.
    // CTS `buffer_storage.errors` asserts INVALID_OPERATION when a
    // glBufferStorage-created buffer without DYNAMIC_STORAGE_BIT takes
    // a subsequent glBufferSubData or glNamedBufferSubData.
    if (object->immutable && !(object->storageFlags & GL_DYNAMIC_STORAGE_BIT)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset > object->size || size > object->size - offset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (size > 0) {
        // S25 Rung 1.5: narrowed — flush only when the write lands in
        // place on a Metal buffer a pending deferred record binds.
        impl_->flushEncodeBoundaryForBufferWrite(*object);
        if (!impl_->writeBufferRange(*object, offset, data, size)) {
            pushError(GL_OUT_OF_MEMORY);
            return false;
        }
    }
    return true;
}

bool GLContext::copyBufferSubData(
    GLenum readTarget,
    GLenum writeTarget,
    GLintptr readOffset,
    GLintptr writeOffset,
    GLsizeiptr size
) {
    if (readOffset < 0 || writeOffset < 0 || size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint readName = impl_->state->boundBuffer(readTarget);
    const GLuint writeName = impl_->state->boundBuffer(writeTarget);
    GLBufferObject* readObject = impl_->objects->buffers().get(readName);
    GLBufferObject* writeObject = impl_->objects->buffers().get(writeName);
    if (readName == 0 || writeName == 0 || readObject == nullptr || writeObject == nullptr
        || !readObject->instantiated || !writeObject->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §6.3: mapped source or destination raises INVALID_OPERATION
    // *unless* the buffer was mapped with GL_MAP_PERSISTENT_BIT. Persistent
    // mapping keeps the memory addressable across draws, so copyBufferSubData
    // is allowed to proceed.
    const auto isNonPersistentMapped = [](const GLBufferObject* obj) {
        return obj->mapped && (obj->mapAccessFlags & GL_MAP_PERSISTENT_BIT) == 0;
    };
    if (isNonPersistentMapped(readObject) || isNonPersistentMapped(writeObject)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (readOffset > readObject->size || size > readObject->size - readOffset
        || writeOffset > writeObject->size || size > writeObject->size - writeOffset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (readName == writeName) {
        const GLintptr readEnd = readOffset + size;
        const GLintptr writeEnd = writeOffset + size;
        if (size > 0 && readOffset < writeEnd && writeOffset < readEnd) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (size > 0) {
        // S25 Rung 1.5: narrowed on the WRITE-side object (the read side
        // consumes the CPU shadow, which deferred records never alias).
        impl_->flushEncodeBoundaryForBufferWrite(*writeObject);
        std::vector<std::uint8_t> copyBytes(static_cast<std::size_t>(size));
        if (!impl_->readBufferRange(*readObject, readOffset, size, copyBytes.data())) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (!impl_->writeBufferRange(*writeObject, writeOffset, copyBytes.data(), size)) {
            pushError(GL_OUT_OF_MEMORY);
            return false;
        }
        impl_->markGpuResourceWrites({
            {Impl::GpuResourceAccess::Kind::Buffer,
             writeName,
             kProducerCopyWrite}
        });
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_BUFFER_CORE_B)
bool GLContext::getBufferSubData(GLenum target, GLintptr offset, GLsizeiptr size, void* data) {
    if (offset < 0 || size < 0 || (size > 0 && data == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 §6.3: glGet{Named,}BufferSubData is legal on a mapped
    // buffer only when the mapping uses GL_MAP_PERSISTENT_BIT. CTS
    // `direct_state_access.buffers_errors` covers both directions.
    if (object->mapped && (object->mapAccessFlags & GL_MAP_PERSISTENT_BIT) == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset > object->size || size > object->size - offset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (size > 0) {
        if (!impl_->readBufferRange(*object, offset, size, data)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
        if (target == GL_TRANSFORM_FEEDBACK_BUFFER) {
            logTFReadback(target, name, offset, size,
                          static_cast<const std::uint8_t*>(data));
        }
    }
    return true;
}

void* GLContext::mapBuffer(GLenum target, GLenum access) {
    GLbitfield flags = 0;
    if (!legacyMapAccessToFlags(access, &flags)) {
        pushError(GL_INVALID_ENUM);
        return nullptr;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || object->mapped || object->size <= 0) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    void* pointer = mapBufferRange(target, 0, object->size, flags);
    if (pointer != nullptr) {
        object->mapAccess = access;
    }
    return pointer;
}

void* GLContext::mapBufferRange(GLenum target, GLintptr offset, GLsizeiptr length, GLbitfield access) {
    if (offset < 0 || length < 0) {
        pushError(GL_INVALID_VALUE);
        return nullptr;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    if (object->sparseStorage) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    // GL 4.4 §6.3.1 spec-order:
    //   INVALID_OPERATION is generated if any bit among MAP_READ_BIT,
    //   MAP_WRITE_BIT, MAP_PERSISTENT_BIT, MAP_COHERENT_BIT is set in
    //   access but not in the buffer's storage flags (for immutable
    //   buffers). For non-immutable buffers, the legacy rule is that
    //   MAP_READ_BIT / MAP_WRITE_BIT must both be settable (they are by
    //   default). PERSISTENT / COHERENT only exist on immutable buffers
    //   with the matching storage-flag set.
    //
    // Check storage-flag compatibility BEFORE the syntactic-access
    // check below — CTS `buffer_storage.errors` expects
    // INVALID_OPERATION on `access=PERSISTENT, storage=DYNAMIC_STORAGE`
    // (storage mismatch) to win over INVALID_VALUE from "access has
    // no READ/WRITE".
    if (object->immutable) {
        const GLbitfield storage = object->storageFlags;
        if ((access & GL_MAP_READ_BIT) && !(storage & GL_MAP_READ_BIT)) {
            pushError(GL_INVALID_OPERATION);
            return nullptr;
        }
        if ((access & GL_MAP_WRITE_BIT) && !(storage & GL_MAP_WRITE_BIT)) {
            pushError(GL_INVALID_OPERATION);
            return nullptr;
        }
        if ((access & GL_MAP_PERSISTENT_BIT) &&
            !(storage & GL_MAP_PERSISTENT_BIT)) {
            pushError(GL_INVALID_OPERATION);
            return nullptr;
        }
        if ((access & GL_MAP_COHERENT_BIT) &&
            !(storage & GL_MAP_COHERENT_BIT)) {
            pushError(GL_INVALID_OPERATION);
            return nullptr;
        }
    }
    if (mapBufferRangeAccessHasUndefinedBits(access)) {
        pushError(GL_INVALID_VALUE);
        return nullptr;
    }
    if (!isSupportedMapBufferRangeAccess(access)) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    if (length == 0 || object->size <= 0) {
        pushError(GL_INVALID_OPERATION);
        return nullptr;
    }
    if (offset > object->size || length > object->size - offset) {
        pushError(GL_INVALID_VALUE);
        return nullptr;
    }

    if ((access & (GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_RANGE_BIT |
                   GL_MAP_INVALIDATE_BUFFER_BIT)) != 0) {
        // S25 Rung 1.5: map-for-write — writes go through the returned
        // pointer directly (no later sync renames them), so any live
        // reader forces the flush; only a buffer with no live readers
        // skips it.
        impl_->flushEncodeBoundaryForBufferWrite(
            *object, /*subsequentWritesBypassSync=*/true);
    }
    if (access & GL_MAP_READ_BIT) {
        impl_->drainPendingGpuProducers(*object);
    }

    std::uint8_t* contents = impl_->mutableBufferContents(*object);
    if (contents == nullptr) {
        pushError(GL_OUT_OF_MEMORY);
        return nullptr;
    }

    object->mapped = true;
    object->mapAccess = legacyMapAccessFromFlags(access);
    object->mapAccessFlags = access;
    object->mapOffset = offset;
    object->mapLength = length;
    object->mapPointer = contents + static_cast<std::size_t>(offset);
    if (target == GL_TRANSFORM_FEEDBACK_BUFFER && (access & GL_MAP_READ_BIT)) {
        logTFReadback(target, name, offset, length,
                      static_cast<const std::uint8_t*>(object->mapPointer));
    }
    return object->mapPointer;
}

GLboolean GLContext::unmapBuffer(GLenum target) {
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || !object->mapped) {
        pushError(GL_INVALID_OPERATION);
        return GL_FALSE;
    }
    if (mapAccessWrites(object->mapAccessFlags)) {
        impl_->syncShadowFromMetal(*object, object->mapOffset, object->mapLength);
        ++object->indexExpansionGeneration;
        object->gpuAuthoredSinceCpuWrite = false;
    }
    resetBufferMapping(*object);
    return GL_TRUE;
}

bool GLContext::flushMappedBufferRange(GLenum target, GLintptr offset, GLsizeiptr length) {
    if (offset < 0 || length < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || !object->mapped
        || (object->mapAccessFlags & GL_MAP_FLUSH_EXPLICIT_BIT) == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset > object->mapLength || length > object->mapLength - offset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (mapAccessWrites(object->mapAccessFlags)) {
        impl_->syncShadowFromMetal(*object, object->mapOffset + offset, length);
        ++object->indexExpansionGeneration;
        object->gpuAuthoredSinceCpuWrite = false;
    }
    return true;
}

bool GLContext::getBufferParameterInteger(GLenum target, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLint64 value = 0;
    if (!getBufferParameterInteger64(target, pname, &value)) {
        return false;
    }
    *params = static_cast<GLint>(value);
    return true;
}

bool GLContext::getBufferParameterInteger64(GLenum target, GLenum pname, GLint64* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    switch (pname) {
        case GL_BUFFER_SIZE:
            *params = object->size;
            return true;
        case GL_BUFFER_USAGE:
            *params = object->usage;
            return true;
        case GL_BUFFER_ACCESS:
            *params = object->mapAccess;
            return true;
        case GL_BUFFER_ACCESS_FLAGS:
            *params = object->mapped ? object->mapAccessFlags : 0;
            return true;
        case GL_BUFFER_MAPPED:
            *params = object->mapped ? GL_TRUE : GL_FALSE;
            return true;
        case GL_BUFFER_MAP_OFFSET:
            *params = object->mapped ? object->mapOffset : 0;
            return true;
        case GL_BUFFER_MAP_LENGTH:
            *params = object->mapped ? object->mapLength : 0;
            return true;
        case GL_BUFFER_IMMUTABLE_STORAGE:
            *params = object->immutable ? GL_TRUE : GL_FALSE;
            return true;
        case GL_BUFFER_STORAGE_FLAGS:
            *params = static_cast<GLint64>(object->storageFlags);
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getBufferPointer(GLenum target, GLenum pname, void** params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname != GL_BUFFER_MAP_POINTER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    *params = object->mapped ? object->mapPointer : nullptr;
    return true;
}

#elif defined(APPGL_GLCONTEXT_BUFFER_CLEAR)
bool GLContext::clearBufferData(GLenum target, GLenum internalformat, GLenum format, GLenum type, const void* data) {
    // GL 4.4 §6.7 validation — order matters; CTS
    // `direct_state_access.buffers_errors` asserts every condition.
    if (!isValidClearBufferInternalFormat(internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!isValidClearBufferFormat(format)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!isValidClearBufferType(type)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLuint boundBuffer = impl_->state->boundBuffer(target);
    if (boundBuffer == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLBufferObject* buffer = impl_->objects->buffers().get(boundBuffer);
    if (buffer == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 §6.7: INVALID_OPERATION when the buffer is mapped
    // without MAP_PERSISTENT_BIT.
    if (buffer->mapped && (buffer->mapAccessFlags & GL_MAP_PERSISTENT_BIT) == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (buffer->size == 0) {
        return true; // valid no-op
    }
    // S25 Rung 1.5: narrowed (see bufferSubData).
    impl_->flushEncodeBoundaryForBufferWrite(*buffer);
    const std::size_t patternBytes = bufferClearPatternBytes(format, type);
    if (!impl_->fillBufferRange(*buffer, 0, buffer->size, data, patternBytes)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

bool GLContext::clearBufferSubData(GLenum target, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data) {
    // Same GL 4.4 §6.7 validation as clearBufferData plus range +
    // alignment constraints.
    if (!isValidClearBufferInternalFormat(internalformat)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (!isValidClearBufferFormat(format)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!isValidClearBufferType(type)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (offset < 0 || size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.4 §6.7: offset and size must be multiples of the
    // internal-format byte size. CTS exercises `internalformat=RGBA8`
    // (= 4 bytes) with size=1 and asserts INVALID_VALUE.
    const std::size_t formatBytes = bufferClearPatternBytes(format, type);
    if (formatBytes > 0 &&
        ((offset % static_cast<GLintptr>(formatBytes)) != 0 ||
         (size % static_cast<GLsizeiptr>(formatBytes)) != 0)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLuint boundBuffer = impl_->state->boundBuffer(target);
    if (boundBuffer == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLBufferObject* buffer = impl_->objects->buffers().get(boundBuffer);
    if (buffer == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (buffer->mapped && (buffer->mapAccessFlags & GL_MAP_PERSISTENT_BIT) == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset + size > buffer->size) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (size == 0) {
        return true;
    }
    // S25 Rung 1.5: narrowed (see bufferSubData).
    impl_->flushEncodeBoundaryForBufferWrite(*buffer);
    const std::size_t patternBytes = bufferClearPatternBytes(format, type);
    if (!impl_->fillBufferRange(*buffer, offset, size, data, patternBytes)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_BUFFER_INVALIDATE)
bool GLContext::invalidateBufferData(GLuint buffer) {
    if (!impl_->objects->buffers().contains(buffer)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Hint that the entire buffer's contents are no longer needed.
    return true;
}

bool GLContext::invalidateBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr length) {
    if (offset < 0 || length < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLBufferObject* buf = impl_->objects->buffers().get(buffer);
    if (buf == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (offset + length > buf->size) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_BUFFER_STORAGE)
bool GLContext::bufferStorage(GLenum target, GLsizeiptr size, const void* data, GLbitfield flags) {
    // GL 4.4 §6.2: error-order matters. Binding / immutability
    // checks run before INVALID_VALUE checks because CTS
    // `buffer_storage.errors` specifically asserts that
    // `glBufferStorage(target, 0 /* size */, …)` with no buffer
    // bound returns INVALID_OPERATION (binding wins) — not
    // INVALID_VALUE from the zero-size check.
    GLuint name = impl_->state->boundBuffer(target);
    if (name == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    auto* buf = impl_->objects->buffers().get(name);
    if (!buf) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (buf->immutable) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // size must be > 0. Both `size < 0` and `size == 0` are
    // INVALID_VALUE per GL 4.4 §6.2.1, two spec violations that
    // CTS buffer_storage.errors cross-checks.
    if (size <= 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLbitfield validBits = GL_MAP_READ_BIT | GL_MAP_WRITE_BIT |
                                 GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT |
                                 GL_DYNAMIC_STORAGE_BIT | GL_CLIENT_STORAGE_BIT |
                                 GL_SPARSE_STORAGE_BIT_ARB;
    if (flags & ~validBits) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if ((flags & GL_SPARSE_STORAGE_BIT_ARB) &&
        (flags & (GL_MAP_READ_BIT | GL_MAP_WRITE_BIT))) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if ((flags & GL_MAP_PERSISTENT_BIT) && !(flags & (GL_MAP_READ_BIT | GL_MAP_WRITE_BIT))) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if ((flags & GL_MAP_COHERENT_BIT) && !(flags & GL_MAP_PERSISTENT_BIT)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (flags & GL_SPARSE_STORAGE_BIT_ARB) {
        if (!impl_->replaceSparseBufferStorage(*buf, size)) {
            pushError(GL_OUT_OF_MEMORY);
            return false;
        }
    } else {
        // Delegate to replaceBufferStorage to create both shadow bytes and Metal
        // buffer, then layer immutability flags on top.  Without this the Metal
        // buffer would remain null and draws would render black.
        if (!impl_->replaceBufferStorage(*buf, size, data, GL_STATIC_DRAW)) {
            pushError(GL_OUT_OF_MEMORY);
            return false;
        }
    }
    buf->immutable = true;
    buf->storageFlags = flags;
    buf->instantiated = true;
    return true;
}

#elif defined(APPGL_GLCONTEXT_BUFFER_PAGE_COMMITMENT)
bool GLContext::bufferPageCommitment(GLenum target, GLintptr offset, GLsizeiptr size, GLboolean commit) {
    if (!isSparseBufferCommitmentTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    const GLuint name = impl_->state->boundBuffer(target);
    GLBufferObject* object = impl_->objects->buffers().get(name);
    if (name == 0 || object == nullptr || !object->instantiated || !object->sparseStorage) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (offset < 0 || size < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLsizeiptr pageSize = object->sparsePageSize > 0
        ? object->sparsePageSize
        : kSparseBufferPageSizeARB;
    if ((offset % pageSize) != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (offset > object->size || size > object->size - offset) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if ((size % pageSize) != 0 && offset + size != object->size) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (!impl_->commitSparseBufferRange(*object, offset, size, commit)) {
        pushError(GL_OUT_OF_MEMORY);
        return false;
    }
    impl_->markGpuResourceWrites({
        {Impl::GpuResourceAccess::Kind::Buffer,
         name,
         kProducerSparseResidency}
    });
    return true;
}

#elif defined(APPGL_GLCONTEXT_BUFFER_MULTIBIND)
bool GLContext::bindBuffersBase(GLenum target, GLuint first, GLsizei count, const GLuint* buffers) {
    if (!isIndexedBufferTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLint64 maxBindings = queryLimit(impl_->capabilities.get(), indexedBufferMaxPname(target), 0);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxBindings) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 ARB_multi_bind §6.1.1 — per-entry semantics. Each
    // invalid (non-zero, non-existent) buffer name generates
    // INVALID_OPERATION and that slot is unmodified; valid entries
    // still bind. bindBufferBase itself already pushes INVALID_
    // OPERATION on a bad name, so just let it run through the loop
    // and the per-entry errors accumulate naturally.
    for (GLsizei i = 0; i < count; ++i) {
        GLuint buf = buffers ? buffers[i] : 0;
        if (buf != 0 && !impl_->objects->buffers().contains(buf)) {
            pushError(GL_INVALID_OPERATION);
            continue;
        }
        bindBufferBase(target, first + static_cast<GLuint>(i), buf);
    }
    return true;
}

bool GLContext::bindBuffersRange(GLenum target, GLuint first, GLsizei count, const GLuint* buffers,
                                 const GLintptr* offsets, const GLsizeiptr* sizes) {
    if (!isIndexedBufferTarget(target)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLint64 maxBindings = queryLimit(impl_->capabilities.get(), indexedBufferMaxPname(target), 0);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxBindings) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    for (GLsizei i = 0; i < count; ++i) {
        GLuint buf = buffers ? buffers[i] : 0;
        GLintptr offset = (buffers && offsets) ? offsets[i] : 0;
        GLsizeiptr sz = (buffers && sizes) ? sizes[i] : 0;
        if (buf != 0 && !impl_->objects->buffers().contains(buf)) {
            pushError(GL_INVALID_OPERATION);
            continue;
        }
        bindBufferRange(target, first + static_cast<GLuint>(i), buf, offset, sz);
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_BUFFER_CREATE)
bool GLContext::createBuffers(GLsizei n, GLuint* buffers) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        buffers[i] = impl_->objects->buffers().reserveName();
        auto* obj = impl_->objects->buffers().get(buffers[i]);
        if (obj) obj->instantiated = true;
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_BUFFER_DSA)
bool GLContext::namedBufferStorage(GLuint buffer, GLsizeiptr size, const void* data, GLbitfield flags) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = bufferStorage(target, size, data, flags);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::namedBufferPageCommitment(GLuint buffer, GLintptr offset, GLsizeiptr size, GLboolean commit) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj || !obj->instantiated || !obj->sparseStorage) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = bufferPageCommitment(target, offset, size, commit);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::namedBufferData(GLuint buffer, GLsizeiptr size, const void* data, GLenum usage) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = bufferData(target, size, data, usage);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::namedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, const void* data) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_COPY_WRITE_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = bufferSubData(target, offset, size, data);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::copyNamedBufferSubData(GLuint readBuffer, GLuint writeBuffer, GLintptr readOffset, GLintptr writeOffset, GLsizeiptr size) {
    if (!impl_->objects->buffers().get(readBuffer)) { pushError(GL_INVALID_OPERATION); return false; }
    if (!impl_->objects->buffers().get(writeBuffer)) { pushError(GL_INVALID_OPERATION); return false; }
    GLuint prevRead = impl_->state->boundBuffer(GL_COPY_READ_BUFFER);
    GLuint prevWrite = impl_->state->boundBuffer(GL_COPY_WRITE_BUFFER);
    impl_->state->bindBuffer(GL_COPY_READ_BUFFER, readBuffer);
    impl_->state->bindBuffer(GL_COPY_WRITE_BUFFER, writeBuffer);
    bool ok = copyBufferSubData(GL_COPY_READ_BUFFER, GL_COPY_WRITE_BUFFER, readOffset, writeOffset, size);
    impl_->state->bindBuffer(GL_COPY_READ_BUFFER, prevRead);
    impl_->state->bindBuffer(GL_COPY_WRITE_BUFFER, prevWrite);
    return ok;
}

bool GLContext::mapNamedBuffer(GLuint buffer, GLenum access, void** result) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); *result = nullptr; return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    *result = mapBuffer(target, access);
    impl_->state->bindBuffer(target, prev);
    return true;
}

bool GLContext::mapNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length, GLbitfield access, void** result) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); *result = nullptr; return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    *result = mapBufferRange(target, offset, length, access);
    impl_->state->bindBuffer(target, prev);
    return true;
}

bool GLContext::unmapNamedBuffer(GLuint buffer, GLboolean* result) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); *result = GL_FALSE; return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    *result = unmapBuffer(target);
    impl_->state->bindBuffer(target, prev);
    return true;
}

bool GLContext::flushMappedNamedBufferRange(GLuint buffer, GLintptr offset, GLsizeiptr length) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = flushMappedBufferRange(target, offset, length);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::clearNamedBufferData(GLuint buffer, GLenum internalformat, GLenum format, GLenum type, const void* data) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = clearBufferData(target, internalformat, format, type, data);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::clearNamedBufferSubData(GLuint buffer, GLenum internalformat, GLintptr offset, GLsizeiptr size, GLenum format, GLenum type, const void* data) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = clearBufferSubData(target, internalformat, offset, size, format, type, data);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::getNamedBufferParameteriv(GLuint buffer, GLenum pname, GLint* params) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = getBufferParameterInteger(target, pname, params);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::getNamedBufferParameteri64v(GLuint buffer, GLenum pname, GLint64* params) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = getBufferParameterInteger64(target, pname, params);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::getNamedBufferPointerv(GLuint buffer, GLenum pname, void** params) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = getBufferPointer(target, pname, params);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

bool GLContext::getNamedBufferSubData(GLuint buffer, GLintptr offset, GLsizeiptr size, void* data) {
    auto* obj = impl_->objects->buffers().get(buffer);
    if (!obj) { pushError(GL_INVALID_OPERATION); return false; }
    GLenum target = GL_ARRAY_BUFFER;
    GLuint prev = impl_->state->boundBuffer(target);
    impl_->state->bindBuffer(target, buffer);
    bool ok = getBufferSubData(target, offset, size, data);
    impl_->state->bindBuffer(target, prev);
    return ok;
}

#else
#error "GLContextBuffer.inc.mm included without a buffer section selector"
#endif
