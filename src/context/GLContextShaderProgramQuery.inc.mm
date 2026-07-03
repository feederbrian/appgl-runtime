// This file is textually included by GLContextShader.inc.mm. Do not compile it directly.
// It contains the GLContext shader-program query method body split out for navigation only.

bool GLContext::useProgram(GLuint program) {
    if (program != 0) {
        GLProgramObject* object = impl_->objects->programs().get(program);
        if (object == nullptr) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (!object->linked) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    // Sprint 9 Phase 1 (CKPT101): GL 4.6 §13.2.2 — UseProgram must
    // generate INVALID_OPERATION when transform feedback is active and
    // not paused on the currently-bound TF object. CTS
    // `transform_feedback.api_errors_test` plants beginTransformFeedback
    // then calls useProgram(0) and asserts the error is generated.
    const bool tfActive = isTransformFeedbackActive();
    const bool tfPaused = impl_->isTfPausedOnBoundImpl();
    if (tfActive && !tfPaused) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // GL 4.6 §7.3 deferred-delete protocol: if the outgoing current
    // program was already flagged deleteRequested by a prior
    // glDeleteProgram, this is the moment it actually gets erased —
    // "no longer part of any context's current state" is satisfied by
    // the upcoming state->useProgram() call. See deleteProgram for
    // the rationale. Skip when the outgoing program is the same as
    // the incoming program (redundant glUseProgram(N)→glUseProgram(N)).
    const GLuint outgoing = impl_->state->currentProgram();
    if (outgoing != 0 && outgoing != program) {
        GLProgramObject* outgoingObj = impl_->objects->programs().get(outgoing);
        if (outgoingObj != nullptr && outgoingObj->deleteRequested) {
            impl_->finalizeDeletedProgramIfUnused(outgoing);
        }
    }
    impl_->state->useProgram(program);
    if (program != 0) {
        GLProgramObject* object = impl_->objects->programs().get(program);
        if (object != nullptr) {
            resetProgramSubroutineSelections(*object, true);
        }
    }
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::ProgramBind);
    return true;
}

bool GLContext::validateProgram(GLuint program) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    object->validated = object->linked;
    object->validateLog = object->linked ? "validation passed" : "program is not linked";
    return object->validated;
}

