// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext VAO and vertex-attrib method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_VERTEX_ARRAY_OBJECTS)
bool GLContext::genVertexArrays(GLsizei count, GLuint* arrays) {
    if (count < 0 || (count > 0 && arrays == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = impl_->objects->vertexArrays().reserveName();
        arrays[index] = name;
        if (GLVertexArrayObject* object = impl_->objects->vertexArrays().get(name); object != nullptr) {
            impl_->objects->initializeVertexArray(*object);
        }
    }
    return true;
}

bool GLContext::deleteVertexArrays(GLsizei count, const GLuint* arrays) {
    if (count < 0 || (count > 0 && arrays == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    for (GLsizei index = 0; index < count; ++index) {
        const GLuint name = arrays[index];
        if (name == 0) {
            continue;
        }
        if (GLVertexArrayObject* object = impl_->objects->vertexArrays().get(name); object != nullptr) {
            impl_->releaseVertexDescriptor(*object);
        }
        if (impl_->objects->vertexArrays().erase(name)) {
            if (impl_->state->boundVertexArray() == name) {
                impl_->state->bindVertexArray(0);
                impl_->state->bindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
            }
            impl_->objects->deferDelete("vertex array " + std::to_string(name));
        }
    }
    return true;
}

bool GLContext::isVertexArray(GLuint array) const {
    const GLVertexArrayObject* object = impl_->objects->vertexArrays().get(array);
    return object != nullptr && object->instantiated;
}

bool GLContext::bindVertexArray(GLuint array) {
    if (array == 0) {
        impl_->state->bindVertexArray(0);
        impl_->state->bindBuffer(GL_ELEMENT_ARRAY_BUFFER, 0);
        impl_->touchR5Residency(MetalR5ResidencyTouchKind::VertexArrayBind);
        return true;
    }
    GLVertexArrayObject* object = impl_->vertexArray(array);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    object->instantiated = true;
    const std::size_t n = std::min<std::size_t>(
        object->attributes.size(), impl_->kMaxImmediateDoubleAttribs);
    for (std::size_t i = 0; i < n; ++i) {
        auto& attr = object->attributes[i];
        const auto& fd = impl_->immediateDoubleAttribs[i];
        const auto& si = impl_->immediateIntAttribs[i];
        const auto& ui = impl_->immediateUIntAttribs[i];
        attr.immediateKind = impl_->immediateAttribKinds[i];
        for (int k = 0; k < 4; ++k) {
            attr.immediateDouble[k] = fd[k];
            attr.immediateInt[k] = si[k];
            attr.immediateUInt[k] = ui[k];
        }
    }
    impl_->state->bindVertexArray(array);
    impl_->state->bindBuffer(GL_ELEMENT_ARRAY_BUFFER, object->elementArrayBuffer);
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::VertexArrayBind);
    return true;
}

#elif defined(APPGL_GLCONTEXT_VERTEX_ATTRIB_POINTERS)
bool GLContext::enableVertexAttribArray(GLuint index, bool enabled) {
    // Use the default VAO fallback when no user VAO is bound (matches
    // real-driver behaviour; CTS `get_uniform_tests.gl_get_uniform`
    // and other gl3c* tests call enableVertexAttribArray without
    // first binding a VAO and expect the call to succeed).
    GLVertexArrayObject* vertexArray = impl_->currentVertexArrayOrDefault();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    // C52 value gate: re-issuing the current enable state is a no-op —
    // skip the vertex-descriptor invalidation and the domain bump.
    if (vertexArray->attributes[index].enabled == enabled) {
        return true;
    }
    vertexArray->attributes[index].enabled = enabled;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribPointer(
    GLuint index,
    GLint size,
    GLenum type,
    GLboolean normalized,
    GLsizei stride,
    const void* pointer
) {
    if (size < 1 || size > 4 || stride < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (stride > 0) {
        GLint64 maxStride = 2048;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger64(
                GL_MAX_VERTEX_ATTRIB_STRIDE, &maxStride);
        }
        if (stride > static_cast<GLsizei>(maxStride)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if ((type == GL_INT_2_10_10_10_REV ||
         type == GL_UNSIGNED_INT_2_10_10_10_REV) &&
        size != 4) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §10.3 technically requires a user-bound VAO for
    // glVertexAttribPointer, but real drivers (NVIDIA, AMD, Mesa)
    // fall back to an implicit "default VAO" — same accommodation
    // already used by glEnableVertexAttribArray (iter 109). Routing
    // through currentVertexArrayOrDefault avoids spurious errors
    // when apps call the attribute-setup sequence without an explicit
    // glBindVertexArray. CTS `draw_indirect.negative-noVAO-*` rely
    // on the setup NOT leaking an INVALID_OPERATION that their
    // subcase-end glGetError check would then trip on.
    GLVertexArrayObject* vertexArray = impl_->currentVertexArrayOrDefault();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const GLuint buffer = impl_->state->boundBuffer(GL_ARRAY_BUFFER);
    if (buffer == 0 && pointer != nullptr && !appglCompatProfileEnabled()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    auto& attribute = vertexArray->attributes[index];
    // GL 4.6 §10.3.8: glVertexAttribPointer(stride=0) means "tight
    // pack using size*sizeof(type)" — not the VAO default (16).
    // The binding-point stride propagates to
    // `MetalVertexDescriptor.layouts[slot].stride`; writing 16
    // for a small (e.g. size=2 FLOAT = 8-byte) attribute makes
    // Metal fetch every other vertex and zero-fills intermediate
    // ones.
    GLsizei effStride = stride;
    if (effStride <= 0) {
        auto byteSize = [](GLenum t) -> GLsizei {
            switch (t) {
                case GL_BYTE: case GL_UNSIGNED_BYTE: return 1;
                case GL_SHORT: case GL_UNSIGNED_SHORT: case GL_HALF_FLOAT: return 2;
                case GL_FIXED:
                case GL_FLOAT: case GL_INT: case GL_UNSIGNED_INT: return 4;
                case GL_DOUBLE: return 8;
                default: return 4;
            }
        };
        effStride = static_cast<GLsizei>(size) * byteSize(type);
        if (effStride <= 0) effStride = 16;
    }
    // C52 value gate: re-specifying the identical attribute record
    // (including the mirrored binding point) is a no-op — skip the
    // vertex-descriptor invalidation and the vertex-input domain bump.
    {
        const bool sameAttribute = attribute.size == size &&
            attribute.type == type && attribute.normalized == normalized &&
            attribute.stride == stride &&
            attribute.pointer == reinterpret_cast<std::uintptr_t>(pointer) &&
            attribute.buffer == buffer && !attribute.integer &&
            !attribute.longData && attribute.bindingIndex == index &&
            attribute.relativeOffset == 0;
        bool sameBinding = true;
        if (index < vertexArray->bindingPoints.size()) {
            const auto& bp = vertexArray->bindingPoints[index];
            sameBinding = bp.buffer == buffer &&
                bp.offset == static_cast<GLintptr>(reinterpret_cast<std::uintptr_t>(pointer)) &&
                bp.stride == effStride;
        }
        if (sameAttribute && sameBinding) {
            return true;
        }
    }
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = normalized;
    attribute.stride = stride;
    attribute.pointer = reinterpret_cast<std::uintptr_t>(pointer);
    attribute.buffer = buffer;
    attribute.integer = false;
    attribute.longData = false;
    // GL 4.6 §10.3.8: glVertexAttribPointer is defined as
    // glVertexAttribFormat(index, size, type, normalized, 0) +
    // glVertexAttribBinding(index, index) +
    // glBindVertexBuffer(index, buffer, (GLintptr)pointer, stride).
    // Mirror the binding-point state so subsequent queries of
    // GL_VERTEX_BINDING_{BUFFER,OFFSET,STRIDE} and
    // GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING route correctly through
    // the binding path.
    attribute.bindingIndex = index;
    attribute.relativeOffset = 0;
    if (index < vertexArray->bindingPoints.size()) {
        auto& bp = vertexArray->bindingPoints[index];
        bp.buffer = buffer;
        bp.offset = static_cast<GLintptr>(attribute.pointer);
        bp.stride = effStride;
    }
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribIPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer) {
    if (size < 1 || size > 4 || stride < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (stride > 0) {
        GLint64 maxStride = 2048;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger64(
                GL_MAX_VERTEX_ATTRIB_STRIDE, &maxStride);
        }
        if (stride > static_cast<GLsizei>(maxStride)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    // Same rationale as vertexAttribPointer — route through the
    // default-VAO fallback so apps that set up attributes without
    // an explicit glBindVertexArray don't queue an INVALID_OPERATION.
    GLVertexArrayObject* vertexArray = impl_->currentVertexArrayOrDefault();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const GLuint buffer = impl_->state->boundBuffer(GL_ARRAY_BUFFER);
    if (buffer == 0 && pointer != nullptr && !appglCompatProfileEnabled()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    auto& attribute = vertexArray->attributes[index];
    // CKPT100 fix: glVertexAttribIPointer(stride=0) means "tight pack
    // using size*sizeof(type)" per GL 4.6 §10.3.8 — not the
    // VAO-default 16. The hardcoded 16 fallback caused
    // KHR-GL46.direct_state_access.vertex_arrays_element_buffer to
    // fail: 1-component GL_INT attribute with stride=0 should fetch
    // every 4 bytes; with stride forced to 16, slot N reads
    // out-of-range past the 12-byte buffer for N≥1, returning
    // zeros. Mirror the byte-size compute already in
    // glVertexAttribPointer for symmetry.
    GLsizei effStride = stride;
    if (effStride <= 0) {
        auto byteSize = [](GLenum t) -> GLsizei {
            switch (t) {
                case GL_BYTE: case GL_UNSIGNED_BYTE: return 1;
                case GL_SHORT: case GL_UNSIGNED_SHORT: return 2;
                case GL_INT: case GL_UNSIGNED_INT: return 4;
                default: return 4;
            }
        };
        effStride = static_cast<GLsizei>(size) * byteSize(type);
        if (effStride <= 0) effStride = 16;
    }
    // C52 value gate: same shape as glVertexAttribPointer above.
    {
        const bool sameAttribute = attribute.size == size &&
            attribute.type == type && attribute.normalized == GL_FALSE &&
            attribute.stride == stride &&
            attribute.pointer == reinterpret_cast<std::uintptr_t>(pointer) &&
            attribute.buffer == buffer && attribute.integer &&
            !attribute.longData && attribute.bindingIndex == index &&
            attribute.relativeOffset == 0;
        bool sameBinding = true;
        if (index < vertexArray->bindingPoints.size()) {
            const auto& bp = vertexArray->bindingPoints[index];
            sameBinding = bp.buffer == buffer &&
                bp.offset == static_cast<GLintptr>(reinterpret_cast<std::uintptr_t>(pointer)) &&
                bp.stride == effStride;
        }
        if (sameAttribute && sameBinding) {
            return true;
        }
    }
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = GL_FALSE;
    attribute.stride = stride;
    attribute.pointer = reinterpret_cast<std::uintptr_t>(pointer);
    attribute.buffer = buffer;
    attribute.integer = true;
    attribute.longData = false;
    // Same spec-equivalence as glVertexAttribPointer (GL 4.6 §10.3.8).
    attribute.bindingIndex = index;
    attribute.relativeOffset = 0;
    if (index < vertexArray->bindingPoints.size()) {
        auto& bp = vertexArray->bindingPoints[index];
        bp.buffer = buffer;
        bp.offset = static_cast<GLintptr>(attribute.pointer);
        bp.stride = effStride;
    }
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribDivisor(GLuint index, GLuint divisor) {
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §10.3.8: `glVertexAttribDivisor(N, D)` is defined as
    // `glVertexBindingDivisor(N, D)` + `glVertexAttribBinding(N, N)`.
    // The divisor lives on the binding point, not the attribute —
    // CTS `vertex_attrib_binding.basic-state4` asserts that a
    // subsequent `glVertexBindingDivisor(N, new)` overwrites the
    // same state.
    if (index < vertexArray->bindingPoints.size()) {
        vertexArray->bindingPoints[index].divisor = divisor;
    }
    vertexArray->attributes[index].bindingIndex = index;
    // Mirror into the legacy field too so the
    // `markVertexDescriptorDirty` + draw-time fetch still sees the
    // value when the attribute was set via glVertexAttribPointer
    // rather than separated-format calls.
    vertexArray->attributes[index].divisor = divisor;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

#elif defined(APPGL_GLCONTEXT_VERTEX_ATTRIB_FORMAT_BINDING)
bool GLContext::bindVertexBuffer(GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride) {
    if (stride < 0 || offset < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.4 §10.3.1: stride must be ≤ GL_MAX_VERTEX_ATTRIB_STRIDE.
    {
        GLint64 maxStride = 2048;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger64(
                GL_MAX_VERTEX_ATTRIB_STRIDE, &maxStride);
        }
        if (stride > static_cast<GLsizei>(maxStride)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 §10.3.1: bindingindex must be < GL_MAX_VERTEX_ATTRIB_BINDINGS.
    // Our VAO's bindingPoints vector is sized to MAX_VERTEX_ATTRIBS (32)
    // which is larger than MAX_VERTEX_ATTRIB_BINDINGS (16), so the
    // size-based check let binding indices in [16, 32) through. CTS
    // `vertex_attrib_binding.negative-bindVertexBuffer` plants
    // bindingindex=17 and asserts INVALID_VALUE.
    GLint64 maxBindings = 16;
    if (impl_->capabilities != nullptr) {
        impl_->capabilities->queryInteger64(
            GL_MAX_VERTEX_ATTRIB_BINDINGS, &maxBindings);
    }
    if (bindingindex >= static_cast<GLuint>(maxBindings)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (bindingindex >= vertexArray->bindingPoints.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Buffer 0 is valid (unbinds the binding point).
    if (buffer != 0 && !impl_->objects->buffers().contains(buffer)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    auto& bp = vertexArray->bindingPoints[bindingindex];
    bp.buffer = buffer;
    bp.offset = offset;
    bp.stride = stride;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::VertexBufferBind);
    return true;
}

bool GLContext::vertexAttribFormat(GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset) {
    // GL 4.4 §10.3.8: type must be one of the accepted tokens.
    // Reject unknown types with INVALID_ENUM. CTS
    // `direct_state_access.vertex_arrays_attribute_format_errors`
    // goes through the DSA entry path which skips the legacy wrapper's
    // type check, so this needs to live at the context level.
    switch (type) {
        case GL_BYTE: case GL_UNSIGNED_BYTE:
        case GL_SHORT: case GL_UNSIGNED_SHORT:
        case GL_INT: case GL_UNSIGNED_INT:
        case GL_HALF_FLOAT: case GL_FLOAT: case GL_DOUBLE:
        case GL_FIXED:
        case GL_INT_2_10_10_10_REV:
        case GL_UNSIGNED_INT_2_10_10_10_REV:
        case GL_UNSIGNED_INT_10F_11F_11F_REV:
            break;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
    // GL 4.4 §10.3.8: size ∈ {1, 2, 3, 4, GL_BGRA}.
    const bool sizeIsBgra = (size == static_cast<GLint>(GL_BGRA));
    if (!sizeIsBgra && (size < 1 || size > 4)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // When size is GL_BGRA: type must be GL_UNSIGNED_BYTE,
    // GL_INT_2_10_10_10_REV, or GL_UNSIGNED_INT_2_10_10_10_REV, and
    // normalized must be GL_TRUE. Violations raise INVALID_OPERATION.
    // CTS `vertex_attrib_binding.negative-vertexAttribFormat` plants
    // `size=GL_BGRA, type=GL_FLOAT, normalized=GL_TRUE` and asserts
    // INVALID_OPERATION.
    if (sizeIsBgra) {
        const bool typeOk = (type == GL_UNSIGNED_BYTE ||
                             type == GL_INT_2_10_10_10_REV ||
                             type == GL_UNSIGNED_INT_2_10_10_10_REV);
        if (!typeOk || normalized != GL_TRUE) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    // GL 4.4 §10.3.8: packed types (2_10_10_10_REV variants) require
    // size = 4 or GL_BGRA. Otherwise INVALID_OPERATION. CTS
    // `vertex_attrib_binding.negative-vertexAttribFormat` exercises
    // `size=3, type=GL_INT_2_10_10_10_REV, normalized=GL_FALSE` and
    // asserts INVALID_OPERATION.
    if ((type == GL_INT_2_10_10_10_REV ||
         type == GL_UNSIGNED_INT_2_10_10_10_REV) &&
        !sizeIsBgra && size != 4) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 §10.3.8: UNSIGNED_INT_10F_11F_11F_REV is a 3-channel
    // packed float — size must be 3. CTS
    // `vertex_arrays_attribute_format_errors` plants a size != 3 with
    // this type and expects INVALID_OPERATION.
    if (type == GL_UNSIGNED_INT_10F_11F_11F_REV && size != 3) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 §10.3.8: relativeoffset must be <=
    // GL_MAX_VERTEX_ATTRIB_RELATIVE_OFFSET. Out-of-range is
    // INVALID_VALUE. CTS plants relativeoffset=2057 with the cap
    // at 2047.
    {
        GLint64 maxRelOffset = 2047;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger64(
                GL_MAX_VERTEX_ATTRIB_RELATIVE_OFFSET, &maxRelOffset);
        }
        if (relativeoffset > static_cast<GLuint>(maxRelOffset)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || attribindex >= vertexArray->attributes.size()) {
        pushError(attribindex >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    auto& attribute = vertexArray->attributes[attribindex];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = normalized;
    attribute.relativeOffset = relativeoffset;
    attribute.integer = false;
    attribute.longData = false;
    attribute.useSeparatedFormat = true;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribIFormat(GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    // GL 4.4 §10.3.8: integer vertex attrib types — byte / short / int,
    // signed or unsigned. Everything else (including packed floats
    // like UNSIGNED_INT_10F_11F_11F_REV and UNSIGNED_INT_2_10_10_10_REV)
    // is rejected with INVALID_ENUM. CTS
    // `vertex_arrays_attribute_format_errors` plants a
    // UNSIGNED_INT_10F_11F_11F_REV type and asserts INVALID_ENUM.
    switch (type) {
        case GL_BYTE: case GL_UNSIGNED_BYTE:
        case GL_SHORT: case GL_UNSIGNED_SHORT:
        case GL_INT: case GL_UNSIGNED_INT:
            break;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
    if (size < 1 || size > 4) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.4 §10.3.8: relativeoffset > MAX_VERTEX_ATTRIB_RELATIVE_OFFSET
    // is INVALID_VALUE.
    {
        GLint64 maxRelOffset = 2047;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger64(
                GL_MAX_VERTEX_ATTRIB_RELATIVE_OFFSET, &maxRelOffset);
        }
        if (relativeoffset > static_cast<GLuint>(maxRelOffset)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || attribindex >= vertexArray->attributes.size()) {
        pushError(attribindex >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    auto& attribute = vertexArray->attributes[attribindex];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = GL_FALSE;
    attribute.relativeOffset = relativeoffset;
    attribute.integer = true;
    attribute.longData = false;
    attribute.useSeparatedFormat = true;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribLFormat(GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    if (size < 1 || size > 4) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (type != GL_DOUBLE) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.4 §10.3.8: relativeoffset > MAX_VERTEX_ATTRIB_RELATIVE_OFFSET
    // is INVALID_VALUE.
    {
        GLint64 maxRelOffset = 2047;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger64(
                GL_MAX_VERTEX_ATTRIB_RELATIVE_OFFSET, &maxRelOffset);
        }
        if (relativeoffset > static_cast<GLuint>(maxRelOffset)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || attribindex >= vertexArray->attributes.size()) {
        pushError(attribindex >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    auto& attribute = vertexArray->attributes[attribindex];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = GL_FALSE;
    attribute.relativeOffset = relativeoffset;
    attribute.integer = false;
    attribute.longData = true;
    attribute.useSeparatedFormat = true;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexAttribBinding(GLuint attribindex, GLuint bindingindex) {
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.4 §10.3.1: attribindex must be < MAX_VERTEX_ATTRIBS,
    // bindingindex must be < MAX_VERTEX_ATTRIB_BINDINGS. The
    // bindingPoints vector is sized to MAX_VERTEX_ATTRIBS (32),
    // wider than MAX_VERTEX_ATTRIB_BINDINGS (16), so the size-
    // based check lets binding indices in [16, 32) through.
    GLint64 maxBindings = 16;
    if (impl_->capabilities != nullptr) {
        impl_->capabilities->queryInteger64(
            GL_MAX_VERTEX_ATTRIB_BINDINGS, &maxBindings);
    }
    if (attribindex >= vertexArray->attributes.size() ||
        bindingindex >= static_cast<GLuint>(maxBindings) ||
        bindingindex >= vertexArray->bindingPoints.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    vertexArray->attributes[attribindex].bindingIndex = bindingindex;
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::vertexBindingDivisor(GLuint bindingindex, GLuint divisor) {
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLint64 maxBindings = 16;
    if (impl_->capabilities != nullptr) {
        impl_->capabilities->queryInteger64(
            GL_MAX_VERTEX_ATTRIB_BINDINGS, &maxBindings);
    }
    if (bindingindex >= static_cast<GLuint>(maxBindings) ||
        bindingindex >= vertexArray->bindingPoints.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    vertexArray->bindingPoints[bindingindex].divisor = divisor;
    // Mirror into the legacy per-attribute `divisor` for every
    // attribute currently routed to this binding — keeps the
    // legacy draw-time path in sync. `GL_VERTEX_ATTRIB_ARRAY_DIVISOR`
    // queries read from the binding point directly (below), so this
    // mirror isn't what drives the query result; it just keeps the
    // MetalVertexDescriptorBuilder's `attribute.divisor` field
    // accurate for draws that use the legacy attribute-fields path.
    for (auto& a : vertexArray->attributes) {
        if (a.bindingIndex == bindingindex) {
            a.divisor = divisor;
        }
    }
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

#elif defined(APPGL_GLCONTEXT_VERTEX_ATTRIB_QUERY)
bool GLContext::getVertexAttribInteger(GLuint index, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const auto& attribute = vertexArray->attributes[index];
    switch (pname) {
        case GL_VERTEX_ATTRIB_ARRAY_ENABLED:
            params[0] = attribute.enabled ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_SIZE:
            params[0] = attribute.size;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_STRIDE:
            params[0] = attribute.stride;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_TYPE:
            params[0] = static_cast<GLint>(attribute.type);
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_NORMALIZED:
            params[0] = attribute.normalized;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING:
            // GL 4.6 §10.3.8: returns the buffer bound to the
            // *binding point* used by this attribute, not the raw
            // legacy `attribute.buffer` field. For
            // glVertexAttribPointer the two coincide because it
            // implicitly sets binding=index and binds the current
            // GL_ARRAY_BUFFER to that binding point.
            if (attribute.bindingIndex < vertexArray->bindingPoints.size()) {
                params[0] = static_cast<GLint>(
                    vertexArray->bindingPoints[attribute.bindingIndex].buffer);
            } else {
                params[0] = static_cast<GLint>(attribute.buffer);
            }
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_INTEGER:
            params[0] = attribute.integer ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_DIVISOR:
            // Per-attribute divisor query — always returns the
            // divisor of the binding point the attribute uses.
            // `glVertexAttribDivisor` / `glVertexBindingDivisor`
            // write the same state slot per GL 4.6 §10.3.8, so the
            // lookup needs to route through the binding index.
            if (attribute.bindingIndex < vertexArray->bindingPoints.size()) {
                params[0] = static_cast<GLint>(
                    vertexArray->bindingPoints[attribute.bindingIndex].divisor);
            } else {
                params[0] = static_cast<GLint>(attribute.divisor);
            }
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_LONG:
            params[0] = attribute.longData ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_BINDING:
            // GL 4.3 separated-format binding index; default = attribute index.
            params[0] = static_cast<GLint>(attribute.bindingIndex);
            return true;
        case GL_VERTEX_ATTRIB_RELATIVE_OFFSET:
            // GL 4.3 separated-format relative offset within the binding.
            params[0] = static_cast<GLint>(attribute.relativeOffset);
            return true;
        case GL_CURRENT_VERTEX_ATTRIB:
            params[0] = 0;
            params[1] = 0;
            params[2] = 0;
            params[3] = 1;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getVertexAttribFloat(GLuint index, GLenum pname, GLfloat* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_CURRENT_VERTEX_ATTRIB) {
        params[0] = 0.0f;
        params[1] = 0.0f;
        params[2] = 0.0f;
        params[3] = 1.0f;
        return true;
    }

    GLint values[4] = {};
    if (!getVertexAttribInteger(index, pname, values)) {
        return false;
    }
    params[0] = static_cast<GLfloat>(values[0]);
    return true;
}

bool GLContext::getVertexAttribPointer(GLuint index, GLenum pname, void** pointer) {
    if (pointer == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname != GL_VERTEX_ATTRIB_ARRAY_POINTER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    *pointer = reinterpret_cast<void*>(vertexArray->attributes[index].pointer);
    return true;
}

#elif defined(APPGL_GLCONTEXT_VERTEX_ATTRIB_DOUBLE_IMMEDIATE)
bool GLContext::vertexAttribLPointer(GLuint index, GLint size, GLenum type, GLsizei stride, const void* pointer) {
    // GL spec: type must be GL_DOUBLE for glVertexAttribLPointer.
    if (size < 1 || size > 4 || stride < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (stride > 0) {
        GLint64 maxStride = 2048;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger64(
                GL_MAX_VERTEX_ATTRIB_STRIDE, &maxStride);
        }
        if (stride > static_cast<GLsizei>(maxStride)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    if (type != GL_DOUBLE) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLVertexArrayObject* vertexArray = impl_->currentVertexArray();
    if (vertexArray == nullptr || index >= vertexArray->attributes.size()) {
        pushError(index >= static_cast<GLuint>(impl_->objects->maxVertexAttribs()) ? GL_INVALID_VALUE : GL_INVALID_OPERATION);
        return false;
    }
    const GLuint buffer = impl_->state->boundBuffer(GL_ARRAY_BUFFER);
    if (buffer == 0 && pointer != nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    auto& attribute = vertexArray->attributes[index];
    attribute.size = size;
    attribute.type = type;
    attribute.normalized = GL_FALSE;
    attribute.stride = stride;
    attribute.pointer = reinterpret_cast<std::uintptr_t>(pointer);
    attribute.buffer = buffer;
    attribute.integer = false;
    attribute.longData = true;
    attribute.bindingIndex = index;
    attribute.relativeOffset = 0;
    if (index < vertexArray->bindingPoints.size()) {
        auto& bp = vertexArray->bindingPoints[index];
        bp.buffer = buffer;
        bp.offset = static_cast<GLintptr>(attribute.pointer);
        bp.stride = stride > 0
            ? stride
            : static_cast<GLsizei>(size * static_cast<GLint>(sizeof(GLdouble)));
    }
    markVertexDescriptorDirty(*vertexArray);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::setVertexAttribImmediate(GLuint index, GLint count, const GLdouble* values) {
    if (index >= impl_->kMaxImmediateDoubleAttribs || values == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    auto& slot = impl_->immediateDoubleAttribs[index];
    slot[0] = count >= 1 ? values[0] : 0.0;
    slot[1] = count >= 2 ? values[1] : 0.0;
    slot[2] = count >= 3 ? values[2] : 0.0;
    slot[3] = count >= 4 ? values[3] : 1.0;
    impl_->immediateAttribKinds[index] = GLVertexAttributeState::ImmediateKind::Float;
    if (GLVertexArrayObject* vertexArray = impl_->currentVertexArrayOrDefault();
        vertexArray != nullptr && index < vertexArray->attributes.size()) {
        auto& attr = vertexArray->attributes[index];
        attr.immediateKind = GLVertexAttributeState::ImmediateKind::Float;
        for (int k = 0; k < 4; ++k) {
            attr.immediateDouble[k] = slot[k];
            attr.immediateInt[k] = static_cast<GLint>(slot[k]);
            attr.immediateUInt[k] = static_cast<GLuint>(std::max<GLdouble>(slot[k], 0.0));
        }
    }
    return true;
}

bool GLContext::setVertexAttribIImmediate(GLuint index, const GLint* values, bool isUnsigned) {
    if (index >= impl_->kMaxImmediateDoubleAttribs || values == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    auto& si = impl_->immediateIntAttribs[index];
    auto& ui = impl_->immediateUIntAttribs[index];
    auto& fd = impl_->immediateDoubleAttribs[index];
    for (int k = 0; k < 4; ++k) {
        if (isUnsigned) {
            const GLuint u = static_cast<GLuint>(values[k]);
            ui[k] = u;
            si[k] = static_cast<GLint>(u);
            fd[k] = static_cast<GLdouble>(u);
        } else {
            const GLint s = values[k];
            si[k] = s;
            ui[k] = static_cast<GLuint>(s);
            fd[k] = static_cast<GLdouble>(s);
        }
    }
    impl_->immediateAttribKinds[index] = isUnsigned
        ? GLVertexAttributeState::ImmediateKind::UInt
        : GLVertexAttributeState::ImmediateKind::Int;
    if (GLVertexArrayObject* vertexArray = impl_->currentVertexArrayOrDefault();
        vertexArray != nullptr && index < vertexArray->attributes.size()) {
        auto& attr = vertexArray->attributes[index];
        attr.immediateKind = impl_->immediateAttribKinds[index];
        for (int k = 0; k < 4; ++k) {
            attr.immediateInt[k] = si[k];
            attr.immediateUInt[k] = ui[k];
            attr.immediateDouble[k] = fd[k];
        }
    }
    return true;
}

bool GLContext::setVertexAttribLImmediate(GLuint index, GLint count, const GLdouble* values) {
    // Immediate vertex attributes are per-context state (not per-VAO).
    if (index >= impl_->kMaxImmediateDoubleAttribs) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    auto& slot = impl_->immediateDoubleAttribs[index];
    slot[0] = count >= 1 ? values[0] : 0.0;
    slot[1] = count >= 2 ? values[1] : 0.0;
    slot[2] = count >= 3 ? values[2] : 0.0;
    slot[3] = count >= 4 ? values[3] : 1.0;
    impl_->immediateAttribKinds[index] = GLVertexAttributeState::ImmediateKind::Float;
    if (GLVertexArrayObject* vertexArray = impl_->currentVertexArrayOrDefault();
        vertexArray != nullptr && index < vertexArray->attributes.size()) {
        auto& attr = vertexArray->attributes[index];
        attr.immediateKind = GLVertexAttributeState::ImmediateKind::Float;
        attr.immediateDouble[0] = slot[0];
        attr.immediateDouble[1] = slot[1];
        attr.immediateDouble[2] = slot[2];
        attr.immediateDouble[3] = slot[3];
        for (int k = 0; k < 4; ++k) {
            attr.immediateInt[k] = static_cast<GLint>(slot[k]);
            attr.immediateUInt[k] = static_cast<GLuint>(std::max<GLdouble>(slot[k], 0.0));
        }
    }
    return true;
}

bool GLContext::getVertexAttribLdv(GLuint index, GLenum pname, GLdouble* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (pname == GL_CURRENT_VERTEX_ATTRIB) {
        // Return the stored per-context immediate double values (lossless).
        if (index >= impl_->kMaxImmediateDoubleAttribs) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const auto& slot = impl_->immediateDoubleAttribs[index];
        params[0] = slot[0];
        params[1] = slot[1];
        params[2] = slot[2];
        params[3] = slot[3];
        return true;
    }
    // For non-CURRENT_VERTEX_ATTRIB pnames, delegate to the integer getter and widen.
    GLint values[4] = {};
    if (!getVertexAttribInteger(index, pname, values)) {
        return false;
    }
    params[0] = static_cast<GLdouble>(values[0]);
    return true;
}

#elif defined(APPGL_GLCONTEXT_VERTEX_ARRAY_MULTIBIND)
bool GLContext::bindVertexBuffers(GLuint first, GLsizei count, const GLuint* buffers,
                                  const GLintptr* offsets, const GLsizei* strides) {
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLint64 maxBindings = queryLimit(impl_->capabilities.get(), GL_MAX_VERTEX_ATTRIB_BINDINGS, 16);
    if (static_cast<GLint64>(first) + static_cast<GLint64>(count) > maxBindings) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    for (GLsizei i = 0; i < count; ++i) {
        GLuint buf = buffers ? buffers[i] : 0;
        GLintptr offset = (buffers && offsets) ? offsets[i] : 0;
        GLsizei stride = (buffers && strides) ? strides[i] : 0;
        bindVertexBuffer(first + static_cast<GLuint>(i), buf, offset, stride);
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_VERTEX_ARRAY_CREATE)
bool GLContext::createVertexArrays(GLsizei n, GLuint* arrays) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        arrays[i] = impl_->objects->vertexArrays().reserveName();
        if (auto* obj = impl_->objects->vertexArrays().get(arrays[i])) {
            obj->instantiated = true;
            // GL 4.5 §10.3.1 — glCreateVertexArrays instantiates the
            // object up-front (unlike glGenVertexArrays which defers
            // to first bind). DSA state queries like
            // glGetVertexArrayIndexediv / glVertexArrayAttribFormat
            // are callable immediately after createVertexArrays, so
            // the attribute + binding-point vectors need to carry
            // their spec-defined defaults (SIZE=4, TYPE=GL_FLOAT,
            // bindingIndex=i, binding stride=16). Without this
            // init, the default test queries return 0 for SIZE /
            // TYPE because the attributes vector is empty.
            impl_->objects->initializeVertexArray(*obj);
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_VERTEX_ARRAY_DSA_CORE)
bool GLContext::vertexArrayAttribFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLboolean normalized, GLuint relativeoffset) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexAttribFormat(attribindex, size, type, normalized, relativeoffset);
        return ok;
    })
}

bool GLContext::vertexArrayAttribIFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexAttribIFormat(attribindex, size, type, relativeoffset);
        return ok;
    })
}

bool GLContext::vertexArrayAttribLFormat(GLuint vaobj, GLuint attribindex, GLint size, GLenum type, GLuint relativeoffset) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexAttribLFormat(attribindex, size, type, relativeoffset);
        return ok;
    })
}

bool GLContext::vertexArrayAttribBinding(GLuint vaobj, GLuint attribindex, GLuint bindingindex) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexAttribBinding(attribindex, bindingindex);
        return ok;
    })
}

bool GLContext::vertexArrayBindingDivisor(GLuint vaobj, GLuint bindingindex, GLuint divisor) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexBindingDivisor(bindingindex, divisor);
        return ok;
    })
}

bool GLContext::vertexArrayVertexAttribDivisorEXT(GLuint vaobj, GLuint index, GLuint divisor) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = vertexAttribDivisor(index, divisor);
        return ok;
    })
}

bool GLContext::vertexArrayVertexBuffer(GLuint vaobj, GLuint bindingindex, GLuint buffer, GLintptr offset, GLsizei stride) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = bindVertexBuffer(bindingindex, buffer, offset, stride);
        return ok;
    })
}

bool GLContext::vertexArrayVertexBuffers(GLuint vaobj, GLuint first, GLsizei count, const GLuint* buffers, const GLintptr* offsets, const GLsizei* strides) {
    DSA_VAO_WRAP(vaobj, {
        bool ok = bindVertexBuffers(first, count, buffers, offsets, strides);
        return ok;
    })
}

bool GLContext::vertexArrayElementBuffer(GLuint vaobj, GLuint buffer) {
    DSA_VAO_CHECK(vaobj)
    // GL 4.5 §10.3.1: buffer must be zero or an existing buffer name.
    // CTS `direct_state_access.vertex_arrays_element_buffer_errors`
    // plants a never-generated buffer ID and asserts INVALID_OPERATION.
    if (buffer != 0 && !impl_->objects->buffers().contains(buffer)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    _vao->elementArrayBuffer = buffer;
    return true;
}

bool GLContext::enableVertexArrayAttrib(GLuint vaobj, GLuint index) {
    DSA_VAO_CHECK(vaobj)
    if (index >= _vao->attributes.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    _vao->instantiated = true;
    if (_vao->attributes[index].enabled) {
        return true;
    }
    _vao->attributes[index].enabled = GL_TRUE;
    markVertexDescriptorDirty(*_vao);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::disableVertexArrayAttrib(GLuint vaobj, GLuint index) {
    DSA_VAO_CHECK(vaobj)
    if (index >= _vao->attributes.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    _vao->instantiated = true;
    if (!_vao->attributes[index].enabled) {
        return true;
    }
    _vao->attributes[index].enabled = GL_FALSE;
    markVertexDescriptorDirty(*_vao);
    impl_->state->markDirty(DirtyBit::VertexInput);
    return true;
}

bool GLContext::getVertexArrayiv(GLuint vaobj, GLenum pname, GLint* param) {
    DSA_VAO_CHECK(vaobj)
    // GL 4.5 §10.3.12: pname is restricted to
    // GL_ELEMENT_ARRAY_BUFFER_BINDING for `glGetVertexArrayiv`
    // (no other enum is accepted at the per-VAO level). CTS
    // `direct_state_access.vertex_arrays_get_vertex_array_errors`
    // plants a bogus pname and asserts INVALID_ENUM.
    if (pname != GL_ELEMENT_ARRAY_BUFFER_BINDING) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (param) {
        *param = static_cast<GLint>(_vao->elementArrayBuffer);
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_VERTEX_ARRAY_DSA_INDEXED_QUERY)
bool GLContext::getVertexArrayIndexediv(GLuint vaobj, GLuint index, GLenum pname, GLint* param) {
    DSA_VAO_CHECK(vaobj)
    if (!isValidVertexArrayIndexedPname(pname)) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.5 §10.3.12: `index` is an attribute index for the
    // per-attribute pnames; GL_INVALID_VALUE if out of range.
    if (index >= _vao->attributes.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (param == nullptr) return true;
    const auto& attr = _vao->attributes[index];
    switch (pname) {
        case GL_VERTEX_ATTRIB_ARRAY_ENABLED:
            *param = attr.enabled ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_SIZE:
            *param = attr.size;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_STRIDE:
            // GL 4.6 Table 22.3 per-attribute state — independent from
            // VERTEX_BINDING_STRIDE (Table 22.4 per-binding state).
            // Returns the stride set via glVertexAttribPointer or
            // glVertexAttribIPointer, default 0. CTS
            // `vertex_arrays_get_vertex_array_indexed` asserts 0 on a
            // fresh VAO even though the binding-point stride defaults
            // to 16.
            *param = attr.stride;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_TYPE:
            *param = static_cast<GLint>(attr.type);
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_NORMALIZED:
            *param = attr.normalized ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_INTEGER:
            *param = attr.integer ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_LONG:
            *param = attr.longData ? GL_TRUE : GL_FALSE;
            return true;
        case GL_VERTEX_ATTRIB_ARRAY_DIVISOR:
            if (attr.bindingIndex < _vao->bindingPoints.size()) {
                *param = static_cast<GLint>(_vao->bindingPoints[attr.bindingIndex].divisor);
            } else {
                *param = static_cast<GLint>(attr.divisor);
            }
            return true;
        case GL_VERTEX_ATTRIB_RELATIVE_OFFSET:
            *param = static_cast<GLint>(attr.relativeOffset);
            return true;
    }
    // Should be unreachable — isValidVertexArrayIndexedPname gated.
    *param = 0;
    return true;
}

bool GLContext::getVertexArrayIndexed64iv(GLuint vaobj, GLuint index, GLenum pname, GLint64* param) {
    DSA_VAO_CHECK(vaobj)
    // GL 4.5 §10.3.12: The 64-bit form only accepts
    // GL_VERTEX_BINDING_OFFSET — it's the 64-bit buffer offset from
    // the attribute's binding point.
    if (pname != GL_VERTEX_BINDING_OFFSET) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (index >= _vao->attributes.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (param == nullptr) return true;
    const auto& attr = _vao->attributes[index];
    if (attr.bindingIndex < _vao->bindingPoints.size()) {
        *param = static_cast<GLint64>(_vao->bindingPoints[attr.bindingIndex].offset);
    } else {
        *param = 0;
    }
    return true;
}

#else
#error "GLContextVertexArray.inc.mm included without a vertex-array section selector"
#endif
