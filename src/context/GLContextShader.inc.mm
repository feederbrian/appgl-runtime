// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext shader-domain method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_SHADER_PRECISION)
void GLContext::getShaderPrecisionFormat(GLenum shadertype, GLenum precisiontype, GLint* range, GLint* precision) {
    // Metal GPUs support full 32-bit float and integer precision.
    // Report ranges matching IEEE 754 single-precision and 32-bit integer.
    (void)shadertype;
    switch (precisiontype) {
        case GL_LOW_FLOAT:
        case GL_MEDIUM_FLOAT:
        case GL_HIGH_FLOAT:
            if (range) { range[0] = 127; range[1] = 127; }
            if (precision) { *precision = 23; }
            break;
        case GL_LOW_INT:
        case GL_MEDIUM_INT:
        case GL_HIGH_INT:
            if (range) { range[0] = 31; range[1] = 30; }
            if (precision) { *precision = 0; }
            break;
        default:
            if (range) { range[0] = 0; range[1] = 0; }
            if (precision) { *precision = 0; }
            break;
    }
}

#elif defined(APPGL_GLCONTEXT_SHADER_OBJECTS)
#include "GLContextShaderObjects.inc.mm"

#elif defined(APPGL_GLCONTEXT_SHADER_PROGRAM_OBJECTS)
bool GLContext::getShaderiv(GLuint shader, GLenum pname, GLint* params) {
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    switch (pname) {
        case GL_SHADER_TYPE:
            *params = static_cast<GLint>(object->stage);
            return true;
        case GL_DELETE_STATUS:
            *params = object->deleteRequested ? GL_TRUE : GL_FALSE;
            return true;
        case GL_COMPILE_STATUS:
            *params = object->compiled ? GL_TRUE : GL_FALSE;
            return true;
        case GL_INFO_LOG_LENGTH:
            *params = static_cast<GLint>(object->compileLog.size() + (object->compileLog.empty() ? 0 : 1));
            return true;
        case GL_SHADER_SOURCE_LENGTH:
            *params = static_cast<GLint>(object->source.size() + (object->source.empty() ? 0 : 1));
            return true;
        case 0x91B1:   // GL_COMPLETION_STATUS_KHR / _ARB
            // Our compile path is synchronous — every compile finishes
            // before glCompileShader returns, so completion is always
            // true. Matches GL_ARB/KHR_parallel_shader_compile spec
            // "If this query is called before a call to glCompileShader,
            // the implementation shall return GL_TRUE" — and after the
            // synchronous compile, it's trivially complete.
            *params = GL_TRUE;
            return true;
        case 0x9552:   // GL_SPIR_V_BINARY_ARB
            // GL_ARB_gl_spirv — TRUE if the shader's last-seen source
            // was a SPIR-V binary via glShaderBinary(); cleared back to
            // FALSE on any subsequent glShaderSource(). Gates the
            // validity of glSpecializeShader on this object.
            *params = object->isSpirvBinary ? GL_TRUE : GL_FALSE;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getShaderInfoLog(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    copyStringToBuffer(object->compileLog, bufSize, length, infoLog);
    return true;
}

bool GLContext::getShaderSource(GLuint shader, GLsizei bufSize, GLsizei* length, GLchar* source) {
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    copyStringToBuffer(object->source, bufSize, length, source);
    return true;
}

GLuint GLContext::createProgram() {
    // GL 4.6 §7.1 shared shader/program name pool (see createShader).
    const GLuint id = impl_->objects->reserveSharedShaderProgramName();
    impl_->objects->programs().insertAt(id);
    return id;
}

bool GLContext::deleteProgram(GLuint program) {
    if (program == 0) {
        return true;
    }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        // Lenient no-op for unknown program names. Spec (GL 4.6 §7.3) says
        // GL_INVALID_VALUE, but CTS tests (e.g. clip_distance.functional)
        // double-delete program ids and treat error queue leakage as
        // destructor-throws — a single errored delete aborts the entire
        // sweep. NVIDIA's driver is similarly lenient. Applications that
        // legitimately track program names won't hit this path.
        return true;
    }
    object->deleteRequested = true;
    // GL 4.6 §7.3: a program object currently in use is NOT erased
    // immediately. It stays alive (and in use) until it is no longer
    // part of any context's current state. The actual erase happens
    // when the currently-bound program changes (via glUseProgram of a
    // different name, including 0), or when the last program pipeline
    // reference is replaced/deleted.
    //
    // This matters because CTS helper classes (e.g. ClipDistance::
    // Utility::Program, CullDistance::Utility::Program) wrap GL
    // programs in RAII, and their `bool useAsShaderInput(Program ...)`
    // helpers take the Program argument BY VALUE. The copy's
    // destructor runs at call-return while the program is still
    // current — if we erase on delete, the subsequent draw sees
    // programName=N in `state->currentProgram()` but programs().get(N)
    // returns nullptr, the translated-pipeline branch skips, and the
    // draw silently no-ops. CTS's clip_distance.functional and
    // cull_distance.functional_* suites (~400 tests) all trip on
    // this — "vertex unexpectedly clipped" is actually "nothing
    // rendered because no program was bound by draw time."
    //
    // Defer both the state-clear and the object-store erase. When a
    // different program takes over in `useProgram`, that call finishes
    // the deletion for any delete-requested predecessor.
    if (impl_->state->currentProgram() == program ||
        impl_->programPipelineReferencesProgram(program)) {
        // Live — defer actual erase until a different program becomes
        // current and until all program pipeline references are gone.
        return true;
    }
    impl_->finalizeProgramDeletion(program);
    return true;
}

void GLContext::finalizeDeletedProgramIfUnused(GLuint program) {
    impl_->finalizeDeletedProgramIfUnused(program);
}

bool GLContext::isProgram(GLuint program) const {
    return impl_->objects->programs().contains(program);
}

bool GLContext::attachShader(GLuint program, GLuint shader) {
    GLProgramObject* programObject = impl_->objects->programs().get(program);
    GLShaderObject* shaderObject = impl_->objects->shaders().get(shader);
    if (programObject == nullptr || shaderObject == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (std::find(programObject->attachedShaders.begin(), programObject->attachedShaders.end(), shader) !=
        programObject->attachedShaders.end()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    programObject->attachedShaders.push_back(shader);
    // See `GLShaderObject::attachmentCount` in GLObjectStore.h. This counter
    // is the entire reason the deferred-erase path works: it pins the shader
    // object in the store across the (engine-scope) glDeleteShader call so
    // glLinkProgram can still see the compiled SPIR-V and the real
    // compileLog when something fails.
    ++shaderObject->attachmentCount;
    return true;
}

bool GLContext::detachShader(GLuint program, GLuint shader) {
    GLProgramObject* programObject = impl_->objects->programs().get(program);
    if (programObject == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    auto it = std::find(programObject->attachedShaders.begin(), programObject->attachedShaders.end(), shader);
    if (it == programObject->attachedShaders.end()) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    programObject->attachedShaders.erase(it);
    // Mirror the attach-time increment, then perform the deferred erase if
    // both conditions are now met (delete was requested earlier and this was
    // the last live attachment). The shader object pointer must be looked up
    // *before* the potential erase, otherwise the dereference of a stale
    // entry would race with the table mutation.
    GLShaderObject* shaderObject = impl_->objects->shaders().get(shader);
    if (shaderObject != nullptr) {
        if (shaderObject->attachmentCount > 0) {
            --shaderObject->attachmentCount;
        }
        if (shaderObject->deleteRequested && shaderObject->attachmentCount == 0) {
            impl_->objects->shaders().erase(shader);
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_SHADER_LINK)
#include "GLContextShaderLink.inc.mm"

#elif defined(APPGL_GLCONTEXT_SHADER_PROGRAM_QUERY)
#include "GLContextShaderProgramQuery.inc.mm"

#elif defined(APPGL_GLCONTEXT_SHADER_UNIFORMS)
// C52 sampler-resolve cache: integer writes to sampler-typed locations
// remap texture units — the one resolve input no state-domain generation
// covers. Mirrors resolveSamplerBindings' sampler-type classification.
static bool appglUniformTypeIsSampler(GLenum type) {
    switch (type) {
        case GL_SAMPLER_1D: case GL_INT_SAMPLER_1D:
        case GL_UNSIGNED_INT_SAMPLER_1D: case GL_SAMPLER_1D_SHADOW:
        case GL_SAMPLER_2D: case GL_INT_SAMPLER_2D:
        case GL_UNSIGNED_INT_SAMPLER_2D: case GL_SAMPLER_2D_SHADOW:
        case GL_SAMPLER_3D: case GL_INT_SAMPLER_3D:
        case GL_UNSIGNED_INT_SAMPLER_3D:
        case GL_SAMPLER_CUBE: case GL_INT_SAMPLER_CUBE:
        case GL_UNSIGNED_INT_SAMPLER_CUBE: case GL_SAMPLER_CUBE_SHADOW:
        case GL_SAMPLER_1D_ARRAY: case GL_INT_SAMPLER_1D_ARRAY:
        case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY: case GL_SAMPLER_1D_ARRAY_SHADOW:
        case GL_SAMPLER_2D_ARRAY: case GL_INT_SAMPLER_2D_ARRAY:
        case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY: case GL_SAMPLER_2D_ARRAY_SHADOW:
        case GL_SAMPLER_CUBE_MAP_ARRAY: case GL_INT_SAMPLER_CUBE_MAP_ARRAY:
        case GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY:
        case GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW:
        case GL_SAMPLER_2D_RECT: case GL_INT_SAMPLER_2D_RECT:
        case GL_UNSIGNED_INT_SAMPLER_2D_RECT: case GL_SAMPLER_2D_RECT_SHADOW:
        case GL_SAMPLER_BUFFER: case GL_INT_SAMPLER_BUFFER:
        case GL_UNSIGNED_INT_SAMPLER_BUFFER:
        case GL_SAMPLER_2D_MULTISAMPLE: case GL_INT_SAMPLER_2D_MULTISAMPLE:
        case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE:
        case GL_SAMPLER_2D_MULTISAMPLE_ARRAY:
        case GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
        case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
            return true;
        default:
            return false;
    }
}

static bool appglUniformTypeIsBool(GLenum type) {
    switch (type) {
        case GL_BOOL:
        case GL_BOOL_VEC2:
        case GL_BOOL_VEC3:
        case GL_BOOL_VEC4:
            return true;
        default:
            return false;
    }
}

static void writeBoolUniformValues(GLProgramUniformValue& slot,
                                   GLContext::UniformElementType element,
                                   const void* values,
                                   std::size_t writeCount,
                                   std::size_t fullCount,
                                   std::size_t writeOffset) {
    if (slot.ints.size() < fullCount) {
        slot.ints.resize(fullCount, 0);
    }

    for (std::size_t i = 0; i < writeCount; ++i) {
        bool truthy = false;
        switch (element) {
            case GLContext::UniformElementType::Float:
                truthy = static_cast<const GLfloat*>(values)[i] != 0.0f;
                break;
            case GLContext::UniformElementType::Int:
                truthy = static_cast<const GLint*>(values)[i] != 0;
                break;
            case GLContext::UniformElementType::UnsignedInt:
                truthy = static_cast<const GLuint*>(values)[i] != 0u;
                break;
        }
        slot.ints[writeOffset + i] = truthy ? 1 : 0;
    }
    slot.floats.clear();
    slot.uints.clear();
}

bool GLContext::setUniformScalarVector(GLint location, UniformElementType element, GLint vectorSize, GLsizei count, const void* values) {
    if (location < 0) {
        return true;  // -1 silently no-ops per spec.
    }
    if (count < 0 || vectorSize < 1 || vectorSize > 4) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.6 §7.3: glUniform* targets the current program; if no
    // current program but a pipeline is bound, target the pipeline's
    // active-shader-program (set by glActiveShaderProgram). CTS
    // `sepshaderobjs.ProgUniformAPI` exercises this fallback.
    GLuint targetProgram = impl_->state->currentProgram();
    if (targetProgram == 0) {
        const GLuint pipelineName = impl_->state->currentProgramPipeline();
        if (pipelineName != 0) {
            GLProgramPipelineObject* ppo = impl_->objects->programPipelines().get(pipelineName);
            if (ppo != nullptr) {
                targetProgram = ppo->activeShaderProgram;
            }
        }
    }
    GLProgramObject* object = impl_->objects->programs().get(targetProgram);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    UniformSlotRef ref = resolveUniformSlot(object, location);
    if (ref.slot == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramUniformValue* slot = ref.slot;

    if (sampleOrImageUniformValidationFailed(this, ref.type,
            element, vectorSize, values, ref.rejectEsImageUnitUpdate)) {
        return false;
    }

    // Clamp count so writes don't overflow the declared array. GL spec: the
    // effective update is min(count, arraySize - elementIndex).
    const GLint remaining = std::max<GLint>(ref.arraySize - ref.elementIndex, 1);
    const GLsizei effCount = std::min<GLsizei>(std::max<GLsizei>(count, 1), remaining);
    const std::size_t components = static_cast<std::size_t>(vectorSize);
    const std::size_t writeCount = components * static_cast<std::size_t>(effCount);
    const std::size_t fullCount  = components * static_cast<std::size_t>(std::max<GLint>(ref.arraySize, 1));
    const std::size_t writeOffset = components * static_cast<std::size_t>(ref.elementIndex);

    auto writeInto = [&](auto& dstVec, auto& otherA, auto& otherB, const auto* src) {
        using T = typename std::remove_reference<decltype(dstVec)>::type::value_type;
        // Size the destination to hold the full array; preserve existing
        // values where possible so per-element writes don't wipe siblings.
        if (dstVec.size() < fullCount) {
            dstVec.resize(fullCount, T{});
        }
        std::memcpy(dstVec.data() + writeOffset, src, writeCount * sizeof(T));
        otherA.clear();
        otherB.clear();
    };

    // Value-gated (C52 family rule): a value-identical glUniform1i re-issue
    // must not bust the sampler-resolve cache.
    bool samplerUnitChanged = false;
    if (element == UniformElementType::Int && appglUniformTypeIsSampler(ref.type)) {
        const GLint* srcInts = static_cast<const GLint*>(values);
        samplerUnitChanged = slot->ints.size() < fullCount ||
            std::memcmp(slot->ints.data() + writeOffset, srcInts,
                        writeCount * sizeof(GLint)) != 0;
    }
    if (appglUniformTypeIsBool(ref.type)) {
        writeBoolUniformValues(
            *slot, element, values, writeCount, fullCount, writeOffset);
    } else {
        switch (element) {
            case UniformElementType::Float:
                writeInto(slot->floats, slot->ints, slot->uints, static_cast<const GLfloat*>(values));
                break;
            case UniformElementType::Int:
                writeInto(slot->ints, slot->floats, slot->uints, static_cast<const GLint*>(values));
                break;
            case UniformElementType::UnsignedInt:
                writeInto(slot->uints, slot->floats, slot->ints, static_cast<const GLuint*>(values));
                break;
        }
    }
    slot->doubles.clear();
    slot->df64TransportWords.clear();
    if (samplerUnitChanged) {
        ++object->samplerUniformValueGen;
    }
    object->markUniformsDirty();
    return true;
}

bool GLContext::setUniformMatrix(GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLfloat* values) {
    if (location < 0) {
        return true;
    }
    if (count < 0 || rows < 2 || rows > 4 || cols < 2 || cols > 4 || values == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // §7.3 active-shader-program fallback — same as setUniformScalarVector.
    GLuint currentProgram = impl_->state->currentProgram();
    if (currentProgram == 0) {
        const GLuint pipelineName = impl_->state->currentProgramPipeline();
        if (pipelineName != 0) {
            GLProgramPipelineObject* ppo = impl_->objects->programPipelines().get(pipelineName);
            if (ppo != nullptr) currentProgram = ppo->activeShaderProgram;
        }
    }
    GLProgramObject* object = impl_->objects->programs().get(currentProgram);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramUniformValue* slot = lookupUniformValue(object, location);
    if (slot == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const std::size_t elements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols) *
                                 static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    slot->floats.assign(elements, 0.0f);
    if (transpose == GL_FALSE) {
        std::memcpy(slot->floats.data(), values, elements * sizeof(GLfloat));
    } else {
        const std::size_t matrixElements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols);
        for (GLsizei m = 0; m < std::max<GLsizei>(count, 1); ++m) {
            for (GLint r = 0; r < rows; ++r) {
                for (GLint c = 0; c < cols; ++c) {
                    const std::size_t srcIndex = static_cast<std::size_t>(m) * matrixElements +
                                                 static_cast<std::size_t>(r) * static_cast<std::size_t>(cols) +
                                                 static_cast<std::size_t>(c);
                    const std::size_t dstIndex = static_cast<std::size_t>(m) * matrixElements +
                                                 static_cast<std::size_t>(c) * static_cast<std::size_t>(rows) +
                                                 static_cast<std::size_t>(r);
                    slot->floats[dstIndex] = values[srcIndex];
                }
            }
        }
    }
    slot->ints.clear();
    slot->uints.clear();
    slot->doubles.clear();
    slot->df64TransportWords.clear();
    object->markUniformsDirty();
    return true;
}

static void assignDf64TransportWords(GLProgramUniformValue& slot,
                                     const GLdouble* values,
                                     std::size_t count) {
    slot.df64TransportWords.resize(count * 2u);
    for (std::size_t i = 0; i < count; ++i) {
        const auto words =
            extensions::fp64::encodeDoubleToDf64Transport(values[i]);
        slot.df64TransportWords[i * 2u] = words.hi;
        slot.df64TransportWords[i * 2u + 1u] = words.lo;
    }
}

static GLint doubleUniformVectorWidth(GLenum type) {
    switch (type) {
        case GL_DOUBLE:      return 1;
        case GL_DOUBLE_VEC2: return 2;
        case GL_DOUBLE_VEC3: return 3;
        case GL_DOUBLE_VEC4: return 4;
        default:             return 0;
    }
}

static bool doubleUniformMatrixShape(GLenum type, GLint& cols, GLint& rows) {
    switch (type) {
        case GL_DOUBLE_MAT2:   cols = 2; rows = 2; return true;
        case GL_DOUBLE_MAT3:   cols = 3; rows = 3; return true;
        case GL_DOUBLE_MAT4:   cols = 4; rows = 4; return true;
        case GL_DOUBLE_MAT2x3: cols = 2; rows = 3; return true;
        case GL_DOUBLE_MAT3x2: cols = 3; rows = 2; return true;
        case GL_DOUBLE_MAT2x4: cols = 2; rows = 4; return true;
        case GL_DOUBLE_MAT4x2: cols = 4; rows = 2; return true;
        case GL_DOUBLE_MAT3x4: cols = 3; rows = 4; return true;
        case GL_DOUBLE_MAT4x3: cols = 4; rows = 3; return true;
        default: return false;
    }
}

static bool uniformWriteCountFits(const UniformSlotRef& ref, GLsizei count) {
    const GLint remaining = std::max<GLint>(ref.arraySize - ref.elementIndex, 1);
    return count <= remaining;
}

static void writeDoubleUniformSlot(GLProgramUniformValue& slot,
                                   GLint arraySize,
                                   GLint elementIndex,
                                   GLint vectorSize,
                                   GLsizei count,
                                   const GLdouble* values) {
    const GLint remaining = std::max<GLint>(arraySize - elementIndex, 1);
    const GLsizei effCount = std::min<GLsizei>(std::max<GLsizei>(count, 1), remaining);
    const std::size_t components = static_cast<std::size_t>(vectorSize);
    const std::size_t writeCount = components * static_cast<std::size_t>(effCount);
    const std::size_t fullCount = components * static_cast<std::size_t>(std::max<GLint>(arraySize, 1));
    const std::size_t writeOffset = components * static_cast<std::size_t>(elementIndex);

    if (slot.doubles.size() < fullCount) {
        slot.doubles.resize(fullCount, 0.0);
    }
    std::memcpy(slot.doubles.data() + writeOffset, values, writeCount * sizeof(GLdouble));

    slot.floats.resize(fullCount);
    for (std::size_t i = 0; i < fullCount; ++i) {
        slot.floats[i] = static_cast<GLfloat>(slot.doubles[i]);
    }

    assignDf64TransportWords(slot, slot.doubles.data(), slot.doubles.size());
    slot.ints.clear();
    slot.uints.clear();
}

bool GLContext::setUniformDouble(GLint location, GLint vectorSize, GLsizei count, const GLdouble* values) {
    if (location < 0) {
        return true;
    }
    if (count < 0 || vectorSize < 1 || vectorSize > 4 || values == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // §7.3 active-shader-program fallback.
    GLuint currentProgram = impl_->state->currentProgram();
    if (currentProgram == 0) {
        const GLuint pipelineName = impl_->state->currentProgramPipeline();
        if (pipelineName != 0) {
            GLProgramPipelineObject* ppo = impl_->objects->programPipelines().get(pipelineName);
            if (ppo != nullptr) currentProgram = ppo->activeShaderProgram;
        }
    }
    GLProgramObject* object = impl_->objects->programs().get(currentProgram);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    UniformSlotRef ref = resolveUniformSlot(object, location);
    if (ref.slot == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (doubleUniformVectorWidth(ref.type) != vectorSize ||
        !uniformWriteCountFits(ref, count)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    writeDoubleUniformSlot(*ref.slot,
                           ref.arraySize,
                           ref.elementIndex,
                           vectorSize,
                           count,
                           values);
    object->markUniformsDirty();
    return true;
}

bool GLContext::setUniformDoubleMatrix(GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLdouble* values) {
    if (location < 0) {
        return true;
    }
    if (count < 0 || rows < 2 || rows > 4 || cols < 2 || cols > 4 || values == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // §7.3 active-shader-program fallback.
    GLuint currentProgram = impl_->state->currentProgram();
    if (currentProgram == 0) {
        const GLuint pipelineName = impl_->state->currentProgramPipeline();
        if (pipelineName != 0) {
            GLProgramPipelineObject* ppo = impl_->objects->programPipelines().get(pipelineName);
            if (ppo != nullptr) currentProgram = ppo->activeShaderProgram;
        }
    }
    GLProgramObject* object = impl_->objects->programs().get(currentProgram);
    if (object == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    UniformSlotRef ref = resolveUniformSlot(object, location);
    if (ref.slot == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLint expectedCols = 0;
    GLint expectedRows = 0;
    if (!doubleUniformMatrixShape(ref.type, expectedCols, expectedRows) ||
        rows != expectedCols || cols != expectedRows ||
        !uniformWriteCountFits(ref, count)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramUniformValue* slot = ref.slot;
    const GLint remaining = std::max<GLint>(ref.arraySize - ref.elementIndex, 1);
    const GLsizei effCount = std::min<GLsizei>(std::max<GLsizei>(count, 1), remaining);
    const std::size_t matrixElements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols);
    const std::size_t elements = matrixElements * static_cast<std::size_t>(effCount);
    const std::size_t fullCount = matrixElements * static_cast<std::size_t>(std::max<GLint>(ref.arraySize, 1));
    const std::size_t writeOffset = matrixElements * static_cast<std::size_t>(ref.elementIndex);
    if (slot->doubles.size() < fullCount) {
        slot->doubles.resize(fullCount, 0.0);
    }
    if (transpose == GL_FALSE) {
        for (std::size_t i = 0; i < elements; ++i) {
            slot->doubles[writeOffset + i] = values[i];
        }
    } else {
        for (GLsizei m = 0; m < effCount; ++m) {
            for (GLint r = 0; r < rows; ++r) {
                for (GLint c = 0; c < cols; ++c) {
                    const std::size_t srcIndex = static_cast<std::size_t>(m) * matrixElements +
                                                 static_cast<std::size_t>(r) * static_cast<std::size_t>(cols) +
                                                 static_cast<std::size_t>(c);
                    const std::size_t dstIndex = writeOffset + static_cast<std::size_t>(m) * matrixElements +
                                                 static_cast<std::size_t>(c) * static_cast<std::size_t>(rows) +
                                                 static_cast<std::size_t>(r);
                    slot->doubles[dstIndex] = values[srcIndex];
                }
            }
        }
    }
    slot->floats.resize(fullCount);
    for (std::size_t i = 0; i < fullCount; ++i) {
        slot->floats[i] = static_cast<GLfloat>(slot->doubles[i]);
    }
    assignDf64TransportWords(*slot, slot->doubles.data(), slot->doubles.size());
    slot->ints.clear();
    slot->uints.clear();
    object->markUniformsDirty();
    return true;
}

// --- GL 4.1: glProgramUniform* family — explicit program handle variants ---

GLProgramObject* GLContext::validateProgramUniformTarget(GLuint program) {
    auto pushTargetError = [&](GLenum error) {
        if (std::find(impl_->errors.begin(), impl_->errors.end(), error) ==
            impl_->errors.end()) {
            pushError(error);
        }
    };
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || object->deleteRequested) {
        pushTargetError(GL_INVALID_VALUE);
        return nullptr;
    }
    if (!object->linked) {
        pushTargetError(GL_INVALID_OPERATION);
        return nullptr;
    }
    return object;
}

bool GLContext::setUniformScalarVectorForProgram(GLuint program, GLint location, UniformElementType element, GLint vectorSize, GLsizei count, const void* values) {
    // GL 4.6 §7.6.1 — error codes for glProgramUniform*. Validate the
    // PROGRAM argument BEFORE checking location, because "not a valid
    // program" and "not linked" fire regardless of location (including
    // location=-1 which would otherwise be a silent no-op).
    //   - program not a program name returned from glCreateProgram → INVALID_VALUE
    //   - program marked for deletion → INVALID_VALUE
    //   - program not linked → INVALID_OPERATION
    // CTS `sepshaderobjs.ProgUniformAPI` exercises both paths with a
    // cached location=-1 from an unlinked-program glGetUniformLocation.
    GLProgramObject* object = validateProgramUniformTarget(program);
    if (object == nullptr) return false;
    if (location < 0) return true;
    if (count < 0 || vectorSize < 1 || vectorSize > 4) { pushError(GL_INVALID_VALUE); return false; }
    UniformSlotRef ref = resolveUniformSlot(object, location);
    if (ref.slot == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    if (sampleOrImageUniformValidationFailed(this, ref.type,
            element, vectorSize, values, ref.rejectEsImageUnitUpdate)) {
        return false;
    }
    GLProgramUniformValue* slot = ref.slot;
    const GLint remaining = std::max<GLint>(ref.arraySize - ref.elementIndex, 1);
    const GLsizei effCount = std::min<GLsizei>(std::max<GLsizei>(count, 1), remaining);
    const std::size_t components = static_cast<std::size_t>(vectorSize);
    const std::size_t writeCount = components * static_cast<std::size_t>(effCount);
    const std::size_t fullCount  = components * static_cast<std::size_t>(std::max<GLint>(ref.arraySize, 1));
    const std::size_t writeOffset = components * static_cast<std::size_t>(ref.elementIndex);
    auto writeInto = [&](auto& dstVec, auto& otherA, auto& otherB, const auto* src) {
        using T = typename std::remove_reference<decltype(dstVec)>::type::value_type;
        if (dstVec.size() < fullCount) dstVec.resize(fullCount, T{});
        std::memcpy(dstVec.data() + writeOffset, src, writeCount * sizeof(T));
        otherA.clear(); otherB.clear();
    };
    // Value-gated (C52 family rule): a value-identical glUniform1i re-issue
    // must not bust the sampler-resolve cache.
    bool samplerUnitChanged = false;
    if (element == UniformElementType::Int && appglUniformTypeIsSampler(ref.type)) {
        const GLint* srcInts = static_cast<const GLint*>(values);
        samplerUnitChanged = slot->ints.size() < fullCount ||
            std::memcmp(slot->ints.data() + writeOffset, srcInts,
                        writeCount * sizeof(GLint)) != 0;
    }
    if (appglUniformTypeIsBool(ref.type)) {
        writeBoolUniformValues(
            *slot, element, values, writeCount, fullCount, writeOffset);
    } else {
        switch (element) {
            case UniformElementType::Float:
                writeInto(slot->floats, slot->ints, slot->uints, static_cast<const GLfloat*>(values)); break;
            case UniformElementType::Int:
                writeInto(slot->ints, slot->floats, slot->uints, static_cast<const GLint*>(values)); break;
            case UniformElementType::UnsignedInt:
                writeInto(slot->uints, slot->floats, slot->ints, static_cast<const GLuint*>(values)); break;
        }
    }
    slot->doubles.clear();
    slot->df64TransportWords.clear();
    if (samplerUnitChanged) {
        ++object->samplerUniformValueGen;
    }
    object->markUniformsDirty();
    return true;
}

bool GLContext::setUniformMatrixForProgram(GLuint program, GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLfloat* values) {
    GLProgramObject* object = validateProgramUniformTarget(program);
    if (object == nullptr) return false;
    if (location < 0) return true;
    if (count < 0 || rows < 2 || rows > 4 || cols < 2 || cols > 4 || values == nullptr) { pushError(GL_INVALID_VALUE); return false; }
    GLProgramUniformValue* slot = lookupUniformValue(object, location);
    if (slot == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    const std::size_t elements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols) * static_cast<std::size_t>(std::max<GLsizei>(count, 1));
    slot->floats.assign(elements, 0.0f);
    if (transpose == GL_FALSE) {
        std::memcpy(slot->floats.data(), values, elements * sizeof(GLfloat));
    } else {
        const std::size_t matrixElements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols);
        for (GLsizei m = 0; m < std::max<GLsizei>(count, 1); ++m) {
            for (GLint r = 0; r < rows; ++r) {
                for (GLint c = 0; c < cols; ++c) {
                    const std::size_t srcIndex = static_cast<std::size_t>(m) * matrixElements + static_cast<std::size_t>(r) * static_cast<std::size_t>(cols) + static_cast<std::size_t>(c);
                    const std::size_t dstIndex = static_cast<std::size_t>(m) * matrixElements + static_cast<std::size_t>(c) * static_cast<std::size_t>(rows) + static_cast<std::size_t>(r);
                    slot->floats[dstIndex] = values[srcIndex];
                }
            }
        }
    }
    slot->ints.clear(); slot->uints.clear();
    slot->doubles.clear(); slot->df64TransportWords.clear();
    object->markUniformsDirty();
    return true;
}

bool GLContext::setUniformDoubleForProgram(GLuint program, GLint location, GLint vectorSize, GLsizei count, const GLdouble* values) {
    GLProgramObject* object = validateProgramUniformTarget(program);
    if (object == nullptr) return false;
    if (location < 0) return true;
    if (count < 0 || vectorSize < 1 || vectorSize > 4 || values == nullptr) { pushError(GL_INVALID_VALUE); return false; }
    UniformSlotRef ref = resolveUniformSlot(object, location);
    if (ref.slot == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    if (doubleUniformVectorWidth(ref.type) != vectorSize ||
        !uniformWriteCountFits(ref, count)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    writeDoubleUniformSlot(*ref.slot,
                           ref.arraySize,
                           ref.elementIndex,
                           vectorSize,
                           count,
                           values);
    object->markUniformsDirty();
    return true;
}

bool GLContext::setUniformDoubleMatrixForProgram(GLuint program, GLint location, GLint rows, GLint cols, GLsizei count, GLboolean transpose, const GLdouble* values) {
    GLProgramObject* object = validateProgramUniformTarget(program);
    if (object == nullptr) return false;
    if (location < 0) return true;
    if (count < 0 || rows < 2 || rows > 4 || cols < 2 || cols > 4 || values == nullptr) { pushError(GL_INVALID_VALUE); return false; }
    UniformSlotRef ref = resolveUniformSlot(object, location);
    if (ref.slot == nullptr) { pushError(GL_INVALID_OPERATION); return false; }
    GLint expectedCols = 0;
    GLint expectedRows = 0;
    if (!doubleUniformMatrixShape(ref.type, expectedCols, expectedRows) ||
        rows != expectedCols || cols != expectedRows ||
        !uniformWriteCountFits(ref, count)) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramUniformValue* slot = ref.slot;
    const GLint remaining = std::max<GLint>(ref.arraySize - ref.elementIndex, 1);
    const GLsizei effCount = std::min<GLsizei>(std::max<GLsizei>(count, 1), remaining);
    const std::size_t matrixElements = static_cast<std::size_t>(rows) * static_cast<std::size_t>(cols);
    const std::size_t elements = matrixElements * static_cast<std::size_t>(effCount);
    const std::size_t fullCount = matrixElements * static_cast<std::size_t>(std::max<GLint>(ref.arraySize, 1));
    const std::size_t writeOffset = matrixElements * static_cast<std::size_t>(ref.elementIndex);
    if (slot->doubles.size() < fullCount) {
        slot->doubles.resize(fullCount, 0.0);
    }
    if (transpose == GL_FALSE) {
        for (std::size_t i = 0; i < elements; ++i) { slot->doubles[writeOffset + i] = values[i]; }
    } else {
        for (GLsizei m = 0; m < effCount; ++m) {
            for (GLint r = 0; r < rows; ++r) {
                for (GLint c = 0; c < cols; ++c) {
                    const std::size_t srcIndex = static_cast<std::size_t>(m) * matrixElements + static_cast<std::size_t>(r) * static_cast<std::size_t>(cols) + static_cast<std::size_t>(c);
                    const std::size_t dstIndex = writeOffset + static_cast<std::size_t>(m) * matrixElements + static_cast<std::size_t>(c) * static_cast<std::size_t>(rows) + static_cast<std::size_t>(r);
                    slot->doubles[dstIndex] = values[srcIndex];
                }
            }
        }
    }
    slot->floats.resize(fullCount);
    for (std::size_t i = 0; i < fullCount; ++i) { slot->floats[i] = static_cast<GLfloat>(slot->doubles[i]); }
    assignDf64TransportWords(*slot, slot->doubles.data(), slot->doubles.size());
    slot->ints.clear(); slot->uints.clear();
    object->markUniformsDirty();
    return true;
}

bool GLContext::getUniformdv(GLuint program, GLint location, GLdouble* params) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    UniformSlotRef ref = resolveUniformSlot(object, location);
    if (ref.slot == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramUniformValue* value = ref.slot;
    const std::size_t components = uniformTypeComponentCount(ref.type ? ref.type : value->type);
    const std::size_t offset = static_cast<std::size_t>(ref.elementIndex) * components;
    // Prefer the lossless double shadow if available.
    if (!value->doubles.empty()) {
        const std::size_t avail = value->doubles.size() > offset
            ? std::min(components, value->doubles.size() - offset) : 0;
        if (avail > 0) {
            std::memcpy(params, value->doubles.data() + offset, avail * sizeof(GLdouble));
        }
    } else if (!value->floats.empty()) {
        const std::size_t avail = value->floats.size() > offset
            ? std::min(components, value->floats.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = static_cast<GLdouble>(value->floats[offset + i]);
        }
    } else if (!value->ints.empty()) {
        const std::size_t avail = value->ints.size() > offset
            ? std::min(components, value->ints.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = static_cast<GLdouble>(value->ints[offset + i]);
        }
    } else if (!value->uints.empty()) {
        const std::size_t avail = value->uints.size() > offset
            ? std::min(components, value->uints.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = static_cast<GLdouble>(value->uints[offset + i]);
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_SHADER_ATOMIC_COUNTERS)
bool GLContext::getActiveAtomicCounterBufferiv(GLuint program, GLuint bufferIndex, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (bufferIndex >= object->resourceAtomicCounterBuffers.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLProgramResourceEntry& entry =
        object->resourceAtomicCounterBuffers[bufferIndex];
    switch (pname) {
        case GL_ATOMIC_COUNTER_BUFFER_BINDING:
            *params = entry.binding;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_DATA_SIZE:
            *params = entry.offset >= 0 ? entry.offset : 0;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_ACTIVE_ATOMIC_COUNTERS:
            *params = static_cast<GLint>(entry.activeVariables.size());
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_ACTIVE_ATOMIC_COUNTER_INDICES:
            for (std::size_t i = 0; i < entry.activeVariables.size(); ++i) {
                params[i] = entry.activeVariables[i];
            }
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_VERTEX_SHADER:
            *params = (entry.referencedBy & 0x01) ? GL_TRUE : GL_FALSE;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_FRAGMENT_SHADER:
            *params = (entry.referencedBy & 0x02) ? GL_TRUE : GL_FALSE;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_GEOMETRY_SHADER:
            *params = (entry.referencedBy & 0x04) ? GL_TRUE : GL_FALSE;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_TESS_CONTROL_SHADER:
            *params = (entry.referencedBy & 0x08) ? GL_TRUE : GL_FALSE;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_TESS_EVALUATION_SHADER:
            *params = (entry.referencedBy & 0x10) ? GL_TRUE : GL_FALSE;
            return true;
        case GL_ATOMIC_COUNTER_BUFFER_REFERENCED_BY_COMPUTE_SHADER:
            *params = (entry.referencedBy & 0x20) ? GL_TRUE : GL_FALSE;
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

#elif defined(APPGL_GLCONTEXT_SHADER_RESOURCE_QUERY)
bool GLContext::getProgramInterfaceiv(GLuint program, GLenum programInterface, GLenum pname, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr) {
        // GL 4.6 §7.3.1: shader-name → INVALID_OPERATION,
        // other bogus names → INVALID_VALUE. See
        // getProgramResourceIndex for the same distinguishing
        // logic. Required by CTS
        // `program_interface_query.invalid-operation` Case 1.
        if (impl_->objects->shaders().contains(program)) {
            pushError(GL_INVALID_OPERATION);
        } else {
            pushError(GL_INVALID_VALUE);
        }
        return false;
    }
    // CTS program_interface_query.empty-shaders constructs a program
    // with no shaders attached, never links it, and queries every
    // interface — expecting ACTIVE_RESOURCES=0 and MAX_NAME_LENGTH=0
    // without an error. A strict GL_INVALID_OPERATION on unlinked
    // programs makes 39/43 of program_interface_query fail; instead
    // the empty-program path returns 0 for numeric pnames and still
    // rejects unknown pnames with INVALID_ENUM. Linked programs go
    // through the normal resource-table path.
    const bool isLinked = prog->linked;
    const auto* table = isLinked ? getResourceTable(*prog, programInterface) : nullptr;
    // Validate programInterface enum even if not linked (unknown
    // interfaces should still raise INVALID_ENUM). The accepted set
    // mirrors getResourceTable.
    if (!isLinked) {
        switch (programInterface) {
            case GL_UNIFORM:
            case GL_UNIFORM_BLOCK:
            case GL_PROGRAM_INPUT:
            case GL_PROGRAM_OUTPUT:
            case GL_SHADER_STORAGE_BLOCK:
            case GL_ATOMIC_COUNTER_BUFFER:
            case GL_BUFFER_VARIABLE:
            case GL_TRANSFORM_FEEDBACK_VARYING:
            case GL_TRANSFORM_FEEDBACK_BUFFER:
            case GL_VERTEX_SUBROUTINE:
            case GL_TESS_CONTROL_SUBROUTINE:
            case GL_TESS_EVALUATION_SUBROUTINE:
            case GL_GEOMETRY_SUBROUTINE:
            case GL_FRAGMENT_SUBROUTINE:
            case GL_COMPUTE_SUBROUTINE:
            case GL_VERTEX_SUBROUTINE_UNIFORM:
            case GL_TESS_CONTROL_SUBROUTINE_UNIFORM:
            case GL_TESS_EVALUATION_SUBROUTINE_UNIFORM:
            case GL_GEOMETRY_SUBROUTINE_UNIFORM:
            case GL_FRAGMENT_SUBROUTINE_UNIFORM:
            case GL_COMPUTE_SUBROUTINE_UNIFORM:
                break;
            default:
                pushError(GL_INVALID_ENUM);
                return false;
        }
    } else if (table == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    switch (pname) {
        case GL_ACTIVE_RESOURCES:
            *params = isLinked ? static_cast<GLint>(table->size()) : 0;
            return true;
        case GL_MAX_NAME_LENGTH: {
            if (!isLinked) {
                *params = 0;
                return true;
            }
            GLint maxLen = 0;
            for (const auto& entry : *table) {
                GLint len = static_cast<GLint>(entry.name.size() + 1);
                if (len > maxLen) maxLen = len;
            }
            *params = maxLen;
            return true;
        }
        case GL_MAX_NUM_ACTIVE_VARIABLES:
            // GL 4.6 §7.3.1 table: this pname is only valid on
            // the interfaces that expose an active-variables
            // list (UNIFORM_BLOCK, ATOMIC_COUNTER_BUFFER,
            // SHADER_STORAGE_BLOCK, TRANSFORM_FEEDBACK_BUFFER).
            // CTS `program_interface_query.invalid-operation`
            // passes GL_PROGRAM_INPUT and expects
            // INVALID_OPERATION. Value is max of activeVariables
            // counts across all block entries on the interface.
            switch (programInterface) {
                case GL_UNIFORM_BLOCK:
                case GL_ATOMIC_COUNTER_BUFFER:
                case GL_SHADER_STORAGE_BLOCK:
                case GL_TRANSFORM_FEEDBACK_BUFFER: {
                    GLint maxN = 0;
                    if (table != nullptr) {
                        for (const auto& entry : *table) {
                            GLint n = static_cast<GLint>(entry.activeVariables.size());
                            if (n > maxN) maxN = n;
                        }
                    }
                    *params = maxN;
                    return true;
                }
                default:
                    pushError(GL_INVALID_OPERATION);
                    return false;
            }
        case GL_MAX_NUM_COMPATIBLE_SUBROUTINES:
            // GL 4.6 §7.3.1: only valid on the *_SUBROUTINE_UNIFORM
            // interfaces. Value = max(count of compatible subroutines
            // across all subroutine uniforms on this interface).
            switch (programInterface) {
                case GL_VERTEX_SUBROUTINE_UNIFORM:
                case GL_TESS_CONTROL_SUBROUTINE_UNIFORM:
                case GL_TESS_EVALUATION_SUBROUTINE_UNIFORM:
                case GL_GEOMETRY_SUBROUTINE_UNIFORM:
                case GL_FRAGMENT_SUBROUTINE_UNIFORM:
                case GL_COMPUTE_SUBROUTINE_UNIFORM: {
                    GLint maxN = 0;
                    if (table != nullptr) {
                        for (const auto& e : *table) {
                            GLint n = static_cast<GLint>(e.activeVariables.size());
                            if (n > maxN) maxN = n;
                        }
                    }
                    *params = maxN;
                    return true;
                }
                default:
                    pushError(GL_INVALID_OPERATION);
                    return false;
            }
        default:
            pushError(isLinked ? GL_INVALID_OPERATION : GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getProgramResourceiv(GLuint program, GLenum programInterface, GLuint index, GLsizei propCount, const GLenum* props, GLsizei count, GLsizei* length, GLint* params) {
    // Always defensively-zero the caller's length output first. CTS tests
    // (e.g. program_interface_query.subroutines-vertex) declare
    // `GLsizei length` uninitialized on the stack, call us with the
    // address, and then use `length` as a for-loop bound — if we return
    // without writing it, the loop runs against stack garbage and reads
    // past the end of its `param[1000]` buffer, producing a deterministic
    // SIGBUS once the stack happens to carry a large value at that offset
    // (observed at test #12648 of a full CTS sweep).
    if (length != nullptr) {
        *length = 0;
    }
    // GL 4.6 §7.3.1: propCount > 0 is required; propCount <= 0 is
    // INVALID_VALUE. But `count` (bufSize) of 0 or a NULL `params`
    // is valid — "no data is written." CTS
    // `program_interface_query.buff-length` calls with count=0 and
    // expects no error + no writes (we'd previously push
    // INVALID_VALUE and scribble `length` = 0 which is itself fine).
    if (propCount <= 0 || props == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // `count` < 0 is explicitly invalid per §7.3.1. CTS
    // `program_interface_query.invalid-value` passes -100 and expects
    // INVALID_VALUE.
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr) {
        // Shader-name-vs-unknown-name: same rule as
        // getProgramResourceIndex.
        if (impl_->objects->shaders().contains(program)) {
            pushError(GL_INVALID_OPERATION);
        } else {
            pushError(GL_INVALID_VALUE);
        }
        return false;
    }
    if (!prog->linked) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const auto* table = getResourceTable(*prog, programInterface);
    if (table == nullptr) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    // GL 4.6 §7.3.1 lists the valid prop enums for
    // getProgramResourceiv. Anything outside this set yields
    // GL_INVALID_ENUM. CTS `program_interface_query.invalid-enum`
    // passes `GL_TEXTURE_1D` as a prop and expects the error.
    auto isValidProp = [](GLenum p) {
        switch (p) {
            case GL_ACTIVE_VARIABLES:
            case GL_BUFFER_BINDING:
            case GL_BUFFER_DATA_SIZE:
            case GL_NUM_ACTIVE_VARIABLES:
            case GL_ARRAY_SIZE:
            case GL_ARRAY_STRIDE:
            case GL_BLOCK_INDEX:
            case GL_IS_ROW_MAJOR:
            case GL_MATRIX_STRIDE:
            case GL_ATOMIC_COUNTER_BUFFER_INDEX:
            case GL_NUM_COMPATIBLE_SUBROUTINES:
            case GL_COMPATIBLE_SUBROUTINES:
            case GL_IS_PER_PATCH:
            case GL_LOCATION:
            case GL_LOCATION_COMPONENT:
            case GL_LOCATION_INDEX:
            case GL_NAME_LENGTH:
            case GL_OFFSET:
            case GL_REFERENCED_BY_VERTEX_SHADER:
            case GL_REFERENCED_BY_TESS_CONTROL_SHADER:
            case GL_REFERENCED_BY_TESS_EVALUATION_SHADER:
            case GL_REFERENCED_BY_GEOMETRY_SHADER:
            case GL_REFERENCED_BY_FRAGMENT_SHADER:
            case GL_REFERENCED_BY_COMPUTE_SHADER:
            case GL_TOP_LEVEL_ARRAY_SIZE:
            case GL_TOP_LEVEL_ARRAY_STRIDE:
            case GL_TRANSFORM_FEEDBACK_BUFFER_INDEX:
            case GL_TRANSFORM_FEEDBACK_BUFFER_STRIDE:
            case GL_TYPE:
                return true;
            default:
                return false;
        }
    };
    for (GLsizei i = 0; i < propCount; ++i) {
        if (!isValidProp(props[i])) {
            pushError(GL_INVALID_ENUM);
            return false;
        }
    }
    // GL 4.6 §7.3.1 table: each prop is only valid on a subset of
    // interfaces. Using a prop that doesn't apply to the queried
    // interface yields INVALID_OPERATION. Only the most common
    // incompatibilities are enforced here; the full matrix would
    // add ~30 cases. CTS
    // `program_interface_query.invalid-operation` Case 3 passes
    // GL_OFFSET to GL_PROGRAM_INPUT — spec says that's an
    // INVALID_OPERATION.
    auto propInterfaceCompatible = [](GLenum prop, GLenum iface) {
        switch (prop) {
            case GL_OFFSET:
            case GL_BLOCK_INDEX:
            case GL_ARRAY_STRIDE:
            case GL_MATRIX_STRIDE:
            case GL_IS_ROW_MAJOR:
            case GL_ATOMIC_COUNTER_BUFFER_INDEX:
                return iface == GL_UNIFORM || iface == GL_BUFFER_VARIABLE
                    || iface == GL_TRANSFORM_FEEDBACK_VARYING;
            case GL_TOP_LEVEL_ARRAY_SIZE:
            case GL_TOP_LEVEL_ARRAY_STRIDE:
                return iface == GL_BUFFER_VARIABLE;
            case GL_BUFFER_BINDING:
            case GL_BUFFER_DATA_SIZE:
            case GL_NUM_ACTIVE_VARIABLES:
            case GL_ACTIVE_VARIABLES:
                return iface == GL_UNIFORM_BLOCK
                    || iface == GL_ATOMIC_COUNTER_BUFFER
                    || iface == GL_SHADER_STORAGE_BLOCK
                    || iface == GL_TRANSFORM_FEEDBACK_BUFFER;
            case GL_TRANSFORM_FEEDBACK_BUFFER_INDEX:
            case GL_TRANSFORM_FEEDBACK_BUFFER_STRIDE:
                return iface == GL_TRANSFORM_FEEDBACK_VARYING
                    || iface == GL_TRANSFORM_FEEDBACK_BUFFER;
            case GL_LOCATION_INDEX:
                return iface == GL_PROGRAM_OUTPUT;
            case GL_IS_PER_PATCH:
                return iface == GL_PROGRAM_INPUT || iface == GL_PROGRAM_OUTPUT;
            case GL_LOCATION:
            case GL_LOCATION_COMPONENT:
                return iface == GL_UNIFORM
                    || iface == GL_PROGRAM_INPUT
                    || iface == GL_PROGRAM_OUTPUT
                    || iface == GL_VERTEX_SUBROUTINE_UNIFORM
                    || iface == GL_TESS_CONTROL_SUBROUTINE_UNIFORM
                    || iface == GL_TESS_EVALUATION_SUBROUTINE_UNIFORM
                    || iface == GL_GEOMETRY_SUBROUTINE_UNIFORM
                    || iface == GL_FRAGMENT_SUBROUTINE_UNIFORM
                    || iface == GL_COMPUTE_SUBROUTINE_UNIFORM;
            case GL_NUM_COMPATIBLE_SUBROUTINES:
            case GL_COMPATIBLE_SUBROUTINES:
                return iface == GL_VERTEX_SUBROUTINE_UNIFORM
                    || iface == GL_TESS_CONTROL_SUBROUTINE_UNIFORM
                    || iface == GL_TESS_EVALUATION_SUBROUTINE_UNIFORM
                    || iface == GL_GEOMETRY_SUBROUTINE_UNIFORM
                    || iface == GL_FRAGMENT_SUBROUTINE_UNIFORM
                    || iface == GL_COMPUTE_SUBROUTINE_UNIFORM;
            default:
                // GL_NAME_LENGTH / GL_TYPE / GL_ARRAY_SIZE /
                // GL_REFERENCED_BY_* apply broadly — accept.
                return true;
        }
    };
    for (GLsizei i = 0; i < propCount; ++i) {
        if (!propInterfaceCompatible(props[i], programInterface)) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    if (index >= table->size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const auto& entry = (*table)[index];
    GLsizei written = 0;
    if (params != nullptr) {
        for (GLsizei i = 0; i < propCount && written < count; ++i) {
            // GL 4.6 §7.3.1: GL_ACTIVE_VARIABLES and
            // GL_COMPATIBLE_SUBROUTINES both write an ARRAY of
            // integers — the next NUM_ACTIVE_VARIABLES (or
            // NUM_COMPATIBLE_SUBROUTINES) slots, one per active
            // member. Every other prop writes a single integer.
            // CTS `program_interface_query.atomic-counters` reads
            // NUM_ACTIVE_VARIABLES via a separate call, then
            // reads the full ACTIVE_VARIABLES list with bufSize
            // large enough to hold all N entries; we must write
            // them all, not just the first.
            if (props[i] == GL_ACTIVE_VARIABLES ||
                props[i] == GL_COMPATIBLE_SUBROUTINES) {
                // GL_COMPATIBLE_SUBROUTINES uses the same
                // activeVariables vector on subroutine-uniform entries,
                // so share the multi-value path.
                for (GLint idx : entry.activeVariables) {
                    if (written >= count) break;
                    params[written++] = idx;
                }
                continue;
            }
            params[written++] = getResourceProperty(entry, props[i]);
        }
    }
    if (length != nullptr) {
        *length = written;
    }
    return true;
}

bool GLContext::getProgramResourceName(GLuint program, GLenum programInterface, GLuint index, GLsizei bufSize, GLsizei* length, GLchar* name) {
    // Defensively zero length first (see getProgramResourceiv for rationale).
    if (length != nullptr) {
        *length = 0;
    }
    // GL 4.6 §7.3.1: `bufSize` < 0 is invalid. CTS
    // `program_interface_query.invalid-value` passes -100 and expects
    // INVALID_VALUE.
    if (bufSize < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.6 §7.3.1: `GL_ATOMIC_COUNTER_BUFFER` /
    // `GL_TRANSFORM_FEEDBACK_BUFFER` buffers carry no names; queries
    // generate INVALID_ENUM.
    if (programInterface == GL_ATOMIC_COUNTER_BUFFER ||
        programInterface == GL_TRANSFORM_FEEDBACK_BUFFER) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr) {
        if (impl_->objects->shaders().contains(program)) {
            pushError(GL_INVALID_OPERATION);
        } else {
            pushError(GL_INVALID_VALUE);
        }
        return false;
    }
    if (!prog->linked) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const auto* table = getResourceTable(*prog, programInterface);
    if (table == nullptr) {
        pushError(GL_INVALID_ENUM);
        return false;
    }
    if (index >= table->size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const auto& entry = (*table)[index];
    if (name != nullptr && bufSize > 0) {
        std::size_t toCopy = std::min(static_cast<std::size_t>(bufSize - 1), entry.name.size());
        std::memcpy(name, entry.name.c_str(), toCopy);
        name[toCopy] = '\0';
        if (length != nullptr) {
            *length = static_cast<GLsizei>(toCopy);
        }
    } else if (length != nullptr) {
        *length = 0;
    }
    return true;
}

GLuint GLContext::getProgramResourceIndex(GLuint program, GLenum programInterface, const GLchar* name) {
    if (name == nullptr) {
        return GL_INVALID_INDEX;
    }
    // GL 4.6 §7.3.1: `GL_ATOMIC_COUNTER_BUFFER` buffers have no
    // names, so this entry point is invalid on that interface.
    // `GL_TRANSFORM_FEEDBACK_BUFFER` is similarly unnamed.
    if (programInterface == GL_ATOMIC_COUNTER_BUFFER ||
        programInterface == GL_TRANSFORM_FEEDBACK_BUFFER) {
        pushError(GL_INVALID_ENUM);
        return GL_INVALID_INDEX;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr) {
        // GL 4.6 §7.3.1 differentiates "name refers to a shader
        // object (INVALID_OPERATION)" from "name is not a generated
        // program name (INVALID_VALUE)". Distinguish here by
        // checking the shader table. CTS
        // `program_interface_query.invalid-operation` calls these
        // entry points with a shader name and expects the specific
        // INVALID_OPERATION error.
        if (impl_->objects->shaders().contains(program)) {
            pushError(GL_INVALID_OPERATION);
        } else {
            pushError(GL_INVALID_VALUE);
        }
        return GL_INVALID_INDEX;
    }
    // Unlinked program: silently return INVALID_INDEX (no match).
    // CTS empty-shaders queries resource indices on an unlinked
    // program and asserts no error is raised; strict
    // INVALID_OPERATION makes that subcase fail.
    if (!prog->linked) {
        return GL_INVALID_INDEX;
    }
    const auto* table = getResourceTable(*prog, programInterface);
    if (table == nullptr) {
        pushError(GL_INVALID_ENUM);
        return GL_INVALID_INDEX;
    }
    // GL 4.6 §7.3.1.1: `glGetProgramResourceIndex` cannot be used to
    // retrieve the index of the built-in transform-feedback markers
    // (`gl_NextBuffer` / `gl_SkipComponentsN`). They still appear in
    // the resource table and can be walked by index via
    // `glGetProgramResourceName`, but lookup-by-name returns
    // INVALID_INDEX. CTS
    // `program_interface_query.transform-feedback-built-in` verifies.
    if (programInterface == GL_TRANSFORM_FEEDBACK_VARYING) {
        const std::string q = name;
        if (q == "gl_NextBuffer" ||
            (q.size() == 18 && q.compare(0, 17, "gl_SkipComponents") == 0)) {
            return GL_INVALID_INDEX;
        }
    }
    for (std::size_t i = 0; i < table->size(); ++i) {
        if ((*table)[i].name == name) {
            if (isSubroutineResourceInterface(programInterface) &&
                (*table)[i].subroutineIndex >= 0) {
                return static_cast<GLuint>((*table)[i].subroutineIndex);
            }
            return static_cast<GLuint>(i);
        }
    }
    // Array-input lookup tolerance: GL 4.6 §7.3.1 says
    // getProgramResourceIndex("arr") should find the same entry as
    // "arr[0]" for an array input, and vice versa. Table entries
    // follow the "[0]"-suffixed convention for arrays
    // (`c` → "c[0]"); queries with bare base name should still
    // match. CTS `program_interface_query.input-types` queries
    // "d" where the table stores "d[0]".
    const std::string query = name;
    // Bare query → find a "<name>[0]" entry.
    {
        const std::string suffixed = query + "[0]";
        for (std::size_t i = 0; i < table->size(); ++i) {
            if ((*table)[i].name == suffixed &&
                (*table)[i].arrayDimensions.empty()) {
                if (isSubroutineResourceInterface(programInterface) &&
                    (*table)[i].subroutineIndex >= 0) {
                    return static_cast<GLuint>((*table)[i].subroutineIndex);
                }
                return static_cast<GLuint>(i);
            }
        }
    }
    // "<base>[0]"-suffixed query → find a bare "<base>" entry.
    if (query.size() >= 3 && query.compare(query.size() - 3, 3, "[0]") == 0) {
        const std::string baseOnly = query.substr(0, query.size() - 3);
        for (std::size_t i = 0; i < table->size(); ++i) {
            if ((*table)[i].name == baseOnly) {
                if (isSubroutineResourceInterface(programInterface) &&
                    (*table)[i].subroutineIndex >= 0) {
                    return static_cast<GLuint>((*table)[i].subroutineIndex);
                }
                return static_cast<GLuint>(i);
            }
        }
    }
    return GL_INVALID_INDEX;
}

GLint GLContext::getProgramResourceLocation(GLuint program, GLenum programInterface, const GLchar* name) {
    if (name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return -1;
    }
    // GL 4.6 §7.3.1 valid interfaces: UNIFORM, PROGRAM_INPUT,
    // PROGRAM_OUTPUT, and the six *_SUBROUTINE_UNIFORM interfaces.
    // The last set lets CTS `subroutines-*` query the subroutine
    // uniform's location via `glGetProgramResourceLocation` (same
    // value `glGetSubroutineUniformLocation` returns).
    if (programInterface != GL_UNIFORM && programInterface != GL_PROGRAM_INPUT &&
        programInterface != GL_PROGRAM_OUTPUT &&
        programInterface != GL_VERTEX_SUBROUTINE_UNIFORM &&
        programInterface != GL_TESS_CONTROL_SUBROUTINE_UNIFORM &&
        programInterface != GL_TESS_EVALUATION_SUBROUTINE_UNIFORM &&
        programInterface != GL_GEOMETRY_SUBROUTINE_UNIFORM &&
        programInterface != GL_FRAGMENT_SUBROUTINE_UNIFORM &&
        programInterface != GL_COMPUTE_SUBROUTINE_UNIFORM) {
        pushError(GL_INVALID_ENUM);
        return -1;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr) {
        if (impl_->objects->shaders().contains(program)) {
            pushError(GL_INVALID_OPERATION);
        } else {
            pushError(GL_INVALID_VALUE);
        }
        return -1;
    }
    if (!prog->linked) {
        pushError(GL_INVALID_OPERATION);
        return -1;
    }
    const auto* table = getResourceTable(*prog, programInterface);
    if (table == nullptr) {
        return -1;
    }
    const std::string lookup = name;
    // Direct match — but skip entries with location=-1. SPIRV-Cross
    // reflection sometimes emits both "u0" (the real base with valid
    // location) and "u0[0]" (a per-element duplicate that was never
    // assigned a location). Without the -1 guard the direct match
    // would hit the duplicate first and short-circuit to -1.
    for (const auto& entry : *table) {
        if (entry.name == lookup && entry.location >= 0) {
            return entry.location;
        }
    }
    // Array-element lookup parity with getUniformLocation: "u[k]"
    // resolves to location(u) + k when u is declared as an array of
    // size > k. GL 4.6 §7.3.1 says both entry points return the same
    // thing for the same name — including array subscript syntax.
    // Entries in the resource table may be stored under either a
    // bare base name ("u") or a "[0]"-suffixed canonical form ("u[0]"
    // for arrays — GL 4.6 §7.3.1 mandate). Match both shapes here.
    // GL 4.6 §7.3.1 (spec for array-subscript names in uniform /
    // resource lookups): only strictly-formatted decimal integers
    // are accepted. Rejected forms: leading/trailing whitespace
    // (`"a[ 0]"`, `"a[0 ]"`), embedded whitespace or arithmetic
    // (`"a[0 + 0]"`, `"a[0+0]"`), alternate whitespace
    // (`"a[\t0]"`, `"a[\n0]"`), leading zero (`"a[01]"`,
    // `"a[00]"`). strtol alone accepts all of these; we pre-validate
    // by scanning the index substring.
    std::string baseName;
    std::vector<GLint> elementIndices;
    const bool parsedArrayElement =
        parseArrayElementLookup(lookup, baseName, elementIndices) &&
        !elementIndices.empty();
    if (parsedArrayElement) {
        GLint flatIndex = 0;
        for (const auto& entry : *table) {
            if (stripBracketZeroSuffix(entry.name) == baseName && entry.arraySize >= 1
                && entry.location >= 0 &&
                flattenArrayElementIndex(entry, elementIndices, flatIndex)) {
                return entry.location + flatIndex;
            }
        }
    }
    // Ordinary default-block uniforms for arrays-of-arrays can be stored
    // as one resource per outer element (`u0[0][0]`, `u0[1][0]`) rather
    // than as a single base resource with arrayDimensions. If the new
    // multidimensional flattening path above did not match, preserve the
    // older innermost-index fallback so `u0[0][1]` resolves through the
    // `u0[0][0]` resource.
    {
        const auto openBracket = lookup.rfind('[');
        if (openBracket != std::string::npos && !lookup.empty() && lookup.back() == ']') {
            const std::string legacyBaseName = lookup.substr(0, openBracket);
            const std::string indexStr = lookup.substr(openBracket + 1, lookup.size() - openBracket - 2);
            long idx = 0;
            if (!legacyBaseName.empty() && parseStrictArrayIndex(indexStr, idx)) {
                for (const auto& entry : *table) {
                    if (stripBracketZeroSuffix(entry.name) == legacyBaseName && entry.arraySize >= 1
                        && idx < static_cast<long>(entry.arraySize)
                        && entry.location >= 0) {
                        return entry.location + static_cast<GLint>(idx);
                    }
                }
            }
        }
    }
    // Bare base-name lookup against a "[0]"-suffixed entry: GL 4.6
    // §7.3.1 says `getProgramResourceLocation("arr")` equals
    // `getProgramResourceLocation("arr[0]")` for array inputs.
    for (const auto& entry : *table) {
        if (stripBracketZeroSuffix(entry.name) == lookup && entry.location >= 0) {
            return entry.location;
        }
    }
    return -1;
}

GLint GLContext::getProgramResourceLocationIndex(GLuint program, GLenum programInterface, const GLchar* name) {
    if (name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return -1;
    }
    if (programInterface != GL_PROGRAM_OUTPUT) {
        pushError(GL_INVALID_ENUM);
        return -1;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr) {
        if (impl_->objects->shaders().contains(program)) {
            pushError(GL_INVALID_OPERATION);
        } else {
            pushError(GL_INVALID_VALUE);
        }
        return -1;
    }
    if (!prog->linked) {
        pushError(GL_INVALID_OPERATION);
        return -1;
    }
    // Fragment output location index (dual-source blending) —
    // comes from `glBindFragDataLocationIndexed`'s `index` arg
    // (0 = primary, 1 = second source). Stored on the entry.
    // Array outputs canonicalised to "<name>[0]" per GL 4.6
    // §7.3.1 — match both bare and suffixed query shapes.
    // Built-in outputs (no user location, e.g. gl_FragDepth)
    // report LOCATION_INDEX = -1 per CTS
    // `output-built-in` expectations.
    auto indexFor = [](const GLProgramResourceEntry& e) {
        return e.location < 0 ? -1 : e.locationIndex;
    };
    const std::string query = name;
    for (const auto& entry : prog->resourceOutputs) {
        if (entry.name == query) return indexFor(entry);
    }
    for (const auto& entry : prog->resourceOutputs) {
        if (entry.name == query + "[0]") return indexFor(entry);
    }
    if (query.size() >= 3 && query.compare(query.size() - 3, 3, "[0]") == 0) {
        const std::string baseOnly = query.substr(0, query.size() - 3);
        for (const auto& entry : prog->resourceOutputs) {
            if (entry.name == baseOnly) return indexFor(entry);
        }
    }
    return -1;
}

// ---------------------------------------------------------------------------
// GL 4.3 — Shader Storage Block Binding
// ---------------------------------------------------------------------------

bool GLContext::shaderStorageBlockBinding(GLuint program, GLuint storageBlockIndex, GLuint storageBlockBinding) {
    // GL 4.3 §7.6.1: INVALID_OPERATION when `program` names a
    // shader (not a program). Must run before the programs().get()
    // null-fallback or we'd return INVALID_VALUE instead.
    if (impl_->objects->shaders().get(program) != nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramObject* prog = impl_->objects->programs().get(program);
    if (prog == nullptr || !prog->linked) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (storageBlockIndex >= prog->resourceStorageBlocks.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.3 §7.6.1: storageBlockBinding must be less than
    // GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS. CTS
    // `shader_storage_buffer_object.negative-api-blockBinding`
    // plants `binding = MAX_BINDINGS` and expects INVALID_VALUE.
    {
        GLint maxBindings = 8;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS, &maxBindings);
        }
        if (storageBlockBinding >= static_cast<GLuint>(maxBindings)) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
    }
    prog->ssboBindingRemap[storageBlockIndex] = storageBlockBinding;
    // Also update the resource entry's location field so queries reflect the remap.
    prog->resourceStorageBlocks[storageBlockIndex].location = static_cast<GLint>(storageBlockBinding);
    return true;
}

#elif defined(APPGL_GLCONTEXT_SHADER_PROGRAM_PIPELINE_CREATE)
bool GLContext::createProgramPipelines(GLsizei n, GLuint* pipelines) {
    if (n < 0) { pushError(GL_INVALID_VALUE); return false; }
    for (GLsizei i = 0; i < n; ++i) {
        pipelines[i] = impl_->objects->programPipelines().reserveName();
        auto* obj = impl_->objects->programPipelines().get(pipelines[i]);
        if (obj) {
            // DSA glCreateProgramPipelines instantiates up-front.
            obj->instantiated = true;
        }
    }
    return true;
}

bool GLContext::deleteProgramPipelines(GLsizei n, const GLuint* pipelines) {
    if (n < 0 || (n > 0 && pipelines == nullptr)) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLuint boundPipeline = impl_->state->currentProgramPipeline();
    for (GLsizei i = 0; i < n; ++i) {
        const GLuint name = pipelines[i];
        if (name == 0) {
            continue;
        }
        std::array<GLuint, 7> referencedPrograms{};
        if (name == boundPipeline) {
            impl_->state->setCurrentProgramPipeline(0);
        }
        if (GLProgramPipelineObject* pipeline = impl_->objects->programPipelines().get(name);
            pipeline != nullptr) {
            referencedPrograms = {
                pipeline->vertexProgram,
                pipeline->fragmentProgram,
                pipeline->geometryProgram,
                pipeline->tessControlProgram,
                pipeline->tessEvalProgram,
                pipeline->computeProgram,
                pipeline->activeShaderProgram,
            };
            impl_->releaseProgramPipelineResources(*pipeline);
        }
        impl_->objects->programPipelines().erase(name);
        for (GLuint program : referencedPrograms) {
            impl_->finalizeDeletedProgramIfUnused(program);
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_SHADER_ROBUST_UNIFORMS)
bool GLContext::getnUniformfv(GLuint program, GLint location, GLsizei bufSize, GLfloat* params) {
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    return getUniformfv(program, location, params);
}

bool GLContext::getnUniformiv(GLuint program, GLint location, GLsizei bufSize, GLint* params) {
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    return getUniformiv(program, location, params);
}

bool GLContext::getnUniformuiv(GLuint program, GLint location, GLsizei bufSize, GLuint* params) {
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    return getUniformuiv(program, location, params);
}

bool GLContext::getnUniformdv(GLuint program, GLint location, GLsizei bufSize, GLdouble* params) {
    if (bufSize < 0) { pushError(GL_INVALID_VALUE); return false; }
    return getUniformdv(program, location, params);
}

#elif defined(APPGL_GLCONTEXT_SHADER_SPECIALIZATION)
bool GLContext::specializeShader(GLuint shader, const GLchar* pEntryPoint,
                                  GLuint numSpecializationConstants,
                                  const GLuint* pConstantIndex, const GLuint* pConstantValue) {
    // GL_ARB_gl_spirv / GL 4.6 §7.2 — promote a SPIR-V binary that was
    // loaded via glShaderBinary into a compiled shader object. We
    // already use SPIR-V as our internal representation (via glslang
    // for the GLSL path), so intake is a matter of validation +
    // marking the object compiled. Real specialization-constant
    // substitution is handled at MSL translation time by
    // `CompilerMSL::set_constant` — for now we record the (index,
    // value) pairs on the shader so downstream SPIRV-Cross calls can
    // consume them.
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        // GL 4.6 §7.2 distinguishes two cases:
        //  * name refers to a program object → INVALID_OPERATION
        //  * name is not a shader or a program → INVALID_VALUE
        if (impl_->objects->programs().get(shader) != nullptr) {
            pushError(GL_INVALID_OPERATION);
        } else {
            pushError(GL_INVALID_VALUE);
        }
        return false;
    }
    // GL 4.6 §7.2: "INVALID_OPERATION is generated if <shader> is not
    // the name of a shader with a SPIR_V_BINARY_ARB state of TRUE"
    // — covers both "no SPIR-V loaded" and "already compiled from
    // GLSL via glCompileShader".
    if (!object->isSpirvBinary || object->spirv.empty()) {
        object->compileLog = "glSpecializeShader: SPIR_V_BINARY_ARB is FALSE on this shader";
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    if (object->compiled) {
        // Specialization may only be done once — reinvoking returns
        // INVALID_OPERATION per GL 4.6 §7.2.
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const char* entry = (pEntryPoint != nullptr) ? pEntryPoint : "main";
    // Minimal SPIR-V validation: the 5-word header must start with
    // the magic number 0x07230203 (little-endian).
    if (object->spirv.size() < 5 || object->spirv[0] != 0x07230203u) {
        object->compileLog = "glSpecializeShader: SPIR-V magic number missing";
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Entry-point + specialization-constant validation. SPIRV-Cross's
    // base Compiler class can walk the module and enumerate entry
    // points and declared spec-constant IDs without a backend. We
    // construct one temporarily here; the real MSL translation
    // (link-time) builds its own CompilerMSL anyway.
    std::unordered_map<std::uint32_t, std::uint32_t> specializationValues;
    try {
        spirv_cross::Compiler introspect(object->spirv.data(), object->spirv.size());
        const auto entries = introspect.get_entry_points_and_stages();
        bool entryOK = false;
        for (const auto& e : entries) {
            if (e.name == entry) { entryOK = true; break; }
        }
        if (!entryOK) {
            object->compileLog = std::string("glSpecializeShader: entry point '")
                                 + entry + "' not found in SPIR-V module";
            pushError(GL_INVALID_VALUE);
            return false;
        }
        // GL 4.6 §7.2 errors: INVALID_VALUE when a spec-constant index
        // in pConstantIndex doesn't correspond to a SpecId in the
        // module. Collect declared IDs once, then check each caller
        // entry against the set.
        if (numSpecializationConstants > 0) {
            if (pConstantIndex == nullptr || pConstantValue == nullptr) {
                pushError(GL_INVALID_VALUE);
                return false;
            }
            const auto specConsts = introspect.get_specialization_constants();
            std::unordered_set<std::uint32_t> declaredIds;
            for (const auto& sc : specConsts) {
                declaredIds.insert(sc.constant_id);
            }
            for (GLuint i = 0; i < numSpecializationConstants; ++i) {
                if (declaredIds.find(pConstantIndex[i]) == declaredIds.end()) {
                    object->compileLog = "glSpecializeShader: specialization "
                                         "constant ID not declared in module";
                    pushError(GL_INVALID_VALUE);
                    return false;
                }
                specializationValues[pConstantIndex[i]] = pConstantValue[i];
            }
        }
    } catch (const spirv_cross::CompilerError& e) {
        object->compileLog = std::string("glSpecializeShader: SPIR-V parse failed: ")
                             + e.what();
        pushError(GL_INVALID_VALUE);
        return false;
    }
    object->spirvEntryPoint = entry;
    object->spirvSpecializationConstants = std::move(specializationValues);
    object->compiled = true;
    object->compileLog.clear();
    return true;
}

#else
#error "GLContextShader.inc.mm included without a shader section selector"
#endif