bool GLContext::getProgramiv(GLuint program, GLenum pname, GLint* params) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    switch (pname) {
        case GL_DELETE_STATUS:
            *params = object->deleteRequested ? GL_TRUE : GL_FALSE;
            return true;
        case GL_LINK_STATUS:
            *params = object->linked ? GL_TRUE : GL_FALSE;
            return true;
        case 0x91B1:   // GL_COMPLETION_STATUS_KHR / _ARB
            // Synchronous link — always complete post-glLinkProgram.
            // See matching case in getShaderiv for rationale.
            *params = GL_TRUE;
            return true;
        case GL_VALIDATE_STATUS:
            *params = object->validated ? GL_TRUE : GL_FALSE;
            return true;
        case GL_INFO_LOG_LENGTH: {
            const std::string& log = object->validateLog.empty() ? object->linkLog : object->validateLog;
            *params = static_cast<GLint>(log.size() + (log.empty() ? 0 : 1));
            return true;
        }
        case GL_ATTACHED_SHADERS:
            *params = static_cast<GLint>(object->attachedShaders.size());
            return true;
        case GL_ACTIVE_UNIFORMS:
            // GL spec: includes ALL active uniforms (bare + in-block).
            // resourceUniforms holds both; uniforms only holds bare ones.
            *params = static_cast<GLint>(
                object->resourceUniforms.empty()
                    ? object->uniforms.size()
                    : object->resourceUniforms.size());
            return true;
        case GL_ACTIVE_UNIFORM_MAX_LENGTH: {
            if (programUsesNamelessSpirvBinaries(*object, *impl_->objects)) {
                *params = 1;
                return true;
            }
            std::size_t maxLen = 0;
            if (!object->resourceUniforms.empty()) {
                for (const auto& u : object->resourceUniforms) {
                    maxLen = std::max(maxLen, u.name.size() + 1);
                }
            } else {
                for (const auto& u : object->uniforms) {
                    maxLen = std::max(maxLen, u.name.size() + 1);
                }
            }
            *params = static_cast<GLint>(maxLen);
            return true;
        }
        case GL_ACTIVE_ATTRIBUTES:
            *params = static_cast<GLint>(object->attributes.size());
            return true;
        case GL_ACTIVE_ATTRIBUTE_MAX_LENGTH: {
            if (programUsesNamelessSpirvBinaries(*object, *impl_->objects)) {
                *params = 1;
                return true;
            }
            std::size_t maxLen = 0;
            for (const auto& a : object->attributes) {
                maxLen = std::max(maxLen, a.name.size() + 1);
            }
            *params = static_cast<GLint>(maxLen);
            return true;
        }
        // Tessellation program queries (GL 4.0).
        case GL_TESS_CONTROL_OUTPUT_VERTICES:
            *params = object->tessControlOutputVertices;
            return true;
        case GL_TESS_GEN_MODE:
            *params = static_cast<GLint>(object->tessGenMode);
            return true;
        case GL_TESS_GEN_SPACING:
            *params = static_cast<GLint>(object->tessGenSpacing);
            return true;
        case GL_TESS_GEN_VERTEX_ORDER:
            *params = static_cast<GLint>(object->tessGenVertexOrder);
            return true;
        case GL_TESS_GEN_POINT_MODE:
            *params = static_cast<GLint>(object->tessGenPointMode);
            return true;
        // Uniform block queries (GL 3.1+)
        case GL_ACTIVE_UNIFORM_BLOCKS:
            *params = static_cast<GLint>(object->resourceUniformBlocks.size());
            return true;
        case GL_ACTIVE_UNIFORM_BLOCK_MAX_NAME_LENGTH: {
            if (programUsesNamelessSpirvBinaries(*object, *impl_->objects)) {
                *params = 1;
                return true;
            }
            std::size_t maxLen = 0;
            for (const auto& block : object->resourceUniformBlocks) {
                maxLen = std::max(maxLen, block.name.size() + 1);
            }
            *params = static_cast<GLint>(maxLen);
            return true;
        }
        // Compute shader queries (GL 4.3+)
        case GL_COMPUTE_WORK_GROUP_SIZE: {
            // GL 4.6 §7.13: INVALID_OPERATION if the program has not
            // been linked successfully, or has been linked but
            // contains no compute shader. Checked by
            // KHR-GL46.compute_shader.api-program. Otherwise returns
            // the shader's local_size_{x,y,z} as declared by the
            // `layout(local_size_x = N) in;` execution mode, populated
            // at link time via extractComputeModes.
            bool hasComputeStage = false;
            for (GLuint shaderId : object->attachedShaders) {
                const GLShaderObject* sh = impl_->objects->shaders().get(shaderId);
                if (sh != nullptr && sh->stage == GL_COMPUTE_SHADER) {
                    hasComputeStage = true;
                    break;
                }
            }
            if (!object->linked || !hasComputeStage) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            params[0] = static_cast<GLint>(object->computeLocalSizeX);
            params[1] = static_cast<GLint>(object->computeLocalSizeY);
            params[2] = static_cast<GLint>(object->computeLocalSizeZ);
            return true;
        }
        // Transform feedback queries (GL 3.0+)
        case GL_TRANSFORM_FEEDBACK_BUFFER_MODE:
            *params = static_cast<GLint>(object->transformFeedbackBufferMode);
            return true;
        case GL_TRANSFORM_FEEDBACK_VARYINGS:
            *params = static_cast<GLint>(object->transformFeedbackVaryingNames.size());
            return true;
        case GL_TRANSFORM_FEEDBACK_VARYING_MAX_LENGTH: {
            if (programUsesNamelessSpirvBinaries(*object, *impl_->objects)) {
                *params = 1;
                return true;
            }
            std::size_t maxLen = 0;
            for (const auto& v : object->transformFeedbackVaryingNames) {
                maxLen = std::max(maxLen, v.size() + 1);
            }
            *params = static_cast<GLint>(maxLen);
            return true;
        }
        // Geometry shader queries (GL 3.2+). GL 4.6 §7.13 "Program
        // Queries": GL_GEOMETRY_* pnames generate GL_INVALID_OPERATION
        // when the program has not been successfully linked with a
        // geometry shader stage. `gsPresent` is populated at link
        // time by `detectGeometryEmulatable` — it's true whenever the
        // linked program contains a GS, independent of whether the
        // CPU emulator can handle the shader body.
        case GL_GEOMETRY_VERTICES_OUT:
            if (!object->linked || !object->gsPresent) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            *params = static_cast<GLint>(object->gsMaxVertices);
            return true;
        case GL_GEOMETRY_INPUT_TYPE:
            if (!object->linked || !object->gsPresent) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            *params = static_cast<GLint>(object->gsInputTopology);
            return true;
        case GL_GEOMETRY_OUTPUT_TYPE:
            if (!object->linked || !object->gsPresent) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            *params = static_cast<GLint>(object->gsOutputTopology);
            return true;
        case GL_GEOMETRY_SHADER_INVOCATIONS:
            if (!object->linked || !object->gsPresent) {
                pushError(GL_INVALID_OPERATION);
                return false;
            }
            *params = static_cast<GLint>(object->gsInvocations);
            return true;
        // Program binary / separable (GL 4.1+)
        case GL_PROGRAM_BINARY_LENGTH:
            *params = 0;  // No binary program support
            return true;
        case GL_PROGRAM_SEPARABLE:
            *params = object->separable ? GL_TRUE : GL_FALSE;
            return true;
        case GL_PROGRAM_BINARY_RETRIEVABLE_HINT:
            *params = GL_FALSE;
            return true;
        // Atomic counter buffers (GL 4.2+)
        case GL_ACTIVE_ATOMIC_COUNTER_BUFFERS:
            *params = static_cast<GLint>(object->resourceAtomicCounterBuffers.size());
            return true;
        default:
            pushError(GL_INVALID_ENUM);
            return false;
    }
}

bool GLContext::getProgramInfoLog(GLuint program, GLsizei bufSize, GLsizei* length, GLchar* infoLog) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const std::string& log = object->validateLog.empty() ? object->linkLog : object->validateLog;
    copyStringToBuffer(log, bufSize, length, infoLog);
    return true;
}

bool GLContext::getAttachedShaders(GLuint program, GLsizei maxCount, GLsizei* count, GLuint* shaders) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const GLsizei n = std::min<GLsizei>(maxCount, static_cast<GLsizei>(object->attachedShaders.size()));
    if (shaders != nullptr) {
        for (GLsizei i = 0; i < n; ++i) {
            shaders[i] = object->attachedShaders[static_cast<std::size_t>(i)];
        }
    }
    if (count != nullptr) {
        *count = n;
    }
    return true;
}

bool GLContext::bindAttribLocation(GLuint program, GLuint index, const GLchar* name) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    object->requestedAttribLocations[std::string(name)] = index;
    return true;
}

GLint GLContext::getAttribLocation(GLuint program, const GLchar* name) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return -1;
    }
    if (!object->linked) {
        pushError(GL_INVALID_OPERATION);
        return -1;
    }
    const std::string lookup = name;
    // GL 4.6 §7.3.1: if name includes `[N]` suffix, return base attribute's
    // location + N. Shaders can declare `in float clipdistance_data[8]` and
    // CTS looks up `clipdistance_data[0]` through `clipdistance_data[7]`
    // expecting consecutive locations — our reflection only records the
    // array's base name, so we need to parse the suffix and do the math.
    std::string baseName = lookup;
    int arrayIndex = 0;
    if (!lookup.empty() && lookup.back() == ']') {
        const auto bracketPos = lookup.rfind('[');
        if (bracketPos != std::string::npos) {
            const std::string idxStr = lookup.substr(bracketPos + 1,
                lookup.size() - bracketPos - 2);
            // Accept only non-negative decimal integers.
            bool ok = !idxStr.empty();
            for (char c : idxStr) {
                if (c < '0' || c > '9') { ok = false; break; }
            }
            if (ok) {
                arrayIndex = std::atoi(idxStr.c_str());
                baseName = lookup.substr(0, bracketPos);
            }
        }
    }
    for (const auto& attrib : object->attributes) {
        if (attrib.name == lookup) {
            return attrib.location;
        }
        if (attrib.name == baseName) {
            auto arrayElementLocationStride = [](GLenum type) -> GLint {
                switch (type) {
                    case GL_FLOAT_MAT2:    case GL_DOUBLE_MAT2:
                    case GL_FLOAT_MAT2x3:  case GL_DOUBLE_MAT2x3:
                    case GL_FLOAT_MAT2x4:  case GL_DOUBLE_MAT2x4:
                        return 2;
                    case GL_FLOAT_MAT3:    case GL_DOUBLE_MAT3:
                    case GL_FLOAT_MAT3x2:  case GL_DOUBLE_MAT3x2:
                    case GL_FLOAT_MAT3x4:  case GL_DOUBLE_MAT3x4:
                        return 3;
                    case GL_FLOAT_MAT4:    case GL_DOUBLE_MAT4:
                    case GL_FLOAT_MAT4x2:  case GL_DOUBLE_MAT4x2:
                    case GL_FLOAT_MAT4x3:  case GL_DOUBLE_MAT4x3:
                        return 4;
                    default:
                        return 1;
                }
            };
            return attrib.location +
                arrayIndex * arrayElementLocationStride(attrib.type);
        }
    }
    return -1;
}

bool GLContext::getActiveAttrib(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (index >= object->attributes.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const auto& attrib = object->attributes[index];
    if (size != nullptr) {
        *size = 1;
    }
    if (type != nullptr) {
        *type = attrib.type;
    }
    copyStringToBuffer(attrib.name, bufSize, length, name);
    return true;
}

GLint GLContext::getUniformLocation(GLuint program, const GLchar* name) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr || name == nullptr) {
        pushError(GL_INVALID_VALUE);
        return -1;
    }
    if (!object->linked) {
        pushError(GL_INVALID_OPERATION);
        return -1;
    }
    const std::string lookup = name;
    auto parseStrictArrayIndex = [](const std::string& s, long& out) -> bool {
        if (s.empty()) return false;
        for (char c : s) {
            if (c < '0' || c > '9') return false;
        }
        char* endp = nullptr;
        out = std::strtol(s.c_str(), &endp, 10);
        return endp != nullptr && *endp == '\0' && out >= 0;
    };
    auto parsePureArrayElementLookup =
        [&](const std::string& text,
            std::string& baseName,
            std::vector<GLint>& indices) -> bool {
        indices.clear();
        const std::size_t firstBracket = text.find('[');
        if (firstBracket == std::string::npos) {
            baseName = text;
            return !baseName.empty();
        }
        baseName = text.substr(0, firstBracket);
        if (baseName.empty()) return false;
        std::size_t p = firstBracket;
        while (p < text.size()) {
            if (text[p] != '[') return false;
            const std::size_t close = text.find(']', p + 1);
            if (close == std::string::npos) return false;
            long idx = 0;
            if (!parseStrictArrayIndex(text.substr(p + 1, close - p - 1), idx)) {
                return false;
            }
            indices.push_back(static_cast<GLint>(idx));
            p = close + 1;
        }
        return !indices.empty();
    };
    auto flattenUniformArrayIndex =
        [](const GLProgramUniformInfo& uniform,
           const std::vector<GLint>& indices,
           GLint& flatIndex) -> bool {
        if (indices.empty()) {
            flatIndex = 0;
            return true;
        }
        if (uniform.arrayDimensions.empty()) {
            if (indices.size() != 1) return false;
            if (indices[0] < 0 || indices[0] >= uniform.arraySize) return false;
            flatIndex = indices[0];
            return true;
        }
        if (indices.size() != uniform.arrayDimensions.size()) return false;
        GLint flat = 0;
        for (std::size_t i = 0; i < indices.size(); ++i) {
            const GLint dim = uniform.arrayDimensions[i];
            if (dim <= 0 || indices[i] < 0 || indices[i] >= dim) return false;
            flat = flat * dim + indices[i];
        }
        if (flat < 0 || flat >= uniform.arraySize) return false;
        flatIndex = flat;
        return true;
    };
    auto lookupUniformLocation = [&](const std::string& text) -> GLint {
        for (const auto& uniform : object->uniforms) {
            if (uniform.name == text) {
                return uniform.location;
            }
        }
        std::string baseName;
        std::vector<GLint> indices;
        if (parsePureArrayElementLookup(text, baseName, indices)) {
            for (const auto& uniform : object->uniforms) {
                GLint flatIndex = 0;
                if (uniform.name == baseName && uniform.location >= 0 &&
                    flattenUniformArrayIndex(uniform, indices, flatIndex)) {
                    return uniform.location + flatIndex;
                }
            }
        }
        return -1;
    };
    const GLint directLocation = lookupUniformLocation(lookup);
    if (directLocation >= 0) {
        return directLocation;
    }
    // GL 4.6 §7.6.1: array-element lookup — `glGetUniformLocation(prog,
    // "u[k]")` for a uniform declared `uniform T u[N]` must return
    // `location(u) + k` when 0 <= k < N. Uniforms are stored by base name
    // ("u"), so the exact-match loop above misses. Parse the trailing
    // [k] subscript and index into the base.
    //
    // Use `rfind('[')` not `find('[')` so deeply-nested names like
    // `l[2].b[1].d[0]` split as base=`l[2].b[1].d`, idx=0 — not
    // base=`l`, idx=`2].b[1].d[0`. CTS
    // `program_interface_query.uniform-types` declares
    // `uniform UU l[3]` where UU contains `U b[2]` containing
    // `float d[2]`, and asserts
    // glGetUniformLocation("l[2].b[1].d[0]") finds the terminal leaf.
    //
    // Covers KHR-GL46.explicit_uniform_location.uniform-loc-arrays-*
    // which exercise `layout(location = N) uniform T arr[M]` and expect
    // u[0]=N, u[1]=N+1, …, u[M-1]=N+M-1.
    const auto openBracket = lookup.rfind('[');
    if (openBracket != std::string::npos && lookup.back() == ']') {
        const std::string baseName = lookup.substr(0, openBracket);
        const std::string indexStr = lookup.substr(openBracket + 1, lookup.size() - openBracket - 2);
        if (!baseName.empty() && !indexStr.empty()) {
            // Parse the subscript (decimal only; GLSL array subscripts are plain ints).
            char* endp = nullptr;
            const long idx = std::strtol(indexStr.c_str(), &endp, 10);
            if (endp && *endp == '\0' && idx >= 0) {
                for (const auto& uniform : object->uniforms) {
                    if (uniform.name == baseName && uniform.arraySize >= 1
                        && idx < static_cast<long>(uniform.arraySize)
                        && uniform.location >= 0) {
                        return uniform.location + static_cast<GLint>(idx);
                    }
                }
            }
        }
    }
    // Fallback: try with _appgl_ prefix reverse-mapping.
    // CompatShaderRewrite renames `sampler` → `_appgl_sampler` for glslang
    // compat; try the rewritten name if the original wasn't found.
    {
        std::string rewritten = lookup;
        const std::string from = "sampler";
        const std::string to = "_appgl_sampler";
        std::string::size_type pos = 0;
        bool changed = false;
        while ((pos = rewritten.find(from, pos)) != std::string::npos) {
            // Word-boundary check: don't replace inside sampler2D etc.
            bool leftOk = (pos == 0) || (!std::isalnum(static_cast<unsigned char>(rewritten[pos - 1])) && rewritten[pos - 1] != '_');
            std::size_t end = pos + from.size();
            bool rightOk = (end >= rewritten.size()) || (!std::isalnum(static_cast<unsigned char>(rewritten[end])) && rewritten[end] != '_');
            if (leftOk && rightOk) {
                rewritten.replace(pos, from.size(), to);
                pos += to.size();
                changed = true;
            } else {
                pos += 1;
            }
        }
        if (changed) {
            const GLint rewrittenLocation = lookupUniformLocation(rewritten);
            if (rewrittenLocation >= 0) {
                return rewrittenLocation;
            }
            // Pass 2: array-element subscript lookup on the rewritten name.
            // Mirrors the non-rewritten `lookup[k]` → `base + k` path above.
            // Needed when CTS asks for `sampler[0]` on a uniform declared
            // `uniform usampler2D sampler[N]` — `sampler` is a Metal reserved
            // word, CompatShaderRewrite renamed it to `_appgl_sampler`, so
            // the base-name subscript loop at the top of this function only
            // searches for base=`sampler` and finds nothing. The rewritten
            // form `_appgl_sampler[0]` matches base=`_appgl_sampler` here.
            const auto openBracketR = rewritten.rfind('[');
            if (openBracketR != std::string::npos && rewritten.back() == ']') {
                const std::string baseR = rewritten.substr(0, openBracketR);
                const std::string idxStrR = rewritten.substr(openBracketR + 1, rewritten.size() - openBracketR - 2);
                if (!baseR.empty() && !idxStrR.empty()) {
                    char* endpR = nullptr;
                    const long idxR = std::strtol(idxStrR.c_str(), &endpR, 10);
                    if (endpR && *endpR == '\0' && idxR >= 0) {
                        for (const auto& uniform : object->uniforms) {
                            if (uniform.name == baseR && uniform.arraySize >= 1
                                && idxR < static_cast<long>(uniform.arraySize)
                                && uniform.location >= 0) {
                                return uniform.location + static_cast<GLint>(idxR);
                            }
                        }
                    }
                }
            }
        }
    }
    return -1;
}

bool GLContext::getActiveUniform(GLuint program, GLuint index, GLsizei bufSize, GLsizei* length, GLint* size, GLenum* type, GLchar* name) {
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // Prefer resourceUniforms (includes UBO members); fall back to bare
    // uniforms list for programs that never went through SPIRV-Cross.
    if (!object->resourceUniforms.empty()) {
        if (index >= static_cast<GLuint>(object->resourceUniforms.size())) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        const auto& u = object->resourceUniforms[index];
        if (size != nullptr) {
            *size = std::max<GLint>(u.arraySize, 1);
        }
        if (type != nullptr) {
            *type = u.type;
        }
        copyStringToBuffer(u.name, bufSize, length, name);
        return true;
    }
    if (index >= object->uniforms.size()) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    const auto& uniform = object->uniforms[index];
    if (size != nullptr) {
        *size = std::max<GLint>(uniform.arraySize, 1);
    }
    if (type != nullptr) {
        *type = uniform.type;
    }
    copyStringToBuffer(uniform.name, bufSize, length, name);
    return true;
}

namespace {

GLProgramUniformValue* lookupUniformValue(GLProgramObject* program, GLint location) {
    if (program == nullptr || location < 0) {
        return nullptr;
    }
    auto it = program->uniformValues.find(location);
    if (it != program->uniformValues.end()) {
        return &it->second;
    }
    // Array-element fallback: glUniform1i(loc+k, …) on a uniform declared
    // with arraySize > 1 hits locations [base+1, base+arraySize). The slot
    // lives at the base location; find it by walking the uniforms list.
    for (const auto& u : program->uniforms) {
        if (u.arraySize > 1 && location > u.location
            && location < u.location + u.arraySize) {
            auto base = program->uniformValues.find(u.location);
            if (base != program->uniformValues.end()) {
                return &base->second;
            }
            return nullptr;
        }
    }
    return nullptr;
}

// Resolve (slot, elementIndex) for a uniform location. elementIndex is the
// zero-based offset inside the array for array-element locations; 0 for the
// base location or a non-array uniform. Returns (nullptr, 0) if the location
// is invalid.
struct UniformSlotRef {
    GLProgramUniformValue* slot = nullptr;
    GLint elementIndex = 0;
    GLint arraySize = 1;
    GLenum type = 0;
    bool rejectEsImageUnitUpdate = false;
};

UniformSlotRef resolveUniformSlot(GLProgramObject* program, GLint location) {
    UniformSlotRef r;
    if (program == nullptr || location < 0) {
        return r;
    }
    for (const auto& u : program->uniforms) {
        const GLint slots = std::max<GLint>(u.arraySize, 1);
        if (u.location >= 0 && location >= u.location &&
            location < u.location + slots) {
            auto base = program->uniformValues.find(u.location);
            if (base != program->uniformValues.end()) {
                r.slot = &base->second;
                r.elementIndex = location - u.location;
                r.arraySize = u.arraySize;
                r.type = u.type;
                r.rejectEsImageUnitUpdate =
                    u.declaredInEsProfile && isImageUniformType(u.type);
            }
            return r;
        }
    }
    auto it = program->uniformValues.find(location);
    if (it != program->uniformValues.end()) {
        r.slot = &it->second;
        r.elementIndex = 0;
        r.arraySize = it->second.arraySize;
        r.type = it->second.type;
        return r;
    }
    for (const auto& u : program->uniforms) {
        if (u.arraySize > 1 && location > u.location
            && location < u.location + u.arraySize) {
            auto base = program->uniformValues.find(u.location);
            if (base != program->uniformValues.end()) {
                r.slot = &base->second;
                r.elementIndex = location - u.location;
                r.arraySize = u.arraySize;
                r.type = u.type;
            }
            return r;
        }
    }
    return r;
}

// Returns the number of scalar components a uniform of the given GLenum
// type contains (1 for scalar/sampler, 4 for vec4, 16 for mat4, etc.).
// Used by glGetUniform* to cap the memcpy at the real per-element width —
// without this, querying location+k of a sampler-array uniform would
// clobber the caller's single-int stack buffer (memcpy'd the full
// ints.size()). Observed as SIGSEGV in CTS layout_binding.sampler3D
// because the bumped per-stage tex cap made the test exercise a path
// that stressed the latent buffer overrun.
std::size_t uniformTypeComponentCount(GLenum type) {
    switch (type) {
        case GL_FLOAT_VEC2: case GL_INT_VEC2: case GL_UNSIGNED_INT_VEC2:
        case GL_BOOL_VEC2: case GL_DOUBLE_VEC2:
            return 2;
        case GL_FLOAT_VEC3: case GL_INT_VEC3: case GL_UNSIGNED_INT_VEC3:
        case GL_BOOL_VEC3: case GL_DOUBLE_VEC3:
            return 3;
        case GL_FLOAT_VEC4: case GL_INT_VEC4: case GL_UNSIGNED_INT_VEC4:
        case GL_BOOL_VEC4: case GL_DOUBLE_VEC4:
            return 4;
        case GL_FLOAT_MAT2: case GL_DOUBLE_MAT2:       return 4;
        case GL_FLOAT_MAT3: case GL_DOUBLE_MAT3:       return 9;
        case GL_FLOAT_MAT4: case GL_DOUBLE_MAT4:       return 16;
        case GL_FLOAT_MAT2x3: case GL_DOUBLE_MAT2x3:   return 6;
        case GL_FLOAT_MAT2x4: case GL_DOUBLE_MAT2x4:   return 8;
        case GL_FLOAT_MAT3x2: case GL_DOUBLE_MAT3x2:   return 6;
        case GL_FLOAT_MAT3x4: case GL_DOUBLE_MAT3x4:   return 12;
        case GL_FLOAT_MAT4x2: case GL_DOUBLE_MAT4x2:   return 8;
        case GL_FLOAT_MAT4x3: case GL_DOUBLE_MAT4x3:   return 12;
        default: return 1;  // scalars, samplers, images
    }
}

GLint roundFp64UniformToGLint(GLdouble value) {
    const GLfloat narrowed = static_cast<GLfloat>(value);
    return static_cast<GLint>(std::floor(narrowed + 0.5f));
}

GLuint roundFp64UniformToGLuint(GLdouble value) {
    if (!(value > 0.0)) {
        return 0u;
    }
    const GLfloat narrowed = static_cast<GLfloat>(value);
    return static_cast<GLuint>(std::floor(narrowed + 0.5f));
}

}  // namespace

bool GLContext::getUniformfv(GLuint program, GLint location, GLfloat* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    // GL 4.6 §7.7: pass a shader handle → INVALID_OPERATION.
    if (impl_->objects->shaders().get(program) != nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
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
    if (!value->doubles.empty()) {
        const std::size_t avail = value->doubles.size() > offset
            ? std::min(components, value->doubles.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = static_cast<GLfloat>(value->doubles[offset + i]);
        }
    } else if (!value->floats.empty()) {
        const std::size_t avail = value->floats.size() > offset
            ? std::min(components, value->floats.size() - offset) : 0;
        if (avail > 0) {
            std::memcpy(params, value->floats.data() + offset, avail * sizeof(GLfloat));
        }
    } else if (!value->ints.empty()) {
        const std::size_t avail = value->ints.size() > offset
            ? std::min(components, value->ints.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = static_cast<GLfloat>(value->ints[offset + i]);
        }
    } else if (!value->uints.empty()) {
        const std::size_t avail = value->uints.size() > offset
            ? std::min(components, value->uints.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = static_cast<GLfloat>(value->uints[offset + i]);
        }
    }
    return true;
}

bool GLContext::getUniformiv(GLuint program, GLint location, GLint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (impl_->objects->shaders().get(program) != nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
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
    if (!value->doubles.empty()) {
        const std::size_t avail = value->doubles.size() > offset
            ? std::min(components, value->doubles.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = roundFp64UniformToGLint(value->doubles[offset + i]);
        }
    } else if (!value->ints.empty()) {
        const std::size_t avail = value->ints.size() > offset
            ? std::min(components, value->ints.size() - offset) : 0;
        if (avail > 0) {
            std::memcpy(params, value->ints.data() + offset, avail * sizeof(GLint));
        }
    } else if (!value->floats.empty()) {
        const std::size_t avail = value->floats.size() > offset
            ? std::min(components, value->floats.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = static_cast<GLint>(value->floats[offset + i]);
        }
    } else if (!value->uints.empty()) {
        const std::size_t avail = value->uints.size() > offset
            ? std::min(components, value->uints.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = static_cast<GLint>(value->uints[offset + i]);
        }
    }
    return true;
}

bool GLContext::getUniformuiv(GLuint program, GLint location, GLuint* params) {
    if (params == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (impl_->objects->shaders().get(program) != nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    GLProgramObject* object = impl_->objects->programs().get(program);
    if (object == nullptr) {
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
    if (!value->doubles.empty()) {
        const std::size_t avail = value->doubles.size() > offset
            ? std::min(components, value->doubles.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = roundFp64UniformToGLuint(value->doubles[offset + i]);
        }
    } else if (!value->uints.empty()) {
        const std::size_t avail = value->uints.size() > offset
            ? std::min(components, value->uints.size() - offset) : 0;
        if (avail > 0) {
            std::memcpy(params, value->uints.data() + offset, avail * sizeof(GLuint));
        }
    } else if (!value->ints.empty()) {
        const std::size_t avail = value->ints.size() > offset
            ? std::min(components, value->ints.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = static_cast<GLuint>(value->ints[offset + i]);
        }
    } else if (!value->floats.empty()) {
        const std::size_t avail = value->floats.size() > offset
            ? std::min(components, value->floats.size() - offset) : 0;
        for (std::size_t i = 0; i < avail; ++i) {
            params[i] = static_cast<GLuint>(value->floats[offset + i]);
        }
    }
    return true;
}
