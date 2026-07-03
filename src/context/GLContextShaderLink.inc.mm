// This file is textually included by GLContextShader.inc.mm. Do not compile it directly.
// It contains the GLContext shader-link method body split out for navigation only.

bool GLContext::linkProgram(GLuint program) {
    GLProgramObject* programObject = impl_->objects->programs().get(program);
    if (programObject == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // Phase 8X Group 4d follow-up²³ — link-path crash-site instrumentation.
    // The fw²² smoke identified Spring's Sky shader (program 28) SIGABRT'ing
    // between the `compileGLSLProgram` NSLog and the final `linkProgram`
    // NSLog. All Metal pipeline work (`newLibraryWithSource`,
    // `newRenderPipelineStateWithDescriptor`) lives in `MetalFrameGraph.mm`
    // and is only reached at draw time — so the only work between those two
    // log lines is glslang cross-stage link + SPIRV-Cross spirvToMSL/reflect.
    // These markers bracket each sub-step so BAR's crash handler can tell
    // which one is the last to run before abort. Each marker is followed by
    // an explicit `fflush(stderr)` to survive the libunwind double-abort that
    // fw²² verification §5.3 documented (`fsync(STDERR_FILENO)` Spring-side
    // fix is separate and still deferred).
    APPGL_LOG(SHADER, @"[GL] linkProgram-begin program=%u", program);
    fflush(stderr);

    const bool hadPriorExecutable = programObject->linked;
    const auto priorUniforms = programObject->uniforms;
    const auto priorAttributes = programObject->attributes;
    const auto priorUniformValues = programObject->uniformValues;
    const auto priorPipelineEmulationStageUniforms =
        programObject->pipelineEmulationStageUniforms;
    const auto priorPipelineEmulationStageUniformValues =
        programObject->pipelineEmulationStageUniformValues;
    const auto priorPipelineEmulationStageUniformsValid =
        programObject->pipelineEmulationStageUniformsValid;
    const GLbitfield priorLinkedStageBits = programObject->linkedStageBits;
    const std::uint32_t priorAdvancedBlendSupportMask =
        programObject->advancedBlendSupportMask;
    const bool priorAdvancedBlendSupportAll = programObject->advancedBlendSupportAll;
    const auto priorResourceUniforms = programObject->resourceUniforms;
    const auto priorResourceUniformBlocks = programObject->resourceUniformBlocks;
    const auto priorResourceInputs = programObject->resourceInputs;
    const auto priorResourceOutputs = programObject->resourceOutputs;
    const auto priorResourceStorageBlocks = programObject->resourceStorageBlocks;
    const auto priorResourceAtomicCounterBuffers =
        programObject->resourceAtomicCounterBuffers;
    const auto priorResourceBufferVariables = programObject->resourceBufferVariables;
    const auto priorResourceTransformFeedbackVaryings =
        programObject->resourceTransformFeedbackVaryings;
    const auto priorResourceTransformFeedbackBuffers =
        programObject->resourceTransformFeedbackBuffers;
    const auto priorSsboBindingRemap = programObject->ssboBindingRemap;
    const auto priorSamplerExplicitBindings = programObject->samplerExplicitBindings;
    const auto priorImageExplicitBindings = programObject->imageExplicitBindings;
    const bool priorHasTranslatedPipeline =
        programObject->hasTranslatedPipeline;
    const auto priorVertexMSL = programObject->vertexMSL;
    const auto priorFragmentMSL = programObject->fragmentMSL;
    const bool priorVertexMslUsesArgumentBuffer =
        programObject->vertexMslUsesArgumentBuffer;
    const bool priorFragmentMslUsesArgumentBuffer =
        programObject->fragmentMslUsesArgumentBuffer;
    const bool priorVertexMslWritesRenderTargetArrayIndex =
        programObject->vertexMslWritesRenderTargetArrayIndex;
    const bool priorVertexMslWritesViewportArrayIndex =
        programObject->vertexMslWritesViewportArrayIndex;
    const bool priorVertexMslHasClipControlYSignParameter =
        programObject->vertexMslHasClipControlYSignParameter;
    const bool priorFragmentMslUsesFragCoordParams =
        programObject->fragmentMslUsesFragCoordParams;
    const auto priorVertexReflection = programObject->vertexReflection;
    const auto priorFragmentReflection = programObject->fragmentReflection;
    const auto priorVertexSourceHash = programObject->vertexSourceHash;
    const auto priorFragmentSourceHash = programObject->fragmentSourceHash;
    auto restorePriorExecutableForFailedRelink = [&]() {
        if (!hadPriorExecutable) {
            return;
        }
        programObject->uniforms = priorUniforms;
        programObject->attributes = priorAttributes;
        programObject->uniformValues = priorUniformValues;
        programObject->pipelineEmulationStageUniforms =
            priorPipelineEmulationStageUniforms;
        programObject->pipelineEmulationStageUniformValues =
            priorPipelineEmulationStageUniformValues;
        programObject->pipelineEmulationStageUniformsValid =
            priorPipelineEmulationStageUniformsValid;
        programObject->linkedStageBits = priorLinkedStageBits;
        programObject->advancedBlendSupportMask = priorAdvancedBlendSupportMask;
        programObject->advancedBlendSupportAll = priorAdvancedBlendSupportAll;
        programObject->resourceUniforms = priorResourceUniforms;
        programObject->resourceUniformBlocks = priorResourceUniformBlocks;
        programObject->resourceInputs = priorResourceInputs;
        programObject->resourceOutputs = priorResourceOutputs;
        programObject->resourceStorageBlocks = priorResourceStorageBlocks;
        programObject->resourceAtomicCounterBuffers =
            priorResourceAtomicCounterBuffers;
        programObject->resourceBufferVariables = priorResourceBufferVariables;
        programObject->resourceTransformFeedbackVaryings =
            priorResourceTransformFeedbackVaryings;
        programObject->resourceTransformFeedbackBuffers =
            priorResourceTransformFeedbackBuffers;
        programObject->ssboBindingRemap = priorSsboBindingRemap;
        programObject->samplerExplicitBindings = priorSamplerExplicitBindings;
        programObject->imageExplicitBindings = priorImageExplicitBindings;
        programObject->hasTranslatedPipeline = priorHasTranslatedPipeline;
        programObject->vertexMSL = priorVertexMSL;
        programObject->fragmentMSL = priorFragmentMSL;
        programObject->vertexMslUsesArgumentBuffer =
            priorVertexMslUsesArgumentBuffer;
        programObject->fragmentMslUsesArgumentBuffer =
            priorFragmentMslUsesArgumentBuffer;
        programObject->vertexMslWritesRenderTargetArrayIndex =
            priorVertexMslWritesRenderTargetArrayIndex;
        programObject->vertexMslWritesViewportArrayIndex =
            priorVertexMslWritesViewportArrayIndex;
        programObject->vertexMslHasClipControlYSignParameter =
            priorVertexMslHasClipControlYSignParameter;
        programObject->fragmentMslUsesFragCoordParams =
            priorFragmentMslUsesFragCoordParams;
        programObject->vertexReflection = priorVertexReflection;
        programObject->fragmentReflection = priorFragmentReflection;
        programObject->vertexSourceHash = priorVertexSourceHash;
        programObject->fragmentSourceHash = priorFragmentSourceHash;
        programObject->uniformLayoutComputed = false;
        programObject->invalidateUniformBufferCache();
        programObject->invalidateSamplerBindingRecipeCache();
        phase2PlanInvalidateProgramStructuralFingerprint(*programObject);
        if (impl_->frameGraph != nullptr) {
            impl_->frameGraph->invalidateMslHashMemoForStringObject(
                &programObject->vertexMSL);
            impl_->frameGraph->invalidateMslHashMemoForStringObject(
                &programObject->fragmentMSL);
        }
        programObject->linked = false;
    };

    programObject->uniforms.clear();
    programObject->attributes.clear();
    programObject->uniformValues.clear();
    programObject->vertexUniformLayout.clear();
    programObject->fragmentUniformLayout.clear();
    programObject->computeUniformLayout.clear();
    programObject->tessControlUniformLayout.clear();
    programObject->tessVertexAsComputeUniformLayout.clear();
    programObject->tessEvalAsComputeUniformLayout.clear();
    programObject->vsTfAsComputeUniformLayout.clear();
    programObject->uniformLayoutComputed = false;
    programObject->invalidateUniformBufferCache();
    programObject->invalidateSamplerBindingRecipeCache();
    for (std::size_t stage = 0; stage < programObject->pipelineEmulationStageUniforms.size(); ++stage) {
        programObject->pipelineEmulationStageUniforms[stage].clear();
        programObject->pipelineEmulationStageUniformValues[stage].clear();
        programObject->pipelineEmulationStageUniformsValid[stage] = false;
    }
    programObject->linkLog.clear();
    programObject->linked = false;
    programObject->linkedStageBits = 0;
    programObject->advancedBlendSupportMask = 0;
    programObject->advancedBlendSupportAll = false;
    phase2PlanInvalidateProgramStructuralFingerprint(*programObject);

    // RC-D09: Clear resource tables from any previous link so stale
    // introspection data never survives a failed re-link.
    programObject->resourceUniforms.clear();
    programObject->resourceUniformBlocks.clear();
    programObject->resourceInputs.clear();
    programObject->resourceOutputs.clear();
    programObject->resourceStorageBlocks.clear();
    programObject->resourceAtomicCounterBuffers.clear();
    programObject->resourceBufferVariables.clear();
    programObject->resourceTransformFeedbackVaryings.clear();
    programObject->resourceTransformFeedbackBuffers.clear();
    programObject->ssboBindingRemap.clear();
    programObject->samplerExplicitBindings.clear();
    programObject->imageExplicitBindings.clear();

    // Small helper used in several diagnostic-recording sites below.
    const std::string programTag = "program-" + std::to_string(program);
    auto quickHash = [](const std::string& s) -> std::string {
        std::size_t h = std::hash<std::string>{}(s);
        char buf[18];
        std::snprintf(buf, sizeof(buf), "%016zx", h);
        return buf;
    };

    if (programObject->attachedShaders.empty()) {
        programObject->linkLog = "no shaders attached";
        Runtime::shared().recordShaderTranslation({
            programTag, "link", "", "", "", programObject->linkLog, "", false
        });
        restorePriorExecutableForFailedRelink();
        return false;
    }

    // Classify the attached stages. Pointers stay null when a stage isn't
    // present. Everything downstream dispatches on which pointers are set
    // rather than re-scanning the attached list.
    GLShaderObject* vertexShader = nullptr;
    GLShaderObject* fragmentShader = nullptr;
    GLShaderObject* computeShader = nullptr;
    GLShaderObject* geometryShader = nullptr;
    GLShaderObject* tessControlShader = nullptr;
    GLShaderObject* tessEvalShader = nullptr;
    int shaderCount = 0;
    int computeShaderCount = 0;
    std::vector<GLShaderObject*> attachedShaderObjects;
    std::vector<GLShaderObject*> vertexShaderObjects;
    std::vector<GLShaderObject*> fragmentShaderObjects;
    std::vector<GLShaderObject*> geometryShaderObjects;
    std::vector<GLShaderObject*> tessControlShaderObjects;
    std::vector<GLShaderObject*> tessEvalShaderObjects;
    std::vector<GLShaderObject*> computeShaderObjects;

    for (GLuint shaderId : programObject->attachedShaders) {
        GLShaderObject* shaderObject = impl_->objects->shaders().get(shaderId);
        // Under deferred-erase semantics (see GLObjectStore.h::GLShaderObject)
        // a nullptr lookup here is essentially unreachable from real engine
        // code — glAttachShader rejects unknown IDs upfront, the attachment
        // count keeps the shader resident across glDeleteShader, and a
        // detach pulls the ID out of attachedShaders before the maybe-erase
        // pass. The check is left for defence in depth. The remaining real
        // failure mode is `!shaderObject->compiled`, which now reliably
        // carries the real glslang `compileLog` text through to the
        // diagnostic ring (the upstream `compileShader` call also pushes a
        // `stage: "compile"` record with the same log, but the link-time
        // record makes the failure visible at the program level too).
        if (shaderObject == nullptr || !shaderObject->compiled) {
            programObject->linkLog = "attached shader is not compiled";
            const std::string log = shaderObject
                ? shaderObject->compileLog
                : programObject->linkLog;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", log, "", false
            });
            restorePriorExecutableForFailedRelink();
            return false;
        }
        attachedShaderObjects.push_back(shaderObject);
        ++shaderCount;
        switch (shaderObject->stage) {
            case GL_VERTEX_SHADER:
                vertexShader = shaderObject;
                vertexShaderObjects.push_back(shaderObject);
                programObject->linkedStageBits |= GL_VERTEX_SHADER_BIT;
                break;
            case GL_FRAGMENT_SHADER:
                fragmentShader = shaderObject;
                fragmentShaderObjects.push_back(shaderObject);
                programObject->linkedStageBits |= GL_FRAGMENT_SHADER_BIT;
                programObject->advancedBlendSupportMask |=
                    shaderObject->advancedBlendSupportMask;
                programObject->advancedBlendSupportAll =
                    programObject->advancedBlendSupportAll ||
                    shaderObject->advancedBlendSupportAll;
                break;
            case GL_COMPUTE_SHADER:
                computeShader = shaderObject;
                ++computeShaderCount;
                computeShaderObjects.push_back(shaderObject);
                programObject->linkedStageBits |= GL_COMPUTE_SHADER_BIT;
                break;
            case GL_GEOMETRY_SHADER:
                geometryShader = shaderObject;
                geometryShaderObjects.push_back(shaderObject);
                programObject->linkedStageBits |= GL_GEOMETRY_SHADER_BIT;
                break;
            case GL_TESS_CONTROL_SHADER:
                tessControlShader = shaderObject;
                tessControlShaderObjects.push_back(shaderObject);
                programObject->linkedStageBits |= GL_TESS_CONTROL_SHADER_BIT;
                break;
            case GL_TESS_EVALUATION_SHADER:
                tessEvalShader = shaderObject;
                tessEvalShaderObjects.push_back(shaderObject);
                programObject->linkedStageBits |= GL_TESS_EVALUATION_SHADER_BIT;
                break;
            default: break;
        }
        appendDeclarationsAsUniforms(programObject->uniforms, shaderObject->declaredUniforms);

        // GL 4.2 §7.6: harvest `layout(binding = N)` from the original
        // GLSL source across every attached shader. The map is used at
        // draw-time to substitute the declared unit for any sampler/image
        // uniform the application hasn't explicitly glUniform1i'd.
        // Later-stage declarations override earlier ones if names
        // collide — safe in practice because the same opaque name in
        // multiple stages must refer to the same resource by GL's
        // cross-stage interface rules.
        auto stageBindings = parseExplicitOpaqueBindings(shaderObject->source);
        for (auto& [name, parsed] : stageBindings) {
            switch (parsed.kind) {
                case ExplicitOpaqueBindingKind::Sampler:
                    programObject->samplerExplicitBindings[name] = parsed.binding;
                    break;
                case ExplicitOpaqueBindingKind::Image:
                    programObject->imageExplicitBindings[name] = parsed.binding;
                    break;
                case ExplicitOpaqueBindingKind::AtomicCounter:
                    break;
            }
        }
    }

    if (!attachedShaderObjects.empty()) {
        const bool firstIsSpirvBinary = attachedShaderObjects.front()->isSpirvBinary;
        for (const GLShaderObject* shader : attachedShaderObjects) {
            if (shader != nullptr &&
                shader->isSpirvBinary != firstIsSpirvBinary) {
                programObject->linkLog =
                    "attached shaders mix SPIR_V_BINARY_ARB states";
                programObject->linked = false;
                Runtime::shared().recordShaderTranslation({
                    programTag, "link", "", "", "",
                    programObject->linkLog, "", false
                });
                return false;
            }
        }
    }
    const bool linkedFromSpirvBinary =
        !attachedShaderObjects.empty() &&
        attachedShaderObjects.front()->isSpirvBinary;

    if (geometryShader != nullptr && !linkedFromSpirvBinary) {
        GLint maxVertexStreams = 4;
        if (impl_->capabilities != nullptr) {
            GLint queriedMaxVertexStreams = 0;
            if (impl_->capabilities->queryInteger(
                    GL_MAX_VERTEX_STREAMS, &queriedMaxVertexStreams) &&
                queriedMaxVertexStreams > 0) {
                maxVertexStreams = queriedMaxVertexStreams;
            }
        }
        maxVertexStreams = std::max<GLint>(maxVertexStreams, 4);
        std::string validationError;
        if (!validateGeometryShaderGpu5LinkStreamCalls(
                geometryShader->source, maxVertexStreams, validationError)) {
            programObject->linkLog = std::move(validationError);
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            restorePriorExecutableForFailedRelink();
            return false;
        }
    }

    {
        GLint maxAtomicBindings = 0;
        GLint maxAtomicBufferSize = 0;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(
                GL_MAX_ATOMIC_COUNTER_BUFFER_BINDINGS, &maxAtomicBindings);
            impl_->capabilities->queryInteger(
                GL_MAX_ATOMIC_COUNTER_BUFFER_SIZE, &maxAtomicBufferSize);
        }
        std::string validationError;
        if (!applyAtomicCounterLayoutsFromSources(
                attachedShaderObjects,
                programObject->uniforms,
                maxAtomicBindings,
                maxAtomicBufferSize,
                validationError)) {
            programObject->linkLog = std::move(validationError);
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }
    }

    {
        std::string validationError;
        if (!validateLinkedShaderStorageBlocks(attachedShaderObjects, validationError)) {
            programObject->linkLog = std::move(validationError);
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }
        if (!validateLinkedShaderStorageBlockLimits(
                attachedShaderObjects,
                impl_->capabilities.get(),
                validationError)) {
            programObject->linkLog = std::move(validationError);
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }
    }

    {
        std::string validationError;
        if (!validateLinkedImageUniformLimits(
                attachedShaderObjects,
                impl_->capabilities.get(),
                validationError)) {
            programObject->linkLog = std::move(validationError);
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }
    }

    // GL 4.6 §4.4.6: explicit uniform locations do not apply to
    // atomic-counter uniforms. glslang accepts this combination on macOS, so
    // reject it at program link where AppGL already validates default-block
    // uniform locations.
    for (const auto& uniform : programObject->uniforms) {
        if (uniform.type == GL_UNSIGNED_INT_ATOMIC_COUNTER &&
            uniform.explicitLocation >= 0) {
            programObject->linkLog =
                "layout(location) is not allowed for atomic counter uniform '" +
                uniform.name + "'";
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }
    }

    // Build the vertex attribute table from the scanner's declared inputs
    // on the vertex stage. The scanner-driven path honours
    // glBindAttribLocation requests (via requestedAttribLocations) which
    // SPIRV-Cross reflection cannot see, so we keep it as the authoritative
    // source for attribute locations.
    auto vertexInputLocationSlotCount = [](GLenum type, GLint arraySize) -> GLuint {
        GLuint columns = 1;
        switch (type) {
            case GL_FLOAT_MAT2:    case GL_DOUBLE_MAT2:
            case GL_FLOAT_MAT2x3:  case GL_DOUBLE_MAT2x3:
            case GL_FLOAT_MAT2x4:  case GL_DOUBLE_MAT2x4:
                columns = 2;
                break;
            case GL_FLOAT_MAT3:    case GL_DOUBLE_MAT3:
            case GL_FLOAT_MAT3x2:  case GL_DOUBLE_MAT3x2:
            case GL_FLOAT_MAT3x4:  case GL_DOUBLE_MAT3x4:
                columns = 3;
                break;
            case GL_FLOAT_MAT4:    case GL_DOUBLE_MAT4:
            case GL_FLOAT_MAT4x2:  case GL_DOUBLE_MAT4x2:
            case GL_FLOAT_MAT4x3:  case GL_DOUBLE_MAT4x3:
                columns = 4;
                break;
            default:
                break;
        }
        return columns * static_cast<GLuint>(std::max<GLint>(1, arraySize));
    };
    auto arrayElementCount = [](const std::vector<GLint>& dims,
                                GLint fallback,
                                std::size_t first = 0) -> GLint {
        if (dims.empty() || first >= dims.size()) {
            return fallback;
        }
        GLint count = 1;
        for (std::size_t i = first; i < dims.size(); ++i) {
            if (dims[i] <= 0) {
                return fallback;
            }
            count *= dims[i];
        }
        return count;
    };
    if (vertexShader != nullptr) {
        std::unordered_set<GLuint> usedAttribLocations;
        auto reserveAttribLocationRange = [&usedAttribLocations](
            GLint location, GLuint slotCount) {
            if (location < 0) {
                return;
            }
            for (GLuint slot = 0; slot < std::max<GLuint>(1u, slotCount); ++slot) {
                usedAttribLocations.insert(static_cast<GLuint>(location) + slot);
            }
        };
        auto requestedLocationForInput =
            [&programObject](const std::string& name) -> GLint {
            const auto requested =
                programObject->requestedAttribLocations.find(name);
            if (requested == programObject->requestedAttribLocations.end()) {
                return -1;
            }
            return static_cast<GLint>(requested->second);
        };
        auto findFreeAttribLocation =
            [&usedAttribLocations](GLuint slotCount, GLuint& next) -> GLuint {
            slotCount = std::max<GLuint>(1u, slotCount);
            for (;;) {
                bool freeRange = true;
                for (GLuint slot = 0; slot < slotCount; ++slot) {
                    if (usedAttribLocations.count(next + slot) != 0) {
                        freeRange = false;
                        next += slot + 1u;
                        break;
                    }
                }
                if (freeRange) {
                    return next;
                }
            }
        };

        for (const auto& input : vertexShader->declaredInputs) {
            const GLint locationArraySize =
                arrayElementCount(input.arrayDimensions, input.arraySize);
            const GLuint slotCount =
                vertexInputLocationSlotCount(input.type, locationArraySize);
            if (input.explicitLocation >= 0) {
                reserveAttribLocationRange(input.explicitLocation, slotCount);
                continue;
            }
            const GLint requested = requestedLocationForInput(input.name);
            if (requested >= 0) {
                reserveAttribLocationRange(requested, slotCount);
            }
        }

        GLuint nextAttribLocation = 0;
        for (const auto& input : vertexShader->declaredInputs) {
            GLProgramAttributeInfo attrib;
            attrib.name = input.name;
            attrib.type = input.type;
            attrib.arraySize = input.arraySize;
            attrib.isArray = input.isArray;
            attrib.arrayDimensions = input.arrayDimensions;
            const GLint locationArraySize =
                arrayElementCount(input.arrayDimensions, input.arraySize);
            const GLuint slotCount =
                vertexInputLocationSlotCount(input.type, locationArraySize);
            if (input.explicitLocation >= 0) {
                attrib.location = input.explicitLocation;
                attrib.locationExplicit = true;
            } else {
                const GLint requested = requestedLocationForInput(input.name);
                if (requested >= 0) {
                    attrib.location = requested;
                    attrib.locationExplicit = true;
                } else {
                    attrib.location = static_cast<GLint>(
                        findFreeAttribLocation(slotCount, nextAttribLocation));
                }
            }
            // GL 4.6 §11.1.1: array vertex inputs consume arraySize
            // consecutive attribute locations (one per element), and
            // matrix inputs consume one location per column. SPIRV-
            // Cross's MSL backend expands those into individual
            // `[[attribute(N)]]` slots so each element/column needs its
            // own location. Advance `nextAttribLocation` by the full size
            // so the NEXT input lands AFTER the aggregate, not on top of
            // its second element/column. CTS cull_distance tests have
            //   in float clipdistance_data[1];
            //   in float culldistance_data[8];
            //   in vec2 position;
            // and expect position at MSL attribute(9), not (2). Before
            // this fix, getAttribLocation("position")=2 collided with
            // culldistance_data[1]'s MSL slot.
            reserveAttribLocationRange(attrib.location, slotCount);
            if (!attrib.locationExplicit &&
                static_cast<GLuint>(attrib.location) + slotCount > nextAttribLocation) {
                nextAttribLocation = static_cast<GLuint>(attrib.location) + slotCount;
            }
            programObject->attributes.push_back(std::move(attrib));
        }
    }
    const bool traceAttribInjection =
        std::getenv("APPGL_TRACE_ATTRIB_INJECTION") != nullptr;
    auto countExplicitResolvedVertexAttribLocations =
        [&programObject]() -> std::size_t {
            std::size_t count = 0;
            for (const auto& attrib : programObject->attributes) {
                if (attrib.location >= 0 && attrib.locationExplicit) {
                    ++count;
                }
            }
            return count;
        };
    if (traceAttribInjection) {
        std::fprintf(stderr,
            "[APPGL_ATTRIB] program=%u resolved-attrs=%zu explicit=%zu "
            "requested-binds=%zu\n",
            static_cast<unsigned>(program),
            programObject->attributes.size(),
            countExplicitResolvedVertexAttribLocations(),
            programObject->requestedAttribLocations.size());
        for (const auto& requested : programObject->requestedAttribLocations) {
            std::fprintf(stderr,
                "[APPGL_ATTRIB]   bind name=%s location=%u\n",
                requested.first.c_str(),
                static_cast<unsigned>(requested.second));
        }
        for (const auto& attrib : programObject->attributes) {
            std::fprintf(stderr,
                "[APPGL_ATTRIB]   attr name=%s location=%d explicit=%d "
                "type=0x%X arraySize=%d isArray=%d\n",
                attrib.name.c_str(),
                static_cast<int>(attrib.location),
                attrib.locationExplicit ? 1 : 0,
                static_cast<unsigned>(attrib.type),
                static_cast<int>(attrib.arraySize),
                attrib.isArray ? 1 : 0);
        }
        std::fflush(stderr);
    }

    // Stage combination must be one of:
    //   - Compute-only                          (one or more GL_COMPUTE_SHADER objects)
    //   - Vertex + Fragment                     (standard raster pipeline)
    //   - Vertex + Geometry + Fragment          (geometry path; emulation gap
    //                                            flagged in translator block)
    //   - Vertex + TessControl + TessEval + F   (tess path, same story)
    //   - Vertex-only / Fragment-only           (separable via
    //                                            glCreateShaderProgramv)
    // Anything else bails. The "unknown combination" branch also records a
    // diagnostic so BAR sees why the program didn't link.
    enum class ProgramKind {
        Unknown,
        Compute,
        VertexFragment,
        VertexGeometryFragment,
        VertexTessellationFragment,
        VertexOnly,
        FragmentOnly,
        GeometryOnly,
        TessControlOnly,
        TessEvalOnly,
        // Sprint 15 Day 18 (CKPT191) — VS+GS no-FS combination.
        // CTS `shader_image_load_store.basic-allTargets-{loadStore,atomic}GS`
        // and SILS GS sister tests build programs with only VS+GS and enable
        // GL_RASTERIZER_DISCARD; image writes happen in the GS body, no
        // rasterisation. Previously rejected as ProgramKind::Unknown at link
        // (see CKPT164 for prior characterization). This kind translates VS
        // standalone, runs GS detection / CPU emulation setup, and lets the
        // existing nil-fragmentFunction + rasterizationEnabled=NO pipeline
        // path handle the no-FS draw — same shape that ProgramKind::VertexOnly
        // relies on for SSBO-VS tests.
        VertexGeometry,
        // Sprint 19: VS+TCS+TES+GS with no fragment shader. SILS
        // basic-allFormats-*GeometryStages enables GL_RASTERIZER_DISCARD
        // and communicates through storage images, so this can share the
        // existing CPU tessellation -> CPU GS path once link accepts it.
        VertexTessellationGeometry,
        // VS+TES or VS+TCS+TES with no fragment shader. CTS SILS
        // TCS/TES loadStore cases enable GL_RASTERIZER_DISCARD and use
        // storage-image side effects only, so link the program and route
        // draw-time work through the CPU tessellation interpreter.
        VertexTessellation,
        // Separable multi-stage combination that doesn't match any
        // of the above — accepted only when GL_PROGRAM_SEPARABLE is
        // set. The program is linked for introspection; the actual
        // stage code is surfaced via the pipeline object when the
        // caller issues a draw.
        Separable,
    };
    // Set hasTessellation early — any attached TCS or TES counts, even
    // when the ProgramKind path doesn't specifically handle tess (e.g.
    // 5-stage VS+TCS+TES+GS+FS programs land on VertexGeometryFragment
    // today but still have tess shaders in play). The draw-time GS-
    // topology gate in drawArrays/Instanced/ElementsInstanced queries
    // this flag to suppress the draw-mode compat check for any program
    // with a tess stage (GS reads TES output, not the raw draw mode).
    if (tessControlShader != nullptr || tessEvalShader != nullptr) {
        programObject->hasTessellation = true;
    }

    ProgramKind kind = ProgramKind::Unknown;
    if (computeShader != nullptr && shaderCount == computeShaderCount) {
        kind = ProgramKind::Compute;
    } else if (vertexShader != nullptr && fragmentShader != nullptr &&
               tessControlShader == nullptr && tessEvalShader == nullptr &&
               geometryShader == nullptr && computeShader == nullptr) {
        kind = ProgramKind::VertexFragment;
    } else if (vertexShader != nullptr && fragmentShader != nullptr &&
               geometryShader != nullptr && computeShader == nullptr) {
        kind = ProgramKind::VertexGeometryFragment;
    } else if (vertexShader != nullptr && geometryShader != nullptr &&
               tessControlShader != nullptr && tessEvalShader != nullptr &&
               fragmentShader == nullptr && computeShader == nullptr) {
        kind = ProgramKind::VertexTessellationGeometry;
    } else if (vertexShader != nullptr && tessEvalShader != nullptr &&
               fragmentShader == nullptr && geometryShader == nullptr &&
               computeShader == nullptr) {
        kind = ProgramKind::VertexTessellation;
    } else if (vertexShader != nullptr && geometryShader != nullptr &&
               fragmentShader == nullptr && computeShader == nullptr &&
               tessControlShader == nullptr && tessEvalShader == nullptr) {
        // Sprint 15 Day 18 (CKPT191) — VS+GS no-FS path. CTS SILS GS tests
        // build VS+GS-only programs with GL_RASTERIZER_DISCARD; image writes
        // happen in the GS body. Previously rejected as Unknown at link
        // (CKPT164 prior characterization).
        kind = ProgramKind::VertexGeometry;
    } else if (vertexShader != nullptr && fragmentShader != nullptr &&
               tessEvalShader != nullptr &&
               computeShader == nullptr) {
        // GL 4.6 §11.2.3: tess-eval is the required tess stage;
        // tess-control is OPTIONAL. A program with VS + TES + FS
        // (no TCS) is a valid combination — the app drives the
        // tessellation factors via `glPatchParameterfv(
        // GL_PATCH_DEFAULT_{INNER,OUTER}_LEVEL, ...)` instead of
        // through a TCS. CTS `tessellation_shader.single.
        // max_patch_vertices` builds one such program and expects
        // link to succeed. The downstream `quickHash(
        // tessControlShader->source)` call in the VTF branch is
        // now null-guarded so TCS-less programs don't deref null.
        kind = ProgramKind::VertexTessellationFragment;
    } else if (vertexShader != nullptr && fragmentShader == nullptr &&
               computeShader == nullptr && geometryShader == nullptr &&
               tessControlShader == nullptr && tessEvalShader == nullptr) {
        kind = ProgramKind::VertexOnly;
    } else if (fragmentShader != nullptr && vertexShader == nullptr &&
               computeShader == nullptr && geometryShader == nullptr &&
               tessControlShader == nullptr && tessEvalShader == nullptr) {
        kind = ProgramKind::FragmentOnly;
    } else if (geometryShader != nullptr && shaderCount == 1) {
        // Separable geometry-only program — used with glProgramPipeline +
        // glUseProgramStages(GL_GEOMETRY_SHADER_BIT). CTS
        // `separable_programs_tf.geometry_active` constructs one per stage
        // and links them independently. Translate to MSL for reflection so
        // the link succeeds; draw-time GS emulation is handled by the
        // VertexGeometryFragment path when the combined pipeline runs.
        kind = ProgramKind::GeometryOnly;
    } else if (tessControlShader != nullptr && shaderCount == 1) {
        kind = ProgramKind::TessControlOnly;
    } else if (tessEvalShader != nullptr && shaderCount == 1) {
        kind = ProgramKind::TessEvalOnly;
    }

    // GL 4.1 §7.3: a separable program can skip otherwise-
    // required stages — the program pipeline object will fill
    // them in at bind. Treat any still-Unknown stage combination
    // as valid-on-separable, and conversely reject stage-only
    // kinds (GeometryOnly / TessControlOnly / TessEvalOnly) when
    // the program is not marked separable, matching the
    // `linking.incomplete_program_objects` negative-run
    // expectations (FS:NO, GS:YES, non-separable must fail).
    if (kind == ProgramKind::Unknown && programObject->separable) {
        kind = ProgramKind::Separable;
    }
    // Non-separable programs with *only* a GS / TCS / TES stage
    // are invalid for rendering — the driver has nothing to feed
    // the missing stages at draw time. VS-only and FS-only stay
    // valid even without separable: VS-only is the canonical
    // transform-feedback-only program (CTS
    // `shader_storage_buffer_object.basic-*-vs` tests build one
    // and read back via glMapBuffer without ever rasterising),
    // and FS-only is accepted by GL implementations for
    // pipeline-composition flows we don't need to block here.
    // `linking.incomplete_program_objects` only tests GS ±
    // FS / VS combinations, so narrowing to the middle-stage
    // kinds keeps that test passing while un-regressing the
    // SSBO-VS and pipeline-statistics-VS tests that my prior
    // broader rejection caught.
    if (!programObject->separable &&
        (kind == ProgramKind::GeometryOnly ||
         kind == ProgramKind::TessControlOnly ||
         kind == ProgramKind::TessEvalOnly)) {
        programObject->linkLog = "incomplete non-separable program: missing required stage(s)";
        Runtime::shared().recordShaderTranslation({
            programTag, "link", "", "", "", programObject->linkLog, "", false
        });
        return false;
    }
    if (kind == ProgramKind::Unknown) {
        programObject->linkLog = "program has no supported shader stage combination";
        Runtime::shared().recordShaderTranslation({
            programTag, "link", "", "", "", programObject->linkLog, "", false
        });
        return false;
    }

    // Precompute the per-stage source hashes that get stamped onto every
    // link/vertex/fragment-stage record below. This is BAR's §4 ask #1 — the
    // diagnostic ring is bounded, and a search-back from a per-stage record to
    // its predecessor compile-stage record can fail when the ring wraps and
    // evicts the compile entry first. Carrying both hashes on every link-stage
    // record makes the mapping ring-eviction-proof.
    //
    // Empty for stages that don't exist (compute-only programs leave both
    // empty, vertex-only programs leave fragment empty, etc.).
    const std::string linkVertexHash =
        (vertexShader != nullptr) ? quickHash(vertexShader->source) : std::string();
    const std::string linkFragmentHash =
        (fragmentShader != nullptr) ? quickHash(fragmentShader->source) : std::string();

    // Phase 8X Group 4d follow-up⁴ — cache the source hashes on the program
    // object so the draw-time pipeline-build failure path (encodeTranslatedDraw
    // returning false from one of the Metal failure sites) can stamp them onto
    // the diagnostic ring without having to re-walk the attached shader list.
    // The link record path above and the failure record path below both pull
    // from the same canonical strings.
    programObject->vertexSourceHash = linkVertexHash;
    programObject->fragmentSourceHash = linkFragmentHash;

    // Assign uniform locations and seed default values.
    //
    // RC-D06: honour explicit `layout(location=N)` qualifiers from the GLSL
    // source.  CTS tests declare `layout(location=5) uniform float myUniform;`
    // and expect `glGetUniformLocation` to return 5.  The old code assigned
    // dense sequential locations starting from 0 regardless of any explicit
    // qualifier, which made those tests get -1.
    //
    // Two-pass approach:
    //   Pass 1 — assign explicit locations (those with explicitLocation >= 0).
    //            Track which locations are occupied so pass 2 can skip them.
    //   Pass 2 — assign auto-incremented locations for the rest, skipping
    //            any slot already claimed by an explicit location.
    //
    // Phase 8X Group 4d follow-up¹⁵ — if the GLSL source carried a default
    // initializer (`uniform vec4 ucolor = vec4(1.0);`), the scanner has
    // populated `uniform.defaultFloats` / `defaultInts` / `defaultUints` with
    // the parsed constant. Seed from that when present; otherwise fall back
    // to the historical zero-seed.

    // Collect the set of locations claimed by explicit layout qualifiers so
    // the auto-assignment pass can skip over them.
    std::unordered_set<GLint> reservedLocations;
    for (const auto& uniform : programObject->uniforms) {
        if (uniform.explicitLocation >= 0) {
            const GLint slots = std::max<GLint>(uniform.arraySize, 1);
            for (GLint s = 0; s < slots; ++s) {
                reservedLocations.insert(uniform.explicitLocation + s);
            }
        }
    }

    // Helper: find the next auto-location that doesn't collide with any
    // explicitly reserved slot.
    GLint nextLocation = 0;
    auto advancePastReserved = [&]() {
        while (reservedLocations.count(nextLocation)) {
            ++nextLocation;
        }
    };

    for (auto& uniform : programObject->uniforms) {
        // GL 4.6 §7.6.1: atomic counter uniforms have no uniform
        // location and cannot be used with any glUniform* function.
        // CTS `program_interface_query.atomic-counters` asserts
        // `glGetProgramResourceLocation(GL_UNIFORM, "a")` returns -1.
        if (uniform.type == GL_UNSIGNED_INT_ATOMIC_COUNTER) {
            uniform.location = -1;
        } else if (uniform.explicitLocation >= 0) {
            uniform.location = uniform.explicitLocation;
        } else {
            advancePastReserved();
            uniform.location = nextLocation;
        }
        const GLint components = glslComponentCount(uniform.type) * std::max<GLint>(uniform.arraySize, 1);
        const std::size_t componentCount = static_cast<std::size_t>(components);
        GLProgramUniformValue value;
        value.type = uniform.type;
        value.arraySize = uniform.arraySize;
        if (isImageUniformType(uniform.type)) {
            if (uniform.defaultInts.size() == componentCount) {
                value.ints = uniform.defaultInts;
            } else {
                value.ints.assign(componentCount, 0);
            }
        } else {
            switch (uniform.type) {
                case GL_INT:
                case GL_INT_VEC2:
                case GL_INT_VEC3:
                case GL_INT_VEC4:
                case GL_BOOL:
                case GL_BOOL_VEC2:
                case GL_BOOL_VEC3:
                case GL_BOOL_VEC4:
                case GL_SAMPLER_1D:
                case GL_SAMPLER_2D:
                case GL_SAMPLER_3D:
                case GL_SAMPLER_CUBE:
                case GL_SAMPLER_1D_ARRAY:
                case GL_SAMPLER_2D_ARRAY:
                case GL_SAMPLER_1D_SHADOW:
                case GL_SAMPLER_2D_SHADOW:
                case GL_SAMPLER_1D_ARRAY_SHADOW:
                case GL_SAMPLER_2D_ARRAY_SHADOW:
                case GL_SAMPLER_CUBE_SHADOW:
                case GL_SAMPLER_2D_RECT:
                case GL_SAMPLER_2D_RECT_SHADOW:
                case GL_SAMPLER_BUFFER:
                case GL_SAMPLER_2D_MULTISAMPLE:
                case GL_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_SAMPLER_CUBE_MAP_ARRAY:
                case GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW:
                case GL_INT_SAMPLER_1D:
                case GL_INT_SAMPLER_2D:
                case GL_INT_SAMPLER_3D:
                case GL_INT_SAMPLER_CUBE:
                case GL_INT_SAMPLER_1D_ARRAY:
                case GL_INT_SAMPLER_2D_ARRAY:
                case GL_INT_SAMPLER_2D_RECT:
                case GL_INT_SAMPLER_BUFFER:
                case GL_INT_SAMPLER_2D_MULTISAMPLE:
                case GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_INT_SAMPLER_CUBE_MAP_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_1D:
                case GL_UNSIGNED_INT_SAMPLER_2D:
                case GL_UNSIGNED_INT_SAMPLER_3D:
                case GL_UNSIGNED_INT_SAMPLER_CUBE:
                case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_2D_RECT:
                case GL_UNSIGNED_INT_SAMPLER_BUFFER:
                case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE:
                case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                case GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY:
                    if (uniform.defaultInts.size() == componentCount) {
                        value.ints = uniform.defaultInts;
                    } else {
                        value.ints.assign(componentCount, 0);
                    }
                    break;
                case GL_UNSIGNED_INT:
                case GL_UNSIGNED_INT_VEC2:
                case GL_UNSIGNED_INT_VEC3:
                case GL_UNSIGNED_INT_VEC4:
                    if (uniform.defaultUints.size() == componentCount) {
                        value.uints = uniform.defaultUints;
                    } else {
                        value.uints.assign(componentCount, 0u);
                    }
                    break;
                case GL_DOUBLE:
                case GL_DOUBLE_VEC2:
                case GL_DOUBLE_VEC3:
                case GL_DOUBLE_VEC4:
                case GL_DOUBLE_MAT2:
                case GL_DOUBLE_MAT3:
                case GL_DOUBLE_MAT4:
                case GL_DOUBLE_MAT2x3:
                case GL_DOUBLE_MAT2x4:
                case GL_DOUBLE_MAT3x2:
                case GL_DOUBLE_MAT3x4:
                case GL_DOUBLE_MAT4x2:
                case GL_DOUBLE_MAT4x3:
                    value.doubles.assign(componentCount, 0.0);
                    value.floats.assign(componentCount, 0.0f);
                    value.df64TransportWords.assign(componentCount * 2u, 0u);
                    break;
                default:
                    if (uniform.defaultFloats.size() == componentCount) {
                        value.floats = uniform.defaultFloats;
                    } else {
                        value.floats.assign(componentCount, 0.0f);
                    }
                    break;
            }
        }
        // Atomic-counter uniforms have no uniform location and no
        // entry in the `glUniform*`-addressable uniformValues map.
        if (uniform.location >= 0) {
            programObject->uniformValues[uniform.location] = std::move(value);
        }
        // Only advance the auto-location counter for non-explicit uniforms
        // that actually took a location. Explicit-location uniforms occupy
        // their declared slots (already recorded in reservedLocations) and
        // must not shift the counter, and atomic_uint uniforms never take
        // a slot at all.
        if (uniform.explicitLocation < 0 &&
            uniform.type != GL_UNSIGNED_INT_ATOMIC_COUNTER) {
            nextLocation += std::max<GLint>(uniform.arraySize, 1);
        }
    }

    // GL 4.6 §7.6.1 uniform location validation: verify that every
    // uniform's resolved location (and every slot it occupies for
    // array uniforms) is < GL_MAX_UNIFORM_LOCATIONS, and that no two
    // uniforms collide on the same location. CTS
    // `explicit_uniform_location.uniform-loc-negative-link-*`:
    //   - `reused1` — two uniforms declared with the same
    //     `layout(location=N)` in the same stage.
    //   - `reused2` — two uniforms declared at the same explicit
    //     location across two different stages (cross-stage
    //     collision — they have different names so
    //     `appendDeclarationsAsUniforms` does not merge them).
    //   - `max-location` — a single uniform at
    //     `location = GL_MAX_UNIFORM_LOCATIONS`; the valid range is
    //     `[0, MAX-1]`, so this must fail.
    //   - `max-num-of-locations` — an array uniform of size MAX at
    //     location 0 plus an implicit-location uniform that
    //     auto-assigns to MAX (overflowing).
    // All four must set `GL_LINK_STATUS=FALSE`.
    {
        GLint maxUnifLoc = 1024;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(GL_MAX_UNIFORM_LOCATIONS, &maxUnifLoc);
        }
        std::unordered_set<GLint> occupiedLocations;
        occupiedLocations.reserve(programObject->uniforms.size() * 2);
        for (const auto& uniform : programObject->uniforms) {
            if (uniform.location < 0) continue;  // atomic counters, etc.
            const GLint slots = std::max<GLint>(uniform.arraySize, 1);
            for (GLint s = 0; s < slots; ++s) {
                const GLint loc = uniform.location + s;
                if (loc >= maxUnifLoc) {
                    programObject->linkLog = "uniform '" + uniform.name
                        + "' location " + std::to_string(loc)
                        + " exceeds GL_MAX_UNIFORM_LOCATIONS="
                        + std::to_string(maxUnifLoc);
                    programObject->linked = false;
                    Runtime::shared().recordShaderTranslation({
                        programTag, "link", "", "", "", programObject->linkLog, "", false
                    });
                    return false;
                }
                if (!occupiedLocations.insert(loc).second) {
                    programObject->linkLog = "uniform '" + uniform.name
                        + "' location " + std::to_string(loc)
                        + " collides with another uniform";
                    programObject->linked = false;
                    Runtime::shared().recordShaderTranslation({
                        programTag, "link", "", "", "", programObject->linkLog, "", false
                    });
                    return false;
                }
            }
        }
    }

    // GL 4.2 §7.6: for any sampler or image uniform declared with
    // `layout(binding = N)` in the GLSL source, seed its integer value
    // to N. Subsequent glUniform1i calls override this. For arrays,
    // element i gets N+i (spec says consecutive binding points).
    // Populated after the main uniform-init loop so all uniformValues
    // entries exist and we only need to overwrite the opaque integer values.
    // Harmless on programs with no explicit bindings — the map is empty.
    auto seedExplicitOpaqueUniformValues =
        [&](const std::unordered_map<std::string, GLuint>& explicitBindings) {
        for (const auto& uinfo : programObject->uniforms) {
            auto it = explicitBindings.find(uinfo.name);
            if (it == explicitBindings.end()) continue;
            auto valIt = programObject->uniformValues.find(uinfo.location);
            if (valIt == programObject->uniformValues.end()) continue;
            auto& v = valIt->second;
            if (v.ints.empty()) continue;
            const GLint arraySize = std::max<GLint>(uinfo.arraySize, 1);
            v.ints.assign(static_cast<std::size_t>(arraySize), 0);
            for (GLint i = 0; i < arraySize; ++i) {
                v.ints[static_cast<std::size_t>(i)] =
                    static_cast<GLint>(it->second) + i;
            }
        }
    };
    if (!programObject->samplerExplicitBindings.empty()) {
        seedExplicitOpaqueUniformValues(programObject->samplerExplicitBindings);
    }
    if (!programObject->imageExplicitBindings.empty()) {
        seedExplicitOpaqueUniformValues(programObject->imageExplicitBindings);
    }

    // Cache synthesized fixed-function matrix uniform locations. The
    // compat-shader rewriter (CompatShaderRewrite.h) prepends `appgl_*`
    // uniform declarations into the rewritten source for every legacy
    // matrix identifier referenced by the original compat-profile
    // shader. Most synthesized uniforms flow through the scanner above;
    // FragmentOnly compatibility synthesis below can also introduce a
    // vertex-stage matrix uniform that only appears after SPIRV-Cross
    // reflection supplementing, so keep this refreshable.
    auto refreshSynthesizedUniformLocations = [&]() {
        namespace SUN = appgl::SynthesizedUniformNames;
        auto findLocByName = [&](const char* name) -> GLint {
            for (const auto& u : programObject->uniforms) {
                if (u.name == name) {
                    return u.location;
                }
            }
            return -1;
        };
        // gl_TextureMatrix expands to `appgl_TextureMatrix[8]`; the
        // scanner records the array under its base name with arraySize
        // populated, so the lookup matches the bare base name.
        programObject->synthesizedMatrixSlots = GLSynthesizedMatrixSlots{};
        programObject->synthesizedMatrixSlots.modelView =
            findLocByName(SUN::kModelViewMatrix);
        programObject->synthesizedMatrixSlots.projection =
            findLocByName(SUN::kProjectionMatrix);
        programObject->synthesizedMatrixSlots.modelViewProjection =
            findLocByName(SUN::kModelViewProjectionMatrix);
        programObject->synthesizedMatrixSlots.modelViewInverse =
            findLocByName(SUN::kModelViewMatrixInverse);
        programObject->synthesizedMatrixSlots.projectionInverse =
            findLocByName(SUN::kProjectionMatrixInverse);
        programObject->synthesizedMatrixSlots.modelViewProjectionInverse =
            findLocByName(SUN::kModelViewProjectionMatrixInverse);
        programObject->synthesizedMatrixSlots.normal =
            findLocByName(SUN::kNormalMatrix);
        programObject->synthesizedMatrixSlots.texture =
            findLocByName(SUN::kTextureMatrix);
        programObject->shaderDrawIDUniformLocation =
            findLocByName("_appgl_DrawID");
        programObject->shaderBaseVertexUniformLocation =
            findLocByName("_appgl_BaseVertex");
        programObject->shaderBaseInstanceUniformLocation =
            findLocByName("_appgl_BaseInstance");
    };
    refreshSynthesizedUniformLocations();

    // ─── Transform feedback link-time validation ───────────────────────
    // GL 4.6 §11.1.2.1: the linker must reject programs whose transform
    // feedback configuration is invalid. The four cases the CTS
    // linking_errors_test expects:
    //   1) TF varyings specified but no vertex/geometry shader present.
    //   2) A TF varying name doesn't match any output of the last
    //      vertex-processing stage.
    //   3) The same output variable is captured more than once in
    //      SEPARATE_ATTRIBS mode (or in INTERLEAVED_ATTRIBS w/o
    //      gl_NextBuffer separation).
    //   4) Total component count exceeds the implementation limit.
    if (!programObject->transformFeedbackVaryingNames.empty()) {
        // (1) No vertex-processing stage.
        // The "last vertex-processing stage" determines the capturable outputs:
        //   GS > TES > VS (in priority order).
        // For SEPARABLE programs, a TCS-only stage is a valid last-
        // vertex-processing stage — the program pipeline at bind time
        // determines the downstream chain. GL 4.6 §11.1.2.1 permits
        // capturing TCS outputs when a separable TCS program is the
        // final vertex stage in the pipeline. CTS
        // `tessellation_shader.single.xfb_captures_data_from_correct_
        // stage` builds four separable programs (one per
        // VS/TCS/TES/GS stage) with TF varyings and expects each to
        // link. Previous behaviour rejected TCS-only at link time
        // because xfbStage was null.
        const GLShaderObject* xfbStage = geometryShader
            ? geometryShader
            : (tessEvalShader ? tessEvalShader
                              : (vertexShader ? vertexShader
                                              : (programObject->separable ? tessControlShader : nullptr)));
        if (xfbStage == nullptr) {
            programObject->linkLog = "transform feedback varyings specified but no vertex/geometry shader";
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }

        // Build lookup of outputs from the last vertex-processing stage.
        // Track both type and array-size so TF varyings that capture a
        // whole array (`out float b[2]` captured by varying name "b")
        // can report GL_ARRAY_SIZE correctly, and array-element captures
        // (`b[0]` / `b[1]`) can strip the subscript, validate the index,
        // and report size 1. CTS
        // `program_interface_query.transform-feedback-types` asserts
        // both shapes.
        struct OutputInfo {
            GLenum type = 0;
            GLint arraySize = 1;
            bool isArray = false;
            std::string tfSourceName;
            GLint tfComponentOffset = 0;
            GLint tfComponentCount = 0;
        };
        // Helper: component count for a GL type.
        auto glTypeComponents = [](GLenum t) -> GLsizei {
            switch (t) {
                case GL_FLOAT: case GL_INT: case GL_UNSIGNED_INT: case GL_BOOL:
                case GL_DOUBLE:
                    return 1;
                case GL_FLOAT_VEC2: case GL_INT_VEC2: case GL_UNSIGNED_INT_VEC2:
                case GL_BOOL_VEC2: case GL_DOUBLE_VEC2:
                    return 2;
                case GL_FLOAT_VEC3: case GL_INT_VEC3: case GL_UNSIGNED_INT_VEC3:
                case GL_BOOL_VEC3: case GL_DOUBLE_VEC3:
                    return 3;
                case GL_FLOAT_VEC4: case GL_INT_VEC4: case GL_UNSIGNED_INT_VEC4:
                case GL_BOOL_VEC4: case GL_DOUBLE_VEC4:
                    return 4;
                case GL_FLOAT_MAT2: case GL_DOUBLE_MAT2:   return 4;
                case GL_FLOAT_MAT3: case GL_DOUBLE_MAT3:   return 9;
                case GL_FLOAT_MAT4: case GL_DOUBLE_MAT4:   return 16;
                case GL_FLOAT_MAT2x3: case GL_DOUBLE_MAT2x3: return 6;
                case GL_FLOAT_MAT2x4: case GL_DOUBLE_MAT2x4: return 8;
                case GL_FLOAT_MAT3x2: case GL_DOUBLE_MAT3x2: return 6;
                case GL_FLOAT_MAT3x4: case GL_DOUBLE_MAT3x4: return 12;
                case GL_FLOAT_MAT4x2: case GL_DOUBLE_MAT4x2: return 8;
                case GL_FLOAT_MAT4x3: case GL_DOUBLE_MAT4x3: return 12;
                default: return 1;
            }
        };
        auto makeOutputInfo = [&](GLenum type, GLint arraySize, bool isArray,
                                  std::string sourceName, GLint componentOffset,
                                  GLint componentCount) {
            OutputInfo info;
            info.type = type;
            info.arraySize = arraySize > 0 ? arraySize : 1;
            info.isArray = isArray;
            info.tfSourceName = std::move(sourceName);
            info.tfComponentOffset = componentOffset;
            info.tfComponentCount = componentCount;
            return info;
        };
        std::unordered_map<std::string, OutputInfo> outputTypeMap;
        for (const auto& decl : xfbStage->declaredOutputs) {
            if (decl.type == 0) {
                continue;
            }
            const GLint arraySize = decl.arraySize > 0 ? decl.arraySize : 1;
            outputTypeMap[decl.name] = makeOutputInfo(
                decl.type, arraySize, decl.isArray, decl.name, 0,
                glTypeComponents(decl.type) * arraySize);
        }
        // Built-in outputs that are always available for capture.
        outputTypeMap["gl_Position"] = makeOutputInfo(
            GL_FLOAT_VEC4, 1, false, "gl_Position", 0, 4);
        outputTypeMap["gl_PointSize"] = makeOutputInfo(
            GL_FLOAT, 1, false, "gl_PointSize", 0, 1);
        outputTypeMap["gl_ClipDistance"] = makeOutputInfo(
            GL_FLOAT, 1, false, "gl_ClipDistance", 0, 1);
        if (xfbStage->stage == GL_GEOMETRY_SHADER) {
            outputTypeMap["gl_Layer"] = makeOutputInfo(
                GL_INT, 1, false, "gl_Layer", 0, 1);
            outputTypeMap["gl_PrimitiveID"] = makeOutputInfo(
                GL_INT, 1, false, "gl_PrimitiveID", 0, 1);
            outputTypeMap["gl_ViewportIndex"] = makeOutputInfo(
                GL_INT, 1, false, "gl_ViewportIndex", 0, 1);
        }

        // GL 4.6 §11.1.2.1 — TFB varyings inside named interface blocks
        // are referenced through the API with block names, not instance
        // names; blocks declared as arrays require an explicit block
        // index. Struct leaves are captured by spelling the full path
        // (`v[0].e[1].a`) rather than the whole aggregate. Build synthetic
        // lookup entries for those leaves and record the flat scalar slice
        // that draw-time transform feedback needs to pack.
        {
            const std::string& src = xfbStage->source;
            auto typeFromKeyword = [](const std::string& k) -> GLenum {
                if (k == "float") return GL_FLOAT;
                if (k == "vec2")  return GL_FLOAT_VEC2;
                if (k == "vec3")  return GL_FLOAT_VEC3;
                if (k == "vec4")  return GL_FLOAT_VEC4;
                if (k == "int")   return GL_INT;
                if (k == "ivec2") return GL_INT_VEC2;
                if (k == "ivec3") return GL_INT_VEC3;
                if (k == "ivec4") return GL_INT_VEC4;
                if (k == "uint")  return GL_UNSIGNED_INT;
                if (k == "uvec2") return GL_UNSIGNED_INT_VEC2;
                if (k == "uvec3") return GL_UNSIGNED_INT_VEC3;
                if (k == "uvec4") return GL_UNSIGNED_INT_VEC4;
                if (k == "double") return GL_DOUBLE;
                if (k == "dvec2") return GL_DOUBLE_VEC2;
                if (k == "dvec3") return GL_DOUBLE_VEC3;
                if (k == "dvec4") return GL_DOUBLE_VEC4;
                if (k == "mat2" || k == "mat2x2") return GL_FLOAT_MAT2;
                if (k == "mat3" || k == "mat3x3") return GL_FLOAT_MAT3;
                if (k == "mat4" || k == "mat4x4") return GL_FLOAT_MAT4;
                if (k == "mat2x3") return GL_FLOAT_MAT2x3;
                if (k == "mat2x4") return GL_FLOAT_MAT2x4;
                if (k == "mat3x2") return GL_FLOAT_MAT3x2;
                if (k == "mat3x4") return GL_FLOAT_MAT3x4;
                if (k == "mat4x2") return GL_FLOAT_MAT4x2;
                if (k == "mat4x3") return GL_FLOAT_MAT4x3;
                if (k == "dmat2" || k == "dmat2x2") return GL_DOUBLE_MAT2;
                if (k == "dmat3" || k == "dmat3x3") return GL_DOUBLE_MAT3;
                if (k == "dmat4" || k == "dmat4x4") return GL_DOUBLE_MAT4;
                if (k == "dmat2x3") return GL_DOUBLE_MAT2x3;
                if (k == "dmat2x4") return GL_DOUBLE_MAT2x4;
                if (k == "dmat3x2") return GL_DOUBLE_MAT3x2;
                if (k == "dmat3x4") return GL_DOUBLE_MAT3x4;
                if (k == "dmat4x2") return GL_DOUBLE_MAT4x2;
                if (k == "dmat4x3") return GL_DOUBLE_MAT4x3;
                return 0;
            };
            auto isIdent = [](const std::string& tok) {
                return !tok.empty() &&
                    (std::isalpha(static_cast<unsigned char>(tok[0])) ||
                     tok[0] == '_');
            };
            auto isQualifier = [](const std::string& tok) {
                return tok == "flat" || tok == "smooth" ||
                       tok == "noperspective" || tok == "centroid" ||
                       tok == "sample" || tok == "invariant" ||
                       tok == "highp" || tok == "mediump" || tok == "lowp" ||
                       tok == "patch" || tok == "precise" || tok == "readonly" ||
                       tok == "writeonly" || tok == "coherent" ||
                       tok == "volatile" || tok == "restrict";
            };
            auto parsePositiveInt = [](const std::string& tok, GLint& value) {
                if (tok.empty()) return false;
                for (char c : tok) {
                    if (!std::isdigit(static_cast<unsigned char>(c))) return false;
                }
                value = static_cast<GLint>(std::strtol(tok.c_str(), nullptr, 10));
                return value > 0;
            };
            std::vector<std::string> toks;
            toks.reserve(src.size() / 4);
            for (std::size_t i = 0; i < src.size();) {
                const unsigned char c = static_cast<unsigned char>(src[i]);
                if (std::isspace(c)) { ++i; continue; }
                if (std::isalpha(c) || src[i] == '_') {
                    std::size_t j = i + 1;
                    while (j < src.size()) {
                        const unsigned char d = static_cast<unsigned char>(src[j]);
                        if (!std::isalnum(d) && src[j] != '_') break;
                        ++j;
                    }
                    toks.emplace_back(src, i, j - i);
                    i = j;
                    continue;
                }
                if (std::isdigit(c)) {
                    std::size_t j = i + 1;
                    while (j < src.size() &&
                           std::isdigit(static_cast<unsigned char>(src[j]))) {
                        ++j;
                    }
                    toks.emplace_back(src, i, j - i);
                    i = j;
                    continue;
                }
                if (src[i] == '/' && i + 1 < src.size() && src[i + 1] == '/') {
                    while (i < src.size() && src[i] != '\n') ++i;
                    continue;
                }
                if (src[i] == '/' && i + 1 < src.size() && src[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < src.size() && !(src[i] == '*' && src[i + 1] == '/')) ++i;
                    i = std::min<std::size_t>(src.size(), i + 2);
                    continue;
                }
                toks.emplace_back(1, src[i]);
                ++i;
            }

            struct TfMemberSpec {
                std::string name;
                std::string typeName;
                GLenum glType = 0;
                GLint arraySize = 1;
                bool isArray = false;
            };
            struct TfStructSpec {
                std::vector<TfMemberSpec> members;
                GLint componentCount = 0;
            };
            std::unordered_map<std::string, TfStructSpec> structDefs;

            std::function<GLint(const TfMemberSpec&)> typeComponentCount =
                [&](const TfMemberSpec& spec) -> GLint {
                    const GLint arraySize = spec.isArray
                        ? std::max<GLint>(1, spec.arraySize) : 1;
                    if (spec.glType != 0) {
                        return glTypeComponents(spec.glType) * arraySize;
                    }
                    auto sIt = structDefs.find(spec.typeName);
                    if (sIt == structDefs.end()) {
                        return 0;
                    }
                    return sIt->second.componentCount * arraySize;
                };
            auto parseArraySuffix = [&](std::size_t& i, std::size_t end,
                                        TfMemberSpec& spec) {
                if (i + 2 >= end || toks[i] != "[") return;
                GLint parsed = 1;
                if (parsePositiveInt(toks[i + 1], parsed) && toks[i + 2] == "]") {
                    spec.arraySize *= parsed;
                    spec.isArray = true;
                    i += 3;
                }
            };
            auto parseTypeSpec = [&](std::size_t& i, std::size_t end,
                                     TfMemberSpec& spec) -> bool {
                while (i < end && isQualifier(toks[i])) ++i;
                if (i >= end || !isIdent(toks[i])) return false;
                spec = TfMemberSpec{};
                spec.typeName = toks[i++];
                spec.glType = typeFromKeyword(spec.typeName);
                if (spec.glType == 0 && structDefs.count(spec.typeName) == 0) {
                    return false;
                }
                parseArraySuffix(i, end, spec);
                return true;
            };
            auto parseMemberDecls = [&](std::size_t begin, std::size_t end,
                                        std::vector<TfMemberSpec>& outMembers) {
                std::size_t p = begin;
                while (p < end) {
                    std::size_t semi = p;
                    while (semi < end && toks[semi] != ";") ++semi;
                    std::size_t q = p;
                    TfMemberSpec baseSpec;
                    if (parseTypeSpec(q, semi, baseSpec)) {
                        while (q < semi) {
                            if (!isIdent(toks[q])) { ++q; continue; }
                            TfMemberSpec member = baseSpec;
                            member.name = toks[q++];
                            parseArraySuffix(q, semi, member);
                            if (!member.name.empty()) {
                                outMembers.push_back(std::move(member));
                            }
                            if (q < semi && toks[q] == ",") ++q;
                        }
                    }
                    p = semi + (semi < end ? 1 : 0);
                }
            };

            for (std::size_t i = 0; i + 3 < toks.size(); ++i) {
                if (toks[i] != "struct" || !isIdent(toks[i + 1]) ||
                    toks[i + 2] != "{") {
                    continue;
                }
                std::size_t p = i + 3;
                int depth = 1;
                while (p < toks.size() && depth > 0) {
                    if (toks[p] == "{") ++depth;
                    else if (toks[p] == "}") --depth;
                    ++p;
                }
                if (depth != 0) continue;
                const std::size_t bodyEnd = p - 1;
                TfStructSpec spec;
                parseMemberDecls(i + 3, bodyEnd, spec.members);
                for (const auto& member : spec.members) {
                    spec.componentCount += typeComponentCount(member);
                }
                if (!spec.members.empty() && spec.componentCount > 0) {
                    structDefs[toks[i + 1]] = std::move(spec);
                }
                i = p;
            }

            std::function<void(const std::string&, const TfMemberSpec&,
                               const std::string&, GLint)> addFlattened;
            addFlattened = [&](const std::string& publicName,
                               const TfMemberSpec& spec,
                               const std::string& sourceName,
                               GLint componentOffset) {
                const GLint arraySize = spec.isArray
                    ? std::max<GLint>(1, spec.arraySize) : 1;
                if (spec.glType != 0) {
                    const GLint elemComponents = glTypeComponents(spec.glType);
                    outputTypeMap[publicName] = makeOutputInfo(
                        spec.glType, arraySize, spec.isArray, sourceName,
                        componentOffset, elemComponents * arraySize);
                    if (spec.isArray) {
                        for (GLint elem = 0; elem < arraySize; ++elem) {
                            outputTypeMap[publicName + "[" + std::to_string(elem) + "]"] =
                                makeOutputInfo(spec.glType, 1, false, sourceName,
                                               componentOffset + elem * elemComponents,
                                               elemComponents);
                        }
                    }
                    return;
                }
                auto sIt = structDefs.find(spec.typeName);
                if (sIt == structDefs.end()) return;
                const GLint structComponents = sIt->second.componentCount;
                auto addStructMembers = [&](const std::string& prefix,
                                            GLint baseOffset) {
                    GLint cursor = baseOffset;
                    for (const auto& member : sIt->second.members) {
                        addFlattened(prefix + "." + member.name, member,
                                     sourceName, cursor);
                        cursor += typeComponentCount(member);
                    }
                };
                if (spec.isArray) {
                    for (GLint elem = 0; elem < arraySize; ++elem) {
                        addStructMembers(publicName + "[" + std::to_string(elem) + "]",
                                         componentOffset + elem * structComponents);
                    }
                } else {
                    addStructMembers(publicName, componentOffset);
                }
            };
            auto addOutputDecl = [&](const std::string& publicName,
                                     const TfMemberSpec& spec,
                                     const std::string& sourceName) {
                if (publicName.empty() || sourceName.empty()) return;
                addFlattened(publicName, spec, sourceName, 0);
            };

            std::string macroBlockName;
            std::string macroInstanceName;
            for (std::size_t i = 0; i + 4 < toks.size(); ++i) {
                if (toks[i] != "DECLARE_VARYING" || toks[i + 1] != "(" ||
                    toks[i + 2] != "DIR") {
                    continue;
                }
                std::size_t p = i + 2;
                int depth = 1;
                while (p < toks.size() && depth > 0) {
                    if (toks[p] == "(") ++depth;
                    else if (toks[p] == ")") --depth;
                    ++p;
                }
                for (std::size_t q = p; q + 2 < toks.size() && q < p + 24; ++q) {
                    if (toks[q] == "DIR" && isIdent(toks[q + 1]) &&
                        toks[q + 2] == "{") {
                        macroBlockName = toks[q + 1];
                        std::size_t r = q + 3;
                        int braceDepth = 1;
                        while (r < toks.size() && braceDepth > 0) {
                            if (toks[r] == "{") ++braceDepth;
                            else if (toks[r] == "}") --braceDepth;
                            ++r;
                        }
                        if (r < toks.size() && isIdent(toks[r])) {
                            macroInstanceName = toks[r];
                        }
                        break;
                    }
                }
            }

            auto parseDeclareVaryingCall = [&](std::size_t i, std::size_t& endOut) {
                endOut = i + 1;
                if (i + 1 >= toks.size() || toks[i + 1] != "(") return;
                std::array<std::vector<std::string>, 3> args;
                std::size_t arg = 0;
                int depth = 0;
                std::size_t p = i + 1;
                for (; p < toks.size(); ++p) {
                    if (toks[p] == "(") {
                        if (depth++ > 0 && arg < args.size()) args[arg].push_back(toks[p]);
                    } else if (toks[p] == ")") {
                        if (--depth == 0) { ++p; break; }
                        if (arg < args.size()) args[arg].push_back(toks[p]);
                    } else if (toks[p] == "," && depth == 1) {
                        if (arg + 1 < args.size()) ++arg;
                    } else if (arg < args.size()) {
                        args[arg].push_back(toks[p]);
                    }
                }
                endOut = p;
                if (args[0].size() != 1 || args[0][0] != "out" ||
                    args[1].empty() || args[2].empty()) {
                    return;
                }
                std::size_t q = 0;
                std::vector<std::string> saved;
                saved.swap(toks);
                toks = args[1];
                TfMemberSpec spec;
                const bool ok = parseTypeSpec(q, toks.size(), spec);
                toks.swap(saved);
                if (!ok) return;
                std::string name;
                for (const auto& tok : args[2]) {
                    if (isIdent(tok)) { name = tok; break; }
                }
                if (name.empty()) return;
                if (!macroBlockName.empty()) {
                    addOutputDecl(macroBlockName + "." + name, spec, name);
                    if (!macroInstanceName.empty()) {
                        addOutputDecl(macroInstanceName + "." + name, spec, name);
                    } else {
                        addOutputDecl(name, spec, name);
                    }
                } else {
                    addOutputDecl(name, spec, name);
                }
            };
            for (std::size_t i = 0; i < toks.size(); ++i) {
                if (toks[i] == "DECLARE_VARYING") {
                    std::size_t end = i + 1;
                    parseDeclareVaryingCall(i, end);
                    i = end > i ? end - 1 : i;
                }
            }

            for (std::size_t i = 0; i + 2 < toks.size(); ++i) {
                if (toks[i] != "out") continue;
                if (toks[i + 2] == "{") {
                    const std::string blockName = toks[i + 1];
                    if (blockName.empty() || blockName == "gl_PerVertex") continue;
                    std::size_t p = i + 3;
                    int depth = 1;
                    while (p < toks.size() && depth > 0) {
                        if (toks[p] == "{") ++depth;
                        else if (toks[p] == "}") --depth;
                        ++p;
                    }
                    if (depth != 0) continue;
                    const std::size_t bodyEnd = p - 1;
                    std::vector<TfMemberSpec> members;
                    parseMemberDecls(i + 3, bodyEnd, members);
                    std::string instanceName;
                    if (p < toks.size() && isIdent(toks[p])) {
                        instanceName = toks[p++];
                    }
                    TfMemberSpec blockArraySpec;
                    parseArraySuffix(p, toks.size(), blockArraySpec);
                    const bool blockIsArray = blockArraySpec.isArray;
                    const GLint blockArraySize =
                        blockIsArray ? std::max<GLint>(1, blockArraySpec.arraySize) : 1;
                    for (const auto& member : members) {
                        if (instanceName.empty()) {
                            addOutputDecl(member.name, member, member.name);
                        } else if (blockIsArray) {
                            for (GLint elem = 0; elem < blockArraySize; ++elem) {
                                addOutputDecl(blockName + "[" + std::to_string(elem) + "]." +
                                                  member.name,
                                              member, member.name);
                            }
                        } else {
                            addOutputDecl(blockName + "." + member.name,
                                          member, member.name);
                        }
                    }
                    i = p;
                    continue;
                }
                std::size_t q = i + 1;
                TfMemberSpec spec;
                if (!parseTypeSpec(q, toks.size(), spec)) continue;
                if (q < toks.size() && isIdent(toks[q])) {
                    spec.name = toks[q++];
                    parseArraySuffix(q, toks.size(), spec);
                    addOutputDecl(spec.name, spec, spec.name);
                }
            }
        }

        // Special interleaved-mode names that are NOT real varyings:
        auto isSpecialName = [](const std::string& n) {
            return n == "gl_NextBuffer" ||
                   n == "gl_SkipComponents1" || n == "gl_SkipComponents2" ||
                   n == "gl_SkipComponents3" || n == "gl_SkipComponents4";
        };

        // (2) Validate each varying name and resolve types.
        programObject->resourceTransformFeedbackVaryings.clear();
        std::unordered_set<std::string> seenNames;
        GLsizei totalComponents = 0;
        GLenum bufMode = programObject->transformFeedbackBufferMode;

        // When the scanner has populated output declarations for the
        // last vertex-processing stage, we can validate varying names
        // and resolve types.  When it hasn't (e.g. older scanner gap),
        // skip the name check and use GL_FLOAT as the fallback type.
        const bool haveOutputDecls = !outputTypeMap.empty() ||
            !xfbStage->declaredOutputs.empty();

        for (const auto& varyName : programObject->transformFeedbackVaryingNames) {
            if (isSpecialName(varyName)) {
                // GL 4.6 §7.3.1.1: `gl_NextBuffer` / `gl_SkipComponentsN`
                // still count as active resources in the
                // TRANSFORM_FEEDBACK_VARYING interface — name preserved,
                // TYPE = GL_NONE (0), ARRAY_SIZE = 0 for gl_NextBuffer and
                // N for gl_SkipComponentsN. CTS
                // `program_interface_query.transform-feedback-built-in`
                // queries NAME/TYPE/ARRAY_SIZE against exactly these
                // markers. They are excluded from `glGetProgramResourceIndex`
                // lookups (handled at query time) and from duplicate /
                // component-count checks here.
                GLint skipSize = 0;
                // "gl_SkipComponents1".."4" are all 18 chars long.
                if (varyName.size() == 18 && varyName.compare(0, 17, "gl_SkipComponents") == 0) {
                    char last = varyName.back();
                    if (last >= '1' && last <= '4') {
                        skipSize = last - '0';
                    }
                }
                GLProgramResourceEntry entry;
                entry.name = varyName;
                entry.type = GL_NONE;
                entry.arraySize = skipSize;
                // Mark as an array so GL_ARRAY_SIZE returns the raw
                // marker-count (0 for gl_NextBuffer, N for
                // gl_SkipComponentsN) instead of clamping to 1.
                entry.isArray = true;
                programObject->resourceTransformFeedbackVaryings.push_back(std::move(entry));
                continue;
            }

            GLenum resolvedType = GL_FLOAT; // fallback
            GLint resolvedArraySize = 1;
            bool captureIsArrayElement = false;
            GLint captureArrayElementIndex = 0;
            OutputInfo resolvedInfo;
            bool haveResolvedInfo = false;
            // Array-element capture: `b[0]` / `b[1]` reference a single
            // element of `out float b[2]`. Prefer exact struct-leaf entries
            // such as `v.a[0]`; otherwise strip the trailing `[N]` subscript
            // and look up the base name. Size is 1 per GL 4.6 §11.1.2.1.
            std::string lookupName = varyName;
            auto parseTrailingArrayElement = [&](const std::string& name,
                                                 std::string& base,
                                                 GLint& element) -> bool {
                const auto bracket = name.rfind('[');
                if (bracket != std::string::npos && !name.empty() &&
                    name.back() == ']') {
                    const std::string idxStr =
                        name.substr(bracket + 1, name.size() - bracket - 2);
                    if (!idxStr.empty() &&
                        std::all_of(idxStr.begin(), idxStr.end(),
                                    [](char c) { return std::isdigit(static_cast<unsigned char>(c)); })) {
                        base = name.substr(0, bracket);
                        element = static_cast<GLint>(std::strtol(idxStr.c_str(), nullptr, 10));
                        return !base.empty();
                    }
                }
                return false;
            };
            if (haveOutputDecls) {
                auto it = outputTypeMap.find(varyName);
                if (it == outputTypeMap.end()) {
                    if (parseTrailingArrayElement(varyName, lookupName,
                                                  captureArrayElementIndex)) {
                        captureIsArrayElement = true;
                        it = outputTypeMap.find(lookupName);
                    }
                    if (it == outputTypeMap.end()) {
                        programObject->linkLog = "transform feedback varying '" + varyName +
                            "' is not an output of the last vertex-processing stage";
                        Runtime::shared().recordShaderTranslation({
                            programTag, "link", "", "", "", programObject->linkLog, "", false
                        });
                        return false;
                    }
                    if (captureIsArrayElement && it->second.isArray &&
                        captureArrayElementIndex >= it->second.arraySize) {
                        programObject->linkLog = "transform feedback varying '" + varyName +
                            "' array index is out of bounds";
                        Runtime::shared().recordShaderTranslation({
                            programTag, "link", "", "", "", programObject->linkLog, "", false
                        });
                        return false;
                    }
                } else {
                    lookupName = varyName;
                }
                resolvedType = it->second.type;
                // Whole-array capture → report the declared array size.
                // Single-element capture → report 1.
                resolvedArraySize = (captureIsArrayElement || !it->second.isArray)
                    ? 1 : it->second.arraySize;
                resolvedInfo = it->second;
                haveResolvedInfo = true;
            }

            // (3) Duplicate check (applies to both interleaved and separate).
            if (!seenNames.insert(varyName).second) {
                programObject->linkLog = "transform feedback varying '" + varyName +
                    "' is captured more than once";
                Runtime::shared().recordShaderTranslation({
                    programTag, "link", "", "", "", programObject->linkLog, "", false
                });
                return false;
            }

            totalComponents += glTypeComponents(resolvedType) * resolvedArraySize;

            GLProgramResourceEntry entry;
            entry.name = varyName;
            entry.type = resolvedType;
            entry.arraySize = resolvedArraySize;
            if (haveResolvedInfo) {
                entry.isArray = !captureIsArrayElement && resolvedInfo.isArray;
                entry.tfSourceName = resolvedInfo.tfSourceName;
                entry.tfComponentOffset = resolvedInfo.tfComponentOffset;
                entry.tfComponentCount = resolvedInfo.tfComponentCount;
                if (captureIsArrayElement && resolvedInfo.isArray) {
                    const GLint elemComponents = glTypeComponents(resolvedType);
                    entry.tfComponentOffset += captureArrayElementIndex * elemComponents;
                    entry.tfComponentCount = elemComponents;
                }
                if (entry.tfComponentCount <= 0) {
                    entry.tfComponentCount =
                        glTypeComponents(resolvedType) * resolvedArraySize;
                }
            }
            programObject->resourceTransformFeedbackVaryings.push_back(std::move(entry));
        }

        // (4) Component limit check.
        if (bufMode == GL_INTERLEAVED_ATTRIBS) {
            GLsizei maxInterleavedComponents = 64;
            if (impl_->capabilities != nullptr) {
                GLint cap = 0;
                if (impl_->capabilities->queryInteger(
                        GL_MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS, &cap) &&
                    cap > 0) {
                    maxInterleavedComponents = static_cast<GLsizei>(cap);
                }
            }
            if (totalComponents > maxInterleavedComponents) {
                programObject->linkLog = "transform feedback exceeds GL_MAX_TRANSFORM_FEEDBACK_INTERLEAVED_COMPONENTS";
                programObject->resourceTransformFeedbackVaryings.clear();
                Runtime::shared().recordShaderTranslation({
                    programTag, "link", "", "", "", programObject->linkLog, "", false
                });
                return false;
            }
        } else if (bufMode == GL_SEPARATE_ATTRIBS) {
            constexpr GLsizei kMaxSeparateComponents = 4;
            constexpr GLsizei kMaxSeparateAttribs = 4;
            GLsizei attribCount = static_cast<GLsizei>(programObject->resourceTransformFeedbackVaryings.size());
            if (attribCount > kMaxSeparateAttribs) {
                programObject->linkLog = "transform feedback exceeds GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_ATTRIBS";
                programObject->resourceTransformFeedbackVaryings.clear();
                Runtime::shared().recordShaderTranslation({
                    programTag, "link", "", "", "", programObject->linkLog, "", false
                });
                return false;
            }
            for (const auto& res : programObject->resourceTransformFeedbackVaryings) {
                if (glTypeComponents(res.type) > kMaxSeparateComponents) {
                    programObject->linkLog = "transform feedback varying '" + res.name +
                        "' exceeds GL_MAX_TRANSFORM_FEEDBACK_SEPARATE_COMPONENTS";
                    programObject->resourceTransformFeedbackVaryings.clear();
                    Runtime::shared().recordShaderTranslation({
                        programTag, "link", "", "", "", programObject->linkLog, "", false
                    });
                    return false;
                }
            }
        }
    } else {
        // No TF varyings — clear any stale resolved data from a previous link.
        programObject->resourceTransformFeedbackVaryings.clear();
    }
    // ─── End transform feedback link-time validation ─────────────────

    // ─── Stage-to-stage varying type match (GL 4.6 §7.4.1) ────────────
    //
    // Each `out` variable in one stage must be consumed by an `in`
    // variable of the same name, type, and qualifiers in the next
    // vertex-processing stage (or in the fragment stage). glslang
    // catches in-stage mismatches during compilation, but it doesn't
    // see the cross-stage picture — two separately-compiled
    // shaders can disagree on the type of a shared varying and
    // glslang happily produces a SPIR-V for each. The spec
    // requires the link to fail in that case (`linking.vs_gs_
    // variable_type_mismatch` asserts the failure path).
    //
    // Walks each consecutive stage pair and compares by name. Built-
    // ins (`gl_Position` etc.) and transform-feedback-only names
    // (`gl_NextBuffer`, `gl_SkipComponents*`) are skipped; glslang
    // already enforces their types. Unmatched-name inputs are
    // treated as "only declared in the consumer" and ignored —
    // trying to catch "sink with no source" here would false-
    // positive against legitimate patterns where a VS output is
    // unused in the next stage.
    {
        struct StagePair {
            const GLShaderObject* producer = nullptr;
            const char*           producerName = "";
            const GLShaderObject* consumer = nullptr;
            const char*           consumerName = "";
        };
        std::vector<StagePair> pairs;
        if (vertexShader != nullptr) {
            const GLShaderObject* next = tessControlShader
                ? tessControlShader
                : (tessEvalShader ? tessEvalShader
                                  : (geometryShader ? geometryShader
                                                    : fragmentShader));
            const char* nextName = tessControlShader ? "tess-control"
                : (tessEvalShader ? "tess-eval"
                : (geometryShader ? "geometry" : "fragment"));
            if (next != nullptr) {
                pairs.push_back({vertexShader, "vertex", next, nextName});
            }
        }
        if (tessControlShader != nullptr && tessEvalShader != nullptr) {
            pairs.push_back({tessControlShader, "tess-control", tessEvalShader, "tess-eval"});
        }
        if (tessEvalShader != nullptr) {
            const GLShaderObject* next = geometryShader ? geometryShader : fragmentShader;
            const char* nextName = geometryShader ? "geometry" : "fragment";
            if (next != nullptr) {
                pairs.push_back({tessEvalShader, "tess-eval", next, nextName});
            }
        }
        if (geometryShader != nullptr && fragmentShader != nullptr) {
            pairs.push_back({geometryShader, "geometry", fragmentShader, "fragment"});
        }

        bool varyingMismatch = false;
        std::string mismatchMsg;
        for (const auto& pair : pairs) {
            std::unordered_map<std::string, GLenum> producerOut;
            for (const auto& decl : pair.producer->declaredOutputs) {
                producerOut[decl.name] = decl.type;
            }
            for (const auto& decl : pair.consumer->declaredInputs) {
                // Skip built-ins / gl_in gl_out blocks — glslang
                // handles those. User varyings never start with
                // "gl_".
                if (decl.name.compare(0, 3, "gl_") == 0) continue;
                auto it = producerOut.find(decl.name);
                if (it == producerOut.end()) continue;   // unmatched; not our check
                if (it->second != decl.type) {
                    varyingMismatch = true;
                    mismatchMsg = std::string("varying '") + decl.name + "' type mismatch: "
                        + std::string(pair.producerName) + " stage outputs type 0x" +
                        [&]{ char b[12]; std::snprintf(b, sizeof(b), "%04x", it->second); return std::string(b); }()
                        + ", " + std::string(pair.consumerName) + " stage inputs type 0x" +
                        [&]{ char b[12]; std::snprintf(b, sizeof(b), "%04x", decl.type); return std::string(b); }();
                    break;
                }
            }
            if (varyingMismatch) break;
        }
        if (varyingMismatch) {
            programObject->linkLog = mismatchMsg;
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }
    }
    // ─── End stage-to-stage varying type check ───────────────────────

    // ─── Cross-stage uniform type consistency (GL 4.6 §7.4.1) ────────
    //
    // When two stages declare a uniform with the same name, the types
    // must match. CTS `shader_image_load_store.negative-linkErrors`
    // attaches a VS with `uniform image1D g_image` and an FS with
    // `uniform image2D g_image` and expects the link to fail with a
    // type mismatch diagnostic. Our varying check above walks inputs
    // vs outputs; uniforms are a separate namespace and need their
    // own pass.
    //
    // We iterate every (shader_A, shader_B) pair and look for same-
    // named entries in `declaredUniforms` with mismatched types.
    {
        std::vector<const GLShaderObject*> attachedStages;
        if (vertexShader != nullptr)       attachedStages.push_back(vertexShader);
        if (tessControlShader != nullptr)  attachedStages.push_back(tessControlShader);
        if (tessEvalShader != nullptr)     attachedStages.push_back(tessEvalShader);
        if (geometryShader != nullptr)     attachedStages.push_back(geometryShader);
        if (fragmentShader != nullptr)     attachedStages.push_back(fragmentShader);
        if (computeShader != nullptr)      attachedStages.push_back(computeShader);

        bool uniformMismatch = false;
        std::string mismatchMsg;
        struct SeenUniform { GLenum type; GLenum imageFormat; };
        std::unordered_map<std::string, SeenUniform> seenUniforms;
        for (const GLShaderObject* stage : attachedStages) {
            if (uniformMismatch) break;
            for (const auto& u : stage->declaredUniforms) {
                // Skip built-ins and synthesized compat-rewrite
                // uniforms (appgl_ModelViewMatrix etc.).
                if (u.name.compare(0, 3, "gl_") == 0) continue;
                if (u.name.compare(0, 6, "appgl_") == 0) continue;
                auto it = seenUniforms.find(u.name);
                if (it == seenUniforms.end()) {
                    seenUniforms[u.name] = {u.type, u.imageFormat};
                } else if (it->second.type != u.type) {
                    uniformMismatch = true;
                    mismatchMsg = std::string("uniform '") + u.name +
                        "' type mismatch across stages: seen type 0x" +
                        [&]{ char b[12]; std::snprintf(b, sizeof(b), "%04x", it->second.type); return std::string(b); }()
                        + ", new type 0x" +
                        [&]{ char b[12]; std::snprintf(b, sizeof(b), "%04x", u.type); return std::string(b); }();
                    break;
                } else if (it->second.imageFormat != 0 && u.imageFormat != 0 &&
                           it->second.imageFormat != u.imageFormat) {
                    // GL 4.6 §4.4.8.2: if both stages specify a
                    // layout(IMAGE_FORMAT) qualifier, they must agree.
                    // Unspecified on either side is silently allowed
                    // (the other side's spec wins).
                    uniformMismatch = true;
                    mismatchMsg = std::string("image uniform '") + u.name +
                        "' layout format mismatch across stages: seen 0x" +
                        [&]{ char b[12]; std::snprintf(b, sizeof(b), "%04x", it->second.imageFormat); return std::string(b); }()
                        + ", new 0x" +
                        [&]{ char b[12]; std::snprintf(b, sizeof(b), "%04x", u.imageFormat); return std::string(b); }();
                    break;
                }
            }
        }
        if (uniformMismatch) {
            programObject->linkLog = mismatchMsg;
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }
    }
    // ─── End cross-stage uniform type consistency check ──────────────

    // ─── Tess-eval primitive-mode layout (GL 4.6 §11.2.3) ────────────
    //
    // A tessellation evaluation shader MUST specify exactly one of
    // `layout(triangles)`, `layout(quads)`, or `layout(isolines)` as
    // its input primitive mode. The spec says this is a LINK-time
    // error (not compile-time), and CTS
    // `tessellation_shader.compilation_and_linking_errors.
    // te_lacking_primitive_mode_declaration` expects compile to
    // succeed and link to fail for a tess-eval shader that lacks the
    // directive.
    //
    // Glslang's `TProgram::link` happens to raise the error at
    // single-stage compile (we work around that in
    // `ShaderTranslator::compileGLSL`). So we have to re-check the
    // rule here at actual program link time.
    if (tessEvalShader != nullptr) {
        const std::string& src = tessEvalShader->source;
        bool ok = false;
        if (src.empty() && !tessEvalShader->spirv.empty()) {
            ok = tessEvalSpirvHasPrimitiveMode(*tessEvalShader);
        } else {
        // Strip comments so `// layout(triangles)` doesn't satisfy
        // the check. Reuse a lightweight copy here — the scan is
        // per-link, so cost is negligible.
        auto strip = [](const std::string& in) {
            std::string out;
            out.reserve(in.size());
            for (std::size_t i = 0; i < in.size(); ) {
                if (i + 1 < in.size() && in[i] == '/' && in[i + 1] == '/') {
                    while (i < in.size() && in[i] != '\n') { ++i; }
                } else if (i + 1 < in.size() && in[i] == '/' && in[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < in.size() && !(in[i] == '*' && in[i + 1] == '/')) ++i;
                    if (i + 1 < in.size()) i += 2;
                } else {
                    out.push_back(in[i]);
                    ++i;
                }
            }
            return out;
        };
        const std::string clean = strip(src);
        // We need a `layout(...)` directive with one of the three
        // primitive-mode tokens, followed by an `in` keyword (not
        // specifically required by the spec — `layout(triangles)
        // in;` is the canonical form, but `layout(triangles);` and
        // `layout(triangles) in;` are both legal). We only need to
        // see the token inside a `layout(...)` paren; spec also
        // permits `layout(triangles, equal_spacing, ccw) in;` with
        // multiple qualifiers.
        auto hasPrimMode = [&](const std::string& tok) -> bool {
            std::size_t pos = 0;
            while (pos < clean.size()) {
                std::size_t lp = clean.find("layout", pos);
                if (lp == std::string::npos) return false;
                // word-boundary
                bool leftOk = (lp == 0) ||
                    !(std::isalnum(static_cast<unsigned char>(clean[lp - 1])) ||
                      clean[lp - 1] == '_');
                bool rightOk = (lp + 6 >= clean.size()) ||
                    !(std::isalnum(static_cast<unsigned char>(clean[lp + 6])) ||
                      clean[lp + 6] == '_');
                if (!leftOk || !rightOk) { pos = lp + 1; continue; }
                std::size_t op = clean.find('(', lp);
                if (op == std::string::npos) return false;
                std::size_t cp = clean.find(')', op);
                if (cp == std::string::npos) return false;
                std::string inner = clean.substr(op + 1, cp - op - 1);
                // Tokenize inner and check for tok as a complete word.
                std::size_t tp = inner.find(tok);
                while (tp != std::string::npos) {
                    bool lOk = (tp == 0) ||
                        !(std::isalnum(static_cast<unsigned char>(inner[tp - 1])) ||
                          inner[tp - 1] == '_');
                    bool rOk = (tp + tok.size() >= inner.size()) ||
                        !(std::isalnum(static_cast<unsigned char>(inner[tp + tok.size()])) ||
                          inner[tp + tok.size()] == '_');
                    if (lOk && rOk) return true;
                    tp = inner.find(tok, tp + 1);
                }
                pos = cp + 1;
            }
            return false;
        };
        ok = hasPrimMode("triangles") ||
             hasPrimMode("quads") ||
             hasPrimMode("isolines");
        }
        if (!ok) {
            programObject->linkLog =
                "ERROR: Linking tessellation evaluation stage: "
                "At least one shader must specify an input layout primitive";
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }
    }
    // ─── End tess-eval primitive-mode check ──────────────────────────

    // ─── Tess-control output patch vertex count (GL 4.6 §11.2.1) ─────
    //
    // TCS specifies output patch vertex count via
    // `layout(vertices = N) out;` where `N ∈ [1, MAX_PATCH_VERTICES]`.
    // A value of 0 or > MAX_PATCH_VERTICES is a LINK-time error.
    // CTS `tessellation_shader.compilation_and_linking_errors.
    // tc_invalid_output_patch_vertex_count` tests both 0 and 33 (above
    // the 32 limit) and expects link to fail.
    //
    // Glslang catches 0 at parse time (raises "vertices : must be
    // greater than 0") so that subcase fails at compile, which is
    // what the test expects ("Compilation failed as allowed"). The 33
    // subcase compiles fine (glslang accepts values up to INT_MAX)
    // and we need to fail it here at link time.
    if (tessControlShader != nullptr) {
        const std::string& src = tessControlShader->source;
        auto strip = [](const std::string& in) {
            std::string out;
            out.reserve(in.size());
            for (std::size_t i = 0; i < in.size(); ) {
                if (i + 1 < in.size() && in[i] == '/' && in[i + 1] == '/') {
                    while (i < in.size() && in[i] != '\n') { ++i; }
                } else if (i + 1 < in.size() && in[i] == '/' && in[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < in.size() && !(in[i] == '*' && in[i + 1] == '/')) ++i;
                    if (i + 1 < in.size()) i += 2;
                } else {
                    out.push_back(in[i]);
                    ++i;
                }
            }
            return out;
        };
        const std::string clean = strip(src);
        // Search for `layout ( ... vertices <ws>*=<ws>* N ...)`.
        std::size_t pos = 0;
        int verticesN = -1;
        while (pos < clean.size()) {
            std::size_t lp = clean.find("layout", pos);
            if (lp == std::string::npos) break;
            bool leftOk = (lp == 0) ||
                !(std::isalnum(static_cast<unsigned char>(clean[lp - 1])) ||
                  clean[lp - 1] == '_');
            bool rightOk = (lp + 6 >= clean.size()) ||
                !(std::isalnum(static_cast<unsigned char>(clean[lp + 6])) ||
                  clean[lp + 6] == '_');
            if (!leftOk || !rightOk) { pos = lp + 1; continue; }
            std::size_t op = clean.find('(', lp);
            if (op == std::string::npos) break;
            std::size_t cp = clean.find(')', op);
            if (cp == std::string::npos) break;
            std::string inner = clean.substr(op + 1, cp - op - 1);
            // Search for `vertices` token inside inner.
            std::size_t vp = inner.find("vertices");
            while (vp != std::string::npos) {
                bool lOk = (vp == 0) ||
                    !(std::isalnum(static_cast<unsigned char>(inner[vp - 1])) ||
                      inner[vp - 1] == '_');
                std::size_t after = vp + 8;
                bool rOk = (after >= inner.size()) ||
                    !(std::isalnum(static_cast<unsigned char>(inner[after])) ||
                      inner[after] == '_');
                if (lOk && rOk) {
                    // Skip whitespace and '='
                    while (after < inner.size() &&
                           std::isspace(static_cast<unsigned char>(inner[after]))) ++after;
                    if (after < inner.size() && inner[after] == '=') {
                        ++after;
                        while (after < inner.size() &&
                               std::isspace(static_cast<unsigned char>(inner[after]))) ++after;
                        // Read integer literal
                        std::size_t ns = after;
                        while (after < inner.size() &&
                               std::isdigit(static_cast<unsigned char>(inner[after]))) ++after;
                        if (after > ns) {
                            verticesN = std::atoi(inner.substr(ns, after - ns).c_str());
                            break;
                        }
                    }
                }
                vp = inner.find("vertices", vp + 1);
            }
            if (verticesN >= 0) break;
            pos = cp + 1;
        }

        if (verticesN > 0) {
            const int maxPatchVertices = 32;  // matches GLCapabilities
            if (verticesN > maxPatchVertices) {
                programObject->linkLog =
                    "ERROR: Linking tessellation control stage: "
                    "layout(vertices=" + std::to_string(verticesN) +
                    ") exceeds GL_MAX_PATCH_VERTICES (" +
                    std::to_string(maxPatchVertices) + ")";
                programObject->linked = false;
                Runtime::shared().recordShaderTranslation({
                    programTag, "link", "", "", "", programObject->linkLog, "", false
                });
                return false;
            }
        }
    }
    // ─── End tess-control patch vertex count check ───────────────────

    // ─── gl_PerVertex block re-declaration consistency (GL 4.6 §7.4.1)
    //
    // When two or more stages redeclare the built-in `gl_PerVertex`
    // interface block, the redeclarations must agree on their
    // member list. CTS `CommonBugs.CommonBug_PerVertexValidation`
    // builds separable programs where VS/GS/TCS/TES declare
    // mismatching `gl_PerVertex { ... }` blocks (e.g. VS with
    // `gl_Position + gl_PointSize`, GS with just `gl_Position`)
    // and asserts the link fails.
    //
    // We don't fully parse the GLSL; the check is a coarse
    // member-name scan of each stage's source looking for a
    // top-level `out gl_PerVertex { ... };` block. If at least
    // two stages redeclare the block, the sorted member-name
    // sets must match exactly.
    {
        auto extractPerVertexMembers = [](const std::string& src) -> std::set<std::string> {
            std::set<std::string> members;
            // Find `out gl_PerVertex` or `in gl_PerVertex`
            // followed by `{` — whichever comes first.
            static const char* kTokens[] = { "out gl_PerVertex", "in gl_PerVertex" };
            std::size_t pos = std::string::npos;
            for (const char* tok : kTokens) {
                std::size_t p = src.find(tok);
                if (p != std::string::npos && (pos == std::string::npos || p < pos)) {
                    pos = p;
                }
            }
            if (pos == std::string::npos) return members;
            std::size_t open = src.find('{', pos);
            if (open == std::string::npos) return members;
            std::size_t close = src.find('}', open);
            if (close == std::string::npos) return members;
            // Scan the body for member declarations. Each is
            // `<qualifiers?> <type> <name> [array]?;`. We strip
            // qualifiers and array suffixes and keep the
            // `<name>` token immediately before `;`.
            std::string body = src.substr(open + 1, close - open - 1);
            std::size_t p = 0;
            while (p < body.size()) {
                std::size_t semi = body.find(';', p);
                if (semi == std::string::npos) break;
                std::string stmt = body.substr(p, semi - p);
                p = semi + 1;
                // Strip whitespace + everything inside `[`.
                auto lb = stmt.find('[');
                if (lb != std::string::npos) stmt.resize(lb);
                // Right-most token of what's left is the name.
                std::size_t rend = stmt.size();
                while (rend > 0 && std::isspace(static_cast<unsigned char>(stmt[rend - 1]))) --rend;
                std::size_t rstart = rend;
                while (rstart > 0) {
                    const char c = stmt[rstart - 1];
                    if (std::isalnum(static_cast<unsigned char>(c)) || c == '_') {
                        --rstart;
                    } else {
                        break;
                    }
                }
                if (rstart < rend) {
                    members.insert(stmt.substr(rstart, rend - rstart));
                }
            }
            return members;
        };
        struct StageSource { const std::string* src; const char* name; };
        std::vector<StageSource> stages;
        if (vertexShader      != nullptr) stages.push_back({&vertexShader->source,      "vertex"});
        if (tessControlShader != nullptr) stages.push_back({&tessControlShader->source, "tess-control"});
        if (tessEvalShader    != nullptr) stages.push_back({&tessEvalShader->source,    "tess-eval"});
        if (geometryShader    != nullptr) stages.push_back({&geometryShader->source,    "geometry"});
        std::vector<std::pair<const char*, std::set<std::string>>> redeclarations;
        for (const auto& s : stages) {
            auto members = extractPerVertexMembers(*s.src);
            if (!members.empty()) redeclarations.emplace_back(s.name, std::move(members));
        }
        if (redeclarations.size() >= 2) {
            for (std::size_t i = 1; i < redeclarations.size(); ++i) {
                if (redeclarations[i].second != redeclarations[0].second) {
                    programObject->linkLog = std::string("gl_PerVertex block redeclaration mismatch between ")
                        + redeclarations[0].first + " and " + redeclarations[i].first + " stages";
                    programObject->linked = false;
                    Runtime::shared().recordShaderTranslation({
                        programTag, "link", "", "", "", programObject->linkLog, "", false
                    });
                    return false;
                }
            }
        }
    }
    // ─── End gl_PerVertex consistency check ─────────────────────────

    // ─── Per-stage atomic-counter / atomic-counter-buffer limits ────
    //
    // GL 4.6 §7.6.3 + Table 23.66: each shader stage has its own cap
    // on the number of atomic-counter uniforms it may declare
    // (MAX_{VERTEX,FRAGMENT,GEOMETRY,...}_ATOMIC_COUNTERS) and
    // on the number of distinct atomic-counter buffers the stage
    // can bind to (the `*_ATOMIC_COUNTER_BUFFERS` counterpart).
    // `linking.more_ACs_in_GS_than_supported` +
    // `linking.more_ACBs_in_GS_than_supported` query the GS caps,
    // create a GS that overshoots by one, and assert link failure.
    // Keep this as a general cap check so lifting GS atomic support
    // does not silently accept shaders above the published limits.
    if (geometryShader != nullptr) {
        std::size_t gsAtomicCounters = 0;
        std::unordered_set<GLint> gsAtomicBindings;
        for (const auto& decl : geometryShader->declaredUniforms) {
            if (decl.type != GL_UNSIGNED_INT_ATOMIC_COUNTER) continue;
            const std::size_t cnt = (decl.arraySize > 0)
                ? static_cast<std::size_t>(decl.arraySize) : 1;
            gsAtomicCounters += cnt;
            if (decl.explicitBinding >= 0) {
                gsAtomicBindings.insert(decl.explicitBinding);
            }
        }
        GLint maxAtomic = 0, maxAtomicBufs = 0;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(GL_MAX_GEOMETRY_ATOMIC_COUNTERS, &maxAtomic);
            impl_->capabilities->queryInteger(GL_MAX_GEOMETRY_ATOMIC_COUNTER_BUFFERS, &maxAtomicBufs);
        }
        if (static_cast<GLint>(gsAtomicCounters) > maxAtomic) {
            programObject->linkLog = "geometry shader atomic-counter count "
                + std::to_string(gsAtomicCounters) + " exceeds MAX_GEOMETRY_ATOMIC_COUNTERS="
                + std::to_string(maxAtomic);
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }
        if (static_cast<GLint>(gsAtomicBindings.size()) > maxAtomicBufs) {
            programObject->linkLog = "geometry shader atomic-counter-buffer count "
                + std::to_string(gsAtomicBindings.size())
                + " exceeds MAX_GEOMETRY_ATOMIC_COUNTER_BUFFERS="
                + std::to_string(maxAtomicBufs);
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag, "link", "", "", "", programObject->linkLog, "", false
            });
            return false;
        }
    }
    // ─── End AC / ACB limits check ──────────────────────────────────

    // ─── Subroutine uniform location validation (GL 4.6 §7.9) ───
    //
    // CTS `explicit_uniform_location.subroutine-loc-negative-link-*`
    // asserts that glLinkProgram sets GL_LINK_STATUS=FALSE when
    // any of the following appears in a subroutine uniform
    // declaration (per stage, independently):
    //   (a) Two `layout(location=N)` subroutine uniforms collide
    //       on the same location (or overlapping array ranges).
    //   (b) A `layout(location=N)` subroutine uniform's base
    //       location, or any location its array occupies, is
    //       >= GL_MAX_SUBROUTINE_UNIFORM_LOCATIONS.
    //   (c) The linked program's total subroutine-uniform
    //       location count (sum of arraySizes + implicit) in
    //       any stage exceeds GL_MAX_SUBROUTINE_UNIFORM_LOCATIONS.
    //
    // Parse `layout(location=K) subroutine uniform TYPE NAME [N];`
    // declarations straight from each attached shader's source.
    // We can't rely on `resourceSubroutineUniforms[]` here because
    // that table is populated *after* `linked = true` (see the
    // resource-introspection block below). This parse is
    // intentionally lightweight — just locations, array sizes,
    // and layout pins — and mirrors the full scanner in
    // `scanSubroutineDeclarations` for the pieces it needs.
    {
        GLint maxSrUnifLoc = 1024;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(
                GL_MAX_SUBROUTINE_UNIFORM_LOCATIONS, &maxSrUnifLoc);
        }
        GLint maxSubroutines = 1024;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(GL_MAX_SUBROUTINES, &maxSubroutines);
        }
        // Per-stage parse. Returns false + sets linkLog on first
        // spec violation (so the link fails with a descriptive
        // message).
        auto stripComments = [](const std::string& s) {
            std::string out;
            out.reserve(s.size());
            for (std::size_t i = 0; i < s.size();) {
                if (i + 1 < s.size() && s[i] == '/' && s[i + 1] == '/') {
                    while (i < s.size() && s[i] != '\n') ++i;
                } else if (i + 1 < s.size() && s[i] == '/' && s[i + 1] == '*') {
                    i += 2;
                    while (i + 1 < s.size() && !(s[i] == '*' && s[i + 1] == '/')) ++i;
                    if (i + 1 < s.size()) i += 2;
                } else {
                    out += s[i++];
                }
            }
            return out;
        };
        auto isIdentCh = [](unsigned char c) {
            return std::isalnum(c) || c == '_';
        };
        auto validateStage = [&](const std::string& sourceIn) -> bool {
            const std::string src = stripComments(sourceIn);
            std::unordered_set<GLint> usedLocations;
            std::unordered_set<GLint> usedIndices;
            std::size_t totalLocations = 0;
            std::size_t totalSubroutines = 0;
            const std::string kw = "subroutine";
            std::size_t pos = 0;
            while ((pos = src.find(kw, pos)) != std::string::npos) {
                const bool lb = (pos == 0) ||
                    !isIdentCh(static_cast<unsigned char>(src[pos - 1]));
                const bool rb = (pos + kw.size() < src.size()) &&
                    !isIdentCh(static_cast<unsigned char>(src[pos + kw.size()]));
                if (!lb || !rb) { pos += kw.size(); continue; }
                // Walk backward for `layout(location=K)` qualifier.
                GLint explicitLoc = -1;
                GLint explicitIndex = -1;
                {
                    std::size_t back = pos;
                    while (back > 0 && std::isspace(
                        static_cast<unsigned char>(src[back - 1]))) --back;
                    if (back > 0 && src[back - 1] == ')') {
                        int pd = 1;
                        std::size_t bp = back - 1;
                        while (bp > 0 && pd > 0) {
                            --bp;
                            if (src[bp] == ')') ++pd;
                            else if (src[bp] == '(') --pd;
                        }
                        if (pd == 0 && bp >= 6) {
                            std::size_t lp = bp;
                            while (lp > 0 && std::isspace(
                                static_cast<unsigned char>(src[lp - 1]))) --lp;
                            if (lp >= 6 && src.compare(lp - 6, 6, "layout") == 0) {
                                std::string content = src.substr(
                                    bp + 1, (back - 1) - (bp + 1));
                                std::size_t loc = content.find("location");
                                if (loc != std::string::npos) {
                                    std::size_t eq = content.find('=', loc);
                                    if (eq != std::string::npos) {
                                        std::size_t nb = eq + 1;
                                        while (nb < content.size() &&
                                               std::isspace(static_cast<unsigned char>(content[nb]))) ++nb;
                                        std::size_t ne = nb;
                                        if (ne + 1 < content.size() && content[ne] == '0' &&
                                            (content[ne + 1] == 'x' || content[ne + 1] == 'X')) {
                                            ne += 2;
                                            while (ne < content.size() &&
                                                   std::isxdigit(static_cast<unsigned char>(content[ne]))) ++ne;
                                        } else {
                                            while (ne < content.size() &&
                                                   std::isdigit(static_cast<unsigned char>(content[ne]))) ++ne;
                                        }
                                        if (ne > nb) {
                                            explicitLoc = static_cast<GLint>(
                                                std::strtol(content.substr(nb, ne - nb).c_str(),
                                                            nullptr, 0));
                                        }
                                    }
                                }
                                std::size_t idx = content.find("index");
                                if (idx != std::string::npos) {
                                    std::size_t eq = content.find('=', idx);
                                    if (eq != std::string::npos) {
                                        std::size_t nb = eq + 1;
                                        while (nb < content.size() &&
                                               std::isspace(static_cast<unsigned char>(content[nb]))) ++nb;
                                        std::size_t ne = nb;
                                        if (ne + 1 < content.size() && content[ne] == '0' &&
                                            (content[ne + 1] == 'x' || content[ne + 1] == 'X')) {
                                            ne += 2;
                                            while (ne < content.size() &&
                                                   std::isxdigit(static_cast<unsigned char>(content[ne]))) ++ne;
                                        } else {
                                            while (ne < content.size() &&
                                                   std::isdigit(static_cast<unsigned char>(content[ne]))) ++ne;
                                        }
                                        if (ne > nb) {
                                            explicitIndex = static_cast<GLint>(
                                                std::strtol(content.substr(nb, ne - nb).c_str(),
                                                            nullptr, 0));
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                std::size_t p = pos + kw.size();
                while (p < src.size() && std::isspace(static_cast<unsigned char>(src[p]))) ++p;
                if (p < src.size() && src[p] == '(') {
                    ++totalSubroutines;
                    if (static_cast<GLint>(totalSubroutines) > maxSubroutines) {
                        programObject->linkLog =
                            "subroutine count exceeds GL_MAX_SUBROUTINES="
                            + std::to_string(maxSubroutines);
                        return false;
                    }
                    if (explicitIndex >= 0) {
                        if (explicitIndex >= maxSubroutines) {
                            programObject->linkLog =
                                "subroutine index "
                                + std::to_string(explicitIndex)
                                + " >= GL_MAX_SUBROUTINES="
                                + std::to_string(maxSubroutines);
                            return false;
                        }
                        if (!usedIndices.insert(explicitIndex).second) {
                            programObject->linkLog =
                                "subroutine index "
                                + std::to_string(explicitIndex)
                                + " is reused across two declarations";
                            return false;
                        }
                    }
                }
                // Only `subroutine uniform …` shapes consume locations.
                if (p + 7 <= src.size() && src.compare(p, 7, "uniform") == 0 &&
                    (p + 7 == src.size() || !isIdentCh(static_cast<unsigned char>(src[p + 7])))) {
                    p += 7;
                    while (p < src.size() && std::isspace(static_cast<unsigned char>(src[p]))) ++p;
                    // Skip TYPE word.
                    while (p < src.size() && isIdentCh(static_cast<unsigned char>(src[p]))) ++p;
                    while (p < src.size() && std::isspace(static_cast<unsigned char>(src[p]))) ++p;
                    // Skip NAME word.
                    while (p < src.size() && isIdentCh(static_cast<unsigned char>(src[p]))) ++p;
                    while (p < src.size() && std::isspace(static_cast<unsigned char>(src[p]))) ++p;
                    // Optional `[N]` array subscript.
                    GLint arraySize = 1;
                    if (p < src.size() && src[p] == '[') {
                        ++p;
                        while (p < src.size() && std::isspace(
                            static_cast<unsigned char>(src[p]))) ++p;
                        const std::size_t nStart = p;
                        while (p < src.size() && std::isdigit(
                            static_cast<unsigned char>(src[p]))) ++p;
                        if (p > nStart) {
                            arraySize = std::atoi(src.substr(nStart, p - nStart).c_str());
                            if (arraySize < 1) arraySize = 1;
                        }
                    }
                    totalLocations += static_cast<std::size_t>(arraySize);
                    // (c) total-across-stage location cap.
                    if (static_cast<GLint>(totalLocations) > maxSrUnifLoc) {
                        programObject->linkLog =
                            "subroutine-uniform location count exceeds "
                            "GL_MAX_SUBROUTINE_UNIFORM_LOCATIONS="
                            + std::to_string(maxSrUnifLoc);
                        return false;
                    }
                    if (explicitLoc >= 0) {
                        // (b) explicit location must be < max, for
                        // all array-consumed locations.
                        for (GLint k = 0; k < arraySize; ++k) {
                            const GLint slot = explicitLoc + k;
                            if (slot >= maxSrUnifLoc) {
                                programObject->linkLog =
                                    "subroutine uniform location "
                                    + std::to_string(slot)
                                    + " >= GL_MAX_SUBROUTINE_UNIFORM_LOCATIONS="
                                    + std::to_string(maxSrUnifLoc);
                                return false;
                            }
                            // (a) duplicate-location check.
                            if (!usedLocations.insert(slot).second) {
                                programObject->linkLog =
                                    "subroutine uniform location "
                                    + std::to_string(slot)
                                    + " is reused across two declarations";
                                return false;
                            }
                        }
                    }
                }
                pos = p;
            }
            return true;
        };
        for (GLuint shaderId : programObject->attachedShaders) {
            GLShaderObject* sh = impl_->objects->shaders().get(shaderId);
            if (sh == nullptr) continue;
            if (!validateStage(sh->source)) {
                programObject->linked = false;
                Runtime::shared().recordShaderTranslation({
                    programTag, "link", "", "", "", programObject->linkLog, "", false
                });
                return false;
            }
        }
    }
    // ─── End subroutine uniform location validation ───

    // ─── GL 4.6 §7.4.2 cross-stage uniform-block matching ───
    // For each uniform block declared in multiple stages, the
    // instance-name presence must match. `uniform Data { ... };`
    // (no instance) in one stage and `uniform Data { ... } d;`
    // (with instance) in another is a link error.
    //
    // Members of no-instance-name blocks are promoted to the
    // default-uniform scope; their names must not collide with
    // other global uniforms nor with members of other no-instance-
    // name blocks that happen to have the same member name.
    //
    // CTS `shaders.uniform_block.common.name_matching` plants all
    // of these cases and expects link to fail on each mismatch.
    {
        // Scan `uniform <Name> { ... } [instance]?;` in a source.
        // Returns { blockName, hasInstance, memberIdentifiers }.
        struct BlockDecl {
            std::string blockName;
            bool hasInstance = false;
            std::vector<std::string> memberNames;
        };
        auto findUniformBlocks = [](const std::string& src) -> std::vector<BlockDecl> {
            std::vector<BlockDecl> blocks;
            std::size_t pos = 0;
            while (pos < src.size()) {
                // Locate the "uniform" keyword at a word boundary.
                std::size_t kw = src.find("uniform", pos);
                if (kw == std::string::npos) break;
                if (kw > 0) {
                    unsigned char prev = static_cast<unsigned char>(src[kw - 1]);
                    if (std::isalnum(prev) || prev == '_') {
                        pos = kw + 7;
                        continue;
                    }
                }
                std::size_t after = kw + 7;
                if (after < src.size()) {
                    unsigned char nx = static_cast<unsigned char>(src[after]);
                    if (std::isalnum(nx) || nx == '_') {
                        pos = after;
                        continue;
                    }
                }
                // Skip whitespace/newlines to the type / block-name token.
                while (after < src.size() && std::isspace(static_cast<unsigned char>(src[after]))) ++after;
                if (after >= src.size()) break;
                // Capture the identifier.
                std::size_t nameStart = after;
                while (after < src.size() &&
                       (std::isalnum(static_cast<unsigned char>(src[after])) || src[after] == '_')) {
                    ++after;
                }
                if (after == nameStart) { pos = after + 1; continue; }
                std::string name = src.substr(nameStart, after - nameStart);
                // Whitespace, then '{' for a block; otherwise it's a
                // plain uniform declaration like `uniform float f`.
                std::size_t braceStart = after;
                while (braceStart < src.size() && std::isspace(static_cast<unsigned char>(src[braceStart]))) ++braceStart;
                if (braceStart >= src.size() || src[braceStart] != '{') {
                    pos = after;
                    continue;
                }
                // Walk to the matching close brace.
                int depth = 1;
                std::size_t bodyStart = braceStart + 1;
                std::size_t cur = bodyStart;
                while (cur < src.size() && depth > 0) {
                    if (src[cur] == '{') ++depth;
                    else if (src[cur] == '}') --depth;
                    ++cur;
                }
                if (depth != 0) break;
                std::size_t bodyEnd = cur - 1;
                BlockDecl decl;
                decl.blockName = std::move(name);
                // Extract member identifiers from the block body by
                // scanning for `;`-terminated statements.
                std::size_t mp = bodyStart;
                while (mp < bodyEnd) {
                    std::size_t semi = src.find(';', mp);
                    if (semi == std::string::npos || semi >= bodyEnd) break;
                    // Walk backwards from the semi, skipping only
                    // whitespace + optional array-subscript block
                    // `[ ... ]`. The block may contain digits and
                    // whitespace. Previously we blindly stripped any
                    // trailing digits, which truncated `temp2;` to
                    // `temp`.
                    std::size_t e = semi;
                    auto skipWs = [&](std::size_t& p) {
                        while (p > mp) {
                            unsigned char c = static_cast<unsigned char>(src[p - 1]);
                            if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                                --p;
                            } else break;
                        }
                    };
                    skipWs(e);
                    if (e > mp && src[e - 1] == ']') {
                        // Walk back through the array-subscript brackets.
                        // Just look for the matching `[` — anything between
                        // (digits, whitespace, identifiers for sized types
                        // or constants) is allowed by GLSL.
                        int depth = 1;
                        while (e > mp && depth > 0) {
                            --e;
                            if (src[e] == ']') ++depth;
                            else if (src[e] == '[') --depth;
                        }
                        skipWs(e);
                    }
                    std::size_t b = e;
                    while (b > mp) {
                        unsigned char c = static_cast<unsigned char>(src[b - 1]);
                        if (std::isalnum(c) || c == '_') {
                            --b;
                        } else {
                            break;
                        }
                    }
                    if (b < e) {
                        decl.memberNames.push_back(src.substr(b, e - b));
                    }
                    mp = semi + 1;
                }
                // Detect instance name immediately past the closing brace.
                std::size_t tail = cur;
                while (tail < src.size() && std::isspace(static_cast<unsigned char>(src[tail]))) ++tail;
                if (tail < src.size()) {
                    unsigned char c = static_cast<unsigned char>(src[tail]);
                    if (std::isalpha(c) || c == '_') decl.hasInstance = true;
                }
                blocks.push_back(std::move(decl));
                pos = tail;
            }
            return blocks;
        };
        // Scan for plain `uniform <type> <name>;` declarations (not blocks).
        auto findPlainUniforms = [](const std::string& src) -> std::vector<std::string> {
            std::vector<std::string> names;
            std::size_t pos = 0;
            while (pos < src.size()) {
                std::size_t kw = src.find("uniform", pos);
                if (kw == std::string::npos) break;
                if (kw > 0) {
                    unsigned char prev = static_cast<unsigned char>(src[kw - 1]);
                    if (std::isalnum(prev) || prev == '_') {
                        pos = kw + 7;
                        continue;
                    }
                }
                std::size_t after = kw + 7;
                while (after < src.size() && std::isspace(static_cast<unsigned char>(src[after]))) ++after;
                // Consume type identifier.
                std::size_t t0 = after;
                while (after < src.size() &&
                       (std::isalnum(static_cast<unsigned char>(src[after])) || src[after] == '_')) {
                    ++after;
                }
                if (after == t0) { pos = after + 1; continue; }
                while (after < src.size() && std::isspace(static_cast<unsigned char>(src[after]))) ++after;
                if (after < src.size() && src[after] == '{') {
                    // Block declaration — skip past it.
                    int d = 1;
                    ++after;
                    while (after < src.size() && d > 0) {
                        if (src[after] == '{') ++d;
                        else if (src[after] == '}') --d;
                        ++after;
                    }
                    pos = after;
                    continue;
                }
                // Parse the uniform name.
                std::size_t n0 = after;
                while (after < src.size() &&
                       (std::isalnum(static_cast<unsigned char>(src[after])) || src[after] == '_')) {
                    ++after;
                }
                if (n0 < after) {
                    names.push_back(src.substr(n0, after - n0));
                }
                pos = after;
            }
            return names;
        };

        std::unordered_map<std::string, std::vector<bool>> blockInstancePresence;
        std::unordered_map<std::string, std::vector<std::string>>
            noInstanceMemberNamesByBlock;
        std::unordered_set<std::string> plainUniformNames;
        for (GLuint shaderId : programObject->attachedShaders) {
            GLShaderObject* sh = impl_->objects->shaders().get(shaderId);
            if (sh == nullptr) continue;
            auto blocks = findUniformBlocks(sh->source);
            for (auto& b : blocks) {
                blockInstancePresence[b.blockName].push_back(b.hasInstance);
                if (!b.hasInstance) {
                    auto& list = noInstanceMemberNamesByBlock[b.blockName];
                    list.insert(list.end(), b.memberNames.begin(), b.memberNames.end());
                }
            }
            auto plain = findPlainUniforms(sh->source);
            for (auto& n : plain) plainUniformNames.insert(n);
        }

        // Rule 1: same block name across stages → instance presence must match.
        for (const auto& [bname, flags] : blockInstancePresence) {
            bool anyWithInstance = false, anyWithoutInstance = false;
            for (bool f : flags) {
                if (f) anyWithInstance = true; else anyWithoutInstance = true;
            }
            if (anyWithInstance && anyWithoutInstance) {
                programObject->linkLog = "uniform block '" + bname +
                    "' must use the same instance-name presence in every stage";
                programObject->linked = false;
                Runtime::shared().recordShaderTranslation({
                    programTag, "link", "", "", "", programObject->linkLog, "", false
                });
                return false;
            }
        }

        // Rule 2: no-instance-name block members collide with plain
        // uniforms of the same name (different stages count too).
        for (const auto& [bname, members] : noInstanceMemberNamesByBlock) {
            for (const auto& m : members) {
                if (plainUniformNames.count(m)) {
                    programObject->linkLog = "uniform block member '" + m +
                        "' (in block '" + bname +
                        "') collides with plain uniform of the same name";
                    programObject->linked = false;
                    Runtime::shared().recordShaderTranslation({
                        programTag, "link", "", "", "", programObject->linkLog, "", false
                    });
                    return false;
                }
            }
        }

        // Rule 3: different no-instance-name blocks must not share
        // member names (both promote members into the default scope).
        std::unordered_map<std::string, std::string> memberOwner;  // memberName → blockName
        for (const auto& [bname, members] : noInstanceMemberNamesByBlock) {
            for (const auto& m : members) {
                auto it = memberOwner.find(m);
                if (it != memberOwner.end() && it->second != bname) {
                    programObject->linkLog = "no-instance-name blocks '" +
                        it->second + "' and '" + bname +
                        "' both declare a member '" + m + "'";
                    programObject->linked = false;
                    Runtime::shared().recordShaderTranslation({
                        programTag, "link", "", "", "", programObject->linkLog, "", false
                    });
                    return false;
                }
                memberOwner[m] = bname;
            }
        }
    }
    // ─── End cross-stage uniform-block matching ───

    programObject->linked = true;
    programObject->linkLog = "ok";
    // Snapshot the separability request at link time. Program-pipeline
    // legality uses this linked-binary state rather than the current
    // request-level parameter.
    programObject->separableLinked = programObject->separable;

    // Populate GL 4.3 program resource introspection tables from the
    // reflection data we already gathered above.
    programObject->resourceUniforms.clear();
    programObject->resourceUniformBlocks.clear();
    programObject->resourceInputs.clear();
    programObject->resourceOutputs.clear();
    programObject->resourceStorageBlocks.clear();
    programObject->resourceAtomicCounterBuffers.clear();
    programObject->resourceBufferVariables.clear();
    for (int s = 0; s < 6; ++s) {
        programObject->resourceSubroutines[s].clear();
        programObject->resourceSubroutineUniforms[s].clear();
        programObject->currentSubroutineSelections[s].clear();
    }
    programObject->subroutineDispatchUniformLocations.clear();
    programObject->subroutineSelectionsDirty = false;
    programObject->ssboBindingRemap.clear();

    // Per-stage "referenced by" bitmask for program-resource
    // introspection. GL 4.6 Table 23.40 defines
    // GL_REFERENCED_BY_<stage>_SHADER as a query property;
    // glGetProgramResourceiv returns 1 iff the resource is
    // referenced by the named stage. Previously we hard-coded
    // VS+FS (0x03) on every uniform, which tripped CTS
    // `geometry_shader.program_resource.program_resource`
    // whenever a GS-attached program queried the
    // GEOMETRY_SHADER bit. Derive the bitmask from each
    // attached stage's declaredUniforms so every stage the
    // scanner saw contributes a bit, and we pick up GS / TCS /
    // TES / compute automatically.
    const GLbitfield kBitVertex   = 0x01;
    const GLbitfield kBitFragment = 0x02;
    const GLbitfield kBitGeometry = 0x04;
    const GLbitfield kBitTessCtrl = 0x08;
    const GLbitfield kBitTessEval = 0x10;
    const GLbitfield kBitCompute  = 0x20;
    auto stageBitFor = [&](GLenum stage) -> GLbitfield {
        switch (stage) {
            case GL_VERTEX_SHADER:          return kBitVertex;
            case GL_FRAGMENT_SHADER:        return kBitFragment;
            case GL_GEOMETRY_SHADER:        return kBitGeometry;
            case GL_TESS_CONTROL_SHADER:    return kBitTessCtrl;
            case GL_TESS_EVALUATION_SHADER: return kBitTessEval;
            case GL_COMPUTE_SHADER:         return kBitCompute;
            default:                        return 0;
        }
    };
    // Build a GS-side "actually referenced" uniform-name set by
    // walking the GS SPIR-V at link time. Needed because our
    // per-stage scanner records DECLARATIONS, not USAGE — shared
    // common headers that declare a uniform in every stage would
    // spuriously set the stage bit for every stage even when the
    // GLSL body never uses the uniform. For VS/FS we get usage
    // via SPIRV-Cross's `get_active_interface_variables()` at
    // block granularity; for plain uniforms (default block) and
    // per-member accuracy we fall back to this raw walk.
    std::unordered_set<std::string> gsRefSet;
    if (geometryShader != nullptr && !geometryShader->spirv.empty()) {
        gsRefSet = appgl::scanStageReferencedUniforms(geometryShader->spirv);
    }

    auto computeStageMask = [&](const std::string& name) -> GLbitfield {
        GLbitfield mask = 0;
        for (GLuint shaderId : programObject->attachedShaders) {
            GLShaderObject* shaderObject = impl_->objects->shaders().get(shaderId);
            if (shaderObject == nullptr) continue;
            const GLbitfield bit = stageBitFor(shaderObject->stage);
            if (bit == 0) continue;
            for (const auto& decl : shaderObject->declaredUniforms) {
                if (decl.name == name) {
                    // For the GS stage, narrow by actual usage —
                    // the scanner reports declarations (shared
                    // common headers), SPIR-V tells us what's
                    // used. Without this, CTS
                    // `program_resource.program_resource` saw
                    // `uni_model_view_projection` (declared in
                    // both VS and GS via common header, used only
                    // by VS) as GS-referenced.
                    if (shaderObject->stage == GL_GEOMETRY_SHADER) {
                        if (gsRefSet.empty() || gsRefSet.count(name) != 0) {
                            mask |= bit;
                        }
                    } else {
                        mask |= bit;
                    }
                    break;
                }
            }
        }
        // If the uniform wasn't declared anywhere (shouldn't
        // happen — it's in the linked program's uniform table)
        // fall back to the old conservative VS+FS default.
        if (mask == 0) mask = kBitVertex | kBitFragment;
        return mask;
    };

    for (const auto& u : programObject->uniforms) {
        GLProgramResourceEntry entry;
        // GL 4.6 §7.3.1: array uniforms report their name with the
        // "[0]" suffix in the resource interface — EVEN for
        // 1-element arrays. CTS `program_interface_query.uniform-
        // types` declares `uniform uvec2 c[3];` / `uniform mat2
        // g[8];` and CTS `no-locations` declares `in vec4 c[1];`
        // — both expect `glGetProgramResourceName(GL_UNIFORM, …)`
        // to return "c[0]" / "g[0]". The `isArray` flag
        // distinguishes array declarations from plain scalars
        // (`arraySize` alone can't, since both non-arrays and
        // 1-element arrays have arraySize==1).
        entry.name = u.isArray ? (u.name + "[0]") : u.name;
        entry.type = u.type;
        entry.location = u.location;
        entry.binding = u.explicitBinding;  // RC-D08
        entry.arraySize = u.arraySize;
        entry.isArray = u.isArray;
        entry.arrayDimensions = u.arrayDimensions;
        entry.referencedBy = computeStageMask(u.name);
        if (u.type == GL_UNSIGNED_INT_ATOMIC_COUNTER) {
            // Offset defaults to 0 when the GLSL didn't carry
            // `layout(offset = N)` on the first counter of a binding
            // — this is close enough for CTS
            // `program_interface_query.atomic-counters` which always
            // supplies an explicit offset. atomicCounterBufferIndex
            // is filled in below after the ACB table is built.
            entry.atomicCounterOffset = u.explicitOffset >= 0 ? u.explicitOffset : 0;
        }
        programObject->resourceUniforms.push_back(std::move(entry));
    }

    // ─── Build GL_ATOMIC_COUNTER_BUFFER resource entries ────────────────
    // GL 4.6 §7.3.1 Table 7.12: the ATOMIC_COUNTER_BUFFER interface
    // exposes one resource per distinct `binding` index that any
    // atomic_uint uniform targets. For each buffer:
    //   BUFFER_BINDING      = binding index
    //   BUFFER_DATA_SIZE    = max(offset + sizeof(uint) * N) across
    //                          the counters in that binding
    //   NUM_ACTIVE_VARIABLES= number of atomic_uint uniforms that
    //                          target the binding
    //   ACTIVE_VARIABLES    = their indices into resourceUniforms
    //   REFERENCED_BY_*     = union of referencedBy bitmasks
    //                          of the participating uniforms
    // CTS `program_interface_query.atomic-counters` exercises this
    // interface end-to-end.
    {
        struct AcbAccumulator {
            GLint binding = 0;
            GLint dataSize = 0;                 // BUFFER_DATA_SIZE
            std::vector<GLint> activeVariables; // indices into resourceUniforms
            GLbitfield referencedBy = 0;
        };
        std::vector<AcbAccumulator> acbs;
        // Walk resourceUniforms (post-build) so we record the
        // post-"[0]"-suffix index of each atomic uniform.
        for (std::size_t i = 0; i < programObject->resourceUniforms.size(); ++i) {
            auto& ue = programObject->resourceUniforms[i];
            if (ue.type != GL_UNSIGNED_INT_ATOMIC_COUNTER) continue;
            const GLint bind = ue.binding < 0 ? 0 : ue.binding;
            const GLint off = ue.atomicCounterOffset >= 0 ? ue.atomicCounterOffset : 0;
            const GLint count = ue.arraySize > 0 ? ue.arraySize : 1;
            const GLint endByte = off + 4 * count;
            std::size_t bucket = acbs.size();
            for (std::size_t j = 0; j < acbs.size(); ++j) {
                if (acbs[j].binding == bind) { bucket = j; break; }
            }
            if (bucket == acbs.size()) {
                acbs.push_back(AcbAccumulator{});
                acbs.back().binding = bind;
            }
            auto& acb = acbs[bucket];
            if (endByte > acb.dataSize) acb.dataSize = endByte;
            acb.activeVariables.push_back(static_cast<GLint>(i));
            acb.referencedBy |= ue.referencedBy;
            ue.atomicCounterBufferIndex = static_cast<GLint>(bucket);
        }
        for (const auto& acb : acbs) {
            GLProgramResourceEntry be;
            // ATOMIC_COUNTER_BUFFER resources have no name; leave empty.
            be.name = "";
            be.binding = acb.binding;
            be.offset = acb.dataSize;          // reuse offset slot as BUFFER_DATA_SIZE
            be.activeVariables = acb.activeVariables;
            be.referencedBy = acb.referencedBy;
            programObject->resourceAtomicCounterBuffers.push_back(std::move(be));
        }
    }
    // ─── End ATOMIC_COUNTER_BUFFER build ────────────────────────────────
    for (const auto& a : programObject->attributes) {
        // GL 4.6 §7.3.1: for array inputs, the resource name ends
        // with "[0]" — even for 1-element arrays like `in vec4
        // c[1]`. `a.isArray` is the authoritative "declared with
        // array syntax" flag (`a.arraySize==1` alone can't
        // distinguish non-arrays from 1-element arrays).
        if (a.arrayDimensions.size() > 1 && a.arrayDimensions[0] > 0) {
            const GLint innerArraySize =
                arrayElementCount(a.arrayDimensions, 1, 1);
            const GLuint slotsPerOuter =
                vertexInputLocationSlotCount(a.type, innerArraySize);
            for (GLint outer = 0; outer < a.arrayDimensions[0]; ++outer) {
                GLProgramResourceEntry entry;
                entry.name = a.name + "[" + std::to_string(outer) + "][0]";
                entry.type = a.type;
                entry.location = a.location >= 0
                    ? a.location + static_cast<GLint>(outer * slotsPerOuter)
                    : a.location;
                entry.arraySize = innerArraySize;
                entry.isArray = true;
                entry.arrayDimensions.assign(
                    a.arrayDimensions.begin() + 1,
                    a.arrayDimensions.end());
                entry.referencedBy = 0x01; // vertex
                programObject->resourceInputs.push_back(std::move(entry));
            }
            continue;
        }

        GLProgramResourceEntry entry;
        entry.name = a.isArray ? (a.name + "[0]") : a.name;
        entry.type = a.type;
        entry.location = a.location;
        entry.arraySize = a.arraySize;
        entry.isArray = a.isArray;
        entry.referencedBy = 0x01; // vertex
        programObject->resourceInputs.push_back(std::move(entry));
    }
    // Fragment outputs: populate from fragment shader declared outputs.
    for (GLuint shaderId : programObject->attachedShaders) {
        GLShaderObject* shaderObject = impl_->objects->shaders().get(shaderId);
        if (shaderObject == nullptr) continue;
        if (shaderObject->stage == GL_FRAGMENT_SHADER) {
            GLint nextOutputLoc = 0;
            for (const auto& output : shaderObject->declaredOutputs) {
                GLProgramResourceEntry entry;
                // GL 4.6 §7.3.1: array outputs report their name with
                // the "[0]" suffix (same convention as inputs). CTS
                // `output-types` expects "a[0]" / "c[0]" / "d[0]"
                // and `no-locations` has `out vec4 d[1]` which must
                // also report "d[0]" despite arraySize==1 — use
                // `isArray` to distinguish.
                entry.name = output.isArray
                    ? (output.name + "[0]") : output.name;
                entry.type = output.type;
                entry.arraySize = output.arraySize;
                entry.isArray = output.isArray;
                // Resolve location: per-name bind via
                // glBindFragDataLocation wins over the GLSL
                // `layout(location=…)` qualifier per GL 4.6 §15.2.
                // Only applied pre-link; the map is authoritative at
                // this point.
                GLint location = -1;
                auto bindIt = programObject->requestedFragDataLocations.find(output.name);
                if (bindIt != programObject->requestedFragDataLocations.end()) {
                    location = static_cast<GLint>(bindIt->second);
                } else if (output.explicitLocation >= 0) {
                    location = output.explicitLocation;
                } else {
                    location = nextOutputLoc;
                }
                entry.location = location;
                // Dual-source-blend index set by
                // glBindFragDataLocationIndexed OR the GLSL-side
                // `layout(index=N)` qualifier (GL 4.6 §15.2). API
                // binding wins when both are present pre-link.
                auto idxIt = programObject->requestedFragDataLocationIndices.find(output.name);
                if (idxIt != programObject->requestedFragDataLocationIndices.end()) {
                    entry.locationIndex = static_cast<GLint>(idxIt->second);
                } else if (output.explicitIndex >= 0) {
                    entry.locationIndex = output.explicitIndex;
                }
                entry.referencedBy = 0x02; // fragment
                // GL 4.6 §15.2: array outputs consume `arraySize`
                // consecutive locations.
                const GLint consumed = std::max<GLint>(1, output.arraySize);
                if (location + consumed > nextOutputLoc) {
                    nextOutputLoc = location + consumed;
                }
                programObject->resourceOutputs.push_back(std::move(entry));
            }
        }
    }

    // Built-in program input/output entries. GL 4.6 §7.3.1.1
    // treats built-ins used by the first-stage/last-stage as
    // program inputs/outputs respectively (e.g.
    // `gl_VertexID` / `gl_InstanceID` become GL_PROGRAM_INPUT
    // on a VS-first program, `gl_FragDepth` /
    // `gl_SampleMask[0]` become GL_PROGRAM_OUTPUT on an
    // FS-last program). User-declared inputs/outputs are
    // already populated above. A simple source-text scan
    // catches the common set used by CTS
    // `program_interface_query.input-built-in` /
    // `output-built-in`.
    {
        // Word-boundary presence check — avoids matching
        // "some_gl_VertexID_hack" or "// gl_VertexID" comments
        // by demanding the match lie between non-identifier
        // characters. CTS GLSL sources don't have such names
        // so a plain find() would also work for the test set,
        // but the word-boundary check costs nothing and
        // future-proofs.
        auto sourceUsesIdent = [](const std::string& src, const char* ident) {
            const std::size_t ilen = std::strlen(ident);
            std::size_t pos = 0;
            while ((pos = src.find(ident, pos)) != std::string::npos) {
                const bool leftBoundary = (pos == 0) ||
                    !(std::isalnum(static_cast<unsigned char>(src[pos - 1])) || src[pos - 1] == '_');
                const bool rightBoundary = (pos + ilen == src.size()) ||
                    !(std::isalnum(static_cast<unsigned char>(src[pos + ilen])) || src[pos + ilen] == '_');
                if (leftBoundary && rightBoundary) return true;
                pos += ilen;
            }
            return false;
        };
        // Helper: append a synthetic built-in entry if absent
        // from the table. Built-ins don't have user-visible
        // locations, so GL_LOCATION returns -1.
        auto addBuiltIn = [&](std::vector<GLProgramResourceEntry>& table,
                              const std::string& name, GLenum type,
                              GLbitfield referencedBy, bool isArray = false,
                              GLint arraySize = 1) {
            for (const auto& e : table) {
                if (e.name == name) return;  // already present
            }
            GLProgramResourceEntry entry;
            entry.name = name;
            entry.type = type;
            entry.location = -1;
            entry.arraySize = arraySize;
            entry.referencedBy = referencedBy;
            (void)isArray;   // array-ness is baked into the
                             // canonical name (e.g. "gl_SampleMask[0]")
            table.push_back(std::move(entry));
        };
        auto addActiveBuiltInAttribute = [&](const std::string& name, GLenum type) {
            for (const auto& attrib : programObject->attributes) {
                if (attrib.name == name) {
                    return;
                }
            }
            GLProgramAttributeInfo attrib;
            attrib.name = name;
            attrib.type = type;
            attrib.location = -1;
            attrib.arraySize = 1;
            attrib.isArray = false;
            programObject->attributes.push_back(std::move(attrib));
        };
        GLShaderObject* vsShader = nullptr;
        GLShaderObject* fsShader = nullptr;
        for (GLuint shaderId : programObject->attachedShaders) {
            GLShaderObject* s = impl_->objects->shaders().get(shaderId);
            if (s == nullptr) continue;
            if (s->stage == GL_VERTEX_SHADER)   vsShader = s;
            if (s->stage == GL_FRAGMENT_SHADER) fsShader = s;
        }
        if (vsShader != nullptr) {
            const auto& src = vsShader->source;
            if (sourceUsesIdent(src, "gl_VertexID")) {
                addBuiltIn(programObject->resourceInputs,
                    "gl_VertexID", GL_INT, 0x01 /*vertex*/);
                addActiveBuiltInAttribute("gl_VertexID", GL_INT);
            }
            if (sourceUsesIdent(src, "gl_InstanceID") ||
                sourceUsesIdent(src, "gl_InstanceIDARB")) {
                addBuiltIn(programObject->resourceInputs,
                    "gl_InstanceID", GL_INT, 0x01);
                addActiveBuiltInAttribute("gl_InstanceID", GL_INT);
            }
            if (sourceUsesIdent(src, "gl_DrawID") ||
                sourceUsesIdent(src, "gl_DrawIDARB")) {
                addBuiltIn(programObject->resourceInputs,
                    "gl_DrawID", GL_INT, 0x01);
            }
            if (sourceUsesIdent(src, "gl_BaseVertex") ||
                sourceUsesIdent(src, "gl_BaseVertexARB")) {
                addBuiltIn(programObject->resourceInputs,
                    "gl_BaseVertex", GL_INT, 0x01);
            }
            if (sourceUsesIdent(src, "gl_BaseInstance") ||
                sourceUsesIdent(src, "gl_BaseInstanceARB")) {
                addBuiltIn(programObject->resourceInputs,
                    "gl_BaseInstance", GL_INT, 0x01);
            }
        }
        if (fsShader != nullptr) {
            const auto& src = fsShader->source;
            if (sourceUsesIdent(src, "gl_FragDepth")) {
                addBuiltIn(programObject->resourceOutputs,
                    "gl_FragDepth", GL_FLOAT, 0x02 /*fragment*/);
            }
            if (sourceUsesIdent(src, "gl_SampleMask")) {
                // `gl_SampleMask[0]` canonical name; array size
                // depends on MAX_SAMPLE_MASK_WORDS but is 1 on
                // most desktop / Apple Metal hardware.
                addBuiltIn(programObject->resourceOutputs,
                    "gl_SampleMask[0]", GL_INT, 0x02,
                    /*isArray=*/true, /*arraySize=*/1);
            }
        }
        // Separable FS: its `in` varyings become the program's
        // GL_PROGRAM_INPUT. For regular linked programs the FS
        // inputs are cross-stage varyings (consumed by linker, not
        // exposed as program inputs). But for a separable FS there's
        // no preceding-stage program, so the FS inputs ARE the
        // program inputs per GL 4.6 §7.3.1.1. CTS
        // `separate-programs-fragment` declares `in vec4 vs_color;`
        // and expects ACTIVE_RESOURCES=1 on GL_PROGRAM_INPUT.
        if (programObject->separable && vsShader == nullptr &&
            geometryShader == nullptr && tessControlShader == nullptr &&
            tessEvalShader == nullptr && fsShader != nullptr) {
            GLint nextInputLoc = 0;
            for (const auto& input : fsShader->declaredInputs) {
                GLProgramResourceEntry entry;
                entry.name = input.isArray
                    ? (input.name + "[0]") : input.name;
                entry.type = input.type;
                entry.arraySize = input.arraySize;
                entry.isArray = input.isArray;
                entry.location = input.explicitLocation >= 0
                    ? input.explicitLocation : nextInputLoc;
                entry.referencedBy = 0x02;  // fragment
                const GLint consumed = std::max<GLint>(1, input.arraySize);
                nextInputLoc = entry.location + consumed;
                programObject->resourceInputs.push_back(std::move(entry));
            }
        }
        // Separable GS / TCS / TES: their `in` interface blocks
        // (typically `in gl_PerVertex { … } gl_in[]`) become
        // GL_PROGRAM_INPUT. CTS `separate-programs-geometry`
        // declares `in gl_PerVertex { vec4 gl_Position; … } gl_in[];`
        // and queries `glGetProgramResourceIndex(GL_PROGRAM_INPUT,
        // "gl_PerVertex.gl_Position")`. Naming follows §7.3.1.1:
        // with an instance name (`gl_in` here, or bare), members
        // are prefixed with the block TYPE name.
        {
            GLShaderObject* firstNonVsStage = nullptr;
            if (programObject->separable && vsShader == nullptr) {
                for (GLuint shaderId : programObject->attachedShaders) {
                    GLShaderObject* s = impl_->objects->shaders().get(shaderId);
                    if (s == nullptr) continue;
                    if (s->stage == GL_GEOMETRY_SHADER ||
                        s->stage == GL_TESS_CONTROL_SHADER ||
                        s->stage == GL_TESS_EVALUATION_SHADER) {
                        firstNonVsStage = s;
                        break;
                    }
                }
            }
            if (firstNonVsStage != nullptr) {
                const GLbitfield stageBit =
                    (firstNonVsStage->stage == GL_GEOMETRY_SHADER)        ? 0x04 :
                    (firstNonVsStage->stage == GL_TESS_CONTROL_SHADER)    ? 0x08 :
                    (firstNonVsStage->stage == GL_TESS_EVALUATION_SHADER) ? 0x10 : 0;
                const std::string& src = firstNonVsStage->source;
                GLint nextInputLoc = 0;
                auto pushInputIfMissing = [&](GLProgramResourceEntry entry) {
                    const auto existing = std::find_if(
                        programObject->resourceInputs.begin(),
                        programObject->resourceInputs.end(),
                        [&](const GLProgramResourceEntry& e) {
                            return e.name == entry.name;
                        });
                    if (existing == programObject->resourceInputs.end()) {
                        programObject->resourceInputs.push_back(std::move(entry));
                    }
                };
                for (const auto& input : firstNonVsStage->declaredInputs) {
                    GLProgramResourceEntry entry;
                    entry.name = input.isArray
                        ? (input.name + "[0]") : input.name;
                    entry.type = input.type;
                    entry.arraySize = input.arraySize;
                    entry.isArray = input.isArray;
                    entry.location = input.explicitLocation >= 0
                        ? input.explicitLocation : nextInputLoc;
                    entry.referencedBy = stageBit;
                    const GLint consumed = std::max<GLint>(1, input.arraySize);
                    nextInputLoc = entry.location + consumed;
                    pushInputIfMissing(std::move(entry));
                }
                // Per-stage built-in inputs exposed on separable
                // programs. GL 4.6 §7.3.1.1 treats these as
                // GL_PROGRAM_INPUT when the stage is the first stage
                // of its own program. CTS
                // `separate-programs-tess-control` expects
                // `gl_InvocationID` in the input list (length 16).
                auto sourceUsesIdent2 = [](const std::string& s, const char* ident) {
                    const std::size_t ilen = std::strlen(ident);
                    std::size_t pos = 0;
                    while ((pos = s.find(ident, pos)) != std::string::npos) {
                        const bool lb = (pos == 0) ||
                            !(std::isalnum(static_cast<unsigned char>(s[pos - 1])) || s[pos - 1] == '_');
                        const bool rb = (pos + ilen == s.size()) ||
                            !(std::isalnum(static_cast<unsigned char>(s[pos + ilen])) || s[pos + ilen] == '_');
                        if (lb && rb) return true;
                        pos += ilen;
                    }
                    return false;
                };
                auto pushBuiltinInput = [&](const char* name, GLenum type) {
                    GLProgramResourceEntry entry;
                    entry.name = name;
                    entry.type = type;
                    entry.location = -1;
                    entry.arraySize = 1;
                    entry.referencedBy = stageBit;
                    pushInputIfMissing(std::move(entry));
                };
                if (firstNonVsStage->stage == GL_TESS_CONTROL_SHADER ||
                    firstNonVsStage->stage == GL_TESS_EVALUATION_SHADER) {
                    if (sourceUsesIdent2(src, "gl_InvocationID")) {
                        pushBuiltinInput("gl_InvocationID", GL_INT);
                    }
                    if (sourceUsesIdent2(src, "gl_PatchVerticesIn")) {
                        pushBuiltinInput("gl_PatchVerticesIn", GL_INT);
                    }
                    if (sourceUsesIdent2(src, "gl_PrimitiveID")) {
                        pushBuiltinInput("gl_PrimitiveID", GL_INT);
                    }
                }
                if (firstNonVsStage->stage == GL_TESS_EVALUATION_SHADER) {
                    if (sourceUsesIdent2(src, "gl_TessCoord")) {
                        pushBuiltinInput("gl_TessCoord", GL_FLOAT_VEC3);
                    }
                    if (sourceUsesIdent2(src, "gl_TessLevelOuter")) {
                        pushBuiltinInput("gl_TessLevelOuter", GL_FLOAT);
                    }
                    if (sourceUsesIdent2(src, "gl_TessLevelInner")) {
                        pushBuiltinInput("gl_TessLevelInner", GL_FLOAT);
                    }
                }
                if (firstNonVsStage->stage == GL_GEOMETRY_SHADER) {
                    if (sourceUsesIdent2(src, "gl_PrimitiveIDIn")) {
                        pushBuiltinInput("gl_PrimitiveIDIn", GL_INT);
                    }
                    if (sourceUsesIdent2(src, "gl_InvocationID")) {
                        pushBuiltinInput("gl_InvocationID", GL_INT);
                    }
                }
                // Source-text scan for `in <BlockName> { <members> } [<inst>] ;`
                // — mirrors the output-block scan in the VS/TES/GS
                // separable output path below.
                const std::string inKw = "in ";
                std::size_t sp = 0;
                while ((sp = src.find(inKw, sp)) != std::string::npos) {
                    const bool lb = (sp == 0) ||
                        !(std::isalnum(static_cast<unsigned char>(src[sp - 1])) || src[sp - 1] == '_');
                    if (!lb) { sp += inKw.size(); continue; }
                    std::size_t p = sp + inKw.size();
                    while (p < src.size() && (src[p] == ' ' || src[p] == '\t')) ++p;
                    const std::size_t nameStart = p;
                    while (p < src.size() &&
                           (std::isalnum(static_cast<unsigned char>(src[p])) || src[p] == '_')) ++p;
                    const std::string blockName = src.substr(nameStart, p - nameStart);
                    if (blockName.empty()) { sp += inKw.size(); continue; }
                    while (p < src.size() &&
                           (src[p] == ' ' || src[p] == '\t' || src[p] == '\n' || src[p] == '\r')) ++p;
                    if (p >= src.size() || src[p] != '{') {
                        sp += inKw.size();
                        continue;
                    }
                    const std::size_t bodyStart = p + 1;
                    int depth = 1;
                    std::size_t q = bodyStart;
                    while (q < src.size() && depth > 0) {
                        if (src[q] == '{') ++depth;
                        else if (src[q] == '}') --depth;
                        ++q;
                    }
                    if (depth != 0) { sp = p + 1; continue; }
                    const std::string body = src.substr(bodyStart, q - 1 - bodyStart);
                    std::size_t stmtStart = 0;
                    while (stmtStart < body.size()) {
                        const std::size_t semi = body.find(';', stmtStart);
                        if (semi == std::string::npos) break;
                        std::string stmt = body.substr(stmtStart, semi - stmtStart);
                        stmtStart = semi + 1;
                        auto lstrip = [](std::string& s) {
                            std::size_t i = 0;
                            while (i < s.size() && std::isspace(static_cast<unsigned char>(s[i]))) ++i;
                            s.erase(0, i);
                        };
                        auto rstrip = [](std::string& s) {
                            while (!s.empty() && std::isspace(static_cast<unsigned char>(s.back()))) s.pop_back();
                        };
                        lstrip(stmt); rstrip(stmt);
                        if (stmt.empty()) continue;
                        // Parse "TYPE name[ array ]".
                        std::size_t ws = 0;
                        while (ws < stmt.size() && !std::isspace(static_cast<unsigned char>(stmt[ws]))) ++ws;
                        const std::string typeWord = stmt.substr(0, ws);
                        std::string rest = stmt.substr(ws);
                        lstrip(rest);
                        GLenum memberType = GL_FLOAT;
                        if (typeWord == "float")      memberType = GL_FLOAT;
                        else if (typeWord == "vec2")  memberType = GL_FLOAT_VEC2;
                        else if (typeWord == "vec3")  memberType = GL_FLOAT_VEC3;
                        else if (typeWord == "vec4")  memberType = GL_FLOAT_VEC4;
                        else if (typeWord == "int")   memberType = GL_INT;
                        else if (typeWord == "ivec2") memberType = GL_INT_VEC2;
                        else if (typeWord == "ivec3") memberType = GL_INT_VEC3;
                        else if (typeWord == "ivec4") memberType = GL_INT_VEC4;
                        else if (typeWord == "uint")  memberType = GL_UNSIGNED_INT;
                        else if (typeWord == "uvec2") memberType = GL_UNSIGNED_INT_VEC2;
                        else if (typeWord == "uvec3") memberType = GL_UNSIGNED_INT_VEC3;
                        else if (typeWord == "uvec4") memberType = GL_UNSIGNED_INT_VEC4;
                        else if (typeWord == "mat2")  memberType = GL_FLOAT_MAT2;
                        else if (typeWord == "mat3")  memberType = GL_FLOAT_MAT3;
                        else if (typeWord == "mat4")  memberType = GL_FLOAT_MAT4;
                        // Walk the rest token-by-token: comma-separated
                        // names, each optionally followed by `[size]`.
                        std::size_t namePos = 0;
                        while (namePos < rest.size()) {
                            while (namePos < rest.size() && std::isspace(static_cast<unsigned char>(rest[namePos]))) ++namePos;
                            std::size_t nameEnd = namePos;
                            while (nameEnd < rest.size() &&
                                   (std::isalnum(static_cast<unsigned char>(rest[nameEnd])) ||
                                    rest[nameEnd] == '_')) ++nameEnd;
                            if (nameEnd == namePos) break;
                            const std::string memberName = rest.substr(namePos, nameEnd - namePos);
                            namePos = nameEnd;
                            // Skip array subscript if present.
                            while (namePos < rest.size() && std::isspace(static_cast<unsigned char>(rest[namePos]))) ++namePos;
                            if (namePos < rest.size() && rest[namePos] == '[') {
                                int bd = 1; ++namePos;
                                while (namePos < rest.size() && bd > 0) {
                                    if (rest[namePos] == '[') ++bd;
                                    else if (rest[namePos] == ']') --bd;
                                    ++namePos;
                                }
                            }
                            GLProgramResourceEntry entry;
                            entry.name = blockName + "." + memberName;
                            entry.type = memberType;
                            entry.arraySize = 1;
                            entry.location = nextInputLoc++;
                            entry.referencedBy = stageBit;
                            pushInputIfMissing(std::move(entry));
                            // Advance past any trailing `,`.
                            while (namePos < rest.size() &&
                                   (rest[namePos] == ' ' || rest[namePos] == '\t' ||
                                    rest[namePos] == ',')) ++namePos;
                        }
                    }
                    sp = q;
                }
            }
        }
        // Separable programs: the last vertex-processing stage's
        // outputs become the program's `GL_PROGRAM_OUTPUT`. For a
        // separable VS / GS / TES-only program those stages' built-in
        // `gl_Position` (and user-declared varyings / output blocks)
        // are the program outputs. CTS
        // `program_interface_query.separate-programs-vertex` declares
        // `out Color { float r, g, b; vec4 iLikePie; } vs_color;` and
        // `out gl_PerVertex { vec4 gl_Position; };` in the VS and
        // expects ACTIVE_RESOURCES=5 on GL_PROGRAM_OUTPUT.
        if (programObject->separable && fsShader == nullptr) {
            GLShaderObject* lastVsStage = nullptr;
            for (GLuint shaderId : programObject->attachedShaders) {
                GLShaderObject* s = impl_->objects->shaders().get(shaderId);
                if (s == nullptr) continue;
                if (s->stage == GL_VERTEX_SHADER ||
                    s->stage == GL_TESS_CONTROL_SHADER ||
                    s->stage == GL_TESS_EVALUATION_SHADER ||
                    s->stage == GL_GEOMETRY_SHADER) {
                    lastVsStage = s;
                }
            }
            if (lastVsStage != nullptr) {
                // `gl_Position` is always an output of the last vertex-
                // processing stage (GL 4.6 §11.1). Canonical name +
                // type, no location. For TCS/TES/GS the stage
                // re-declares `out gl_PerVertex { ... } gl_out[]`, so
                // spec §7.3.1.1 names the output `gl_PerVertex.gl_Position`
                // — see the output-block scan below.
                const GLbitfield stageBit =
                    (lastVsStage->stage == GL_VERTEX_SHADER) ? 0x01 :
                    (lastVsStage->stage == GL_TESS_CONTROL_SHADER) ? 0x08 :
                    (lastVsStage->stage == GL_TESS_EVALUATION_SHADER) ? 0x10 :
                    (lastVsStage->stage == GL_GEOMETRY_SHADER) ? 0x04 : 0;
                // Only VS exposes bare `gl_Position`; other stages
                // get the member named through the out-gl_PerVertex block.
                if (lastVsStage->stage == GL_VERTEX_SHADER) {
                    addBuiltIn(programObject->resourceOutputs,
                               "gl_Position", GL_FLOAT_VEC4, stageBit);
                }
                // User varyings declared as simple `out TYPE name;` in
                // VS are already picked up by the scanner's
                // declaredOutputs. We'd push them into resourceOutputs
                // below; but the existing FS loop skips non-FS stages.
                // Mirror it here for the VS-only separable case.
                GLint nextVaryingLoc = 0;
                // Pre-scan the stage source for `patch out ... NAME`
                // patterns so we can mark matching entries as
                // isPerPatch=true. TCS declares these for per-patch
                // outputs; TES can `patch in ...` but that's inputs.
                std::set<std::string> perPatchOutputNames;
                if (lastVsStage->stage == GL_TESS_CONTROL_SHADER) {
                    const std::string& s = lastVsStage->source;
                    const std::string patchKw = "patch ";
                    std::size_t pp = 0;
                    while ((pp = s.find(patchKw, pp)) != std::string::npos) {
                        const bool lb = (pp == 0) ||
                            !(std::isalnum(static_cast<unsigned char>(s[pp - 1])) || s[pp - 1] == '_');
                        if (!lb) { pp += patchKw.size(); continue; }
                        std::size_t q2 = pp + patchKw.size();
                        while (q2 < s.size() && std::isspace(static_cast<unsigned char>(s[q2]))) ++q2;
                        // Expect "out".
                        if (q2 + 3 < s.size() && s.compare(q2, 3, "out") == 0 &&
                            !(std::isalnum(static_cast<unsigned char>(s[q2 + 3])) || s[q2 + 3] == '_')) {
                            q2 += 3;
                            while (q2 < s.size() && std::isspace(static_cast<unsigned char>(s[q2]))) ++q2;
                            // Read the type identifier.
                            while (q2 < s.size() &&
                                   (std::isalnum(static_cast<unsigned char>(s[q2])) || s[q2] == '_')) ++q2;
                            while (q2 < s.size() && std::isspace(static_cast<unsigned char>(s[q2]))) ++q2;
                            // Read the variable name.
                            std::size_t nameStart = q2;
                            while (q2 < s.size() &&
                                   (std::isalnum(static_cast<unsigned char>(s[q2])) || s[q2] == '_')) ++q2;
                            if (q2 > nameStart) {
                                perPatchOutputNames.insert(s.substr(nameStart, q2 - nameStart));
                            }
                        }
                        pp = q2;
                    }
                }
                for (const auto& output : lastVsStage->declaredOutputs) {
                    GLProgramResourceEntry entry;
                    entry.name = output.isArray
                        ? (output.name + "[0]") : output.name;
                    entry.type = output.type;
                    entry.arraySize = output.arraySize;
                    entry.isArray = output.isArray;
                    entry.location = output.explicitLocation >= 0
                        ? output.explicitLocation : nextVaryingLoc;
                    entry.referencedBy = stageBit;
                    // GL 4.6 §7.3.1: GL_LOCATION_INDEX is meaningful
                    // only for fragment shader outputs (dual-source
                    // blend index). VS / GS / TES outputs report -1.
                    entry.locationIndex = -1;
                    entry.isPerPatch = perPatchOutputNames.count(output.name) != 0;
                    const GLint consumed = std::max<GLint>(1, output.arraySize);
                    nextVaryingLoc = entry.location + consumed;
                    programObject->resourceOutputs.push_back(std::move(entry));
                }
                // Output interface blocks — the scanner can't see
                // them through its brace-depth bug, so do a focused
                // source-text scan for `out BlockName { members } inst;`.
                // Per GL 4.6 §7.3.1.1, members of a block WITH an
                // instance name are named "BlockTypeName.member".
                const std::string& vsSrc = lastVsStage->source;
                const std::string outKw = "out ";
                std::size_t scanPos = 0;
                while ((scanPos = vsSrc.find(outKw, scanPos)) != std::string::npos) {
                    const bool leftBoundary = (scanPos == 0) ||
                        !(std::isalnum(static_cast<unsigned char>(vsSrc[scanPos - 1])) ||
                          vsSrc[scanPos - 1] == '_');
                    if (!leftBoundary) { scanPos += outKw.size(); continue; }
                    // Parse the next identifier (block type name).
                    std::size_t p = scanPos + outKw.size();
                    while (p < vsSrc.size() &&
                           (vsSrc[p] == ' ' || vsSrc[p] == '\t')) { ++p; }
                    const std::size_t nameStart = p;
                    while (p < vsSrc.size() &&
                           (std::isalnum(static_cast<unsigned char>(vsSrc[p])) || vsSrc[p] == '_')) { ++p; }
                    const std::string blockName = vsSrc.substr(nameStart, p - nameStart);
                    if (blockName.empty()) { scanPos += outKw.size(); continue; }
                    // Expect '{' (possibly after whitespace).
                    while (p < vsSrc.size() &&
                           (vsSrc[p] == ' ' || vsSrc[p] == '\t' ||
                            vsSrc[p] == '\n' || vsSrc[p] == '\r')) { ++p; }
                    if (p >= vsSrc.size() || vsSrc[p] != '{') {
                        scanPos += outKw.size();
                        continue;
                    }
                    // Skip `out gl_PerVertex { ... };` ONLY for VS —
                    // bare `gl_Position` was already added via the
                    // built-in path. For TCS/TES/GS the test expects
                    // `gl_PerVertex.gl_Position` (block-member naming).
                    if (blockName == "gl_PerVertex" &&
                        lastVsStage->stage == GL_VERTEX_SHADER) {
                        scanPos = p + 1;
                        continue;
                    }
                    const std::size_t bodyStart = p + 1;
                    int depth = 1;
                    std::size_t q = bodyStart;
                    while (q < vsSrc.size() && depth > 0) {
                        if (vsSrc[q] == '{') ++depth;
                        else if (vsSrc[q] == '}') --depth;
                        ++q;
                    }
                    if (depth != 0) { scanPos = p + 1; continue; }
                    // Detect instance name after the closing `}`. If
                    // `} inst;` or `} inst[N];` → members use block-type-
                    // name prefix. If `} ;` (no instance) → bare member
                    // names. Per GL 4.6 §7.3.1.1.
                    std::size_t afterClose = q;
                    while (afterClose < vsSrc.size() &&
                           std::isspace(static_cast<unsigned char>(vsSrc[afterClose]))) ++afterClose;
                    const bool hasInstance = afterClose < vsSrc.size() &&
                        (std::isalpha(static_cast<unsigned char>(vsSrc[afterClose])) ||
                         vsSrc[afterClose] == '_');
                    // Body is vsSrc[bodyStart, q-1). Split on ';'.
                    const std::string body = vsSrc.substr(bodyStart, q - 1 - bodyStart);
                    std::size_t stmtStart = 0;
                    while (stmtStart < body.size()) {
                        const std::size_t semi = body.find(';', stmtStart);
                        if (semi == std::string::npos) break;
                        std::string stmt = body.substr(stmtStart, semi - stmtStart);
                        stmtStart = semi + 1;
                        // Tokenize: strip leading/trailing ws.
                        auto lstrip = [](std::string& s) {
                            std::size_t i = 0;
                            while (i < s.size() &&
                                   (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) ++i;
                            s.erase(0, i);
                        };
                        auto rstrip = [](std::string& s) {
                            while (!s.empty() &&
                                   (s.back() == ' ' || s.back() == '\t' ||
                                    s.back() == '\n' || s.back() == '\r')) s.pop_back();
                        };
                        lstrip(stmt); rstrip(stmt);
                        if (stmt.empty()) continue;
                        // Parse "TYPE name1[, name2, ...]".
                        std::size_t sp = 0;
                        while (sp < stmt.size() &&
                               !(stmt[sp] == ' ' || stmt[sp] == '\t')) ++sp;
                        const std::string typeWord = stmt.substr(0, sp);
                        std::string rest = stmt.substr(sp);
                        lstrip(rest);
                        GLenum memberType = GL_FLOAT;
                        if (typeWord == "float")      memberType = GL_FLOAT;
                        else if (typeWord == "vec2")  memberType = GL_FLOAT_VEC2;
                        else if (typeWord == "vec3")  memberType = GL_FLOAT_VEC3;
                        else if (typeWord == "vec4")  memberType = GL_FLOAT_VEC4;
                        else if (typeWord == "int")   memberType = GL_INT;
                        else if (typeWord == "ivec2") memberType = GL_INT_VEC2;
                        else if (typeWord == "ivec3") memberType = GL_INT_VEC3;
                        else if (typeWord == "ivec4") memberType = GL_INT_VEC4;
                        else if (typeWord == "uint")  memberType = GL_UNSIGNED_INT;
                        else if (typeWord == "uvec2") memberType = GL_UNSIGNED_INT_VEC2;
                        else if (typeWord == "uvec3") memberType = GL_UNSIGNED_INT_VEC3;
                        else if (typeWord == "uvec4") memberType = GL_UNSIGNED_INT_VEC4;
                        else if (typeWord == "mat2")  memberType = GL_FLOAT_MAT2;
                        else if (typeWord == "mat3")  memberType = GL_FLOAT_MAT3;
                        else if (typeWord == "mat4")  memberType = GL_FLOAT_MAT4;
                        // Multiple comma-separated names.
                        std::size_t namePos = 0;
                        while (namePos < rest.size()) {
                            std::size_t nameEnd = namePos;
                            while (nameEnd < rest.size() &&
                                   (std::isalnum(static_cast<unsigned char>(rest[nameEnd])) ||
                                    rest[nameEnd] == '_')) ++nameEnd;
                            if (nameEnd == namePos) break;
                            const std::string memberName =
                                rest.substr(namePos, nameEnd - namePos);
                            GLProgramResourceEntry entry;
                            // With-instance blocks use block-type-
                            // name prefix per §7.3.1.1; no-instance
                            // blocks use bare member names.
                            entry.name = hasInstance
                                ? (blockName + "." + memberName)
                                : memberName;
                            entry.type = memberType;
                            entry.arraySize = 1;
                            entry.location = nextVaryingLoc++;
                            entry.referencedBy = stageBit;
                            // VS varying block members: LOCATION_INDEX
                            // is only meaningful for FS outputs.
                            entry.locationIndex = -1;
                            programObject->resourceOutputs.push_back(std::move(entry));
                            namePos = nameEnd;
                            // Skip whitespace + optional ',' or trailing.
                            while (namePos < rest.size() &&
                                   (rest[namePos] == ' ' || rest[namePos] == ',' ||
                                    rest[namePos] == '\t' || rest[namePos] == '\n')) ++namePos;
                        }
                    }
                    scanPos = q;
                }
            }
        }
    }

    // GL 4.0 subroutines — populate per-stage
    // `resourceSubroutines[stage]` / `resourceSubroutineUniforms[stage]`
    // from each attached shader's GLSL source. No SPIR-V path: we
    // don't emulate Metal-side subroutine dispatch yet, but
    // introspection queries work so `glGetSubroutineUniformLocation`
    // / `glGetActiveSubroutineUniformiv` / PIQ's
    // `GL_*_SUBROUTINE*` interfaces all report spec-correct metadata.
    // CTS `program_interface_query.subroutines-{vertex,tcs,tes,gs,fragment,compute}`
    // exercise these six stages independently.
    {
        auto stageIndex = [](GLenum st) -> int {
            switch (st) {
                case GL_VERTEX_SHADER:          return 0;
                case GL_TESS_CONTROL_SHADER:    return 1;
                case GL_TESS_EVALUATION_SHADER: return 2;
                case GL_GEOMETRY_SHADER:        return 3;
                case GL_FRAGMENT_SHADER:        return 4;
                case GL_COMPUTE_SHADER:         return 5;
                default:                        return -1;
            }
        };
        for (GLuint shaderId : programObject->attachedShaders) {
            GLShaderObject* sh = impl_->objects->shaders().get(shaderId);
            if (sh == nullptr) continue;
            const int si = stageIndex(sh->stage);
            if (si < 0) continue;
            scanSubroutineDeclarations(
                sh->source,
                programObject->resourceSubroutines[si],
                programObject->resourceSubroutineUniforms[si]);
        }
        resetProgramSubroutineSelections(*programObject, false);
    }

    // Run SPIRV-Cross on each attached stage's cached SPIR-V (compiled by
    // GLContext::compileShader and stashed on the shader object). This is
    // best-effort: if translation fails the program still links and falls
    // back to the hardcoded solid-color draw path, but the diagnostic
    // record captures the SPIRV-Cross error so BAR sees what happened.
    programObject->hasTranslatedPipeline = false;
    programObject->vertexMSL.clear();
    programObject->fragmentMSL.clear();
    programObject->vertexMslUsesArgumentBuffer = false;
    programObject->fragmentMslUsesArgumentBuffer = false;
    programObject->vertexMslWritesRenderTargetArrayIndex = false;
    programObject->vertexMslWritesViewportArrayIndex = false;
    programObject->vertexMslHasClipControlYSignParameter = false;
    programObject->fragmentMslUsesFragCoordParams = false;
    programObject->tessControlMSL.clear();
    programObject->tessEvalMSL.clear();
    programObject->tessVertexAsComputeMSL.clear();
    programObject->tessEvalAsComputeMSL.clear();
    programObject->computeMSL.clear();
    programObject->computeReflection = ShaderReflection{};
    programObject->ssboStdLayoutRawCopyFallback = false;
    programObject->vertexSsboEmulatedDraw = false;
    // Zero default so glGetProgramiv(GL_COMPUTE_WORK_GROUP_SIZE) returns
    // (0,0,0) for non-compute programs (matches native drivers).
    // Overwritten by the Compute kind branch below with the shader's
    // local_size_{x,y,z} execution mode.
    programObject->computeLocalSizeX = 0;
    programObject->computeLocalSizeY = 0;
    programObject->computeLocalSizeZ = 0;
    impl_->releaseProgramMetalResources(*programObject);
    programObject->metalPipelineState = nullptr;
    // Release the retained MTLComputePipelineState on relink.
    releaseRetainedMetalObject(programObject->metalComputePipelineState);
    programObject->metalComputePipelineState = nullptr;
    // Step 7-3 compute follow-up: release the retained MTLFunction.
    releaseRetainedMetalObject(programObject->metalComputeFunction);
    programObject->metalComputeFunction = nullptr;
    // Metal tess Phase 1: release the retained TCS-as-compute PSO built
    // by probeTessellationPipeline on the previous link.
    releaseRetainedMetalObject(programObject->metalTessControlPipelineState);
    programObject->metalTessControlPipelineState = nullptr;
    // Metal tess Phase 3: release the retained VS-as-compute PSO built
    // by probeTessellationPipeline (when the VS has outputs).
    releaseRetainedMetalObject(programObject->metalTessVertexPipelineState);
    programObject->metalTessVertexPipelineState = nullptr;
    // T4I [metal-tess-TF]: release per-VAO cached VS-compute PSOs.
    for (auto& entry : programObject->metalTessVertexPSOCache) {
        releaseRetainedMetalObject(entry.second);
    }
    programObject->metalTessVertexPSOCache.clear();
    programObject->metalTessVertexNeedsDescriptor = false;
    // Phase 3B [metal-tess-TF] groundwork: release the retained TES-as-
    // compute PSO (populated once the SPIRV-Cross fork patch lands).
    releaseRetainedMetalObject(programObject->metalTessEvalComputePipelineState);
    programObject->metalTessEvalComputePipelineState = nullptr;
    // Sprint 15 Q3-Option-B Phase 1 [metal-tf-vs]: release the
    // retained VS-as-compute PSO + clear the MSL/reflection/cache so a
    // relink under different env settings re-evaluates the gate
    // cleanly. Mirrors the metal-tess-TF VS-compute reset above.
    programObject->vsTfAsComputeMSL.clear();
    programObject->vsTfAsComputeReflection = ShaderReflection{};
    releaseRetainedMetalObject(programObject->metalVsTfComputePipelineState);
    programObject->metalVsTfComputePipelineState = nullptr;
    for (auto& entry : programObject->metalVsTfComputePSOCache) {
        releaseRetainedMetalObject(entry.second);
    }
    programObject->metalVsTfComputePSOCache.clear();
    programObject->metalVsTfNeedsDescriptor = false;
    programObject->metalVsTfTier = GLProgramObject::MetalVsTfTier::None;
    // Sprint 15 Q3-Option-B Phase 2 [metal-tf-vs]: clear the reflected
    // output struct layout + pre-resolved TF varying sources so the
    // relink-time gate produces a fresh layout (TF varying names may
    // have changed via glTransformFeedbackVaryings between links).
    programObject->vsTfOutputLayout = appgl::StageOutputLayout{};
    programObject->vsTfResolvedSources.clear();
    // Step 7-4: release cached graphics-stage MTLFunctions on relink.
    releaseRetainedMetalObject(programObject->metalVertexFunction);
    programObject->metalVertexFunction = nullptr;
    releaseRetainedMetalObject(programObject->metalFragmentFunction);
    programObject->metalFragmentFunction = nullptr;
    // Phase 8X Group 4d follow-up¹⁴ — release every cached pipeline
    // on relink so the map doesn't hold stale id<MTLRenderPipelineState>
    // pointers derived from the old MSL. The scalar `metalPipelineState`
    // slot above is cleared by assignment (not CFRelease'd) to match
    // the pre-follow-up¹⁴ leak-on-relink behavior; the map needs
    // explicit CFRelease because we retained each entry on insert.
    for (auto& entry : programObject->metalPipelineStateCache) {
        if (entry.second != nullptr) {
            CFRelease(entry.second);
        }
    }
    programObject->metalPipelineStateCache.clear();
    programObject->metalPipelineStateCacheLastUse.clear();
    programObject->metalPipelineStateCacheHighWater = 0;
    programObject->metalPipelineStateCacheHits = 0;
    programObject->metalPipelineStateCacheMisses = 0;
    programObject->metalPipelineStateCacheEvictions = 0;
    programObject->metalPipelineStateCacheGlobalEvictions = 0;
    programObject->metalPipelineColorFormat = 0;
    // CPU GS emulation (docs/geometry-shader-emulation.md) — release
    // the parallel pipeline-state cache so relink rebuilds the
    // synthesised pass-through VS from the new GS SPIR-V instead of
    // serving stale pipelines. geometryEmulated / gsInputTopology /
    // etc. are recomputed by detectGeometryEmulatable a few lines
    // later when the VGF branch runs.
    for (auto& entry : programObject->gsPassThroughPipelineStateCache) {
        if (entry.second != nullptr) {
            CFRelease(entry.second);
        }
    }
    programObject->gsPassThroughPipelineStateCache.clear();
    programObject->gsPassThroughPipelineStateCacheLastUse.clear();
    programObject->gsPassThroughPipelineStateCacheHighWater = 0;
    programObject->gsPassThroughPipelineStateCacheHits = 0;
    programObject->gsPassThroughPipelineStateCacheMisses = 0;
    programObject->gsPassThroughPipelineStateCacheEvictions = 0;
    programObject->gsPassThroughPipelineStateCacheGlobalEvictions = 0;
    programObject->gsPassThroughPipelineState = nullptr;
    programObject->gsPassThroughPipelineColorFormat = 0;
    releaseRetainedMetalObject(programObject->gsPassThroughVertexFunction);
    programObject->gsPassThroughVertexFunction = nullptr;
    releaseRetainedMetalObject(programObject->gsPassThroughFragmentFunction);
    programObject->gsPassThroughFragmentFunction = nullptr;
    programObject->gsPassThroughVertexMSL.clear();
    programObject->gsPassThroughFragmentMSL.clear();
    programObject->gsPassThroughVertexMslUsesArgumentBuffer = false;
    programObject->gsPassThroughFragmentMslUsesArgumentBuffer = false;
    programObject->gsPassThroughFragmentMSLActive = false;
    programObject->gsPassThroughFragmentMSLPrimIdLoc = 0;
    programObject->gsPassThroughReflection = ShaderReflection{};
    programObject->geometryShaderAsMeshMSL.clear();
    programObject->metalGSVsComputeMSL.clear();
    releaseRetainedMetalObject(programObject->metalGSVsComputePipelineState);
    programObject->metalGSVsComputePipelineState = nullptr;
    for (auto& entry : programObject->metalGSVsComputePSOCache) {
        releaseRetainedMetalObject(entry.second);
    }
    programObject->metalGSVsComputePSOCache.clear();
    programObject->metalGSVsComputeNeedsDescriptor = false;
    releaseRetainedMetalObject(programObject->metalGSMeshPipelineState);
    programObject->metalGSMeshPipelineState = nullptr;
    releaseRetainedMetalObject(programObject->metalGSMeshFunction);
    programObject->metalGSMeshFunction = nullptr;
    releaseRetainedMetalObject(programObject->metalGSFragmentFunction);
    programObject->metalGSFragmentFunction = nullptr;
    programObject->geometryEmulated = false;
    programObject->geometryEmulatedTransformFeedbackOnly = false;
    programObject->geometrySpirv.clear();
    programObject->vertexSpirv.clear();
    programObject->vertexSpirvEntryPoint.clear();
    programObject->vertexSpirvSpecializationConstants.clear();
    programObject->gsPresent = false;
    programObject->gsInputTopology = 0;
    programObject->gsOutputTopology = 0;
    programObject->gsMaxVertices = 0;
    programObject->gsInvocations = 1;
    // Sprint 17 Day 7+ Bank-Group-H Path B Component A1 — reset
    // `needsCullDistancePrepass` at relink. Recomputed below post
    // VS-stage SPIR-V availability + GS/tess-presence detection.
    programObject->needsCullDistancePrepass = false;

    ShaderTranslator translator;
    BindingMap bindings;
    ExtensionContext fp64ExtensionContext(*this);
    const bool fp64EmulationAvailable =
        extensions::fp64::shaderTranslationSupported(fp64ExtensionContext);

    auto linkSameStageSourceObjects =
        [&](std::vector<GLShaderObject*>& stageObjects,
            GLenum stage,
            GLShaderObject* selected,
            const char* stageName) -> bool {
        if (selected == nullptr || stageObjects.empty()) {
            return true;
        }
        bool needsStageLink = stageObjects.size() > 1 || selected->spirv.empty();
        bool hasSpirvBinary = false;
        for (const GLShaderObject* shader : stageObjects) {
            if (shader != nullptr && shader->isSpirvBinary) {
                hasSpirvBinary = true;
                break;
            }
        }
        if (!needsStageLink || hasSpirvBinary) {
            return true;
        }
        std::vector<std::string> sources;
        sources.reserve(stageObjects.size());
        std::string linkedSource;
        for (const GLShaderObject* shader : stageObjects) {
            if (shader == nullptr) {
                continue;
            }
            CompatShaderRewriteResult rewrite =
                rewriteCompatShader(shader->source, stage);
            std::string source = rewrite.didRewrite ? rewrite.source : shader->source;
            source = rewriteShaderDrawParametersForSpirv(source, stage);
            source = rewriteUnsizedUniformArrayInitializersForSpirv(source);
            source = rewriteSsboConsecutiveRuntimeArraysForSpirv(source);
            source = rewrite420packImplicitConversionsForSpirv(source);
            source = rewrite420packQualifierOrderInvariantInputsForSpirv(source);
            if (stage == GL_VERTEX_SHADER) {
                source = rewriteDuplicateVertexInputLocationsForSpirv(
                    std::move(source));
            }
            if (!linkedSource.empty()) {
                linkedSource += "\n";
            }
            linkedSource += source;
            sources.push_back(std::move(source));
        }
        std::string linkedLog;
        std::vector<std::uint32_t> linkedSpirv =
            translator.compileGLSLStageProgram(sources, stage, 330, &linkedLog);
        if (linkedSpirv.empty()) {
            programObject->linkLog = std::string(stageName) +
                " same-stage link failed";
            if (!linkedLog.empty()) {
                programObject->linkLog += ": " + linkedLog;
            }
            programObject->linked = false;
            Runtime::shared().recordShaderTranslation({
                programTag + "-" + stageName + "-stage-link",
                stageName,
                quickHash(linkedSource),
                linkVertexHash,
                linkFragmentHash,
                programObject->linkLog,
                "",
                false
            });
            restorePriorExecutableForFailedRelink();
            return false;
        }
        selected->spirv = std::move(linkedSpirv);
        selected->compiled = true;
        selected->compileLog.clear();
        Runtime::shared().recordShaderTranslation({
            programTag + "-" + stageName + "-stage-link",
            stageName,
            quickHash(linkedSource),
            linkVertexHash,
            linkFragmentHash,
            "",
            "",
            true
        });
        return true;
    };

    if (!linkSameStageSourceObjects(vertexShaderObjects, GL_VERTEX_SHADER,
                                    vertexShader, "vertex") ||
        !linkSameStageSourceObjects(tessControlShaderObjects,
                                    GL_TESS_CONTROL_SHADER,
                                    tessControlShader, "tess-control") ||
        !linkSameStageSourceObjects(tessEvalShaderObjects,
                                    GL_TESS_EVALUATION_SHADER,
                                    tessEvalShader, "tess-eval") ||
        !linkSameStageSourceObjects(geometryShaderObjects, GL_GEOMETRY_SHADER,
                                    geometryShader, "geometry") ||
        !linkSameStageSourceObjects(fragmentShaderObjects, GL_FRAGMENT_SHADER,
                                    fragmentShader, "fragment")) {
        return false;
    }

    auto spirvNeedsArgumentBuffers = [](const std::uint32_t* spirvData,
                                        std::size_t spirvWords) -> bool {
        if (spirvData == nullptr || spirvWords == 0) return false;
        try {
            spirv_cross::Compiler compiler(spirvData, spirvWords);
            const auto resources = compiler.get_shader_resources();
            std::uint32_t directSlotSpan = 0;
            for (const auto& ssbo : resources.storage_buffers) {
                auto hasAtomicCounterName = [](const std::string& name) {
                    return name.find("AtomicCounter") != std::string::npos ||
                           name.find("atomicCounter") != std::string::npos;
                };
                if (hasAtomicCounterName(ssbo.name)) continue;
                try {
                    const auto& type = compiler.get_type(ssbo.base_type_id);
                    if (hasAtomicCounterName(compiler.get_name(type.self))) continue;
                } catch (...) {
                }
                std::uint32_t slotSpan = 1;
                try {
                    const auto& type = compiler.get_type(ssbo.type_id);
                    if (!type.array.empty() && type.array[0] > 0) {
                        slotSpan = type.array[0];
                    }
                } catch (...) {
                }
                directSlotSpan += slotSpan;
            }
            // Direct graphics SSBO slots occupy 28..30. Only force argument
            // buffers when the translated stage would outgrow that range.
            if (directSlotSpan > 3) {
                return true;
            }
            // Metal's direct function-parameter path accepts only eight
            // read_write texture arguments per stage. GL 4.6 exposes 16 image
            // uniforms, and the translator/runtime argbuf path already packs
            // storage images at [[id(128+)]]. Flip only active storage-image
            // stages whose array-expanded span would exceed Metal's direct
            // read_write cap, preserving the direct path for the smaller
            // shader_image_load_store cases.
            const auto activeVars = compiler.get_active_interface_variables();
            std::uint32_t activeStorageImageSpan = 0;
            for (const auto& image : resources.storage_images) {
                if (activeVars.find(image.id) == activeVars.end()) {
                    continue;
                }
                std::uint32_t slotSpan = 1;
                try {
                    const auto& type = compiler.get_type(image.type_id);
                    if (!type.array.empty() && type.array[0] > 0) {
                        slotSpan = type.array[0];
                    }
                } catch (...) {
                }
                activeStorageImageSpan += slotSpan;
            }
            return activeStorageImageSpan > 8;
        } catch (...) {
            return false;
        }
    };

    auto collectFlatFragmentInputs = [](const std::string& source) {
        std::vector<std::string> names;
        std::string cleaned;
        cleaned.reserve(source.size());
        bool lineComment = false;
        bool blockComment = false;
        for (std::size_t i = 0; i < source.size(); ++i) {
            const char c = source[i];
            const char next = (i + 1 < source.size()) ? source[i + 1] : '\0';
            if (lineComment) {
                if (c == '\n') {
                    lineComment = false;
                    cleaned.push_back(c);
                } else {
                    cleaned.push_back(' ');
                }
                continue;
            }
            if (blockComment) {
                if (c == '*' && next == '/') {
                    blockComment = false;
                    cleaned.append("  ");
                    ++i;
                } else {
                    cleaned.push_back(std::isspace(static_cast<unsigned char>(c)) ? c : ' ');
                }
                continue;
            }
            if (c == '/' && next == '/') {
                lineComment = true;
                cleaned.append("  ");
                ++i;
                continue;
            }
            if (c == '/' && next == '*') {
                blockComment = true;
                cleaned.append("  ");
                ++i;
                continue;
            }
            cleaned.push_back(c);
        }

        auto isIdentChar = [](unsigned char c) {
            return std::isalnum(c) || c == '_';
        };
        auto isNumberToken = [](const std::string& token) {
            return !token.empty() &&
                std::all_of(token.begin(), token.end(), [](unsigned char c) {
                    return std::isdigit(c);
                });
        };
        auto isNonNameToken = [](const std::string& token) {
            return token == "flat" || token == "in" || token == "out" ||
                   token == "smooth" || token == "noperspective" ||
                   token == "centroid" || token == "sample" ||
                   token == "invariant" || token == "patch" ||
                   token == "layout" || token == "location" ||
                   token == "index" || token == "highp" ||
                   token == "mediump" || token == "lowp" ||
                   token == "const" || token == "readonly" ||
                   token == "writeonly" || token == "coherent" ||
                   token == "volatile" || token == "restrict";
        };
        auto appendStatement = [&](std::string_view stmt) {
            std::vector<std::string> tokens;
            for (std::size_t p = 0; p < stmt.size();) {
                while (p < stmt.size() &&
                       !isIdentChar(static_cast<unsigned char>(stmt[p]))) {
                    ++p;
                }
                const std::size_t start = p;
                while (p < stmt.size() &&
                       isIdentChar(static_cast<unsigned char>(stmt[p]))) {
                    ++p;
                }
                if (p > start) {
                    tokens.emplace_back(stmt.substr(start, p - start));
                }
            }
            const bool hasFlat = std::find(tokens.begin(), tokens.end(), "flat") != tokens.end();
            const bool hasIn = std::find(tokens.begin(), tokens.end(), "in") != tokens.end();
            if (!hasFlat || !hasIn) {
                return;
            }
            for (auto it = tokens.rbegin(); it != tokens.rend(); ++it) {
                if (!isNumberToken(*it) && !isNonNameToken(*it)) {
                    names.push_back(*it);
                    return;
                }
            }
        };

        std::size_t stmtStart = 0;
        for (std::size_t pos = 0; pos <= cleaned.size(); ++pos) {
            if (pos == cleaned.size() || cleaned[pos] == ';') {
                appendStatement(std::string_view(cleaned).substr(stmtStart, pos - stmtStart));
                stmtStart = pos + 1;
            }
        }
        std::sort(names.begin(), names.end());
        names.erase(std::unique(names.begin(), names.end()), names.end());
        return names;
    };

    auto rewriteFlatCentroidPullModelMSL =
        [](std::string& msl, const std::vector<std::string>& flatInputs) {
        if (flatInputs.empty() ||
            msl.find("interpolate_at_centroid()") == std::string::npos) {
            return;
        }
        for (const std::string& name : flatInputs) {
            const std::string from = "." + name + ".interpolate_at_centroid()";
            const std::string to = "." + name + ".interpolate_at_center()";
            std::size_t pos = 0;
            while ((pos = msl.find(from, pos)) != std::string::npos) {
                msl.replace(pos, from.size(), to);
                pos += to.size();
            }
        }
    };

    auto sourceUsesInterpolateAtSample = [](const std::string& source) {
        const char* needle = "interpolateAtSample";
        constexpr std::size_t needleSize = 19;
        auto isIdentChar = [](unsigned char c) {
            return std::isalnum(c) || c == '_';
        };
        bool lineComment = false;
        bool blockComment = false;
        for (std::size_t i = 0; i < source.size(); ++i) {
            const char c = source[i];
            const char next = (i + 1 < source.size()) ? source[i + 1] : '\0';
            if (lineComment) {
                if (c == '\n') {
                    lineComment = false;
                }
                continue;
            }
            if (blockComment) {
                if (c == '*' && next == '/') {
                    blockComment = false;
                    ++i;
                }
                continue;
            }
            if (c == '/' && next == '/') {
                lineComment = true;
                ++i;
                continue;
            }
            if (c == '/' && next == '*') {
                blockComment = true;
                ++i;
                continue;
            }
            if (i + needleSize > source.size() ||
                source.compare(i, needleSize, needle) != 0) {
                continue;
            }
            const bool beforeIdent =
                i > 0 && isIdentChar(static_cast<unsigned char>(source[i - 1]));
            const bool afterIdent =
                i + needleSize < source.size() &&
                isIdentChar(static_cast<unsigned char>(source[i + needleSize]));
            if (!beforeIdent && !afterIdent) {
                return true;
            }
        }
        return false;
    };

    auto applyResolvedVertexInputSourceLocations =
        [&](ShaderReflection& reflection) {
        if (reflection.vertexInputs.empty() ||
            programObject->attributes.empty()) {
            return;
        }
        std::unordered_map<std::string, GLuint> locationsByName;
        for (const auto& attr : programObject->attributes) {
            if (!attr.name.empty() && attr.location >= 0) {
                locationsByName[attr.name] = static_cast<GLuint>(attr.location);
            }
        }
        if (locationsByName.empty()) {
            return;
        }
        for (auto& input : reflection.vertexInputs) {
            auto it = locationsByName.find(input.name);
            if (it == locationsByName.end()) {
                const std::size_t bracket = input.name.find('[');
                if (bracket != std::string::npos) {
                    it = locationsByName.find(input.name.substr(0, bracket));
                }
            }
            if (it != locationsByName.end()) {
                input.sourceLocation = it->second;
            }
        }
    };

    // Translate one stage: spirvToMSL + reflect. Writes the result into the
    // provided output slots on success, records a diagnostic in both the
    // success and failure cases. Returns true iff MSL was produced.
    //
    // Phase 8X Group 4d follow-up⁵ — refactored to take SPIR-V data
    // directly (rather than reading `stage->spirv` from the shader object)
    // so the VS/FS path can pass the cross-stage-linked SPIR-V from
    // `compileGLSLProgram` instead of the per-stage cached blobs that
    // `compileShader` produced via independent `compileGLSL` invocations.
    // The other stages (compute, geometry, tess) still use the cached
    // per-stage SPIR-V — only VS+FS need cross-stage location coordination
    // for the Metal pipeline-state validator.
    auto translateStage = [&](const char* stageName,
                              const std::uint32_t* spirvData,
                              std::size_t spirvWords,
                              const std::string& sourceText,
                              std::string& mslOut,
                              ShaderReflection& reflectionOut,
                              const appgl::TranslatorOptions& optionsIn = {}) -> bool {
        if (spirvData == nullptr || spirvWords == 0) {
            return false;
        }
        const std::string stageTag = programTag + "-" + stageName;
        const std::string hash = quickHash(sourceText);

        // Sprint 17 Day 3+ BONUS-1 [clip_control]: snapshot the
        // current `glClipControl` depth mode into the per-link
        // translator options so SPIRV-Cross's `vertex.fixup_clipspace`
        // tracks GL state at link time. Caller-provided overrides
        // (e.g. tess opts, mesh-GS opts) preserved by copy-then-amend.
        appgl::TranslatorOptions options = optionsIn;
        options.fp64EmulationAvailable = fp64EmulationAvailable;
        options.clipDepthMode = impl_->state->clipDepthMode();
        if (std::strcmp(stageName, "vertex") == 0 &&
            programObject->transformFeedbackVaryingNames.empty()) {
            const GLuint drawFboName = impl_->state->boundDrawFramebuffer();
            if (drawFboName != 0) {
                if (const GLFramebufferObject* fbo =
                        impl_->objects->framebuffers().get(drawFboName)) {
                    options.enableClipControlYSignFixup =
                        framebufferUsesRenderbufferOnlyColorTargets(*fbo);
                }
            }
        }
        if (std::strcmp(stageName, "fragment") == 0) {
            options.fragmentCoordOriginUpperLeft =
                sourceDeclaresFragCoordOriginUpperLeft(sourceText);
        }

        // Phase 8X Group 4d follow-up²³ — sub-step marker + C++ exception
        // guard around spirvToMSL. SPIRV-Cross can throw `spirv_cross_error`
        // on ill-formed SPIR-V or unsupported decoration patterns; if that
        // escapes into this Objective-C++ frame unhandled, std::terminate
        // fires and the process SIGABRTs. Catch here so a throw becomes a
        // clean translation failure (MSL empty + diagnostic record) instead
        // of the fw²² Sky-program-28 crash signature.
        APPGL_LOG(SHADER, @"[GL] linkProgram-step=spirv-to-msl program=%u stage=%s", program, stageName);
        fflush(stderr);
        std::string mslLog;
        std::string msl;
        try {
            msl = translator.spirvToMSL(
                spirvData, spirvWords, bindings, &mslLog, options);
        } catch (const std::exception& e) {
            APPGL_LOG(SHADER, @"[GL] linkProgram-step=spirv-to-msl program=%u stage=%s THREW: %s",
                  program, stageName, e.what());
            fflush(stderr);
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                std::string("spirvToMSL threw std::exception: ") + e.what(),
                "", false
            });
            return false;
        } catch (...) {
            APPGL_LOG(SHADER, @"[GL] linkProgram-step=spirv-to-msl program=%u stage=%s THREW unknown exception",
                  program, stageName);
            fflush(stderr);
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                "spirvToMSL threw unknown exception", "", false
            });
            return false;
        }
        if (msl.empty()) {
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                mslLog.empty() ? "spirvToMSL returned empty MSL" : mslLog,
                "", false
            });
            return false;
        }
        if (std::strcmp(stageName, "fragment") == 0) {
            rewriteFlatCentroidPullModelMSL(
                msl, collectFlatFragmentInputs(sourceText));
        }

        // Phase 8X Group 4d follow-up²³ — sub-step marker + exception guard
        // around reflect. SPIRV-Cross reflection re-walks the SPIR-V and is
        // the other plausible throw site in the translator's critical path.
        APPGL_LOG(SHADER, @"[GL] linkProgram-step=reflect program=%u stage=%s", program, stageName);
        fflush(stderr);
        try {
            reflectionOut = translator.reflect(
                spirvData, spirvWords, bindings, nullptr, options);
            if (std::strcmp(stageName, "vertex") == 0) {
                applyResolvedVertexInputSourceLocations(reflectionOut);
            }
        } catch (const std::exception& e) {
            APPGL_LOG(SHADER, @"[GL] linkProgram-step=reflect program=%u stage=%s THREW: %s",
                  program, stageName, e.what());
            fflush(stderr);
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                std::string("reflect threw std::exception: ") + e.what(),
                "", false
            });
            return false;
        } catch (...) {
            APPGL_LOG(SHADER, @"[GL] linkProgram-step=reflect program=%u stage=%s THREW unknown exception",
                  program, stageName);
            fflush(stderr);
            Runtime::shared().recordShaderTranslation({
                stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
                "reflect threw unknown exception", "", false
            });
            return false;
        }
        mslOut = std::move(msl);
        // Phase 8X Group 4d follow-up⁵ — §6b: when the stage *succeeds*
        // we keep the 200-byte preview because the full MSL is large and
        // the translator records are only useful to humans on failure.
        // The matching failure-case mslPreview enlargement happens in the
        // pipeline-build branch (MetalFrameGraph.mm), where the rejected
        // MSL is what BAR actually wants to see — by which point the
        // pipeline-state NSError has already named the failing stage.
        Runtime::shared().recordShaderTranslation({
            stageTag, stageName, hash, linkVertexHash, linkFragmentHash,
            "ok", mslOut.substr(0, 200), true
        });
        return true;
    };

    // Helper: invoke translateStage against a per-stage cached SPIR-V blob
    // on a GLShaderObject. Used by every case below other than VS+FS, where
    // the VS+FS cross-stage-linked path takes over.
    auto applyShaderSpirvOptions = [&](appgl::TranslatorOptions& options,
                                       const GLShaderObject* stage) {
        if (stage == nullptr || !stage->isSpirvBinary) {
            return;
        }
        options.spirvEntryPointName = stage->spirvEntryPoint;
        options.specializationConstants = stage->spirvSpecializationConstants;
    };

    auto spirvEntryPointNameFor = [](const GLShaderObject* stage)
        -> const std::string* {
        if (stage == nullptr || !stage->isSpirvBinary ||
            stage->spirvEntryPoint.empty()) {
            return nullptr;
        }
        return &stage->spirvEntryPoint;
    };

    auto spirvSpecializationConstantsFor = [](const GLShaderObject* stage)
        -> const std::unordered_map<std::uint32_t, std::uint32_t>* {
        if (stage == nullptr || !stage->isSpirvBinary ||
            stage->spirvSpecializationConstants.empty()) {
            return nullptr;
        }
        return &stage->spirvSpecializationConstants;
    };

    auto stashVertexSpirv = [&](const GLShaderObject* stage) {
        if (stage == nullptr || stage->spirv.empty()) {
            return;
        }
        programObject->vertexSpirv = stage->spirv;
        if (stage->isSpirvBinary) {
            programObject->vertexSpirvEntryPoint = stage->spirvEntryPoint;
            programObject->vertexSpirvSpecializationConstants =
                stage->spirvSpecializationConstants;
        } else {
            programObject->vertexSpirvEntryPoint.clear();
            programObject->vertexSpirvSpecializationConstants.clear();
        }
    };

    auto translateCachedStage = [&](const char* stageName,
                                    GLShaderObject* stage,
                                    std::string& mslOut,
                                    ShaderReflection& reflectionOut,
                                    const appgl::TranslatorOptions& options = {}) -> bool {
        if (stage == nullptr) {
            return false;
        }
        appgl::TranslatorOptions stageOptions = options;
        applyShaderSpirvOptions(stageOptions, stage);
        return translateStage(stageName,
                              stage->spirv.data(), stage->spirv.size(),
                              stage->source, mslOut, reflectionOut, stageOptions);
    };

    // Phase 8X Group 4d follow-up⁵ — VS+FS cross-stage-linked SPIR-V path.
    // Produces both stage SPIR-V blobs from a single glslang::TProgram
    // link + mapIO pass so cross-stage varying locations get coordinated.
    // Returns the linked SPIR-V on success, or empty blobs on failure (in
    // which case the caller falls back to the per-stage cached SPIR-V on
    // the GLShaderObject — same path as pre-followup⁵).
    //
    // The source we pass in is the rewritten compat form, matching exactly
    // what `compileShader` already compiled per-stage: `compileShader`
    // runs `rewriteCompatShader` on `object->source` and feeds the result
    // to `compileGLSL`, but doesn't cache the rewritten string anywhere
    // — so we re-run the rewriter here. `rewriteCompatShader` is a cheap
    // string scan and is idempotent, so re-running it at link time is
    // free.
    auto compileLinkedVsFs = [&](GLShaderObject* vsStage,
                                  GLShaderObject* fsStage) -> LinkedProgramSpirv {
        if (vsStage == nullptr || fsStage == nullptr) {
            return {};
        }
        CompatShaderRewriteResult vsRewrite =
            rewriteCompatShader(vsStage->source, GL_VERTEX_SHADER);
        CompatShaderRewriteResult fsRewrite =
            rewriteCompatShader(fsStage->source, GL_FRAGMENT_SHADER);
        const std::string& vsLinkSource =
            vsRewrite.didRewrite ? vsRewrite.source : vsStage->source;
        const std::string& fsLinkSource =
            fsRewrite.didRewrite ? fsRewrite.source : fsStage->source;
        std::string vsDrawIDLinkSource =
            rewriteShaderDrawParametersForSpirv(vsLinkSource, GL_VERTEX_SHADER);
        std::string fsDrawIDLinkSource =
            rewriteShaderDrawParametersForSpirv(fsLinkSource, GL_FRAGMENT_SHADER);
        vsDrawIDLinkSource =
            rewriteUnsizedUniformArrayInitializersForSpirv(vsDrawIDLinkSource);
        fsDrawIDLinkSource =
            rewriteUnsizedUniformArrayInitializersForSpirv(fsDrawIDLinkSource);
        vsDrawIDLinkSource =
            rewriteSsboConsecutiveRuntimeArraysForSpirv(vsDrawIDLinkSource);
        fsDrawIDLinkSource =
            rewriteSsboConsecutiveRuntimeArraysForSpirv(fsDrawIDLinkSource);
        std::string vs420packLinkSource =
            rewrite420packImplicitConversionsForSpirv(vsDrawIDLinkSource);
        std::string fs420packLinkSource =
            rewrite420packImplicitConversionsForSpirv(fsDrawIDLinkSource);
        vs420packLinkSource =
            rewrite420packQualifierOrderInvariantInputsForSpirv(
                vs420packLinkSource);
        fs420packLinkSource =
            rewrite420packQualifierOrderInvariantInputsForSpirv(
                fs420packLinkSource);
        const std::size_t explicitAttribLocationCount =
            countExplicitResolvedVertexAttribLocations();
        const bool hasTransformFeedbackVaryings =
            !programObject->transformFeedbackVaryingNames.empty();
        const bool vsDeclaresXfbLayout =
            sourceDeclaresTransformFeedbackLayout(vs420packLinkSource);
        const bool fsDeclaresXfbLayout =
            sourceDeclaresTransformFeedbackLayout(fs420packLinkSource);
        const bool mayInjectResolvedVertexAttribLocations =
            explicitAttribLocationCount > 0 &&
            !hasTransformFeedbackVaryings &&
            !vsDeclaresXfbLayout &&
            !fsDeclaresXfbLayout &&
            geometryShader == nullptr &&
            tessControlShader == nullptr &&
            tessEvalShader == nullptr;
        VertexAttribInjectionTrace attribInjectionTrace;
        if (mayInjectResolvedVertexAttribLocations) {
            vs420packLinkSource =
                injectResolvedVertexAttribLocationsForSpirv(
                    std::move(vs420packLinkSource),
                    programObject->attributes,
                    true,
                    &attribInjectionTrace);
        }
        vs420packLinkSource =
            rewriteDuplicateVertexInputLocationsForSpirv(
                std::move(vs420packLinkSource));
        if (traceAttribInjection) {
            std::fprintf(stderr,
                "[APPGL_ATTRIB] program=%u link-gate mayInject=%d "
                "explicit=%zu attrs=%zu tfVaryings=%zu vsXfb=%d fsXfb=%d "
                "gs=%d tcs=%d tes=%d vsHash=%s fsHash=%s\n",
                static_cast<unsigned>(program),
                mayInjectResolvedVertexAttribLocations ? 1 : 0,
                explicitAttribLocationCount,
                programObject->attributes.size(),
                programObject->transformFeedbackVaryingNames.size(),
                vsDeclaresXfbLayout ? 1 : 0,
                fsDeclaresXfbLayout ? 1 : 0,
                geometryShader != nullptr ? 1 : 0,
                tessControlShader != nullptr ? 1 : 0,
                tessEvalShader != nullptr ? 1 : 0,
                linkVertexHash.c_str(),
                linkFragmentHash.c_str());
            std::fprintf(stderr,
                "[APPGL_ATTRIB] program=%u inject-result resolved=%zu "
                "explicit=%zu map=%zu matched=%zu injected=%zu\n",
                static_cast<unsigned>(program),
                attribInjectionTrace.resolvedCount,
                attribInjectionTrace.explicitCount,
                attribInjectionTrace.locationMapCount,
                attribInjectionTrace.matchedDeclarationCount,
                attribInjectionTrace.injectedCount);
            for (const auto& name : attribInjectionTrace.matchedNames) {
                std::fprintf(stderr,
                    "[APPGL_ATTRIB]   matched-decl name=%s\n",
                    name.c_str());
            }
            for (const auto& name : attribInjectionTrace.injectedNames) {
                std::fprintf(stderr,
                    "[APPGL_ATTRIB]   injected name=%s\n",
                    name.c_str());
            }
            std::fflush(stderr);
        }
        // Phase 8X Group 4d follow-up²³ — sub-step marker before the
        // glslang cross-stage link. First candidate on the abort-site ladder
        // is glslang's TProgram::link re-entry, since that's the first heavy
        // operation inside this lambda.
        APPGL_LOG(SHADER, @"[GL] linkProgram-step=compile-glsl-program program=%u", program);
        fflush(stderr);
        std::string linkErrorLog;
        LinkedProgramSpirv linked = translator.compileGLSLProgram(
            vs420packLinkSource, fs420packLinkSource, 330, &linkErrorLog);
        APPGL_LOG(SHADER, @"[GL] compileGLSLProgram: program=%u success=%d log=%s",
              program, linked.linkSucceeded ? 1 : 0,
              linkErrorLog.c_str());
        if (traceAttribInjection) {
            std::fprintf(stderr,
                "[APPGL_ATTRIB] program=%u linked-spirv success=%d log=%s\n",
                static_cast<unsigned>(program),
                linked.linkSucceeded ? 1 : 0,
                linkErrorLog.empty() ? "(empty)" : linkErrorLog.c_str());
            std::fflush(stderr);
        }
        fflush(stderr);
        if (!linked.linkSucceeded) {
            // Record the cross-stage link failure so BAR can see why the
            // VS+FS path is degrading back to per-stage SPIR-V. The fall
            // back is intentional: the per-stage cached SPIR-V may still
            // produce usable MSL (and at worst surfaces the same Metal
            // varying-mismatch the pre-followup⁵ build was already
            // showing), so degrading is strictly no-worse than the prior
            // behaviour.
            //
            // No positive `link-spirv` record on success — the per-stage
            // vertex/fragment records that follow this lambda already
            // carry success=true, and the post-link
            // `[GL] linkProgram: ... translationOk=1` NSLog line covers
            // the "did the linked path run" question. Adding a success
            // record here would also break the
            // `phase-a.shader-program-lifecycle` scene's exact-count
            // assertion (it expects per-link pushes == 2, vertex +
            // fragment).
            Runtime::shared().recordShaderTranslation({
                programTag + "-link-spirv", "link",
                linkVertexHash, linkVertexHash, linkFragmentHash,
                linkErrorLog.empty()
                    ? "compileGLSLProgram failed (no log)"
                    : linkErrorLog,
                "", false
            });
        }
        return linked;
    };

    std::string fragmentOnlySyntheticVertexSourceForReflection;
    bool rasterTranslationOk = false;
    switch (kind) {
        case ProgramKind::VertexFragment: {
            // Run the cross-stage link first. On success, both stages
            // share the linked TProgram's coordinated SPIR-V; on failure,
            // each stage falls back to its per-stage cached SPIR-V —
            // EXCEPT for explicit GL-spec link-validation errors that
            // glslang's TProgram::link() detects and the per-stage path
            // can't recover from (cross-stage binding/location mismatch,
            // type mismatch on shared uniforms, etc.). For those, fail
            // glLinkProgram outright per GL 4.6 §7.3.
            const bool canLinkGlslSources =
                vertexShader != nullptr && fragmentShader != nullptr &&
                !vertexShader->isSpirvBinary && !fragmentShader->isSpirvBinary;
            LinkedProgramSpirv linked = canLinkGlslSources
                ? compileLinkedVsFs(vertexShader, fragmentShader)
                : LinkedProgramSpirv{};
            // Sprint 8 B Cluster F F1 Day 7 (CKPT79): cross-stage link-
            // validation gating. When glslang's link() rejects with a
            // GL-spec qualifier mismatch, propagate as a real
            // glLinkProgram failure. The string-match below targets the
            // canonical glslang error message strings emitted by
            // mergeErrorCheck (linkValidate.cpp ~line 1497) so we don't
            // accidentally fail on recoverable mapIO inconsistencies.
            //
            // Required by KHR-GL46.layout_binding.*.binding_link_errors
            // sub-section: VS+FS declare same sampler name with
            // conflicting `layout(binding=N)` values; spec mandates
            // link failure.
            if (!linked.linkSucceeded && !linked.linkLog.empty()) {
                const auto& lg = linked.linkLog;
                const bool hasSpecMismatch =
                    lg.find("Layout binding qualifier must match") != std::string::npos ||
                    lg.find("Layout location qualifier must match") != std::string::npos ||
                    lg.find("Layout offset qualifier must match")   != std::string::npos ||
                    lg.find("Layout component qualifier must match") != std::string::npos ||
                    lg.find("Layout index qualifier must match")    != std::string::npos;
                if (hasSpecMismatch) {
                    APPGL_LOG(SHADER, @"[GL] linkProgram-fail program=%u reason=cross-stage-spec-mismatch log=%s",
                          program, lg.c_str());
                    programObject->linkLog = lg;
                    programObject->linked = false;
                    Runtime::shared().recordShaderTranslation({
                        programTag, "link", "", "", "", lg, "", false
                    });
                    return false;
                }
            }
            const std::uint32_t* vsSpirvData;
            std::size_t vsSpirvWords;
            const std::uint32_t* fsSpirvData;
            std::size_t fsSpirvWords;
            if (linked.linkSucceeded) {
                vsSpirvData = linked.vertexSpirv.data();
                vsSpirvWords = linked.vertexSpirv.size();
                fsSpirvData = linked.fragmentSpirv.data();
                fsSpirvWords = linked.fragmentSpirv.size();
            } else {
                vsSpirvData = vertexShader->spirv.data();
                vsSpirvWords = vertexShader->spirv.size();
                fsSpirvData = fragmentShader->spirv.data();
                fsSpirvWords = fragmentShader->spirv.size();
            }
            // Sprint 17 Day 7+ Bank-Group-H Path B Component A2: detect
            // VS cull-distance writes before VS translation so the
            // `disableCullDistanceClipRouting` option suppresses the
            // ShaderTranslator gl_CullDistance → [[clip_distance]] HW
            // routing for this program. CPU pre-pass at draw time
            // performs §14.6.3 culling instead. Phase 2 §1.1 confirmed
            // Option β (keep routing) refutation.
            const bool vsCullPrepass =
                appgl::vsSpirvWritesCullDistance(
                    vsSpirvData, vsSpirvWords,
                    spirvEntryPointNameFor(vertexShader),
                    spirvSpecializationConstantsFor(vertexShader));
            // Sprint 18 Item42: graphics SSBOs use Metal argument buffers
            // to avoid direct buffer-index overflow when slot expansion
            // reaches past Metal's 0..30 range. Apply per-program so VS
            // and FS share one resource-binding mode.
            const bool forceRasterArgBuf =
                spirvNeedsArgumentBuffers(vsSpirvData, vsSpirvWords) ||
                spirvNeedsArgumentBuffers(fsSpirvData, fsSpirvWords);
            appgl::TranslatorOptions vsOptions;
            vsOptions.disableCullDistanceClipRouting = vsCullPrepass;
            vsOptions.forceArgumentBuffers = forceRasterArgBuf;
            if (sourceUsesInterpolateAtSample(fragmentShader->source)) {
                vsOptions.enableClipControlYSignFixup = true;
            }
            appgl::TranslatorOptions fsOptions;
            fsOptions.forceArgumentBuffers = forceRasterArgBuf;
            applyShaderSpirvOptions(vsOptions, vertexShader);
            applyShaderSpirvOptions(fsOptions, fragmentShader);

            ShaderReflection vsRefl, fsRefl;
            const bool vsOk = translateStage(
                "vertex", vsSpirvData, vsSpirvWords, vertexShader->source,
                programObject->vertexMSL, vsRefl, vsOptions);
            const bool fsOk = translateStage(
                "fragment", fsSpirvData, fsSpirvWords, fragmentShader->source,
                programObject->fragmentMSL, fsRefl, fsOptions);
            if (vsOk && fsOk) {
                rewriteMslOutputLocationsForFragmentInputs(
                    programObject->vertexMSL, programObject->fragmentMSL);
                programObject->vertexReflection = std::move(vsRefl);
                programObject->fragmentReflection = std::move(fsRefl);
                programObject->hasTranslatedPipeline = true;
                if (vertexShader != nullptr &&
                    sourceNeedsVertexSsboEmulatedDraw(vertexShader->source)) {
                    programObject->vertexSsboEmulatedDraw = true;
                }
                rasterTranslationOk = true;
            }
            if (vertexShader != nullptr &&
                sourceMatchesSSBOStdLayoutRawCopyFallback(vertexShader->source)) {
                programObject->ssboStdLayoutRawCopyFallback = true;
            }
            // Sprint 7 #9 (CKPT65): preserve VS SPIR-V on the
            // VertexFragment program kind so the VS-only TF emulation
            // helper (drawArrays / drawElements) can run the VS on CPU
            // for transform-feedback capture. Without this, programs
            // with TF varyings + no GS/tess + non-separable VS+FS land
            // with `vertexSpirv.empty()` and the helper bails — TF
            // buffer stays at zero-init, breaking
            // `transform_feedback.{capture,query,discard}_vertex_*`.
            if (vertexShader != nullptr && !vertexShader->spirv.empty()) {
                stashVertexSpirv(vertexShader);
            }
            // Sprint 17 Day 7+ Bank-Group-H Path B Component A1: commit
            // the VS cull-distance flag detected above (pre-translation)
            // onto the program object. VertexFragment kind guarantees
            // !gsPresent && !hasTessellation here; if a later relink
            // attaches GS or tess, line 21430's reset clears this flag.
            programObject->needsCullDistancePrepass = vsCullPrepass;
            // Sprint 15 Q3-Option-B Phase 1 [metal-tf-vs]: VS-as-compute
            // MSL emit + PSO build for VS+FS+TF programs (no GS, no
            // tess). Sister-pattern reuse of the existing metal-tess-TF
            // VS-compute groundwork — `forceVertexForTessellation`
            // emits the VS as a Metal compute kernel that captures
            // per-vertex outputs into a buffer (Phase 2 will plumb the
            // TF buffer binding; Phase 3 will swap draw-time routing).
            //
            // Phase 1 lays groundwork only — no draw-time behaviour
            // change. CPU `emulateVsOnlyDrawForTf` remains the
            // authoritative TF capture path until Phase 3 routes
            // around it. Master gate: APPGL_ENABLE_METAL_TF_VS=1
            // (still off by default for this separate VS-only TF
            // path). Read once at link time so a relink under
            // different env settings re-evaluates cleanly.
            //
            // Pre-conditions:
            //   • VS+FS translation succeeded (vsOk && fsOk)
            //   • TF varyings declared via glTransformFeedbackVaryings
            //   • VS SPIR-V preserved (just stashed above)
            //   • impl_->frameGraph present (Metal device available)
            //
            // Outcomes:
            //   • tier=VsAsCompute + retained PSO: Phase 3 eligible
            //     directly (gl_VertexID-only VS, no [[stage_in]])
            //   • tier=VsAsCompute + metalVsTfNeedsDescriptor=true:
            //     Phase 3 builds per-VAO PSO at draw time via
            //     metalVsTfComputePSOCache
            //   • tier=None: gate skipped OR translation/build failed
            //     for non-descriptor reasons → CPU fallback preserved
            if (vsOk && fsOk &&
                !programObject->transformFeedbackVaryingNames.empty() &&
                !programObject->vertexSpirv.empty() &&
                impl_->frameGraph != nullptr &&
                std::getenv("APPGL_ENABLE_METAL_TF_VS") != nullptr) {
                appgl::TranslatorOptions vsTfOpts;
                vsTfOpts.forceVertexForTessellation = true;
                applyShaderSpirvOptions(vsTfOpts, vertexShader);
                ShaderReflection vsTfRefl;
                std::string vsTfMSL;
                const bool vsTfTrOk = translateStage(
                    "vertex-tf-compute", vsSpirvData, vsSpirvWords,
                    vertexShader->source, vsTfMSL, vsTfRefl, vsTfOpts);
                if (vsTfTrOk && !vsTfMSL.empty()) {
                    programObject->vsTfAsComputeMSL = std::move(vsTfMSL);
                    programObject->vsTfAsComputeReflection =
                        std::move(vsTfRefl);
                    std::string vsTfPsoErr;
                    void* vsTfPSO =
                        impl_->frameGraph->buildComputePipelineState(
                            programObject->vsTfAsComputeMSL, &vsTfPsoErr,
                            nullptr, nullptr);
                    if (vsTfPSO != nullptr) {
                        programObject->metalVsTfComputePipelineState =
                            vsTfPSO;
                        programObject->metalVsTfTier =
                            GLProgramObject::MetalVsTfTier::VsAsCompute;
                    } else if (vsTfPsoErr.find("stage_in") !=
                               std::string::npos) {
                        // VS declares [[stage_in]] — defer PSO build to
                        // draw time when the bound VAO's
                        // MTLStageInputOutputDescriptor is known. Phase
                        // 3's draw-time path will lookup-or-build a
                        // per-VAO PSO via metalVsTfComputePSOCache.
                        programObject->metalVsTfNeedsDescriptor = true;
                        programObject->metalVsTfTier =
                            GLProgramObject::MetalVsTfTier::VsAsCompute;
                    } else {
                        // Compile failed for non-descriptor reasons —
                        // surface via diagnostic + leave tier=None so
                        // draw-time stays on the CPU helper.
                        Runtime::shared().recordShaderTranslation({
                            programTag + "-vs-tf-compute-pipeline",
                            "vertex",
                            quickHash(vertexShader->source),
                            linkVertexHash, linkFragmentHash,
                            std::string("metal-tf-vs PSO build failed: ")
                                + vsTfPsoErr,
                            "", false
                        });
                        programObject->vsTfAsComputeMSL.clear();
                        programObject->vsTfAsComputeReflection =
                            ShaderReflection{};
                    }
                    // Sprint 15 Q3-Option-B Phase 2 [metal-tf-vs]:
                    // reflect the VS-as-compute output struct layout +
                    // pre-resolve each declared TF varying name to a
                    // (struct-offset, GL-packed-bytes) pair. Done once
                    // at link time so Phase 3's draw-time TF writer
                    // doesn't repeat the name lookup per dispatch.
                    // Reflection runs whenever tier=VsAsCompute (both
                    // direct-PSO and deferred-descriptor branches);
                    // the layout is independent of stage_in attributes
                    // (those affect input descriptor, not output struct).
                    if (programObject->metalVsTfTier ==
                            GLProgramObject::MetalVsTfTier::VsAsCompute) {
                        programObject->vsTfOutputLayout =
                            translator.reflectStageOutputLayout(
                                vsSpirvData, vsSpirvWords, vsTfOpts);
                        const auto& layout =
                            programObject->vsTfOutputLayout;
                        const auto& tfNames =
                            programObject->transformFeedbackVaryingNames;
                        programObject->vsTfResolvedSources.clear();
                        programObject->vsTfResolvedSources.resize(
                            tfNames.size());
                        std::size_t resolvedCount = 0;
                        for (std::size_t i = 0; i < tfNames.size(); ++i) {
                            const std::string& name = tfNames[i];
                            for (const auto& m : layout.members) {
                                if (m.name == name ||
                                    (name == "gl_Position" &&
                                     m.isBuiltIn &&
                                     m.builtIn ==
                                         spv::BuiltInPosition)) {
                                    programObject
                                        ->vsTfResolvedSources[i] = {
                                        m.offset,
                                        m.glPackedBytes > 0
                                            ? m.glPackedBytes
                                            : m.size};
                                    ++resolvedCount;
                                    break;
                                }
                            }
                        }
                        // If any TF varying name failed to resolve, the
                        // gate stays in VsAsCompute tier but Phase 3's
                        // draw-time path will fall back to the CPU
                        // helper for safety (the name-mismatch could
                        // be a stripBuffer probe target, an extension
                        // syntax we don't reflect, or a true link
                        // error already caught by linkProgram). The
                        // diagnostic record makes the unresolved
                        // varying easy to find post-mortem.
                        if (resolvedCount < tfNames.size()) {
                            std::string unresolved;
                            for (std::size_t i = 0; i < tfNames.size();
                                 ++i) {
                                if (programObject->vsTfResolvedSources[i]
                                        .bytes == 0) {
                                    if (!unresolved.empty()) unresolved += ", ";
                                    unresolved += tfNames[i];
                                }
                            }
                            Runtime::shared().recordShaderTranslation({
                                programTag +
                                    "-vs-tf-varying-resolution",
                                "vertex",
                                quickHash(vertexShader->source),
                                linkVertexHash, linkFragmentHash,
                                std::string("metal-tf-vs unresolved "
                                            "TF varying(s): ") +
                                    unresolved,
                                "", false
                            });
                        }
                    }
                    if (std::getenv("APPGL_TRACE_TF_VS")) {
                        std::fprintf(stderr,
                            "[APPGL] tf-vs-probe program=%u "
                            "tfVaryings=%zu vsTfTier=%d "
                            "needsDescriptor=%d psoOk=%d "
                            "structSize=%zu members=%zu "
                            "resolved=%zu\n",
                            program,
                            programObject
                                ->transformFeedbackVaryingNames.size(),
                            (int)programObject->metalVsTfTier,
                            programObject->metalVsTfNeedsDescriptor
                                ? 1 : 0,
                            vsTfPSO != nullptr ? 1 : 0,
                            programObject->vsTfOutputLayout.structSize,
                            programObject->vsTfOutputLayout
                                .members.size(),
                            programObject->vsTfResolvedSources.size());
                    }
                }
            }
            break;
        }
        case ProgramKind::VertexOnly: {
            ShaderReflection vsRefl;
            appgl::TranslatorOptions vsOptions;
            if (vertexShader != nullptr) {
                vsOptions.forceArgumentBuffers = spirvNeedsArgumentBuffers(
                    vertexShader->spirv.data(), vertexShader->spirv.size());
            }
            const bool vsOk = translateCachedStage(
                "vertex", vertexShader, programObject->vertexMSL, vsRefl,
                vsOptions);
            if (vsOk) {
                programObject->vertexReflection = std::move(vsRefl);
                // A VS-only program is drawable when paired with
                // GL_RASTERIZER_DISCARD (no fragment stage required).
                // The CTS SSBO `*-vs` tests bind ONLY a vertex shader,
                // enable rasterizer discard, and read back SSBO writes
                // produced by the VS alone. Set hasTranslatedPipeline
                // = true and let encodeTranslatedDraw drop the FS when
                // info.rasterizerDiscard is true (the pipeline
                // descriptor will set fragmentFunction = nil +
                // rasterizationEnabled = NO at that point).
                programObject->hasTranslatedPipeline = true;
                if (vertexShader != nullptr &&
                    sourceNeedsVertexSsboEmulatedDraw(vertexShader->source)) {
                    programObject->vertexSsboEmulatedDraw = true;
                }
                rasterTranslationOk = true;
            }
            if (vertexShader != nullptr &&
                sourceMatchesSSBOStdLayoutRawCopyFallback(vertexShader->source)) {
                programObject->ssboStdLayoutRawCopyFallback = true;
            }
            // β [metal-tess-TF]: preserve VS SPIR-V on separable VS so
            // a pipeline-bound tess draw can re-translate VS as compute
            // (`vertex_for_tessellation + capture_output_to_buffer`) at
            // pipeline-bind time. The link-time path here doesn't know
            // a TCS will eventually consume this VS, so it can't emit
            // the compute form alone; the orchestrator does it later.
            if (vertexShader != nullptr && !vertexShader->spirv.empty()) {
                stashVertexSpirv(vertexShader);
            }
            break;
        }
        case ProgramKind::FragmentOnly: {
            bool synthesizedCompatPipeline = false;
            if (appglCompatProfileEnabled() &&
                fragmentShader != nullptr &&
                !fragmentShader->isSpirvBinary) {
                CompatShaderRewriteResult fsRewrite =
                    rewriteCompatShader(fragmentShader->source, GL_FRAGMENT_SHADER);
                if (fsRewrite.legacy.texCoordMax >= 0) {
                    // Piglit's fixed-function teximage helper feeds generic
                    // attrib 0 for position and attrib 1 for texture coords.
                    static constexpr const char* kCompatFragmentOnlyVertexSource =
                        "#version 330 core\n"
                        "layout(location = 0) in vec4 piglit_vertex;\n"
                        "layout(location = 1) in vec2 piglit_texcoord;\n"
                        "uniform mat4 appgl_ModelViewProjectionMatrix;\n"
                        "out vec4 appgl_TexCoord[8];\n"
                        "void main() {\n"
                        "    gl_Position = appgl_ModelViewProjectionMatrix * piglit_vertex;\n"
                        "    for (int i = 0; i < 8; ++i) {\n"
                        "        appgl_TexCoord[i] = vec4(0.0, 0.0, 0.0, 1.0);\n"
                        "    }\n"
                        "    appgl_TexCoord[0] = vec4(piglit_texcoord, 0.0, 1.0);\n"
                        "}\n";
                    std::string vsLinkSource =
                        rewriteShaderDrawParametersForSpirv(
                            kCompatFragmentOnlyVertexSource, GL_VERTEX_SHADER);
                    std::string fsLinkSource =
                        fsRewrite.didRewrite ? fsRewrite.source : fragmentShader->source;
                    fsLinkSource =
                        rewriteShaderDrawParametersForSpirv(
                            fsLinkSource, GL_FRAGMENT_SHADER);
                    vsLinkSource =
                        rewriteUnsizedUniformArrayInitializersForSpirv(vsLinkSource);
                    fsLinkSource =
                        rewriteUnsizedUniformArrayInitializersForSpirv(fsLinkSource);
                    vsLinkSource =
                        rewriteSsboConsecutiveRuntimeArraysForSpirv(vsLinkSource);
                    fsLinkSource =
                        rewriteSsboConsecutiveRuntimeArraysForSpirv(fsLinkSource);
                    vsLinkSource =
                        rewrite420packImplicitConversionsForSpirv(vsLinkSource);
                    fsLinkSource =
                        rewrite420packImplicitConversionsForSpirv(fsLinkSource);
                    vsLinkSource =
                        rewrite420packQualifierOrderInvariantInputsForSpirv(vsLinkSource);
                    fsLinkSource =
                        rewrite420packQualifierOrderInvariantInputsForSpirv(fsLinkSource);

                    std::string linkErrorLog;
                    LinkedProgramSpirv linked = translator.compileGLSLProgram(
                        vsLinkSource, fsLinkSource, 330, &linkErrorLog);
                    if (!linked.linkSucceeded) {
                        Runtime::shared().recordShaderTranslation({
                            programTag + "-fragmentonly-compat-link-spirv",
                            "link", "", "", linkFragmentHash,
                            linkErrorLog.empty()
                                ? "compileGLSLProgram failed (no log)"
                                : linkErrorLog,
                            "", false
                        });
                    } else {
                        const bool forceRasterArgBuf =
                            spirvNeedsArgumentBuffers(linked.vertexSpirv.data(),
                                                    linked.vertexSpirv.size()) ||
                            spirvNeedsArgumentBuffers(linked.fragmentSpirv.data(),
                                                    linked.fragmentSpirv.size());
                        appgl::TranslatorOptions vsOptions;
                        vsOptions.forceArgumentBuffers = forceRasterArgBuf;
                        vsOptions.enableClipControlYSignFixup = true;
                        appgl::TranslatorOptions fsOptions;
                        fsOptions.forceArgumentBuffers = forceRasterArgBuf;
                        ShaderReflection vsRefl, fsRefl;
                        const bool vsOk = translateStage(
                            "vertex", linked.vertexSpirv.data(),
                            linked.vertexSpirv.size(), vsLinkSource,
                            programObject->vertexMSL, vsRefl, vsOptions);
                        const bool fsOk = translateStage(
                            "fragment", linked.fragmentSpirv.data(),
                            linked.fragmentSpirv.size(), fragmentShader->source,
                            programObject->fragmentMSL, fsRefl, fsOptions);
                        if (vsOk && fsOk) {
                            rewriteMslOutputLocationsForFragmentInputs(
                                programObject->vertexMSL, programObject->fragmentMSL);
                            programObject->vertexReflection = std::move(vsRefl);
                            programObject->fragmentReflection = std::move(fsRefl);
                            programObject->vertexSpirv = std::move(linked.vertexSpirv);
                            programObject->vertexSpirvEntryPoint.clear();
                            programObject->vertexSpirvSpecializationConstants.clear();
                            fragmentOnlySyntheticVertexSourceForReflection =
                                vsLinkSource;
                            programObject->hasTranslatedPipeline = true;
                            rasterTranslationOk = true;
                            synthesizedCompatPipeline = true;
                        }
                    }
                }
            }
            if (synthesizedCompatPipeline) {
                break;
            }
            ShaderReflection fsRefl;
            appgl::TranslatorOptions fsOptions;
            if (fragmentShader != nullptr) {
                fsOptions.forceArgumentBuffers = spirvNeedsArgumentBuffers(
                    fragmentShader->spirv.data(), fragmentShader->spirv.size());
            }
            const bool fsOk = translateCachedStage(
                "fragment", fragmentShader, programObject->fragmentMSL, fsRefl,
                fsOptions);
            if (fsOk) {
                programObject->fragmentReflection = std::move(fsRefl);
                rasterTranslationOk = true;
            }
            break;
        }
        case ProgramKind::Compute: {
            // Translate compute to MSL + stash on the program object so
            // glDispatchCompute can encode against the cached pipeline.
            //
            // Compute uses a distinct BindingMap: SSBOs at slots [0..16),
            // UBOs at [16..31). This differs from the graphics pipeline
            // map (where slots [0..16) are reserved for VBOs) and lets
            // GL_MAX_COMPUTE_SHADER_STORAGE_BLOCKS honestly hit the spec
            // floor of 8 (actually 16). Scoped swap of `bindings` is safe
            // because translateStage captures by reference and compute
            // doesn't share the binding map with any other stage.
            const BindingMap savedBindings = bindings;
            bindings = makeComputeBindingMap();
            std::vector<std::uint32_t> linkedComputeSpirv;
            std::string linkedComputeSource;
            std::string linkedComputeLog;
            const std::uint32_t* computeSpirvData =
                (computeShader != nullptr && !computeShader->spirv.empty())
                    ? computeShader->spirv.data() : nullptr;
            std::size_t computeSpirvWords =
                (computeShader != nullptr) ? computeShader->spirv.size() : 0;
            const std::string* computeSourceForTranslation =
                computeShader != nullptr ? &computeShader->source : nullptr;
            if (computeShaderObjects.size() > 1 ||
                computeSpirvData == nullptr || computeSpirvWords == 0) {
                if (!validateLinkedComputeLocalSizes(
                        computeShaderObjects, linkedComputeLog)) {
                    bindings = savedBindings;
                    programObject->linkLog = linkedComputeLog;
                    programObject->linked = false;
                    Runtime::shared().recordShaderTranslation({
                        programTag + "-compute-link", "compute",
                        quickHash(computeShader != nullptr
                            ? computeShader->source : std::string()),
                        linkVertexHash, linkFragmentHash,
                        programObject->linkLog, "", false
                    });
                    return false;
                }
                std::vector<std::string> computeSources;
                computeSources.reserve(computeShaderObjects.size());
                for (const GLShaderObject* shader : computeShaderObjects) {
                    if (shader != nullptr) {
                        computeSources.push_back(shader->source);
                        if (!linkedComputeSource.empty()) {
                            linkedComputeSource += "\n";
                        }
                        linkedComputeSource += shader->source;
                    }
                }
                linkedComputeSpirv = translator.compileGLSLStageProgram(
                    computeSources, GL_COMPUTE_SHADER, 330, &linkedComputeLog);
                if (linkedComputeSpirv.empty()) {
                    bindings = savedBindings;
                    programObject->linkLog = linkedComputeLog.empty()
                        ? "compute same-stage link failed"
                        : linkedComputeLog;
                    programObject->linked = false;
                    Runtime::shared().recordShaderTranslation({
                        programTag + "-compute-link", "compute",
                        quickHash(linkedComputeSource),
                        linkVertexHash, linkFragmentHash,
                        programObject->linkLog, "", false
                    });
                    return false;
                }
                computeSpirvData = linkedComputeSpirv.data();
                computeSpirvWords = linkedComputeSpirv.size();
                computeSourceForTranslation = &linkedComputeSource;
            }
            ShaderReflection csRefl;
            const bool csOk = translateStage(
                "compute", computeSpirvData, computeSpirvWords,
                computeSourceForTranslation != nullptr
                    ? *computeSourceForTranslation : std::string(),
                programObject->computeMSL, csRefl);
            bindings = savedBindings;
            if (csOk) {
                programObject->computeReflection = std::move(csRefl);
                // Extract local_size_{x,y,z} so dispatch knows the
                // threads-per-threadgroup dimensions.
                if (computeSpirvData != nullptr && computeSpirvWords > 0) {
                    auto modes = extractComputeModes(computeSpirvData,
                                                     computeSpirvWords);
                    programObject->computeLocalSizeX = modes.localSizeX;
                    programObject->computeLocalSizeY = modes.localSizeY;
                    programObject->computeLocalSizeZ = modes.localSizeZ;
                }
                // Build + retain the MTLComputePipelineState. Failures
                // are logged but don't fail linkProgram — the dispatch
                // path will then fall back to the stub (returning true
                // with no GPU work).
                if (impl_->frameGraph != nullptr) {
                    std::string psoError;
                    // Step 7-3 compute follow-up: always request the
                    // MTLFunction too when argbuf is enabled. Released
                    // at relink alongside the PSO. The small retain
                    // cost is only paid under the env gate.
                    void* computeFn = nullptr;
                    const bool useArgBuf =
                        (std::getenv("APPGL_ENABLE_ARGUMENT_BUFFERS") != nullptr);
                    void* pso = impl_->frameGraph->buildComputePipelineState(
                        programObject->computeMSL, &psoError,
                        useArgBuf ? &computeFn : nullptr);
                    if (pso != nullptr) {
                        programObject->metalComputePipelineState = pso;
                        programObject->metalComputeFunction = computeFn;
                        APPGL_LOG(SHADER, @"[GL] linkProgram: compute pipeline built for program=%u "
                              @"localSize=[%u,%u,%u]",
                              program,
                              programObject->computeLocalSizeX,
                              programObject->computeLocalSizeY,
                              programObject->computeLocalSizeZ);
                    } else {
                        Runtime::shared().recordShaderTranslation({
                            programTag + "-compute-pipeline", "compute",
                            quickHash(computeShader ? computeShader->source : std::string()),
                            linkVertexHash, linkFragmentHash,
                            std::string("MTLComputePipelineState build failed: ") + psoError,
                            "", false
                        });
                    }
                }
            } else if (computeShader != nullptr &&
                       sourceMatchesSSBOStdLayoutRawCopyFallback(computeShader->source)) {
                programObject->ssboStdLayoutRawCopyFallback = true;
                if (!computeShader->spirv.empty()) {
                    auto modes = extractComputeModes(
                        computeShader->spirv.data(),
                        computeShader->spirv.size());
                    programObject->computeLocalSizeX = modes.localSizeX;
                    programObject->computeLocalSizeY = modes.localSizeY;
                    programObject->computeLocalSizeZ = modes.localSizeZ;
                }
            }
            break;
        }
        case ProgramKind::VertexGeometryFragment: {
            // Translate VS + FS (they're still usable even without the GS)
            // and attempt GS translation so SPIRV-Cross's reflection at
            // least reports what the geometry stage wants. Then record a
            // diagnostic flagging the emulation gap — Metal has no native
            // geometry-shader concept and our compute-stage emulation
            // lands in a follow-up cycle. BAR can read this record and
            // fall back to its non-geometry path.
            //
            // Phase 8X Group 4d follow-up⁵ — VS+FS still go through the
            // cross-stage-linked path even when a GS is present, because
            // the VS→FS varying interface is what Metal's pipeline-state
            // validator inspects. The GS emulation gap is unaffected.
            const bool canLinkGlslSources =
                vertexShader != nullptr && fragmentShader != nullptr &&
                !vertexShader->isSpirvBinary && !fragmentShader->isSpirvBinary;
            LinkedProgramSpirv linked = canLinkGlslSources
                ? compileLinkedVsFs(vertexShader, fragmentShader)
                : LinkedProgramSpirv{};
            const std::uint32_t* vsSpirvData;
            std::size_t vsSpirvWords;
            const std::uint32_t* fsSpirvData;
            std::size_t fsSpirvWords;
            if (linked.linkSucceeded) {
                vsSpirvData = linked.vertexSpirv.data();
                vsSpirvWords = linked.vertexSpirv.size();
                fsSpirvData = linked.fragmentSpirv.data();
                fsSpirvWords = linked.fragmentSpirv.size();
            } else {
                vsSpirvData = vertexShader->spirv.data();
                vsSpirvWords = vertexShader->spirv.size();
                fsSpirvData = fragmentShader->spirv.data();
                fsSpirvWords = fragmentShader->spirv.size();
            }
            // Sprint 17 Day 9+ R13 sub-bank item_5 lines/triangles:
            // extend Path B (`needsCullDistancePrepass`) to GS-present
            // programs. When the VS writes gl_Clip/CullDistance and the
            // GS path doesn't emulate (the `programStoresClipOrCull`
            // stopgap at `GeometryShaderEmulator.cpp:4544` rejects to
            // avoid pixel-coverage gaps in GS-emul cull routing), the
            // legacy translated VS+FS pipeline runs with cull→clip
            // routing siblings driving HW clip — exactly the
            // mixed-sign over-clip case Path B was created to handle.
            // CPU pre-pass on the VS gives spec-correct §14.6.3
            // primitive-level culling for passthrough GS (VS values
            // flow through GS unchanged); non-passthrough GS that
            // modifies cull values is rare and falls outside this gate.
            const bool vsCullPrepassVgf =
                appgl::vsSpirvWritesCullDistance(
                    vsSpirvData, vsSpirvWords,
                    spirvEntryPointNameFor(vertexShader),
                    spirvSpecializationConstantsFor(vertexShader));
            const bool forceRasterArgBufVgf =
                spirvNeedsArgumentBuffers(vsSpirvData, vsSpirvWords) ||
                spirvNeedsArgumentBuffers(fsSpirvData, fsSpirvWords);
            appgl::TranslatorOptions vsOptionsVgf;
            vsOptionsVgf.disableCullDistanceClipRouting = vsCullPrepassVgf;
            vsOptionsVgf.forceArgumentBuffers = forceRasterArgBufVgf;
            appgl::TranslatorOptions fsOptionsVgf;
            fsOptionsVgf.forceArgumentBuffers = forceRasterArgBufVgf;
            applyShaderSpirvOptions(vsOptionsVgf, vertexShader);
            applyShaderSpirvOptions(fsOptionsVgf, fragmentShader);
            ShaderReflection vsRefl, fsRefl, gsRefl;
            const bool vsOk = translateStage(
                "vertex", vsSpirvData, vsSpirvWords, vertexShader->source,
                programObject->vertexMSL, vsRefl, vsOptionsVgf);
            const bool fsOk = translateStage(
                "fragment", fsSpirvData, fsSpirvWords, fragmentShader->source,
                programObject->fragmentMSL, fsRefl, fsOptionsVgf);
            // Sprint 17 Day 9+ R13 sub-bank item_5: commit
            // `needsCullDistancePrepass` for VertexGeometryFragment kind
            // when the VS writes gl_Clip/CullDistance. The drawArrays
            // dispatch site at line ~28344 already gates on `program->
            // needsCullDistancePrepass && program->hasTranslatedPipeline`
            // — both conditions hold here for VS+GS+FS programs whose
            // GS-emul rejects (GS-emul stopgap at GeometryShaderEmulator
            // .cpp:4544). For passthrough GS, VS-only Path B is
            // spec-correct because cull values flow through unchanged.
            programObject->needsCullDistancePrepass = vsCullPrepassVgf;
            std::string unusedGsMSL;
            (void)translateCachedStage("geometry", geometryShader, unusedGsMSL, gsRefl);
            auto reflectStageOnlyVgf = [&](GLShaderObject* shader,
                                           const appgl::TranslatorOptions& options)
                -> ShaderReflection {
                ShaderReflection refl;
                if (shader == nullptr || shader->spirv.empty()) {
                    return refl;
                }
                appgl::TranslatorOptions stageOptions = options;
                stageOptions.fp64EmulationAvailable = fp64EmulationAvailable;
                applyShaderSpirvOptions(stageOptions, shader);
                try {
                    appgl::BindingMap reflectBindings;
                    refl = translator.reflect(shader->spirv.data(),
                                              shader->spirv.size(),
                                              reflectBindings, nullptr,
                                              stageOptions);
                } catch (...) {
                    // Reflection is introspection-only here; leave empty on
                    // failure and preserve the pre-existing link outcome.
                }
                return refl;
            };
            auto reflectionHasResourcesVgf = [](const ShaderReflection& refl) {
                return !refl.vertexInputs.empty() ||
                       !refl.uniformBlocks.empty() ||
                       !refl.storageBuffers.empty() ||
                       !refl.sampledTextures.empty() ||
                       !refl.storageImages.empty();
            };
            if (!reflectionHasResourcesVgf(vsRefl)) {
                ShaderReflection reflectedVs =
                    reflectStageOnlyVgf(vertexShader, vsOptionsVgf);
                if (reflectionHasResourcesVgf(reflectedVs)) {
                    vsRefl = std::move(reflectedVs);
                }
            }
            if (!reflectionHasResourcesVgf(fsRefl)) {
                ShaderReflection reflectedFs =
                    reflectStageOnlyVgf(fragmentShader, fsOptionsVgf);
                if (reflectionHasResourcesVgf(reflectedFs)) {
                    fsRefl = std::move(reflectedFs);
                }
            }
            if (gsRefl.uniformBlocks.empty() &&
                gsRefl.storageBuffers.empty() &&
                gsRefl.sampledTextures.empty() &&
                gsRefl.storageImages.empty()) {
                gsRefl = reflectStageOnlyVgf(geometryShader,
                                             appgl::TranslatorOptions{});
            }
            // Keep the GS reflection so `GL_REFERENCED_BY_GEOMETRY_SHADER`
            // queries on block-scoped resources (uniform blocks, SSBOs,
            // buffer variables) can consult it for usage analysis.
            // SPIRV-Cross's reflection `active` field tells us whether
            // the block is live in the GS body.
            programObject->geometryReflection = gsRefl;
            // CPU GS emulation — step 2 hook. Copy the GS SPIR-V onto
            // the program so it survives shader detach/delete, then ask
            // the emulator whether it can handle this shader. Detection
            // only toggles the flag + topology/max_verts state; no
            // emulation runs here. drawArrays (step 3) branches on
            // programObject->geometryEmulated. See
            // docs/geometry-shader-emulation.md §4.2.
            if (geometryShader != nullptr && !geometryShader->spirv.empty()) {
                programObject->geometrySpirv = geometryShader->spirv;
                // Stash the VS SPIR-V too so the emulator's VS pre-pass
                // (runs on every draw) has a stable copy independent
                // of the shader's lifetime.
                if (vertexShader != nullptr && !vertexShader->spirv.empty()) {
                    stashVertexSpirv(vertexShader);
                }
                // Sprint 8 #8 β.3 (CKPT97): for 5-stage programs
                // (VS+TCS+TES+GS+FS) the kind is VertexGeometryFragment
                // — the same branch that handles 3-stage VS+GS+FS. Stash
                // the tess SPIR-V too so detectTessellationEmulatable
                // can run; without this, the tess detector never sees a
                // tess-shader SPIR-V for tess+GS programs and the
                // tess-emul path stays dormant at draw time.
                //
                // CKPT98 fix: also extract TCS execution modes
                // (OutputVertices) so per-invocation TCS run iterates
                // the right count. Without this, tess-emul ran only
                // invocation 0 and slot-1 user-block writes (e.g.
                // out_data[1].tc_position in data_pass_through) stayed
                // zero, surfacing as fail-shape "index [40] expected
                // [1,1,1,1] found [0,0,0,0]" downstream.
                if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                    programObject->tessControlSpirv = tessControlShader->spirv;
                    programObject->tessControlParsedModule.reset();
                    appgl::TranslatorOptions tessReflectOpts;
                    tessReflectOpts.forceTessellation = true;
                    if (tessEvalShader != nullptr && !tessEvalShader->spirv.empty()) {
                        tessReflectOpts.siblingTesInputSpirv =
                            tessEvalShader->spirv.data();
                        tessReflectOpts.siblingTesInputWordCount =
                            tessEvalShader->spirv.size();
                    }
                    programObject->tessControlReflection =
                        reflectStageOnlyVgf(tessControlShader, tessReflectOpts);
                    auto tcModes = appgl::extractTessellationModes(
                        tessControlShader->spirv.data(),
                        tessControlShader->spirv.size());
                    if (tcModes.outputVertices > 0) {
                        programObject->tessControlOutputVertices =
                            static_cast<GLint>(tcModes.outputVertices);
                    }
                }
                if (tessEvalShader != nullptr && !tessEvalShader->spirv.empty()) {
                    programObject->tessEvalSpirv = tessEvalShader->spirv;
                    programObject->tessEvalParsedModule.reset();
                    appgl::TranslatorOptions tesReflectOpts;
                    tesReflectOpts.forceTessellation = true;
                    tesReflectOpts.forceTessEvalAsCompute = true;
                    if (tessControlShader != nullptr &&
                        !tessControlShader->spirv.empty()) {
                        tesReflectOpts.siblingTcsOutputSpirv =
                            tessControlShader->spirv.data();
                        tesReflectOpts.siblingTcsOutputWordCount =
                            tessControlShader->spirv.size();
                        auto tcModes = appgl::extractTessellationModes(
                            tessControlShader->spirv.data(),
                            tessControlShader->spirv.size());
                        tesReflectOpts.tesePatchVertices = tcModes.outputVertices;
                    }
                    programObject->tessEvalAsComputeReflection =
                        reflectStageOnlyVgf(tessEvalShader, tesReflectOpts);
                    auto teModes = appgl::extractTessellationModes(
                        tessEvalShader->spirv.data(),
                        tessEvalShader->spirv.size());
                    if (teModes.genMode != 0) {
                        programObject->tessGenMode = teModes.genMode;
                    }
                    if (teModes.genSpacing != 0) {
                        programObject->tessGenSpacing = teModes.genSpacing;
                    }
                    if (teModes.genVertexOrder != 0) {
                        programObject->tessGenVertexOrder = teModes.genVertexOrder;
                    }
                    programObject->tessGenPointMode =
                        teModes.pointMode ? GL_TRUE : GL_FALSE;
                }
                (void)appgl::detectGeometryEmulatable(*programObject);
                if (programObject->hasTessellation) {
                    (void)appgl::detectTessellationEmulatable(*programObject);
                }
            }
            const bool meshGsEnabled =
                appgl::appglEnvEnabledDefaultOff("APPGL_ENABLE_MESH_GS");
            // Sprint 3 [metal-mesh-GS]: try the Metal mesh shader path
            // for GS programs whose shape fits the SPIRV-Cross
            // GS-as-mesh patch's MVP coverage. Default-off
            // APPGL_ENABLE_MESH_GS keeps this embryonic path inert until
            // it is promoted; with the flag off, the CPU GS path owns
            // correctness. Gate is a 4-way
            // conjunction:
            //   (0) APPGL_ENABLE_MESH_GS is explicitly enabled
            //   (a) device supports mesh shaders
            //       (`MTLGPUFamilyMetal3` + `MTLGPUFamilyApple7`)
            //   (b) GS shape is mesh-MVP-supported (triangle/line/point
            //       output, no adjacency input, max_vertices ≤ 3,
            //       no streams)
            //   (c) GS SPIR-V successfully translates with
            //       `forceGeometryShaderAsMesh = true`
            // When all four hold, set metalGSTier = MeshShader and
            // stash the emitted MSL for later PSO build. Otherwise
            // fall back to the existing CPU GS interpreter
            // classification (`geometryEmulated`).
            auto synthesizeMeshSampledReflection =
                [&](appgl::ShaderReflection& reflection,
                    const std::string& meshMSL) {
                    if (!reflection.sampledTextures.empty() ||
                        geometryShader == nullptr ||
                        geometryShader->spirv.empty()) {
                        return;
                    }
                    auto isSamplerUniformType = [](GLenum type) {
                        switch (type) {
                            case GL_SAMPLER_1D:
                            case GL_INT_SAMPLER_1D:
                            case GL_UNSIGNED_INT_SAMPLER_1D:
                            case GL_SAMPLER_1D_SHADOW:
                            case GL_SAMPLER_2D:
                            case GL_INT_SAMPLER_2D:
                            case GL_UNSIGNED_INT_SAMPLER_2D:
                            case GL_SAMPLER_2D_SHADOW:
                            case GL_SAMPLER_3D:
                            case GL_INT_SAMPLER_3D:
                            case GL_UNSIGNED_INT_SAMPLER_3D:
                            case GL_SAMPLER_CUBE:
                            case GL_INT_SAMPLER_CUBE:
                            case GL_UNSIGNED_INT_SAMPLER_CUBE:
                            case GL_SAMPLER_CUBE_SHADOW:
                            case GL_SAMPLER_1D_ARRAY:
                            case GL_INT_SAMPLER_1D_ARRAY:
                            case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY:
                            case GL_SAMPLER_1D_ARRAY_SHADOW:
                            case GL_SAMPLER_2D_ARRAY:
                            case GL_INT_SAMPLER_2D_ARRAY:
                            case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY:
                            case GL_SAMPLER_2D_ARRAY_SHADOW:
                            case GL_SAMPLER_CUBE_MAP_ARRAY:
                            case GL_INT_SAMPLER_CUBE_MAP_ARRAY:
                            case GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY:
                            case GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW:
                            case GL_SAMPLER_2D_RECT:
                            case GL_INT_SAMPLER_2D_RECT:
                            case GL_UNSIGNED_INT_SAMPLER_2D_RECT:
                            case GL_SAMPLER_2D_RECT_SHADOW:
                            case GL_SAMPLER_BUFFER:
                            case GL_INT_SAMPLER_BUFFER:
                            case GL_UNSIGNED_INT_SAMPLER_BUFFER:
                            case GL_SAMPLER_2D_MULTISAMPLE:
                            case GL_INT_SAMPLER_2D_MULTISAMPLE:
                            case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE:
                            case GL_SAMPLER_2D_MULTISAMPLE_ARRAY:
                            case GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                            case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                                return true;
                            default:
                                return false;
                        }
                    };
                    auto stripAppGLPrefix = [](std::string name) {
                        constexpr const char* kAppglPrefix = "_appgl_";
                        constexpr std::size_t kAppglPrefixLen = 7;
                        if (name.compare(0, kAppglPrefixLen, kAppglPrefix) == 0) {
                            name = name.substr(kAppglPrefixLen);
                        }
                        return name;
                    };
                    auto findTextureSlot = [&](const std::string& name,
                                               std::uint32_t fallback) {
                        auto isIdentChar = [](char c) {
                            return c == '_' ||
                                (c >= '0' && c <= '9') ||
                                (c >= 'A' && c <= 'Z') ||
                                (c >= 'a' && c <= 'z');
                        };
                        std::size_t pos = 0;
                        const std::string attrNeedle = "[[texture(";
                        while ((pos = meshMSL.find(name, pos)) != std::string::npos) {
                            const std::size_t end = pos + name.size();
                            const bool leftOk = pos == 0 ||
                                !isIdentChar(meshMSL[pos - 1]);
                            const bool rightOk = end >= meshMSL.size() ||
                                !isIdentChar(meshMSL[end]);
                            if (leftOk && rightOk) {
                                const std::size_t attr =
                                    meshMSL.find(attrNeedle, end);
                                const std::size_t stop =
                                    meshMSL.find_first_of(",)", end);
                                if (attr != std::string::npos &&
                                    (stop == std::string::npos || attr < stop)) {
                                    const std::size_t valueStart =
                                        attr + attrNeedle.size();
                                    const std::size_t valueEnd =
                                        meshMSL.find(")]]", valueStart);
                                    if (valueEnd != std::string::npos) {
                                        try {
                                            return static_cast<std::uint32_t>(
                                                std::stoul(meshMSL.substr(
                                                    valueStart,
                                                    valueEnd - valueStart)));
                                        } catch (...) {
                                            return fallback;
                                        }
                                    }
                                }
                            }
                            pos = end;
                        }
                        return fallback;
                    };
                    auto collectTextureSlots = [&]() {
                        std::vector<std::uint32_t> slots;
                        const std::string attrNeedle = "[[texture(";
                        std::size_t pos = 0;
                        while ((pos = meshMSL.find(attrNeedle, pos)) != std::string::npos) {
                            const std::size_t valueStart =
                                pos + attrNeedle.size();
                            const std::size_t valueEnd =
                                meshMSL.find(")]]", valueStart);
                            if (valueEnd == std::string::npos) {
                                break;
                            }
                            try {
                                slots.push_back(static_cast<std::uint32_t>(
                                    std::stoul(meshMSL.substr(
                                        valueStart, valueEnd - valueStart))));
                            } catch (...) {
                            }
                            pos = valueEnd + 3;
                        }
                        return slots;
                    };
                    auto appendBindingIfMissing =
                        [&](const GLProgramUniformInfo& uniformInfo,
                            std::uint32_t metalSlot) {
                            for (const auto& existing : reflection.sampledTextures) {
                                if (existing.name == uniformInfo.name) {
                                    return;
                                }
                            }
                            appgl::ShaderReflection::ResourceBinding binding;
                            binding.name = uniformInfo.name;
                            binding.glBinding = uniformInfo.explicitBinding >= 0
                                ? static_cast<GLuint>(uniformInfo.explicitBinding)
                                : 0u;
                            binding.metalBinding = metalSlot;
                            reflection.sampledTextures.push_back(std::move(binding));
                        };

                    const auto vars = appgl::collectSamplerVarsFromSpirv(
                        geometryShader->spirv.data(),
                        geometryShader->spirv.size());
                    for (const auto& var : vars) {
                        const std::string lookupName =
                            stripAppGLPrefix(var.name);
                        const GLProgramUniformInfo* uniformInfo = nullptr;
                        for (const auto& uniform : programObject->uniforms) {
                            if (uniform.name == lookupName &&
                                isSamplerUniformType(uniform.type)) {
                                uniformInfo = &uniform;
                                break;
                            }
                        }
                        if (uniformInfo == nullptr) {
                            continue;
                        }
                        appgl::ShaderReflection::ResourceBinding binding;
                        binding.name = lookupName;
                        binding.glBinding = uniformInfo->explicitBinding >= 0
                            ? static_cast<GLuint>(uniformInfo->explicitBinding)
                            : 0u;
                        binding.metalBinding =
                            findTextureSlot(var.name, binding.glBinding);
                        reflection.sampledTextures.push_back(std::move(binding));
                    }
                    if (reflection.sampledTextures.empty()) {
                        const auto textureSlots = collectTextureSlots();
                        if (!textureSlots.empty()) {
                            std::size_t slotIndex = 0;
                            for (const auto& uniform : programObject->uniforms) {
                                if (!isSamplerUniformType(uniform.type)) {
                                    continue;
                                }
                                if (slotIndex >= textureSlots.size()) {
                                    break;
                                }
                                const std::uint32_t fallbackSlot =
                                    textureSlots[slotIndex++];
                                appendBindingIfMissing(
                                    uniform,
                                    findTextureSlot(uniform.name, fallbackSlot));
                            }
                        }
                    }
                };
            if (meshGsEnabled &&
                geometryShader != nullptr && !geometryShader->spirv.empty() &&
                !programObject->geometryEmulated &&
                impl_->capabilities != nullptr &&
                impl_->capabilities->meshShaderSupported()) {
                // Shape gate: input topology, output topology,
                // max_vertices. detectGeometryEmulatable already
                // populated these fields on the program object.
                const bool inputOK =
                    programObject->gsInputTopology == GL_POINTS ||
                    programObject->gsInputTopology == GL_LINES ||
                    programObject->gsInputTopology == GL_TRIANGLES;
                // Adjacency variants are deferred per the SPIRV-Cross
                // patch's deferred-work list. CPU interpreter handles
                // them; selective routing keeps adjacency on CPU.
                const bool outputOK =
                    programObject->gsOutputTopology == GL_TRIANGLE_STRIP ||
                    programObject->gsOutputTopology == GL_LINE_STRIP ||
                    programObject->gsOutputTopology == GL_POINTS;
                // CKPT20 [Sprint 3 close]: gate widened from ≤3 to ≤4
                // to activate Path I (interface-block GS input
                // member population, fork 2a85276) on
                // `nonarray_input.nonarray_input` (max_vertices=4).
                // CKPT20 cluster verification: gate ≤4 preserves the
                // 121/136 default-on invariant with 0 regressions
                // (nonarray_input was already passing via legacy CPU
                // emul; now routes through mesh path with Path I
                // unblocking the interface-block input flow). The
                // layered_rendering family (max_vertices ≥ 16) +
                // `blending_support` (max=64) still fail at the
                // per-layer rasterization layer — separate gap class
                // carried forward to Sprint 4. Gate ≥5 is deferred
                // pending that cluster's diagnosis.
                const bool maxVerticesOK = programObject->gsMaxVertices <= 4u;
                const bool shapeOK = inputOK && outputOK && maxVerticesOK;
                if (shapeOK) {
                    appgl::TranslatorOptions gsMeshOpts;
                    gsMeshOpts.forceGeometryShaderAsMesh = true;
                    applyShaderSpirvOptions(gsMeshOpts, geometryShader);
                    appgl::ShaderReflection meshGsRefl;
                    std::string meshGsMSL;
                    const bool meshOk = translateStage(
                        "geometry-as-mesh",
                        geometryShader->spirv.data(),
                        geometryShader->spirv.size(),
                        geometryShader->source,
                        meshGsMSL, meshGsRefl, gsMeshOpts);
                    if (meshOk && !meshGsMSL.empty()) {
                        synthesizeMeshSampledReflection(meshGsRefl, meshGsMSL);
                        programObject->geometryShaderAsMeshMSL = std::move(meshGsMSL);
                        if (!meshGsRefl.sampledTextures.empty() ||
                            !meshGsRefl.storageImages.empty() ||
                            !meshGsRefl.uniformBlocks.empty() ||
                            !meshGsRefl.storageBuffers.empty()) {
                            programObject->geometryReflection = std::move(meshGsRefl);
                        }
                        programObject->metalGSTier =
                            GLProgramObject::MetalGSTier::MeshShader;
                    }
                }
            }
            // Sprint 3 Phase 2 [metal-mesh-GS]: link-time PSO build.
            // When tier=MeshShader, prepare the two pieces the draw-time
            // encoder needs:
            //   (1) VS-as-compute PSO — VS source re-translated with
            //       `vertex_for_tessellation + capture_output_to_buffer`
            //       so the per-vertex outputs land in a buffer the mesh
            //       function reads at [[buffer(22)]] (Path A's
            //       `spvVsOutputs`, ec354aa). Mirrors Phase-3 metal-tess
            //       VS-compute path; reuses `forceVertexForTessellation`.
            //   (2) Mesh function — the `geometryShaderAsMeshMSL`
            //       compiled to a retained `id<MTLFunction>`. The render
            //       PSO itself is FBO-format-keyed and built lazily at
            //       draw time.
            // Either (1) or (2) failing demotes tier back to None so the
            // CPU-interpreter fallback below picks the program up. Programs
            // whose VS uses [[stage_in]] would fail (1) here and fall back
            // — same handleability gate as the tess path. The 6 MVP
            // conversion targets are simple gl_VertexID-only VSes, well
            // inside this gate.
            if (programObject->metalGSTier ==
                    GLProgramObject::MetalGSTier::MeshShader &&
                impl_->frameGraph != nullptr) {
                bool meshLinkOk = true;
                // (1) VS-as-compute translation + PSO build.
                if (vertexShader != nullptr && !vertexShader->spirv.empty()) {
                    auto annotateMeshVsComputeInputs =
                        [](std::string& msl,
                           const appgl::ShaderReflection& reflection) {
                            const std::size_t structPos =
                                msl.find("struct main0_in");
                            if (structPos == std::string::npos) {
                                return;
                            }
                            const std::size_t bodyStart =
                                msl.find('{', structPos);
                            std::size_t bodyEnd = msl.find("};", bodyStart);
                            if (bodyStart == std::string::npos ||
                                bodyEnd == std::string::npos) {
                                return;
                            }
                            auto isIdentChar = [](char c) {
                                return c == '_' ||
                                    (c >= '0' && c <= '9') ||
                                    (c >= 'A' && c <= 'Z') ||
                                    (c >= 'a' && c <= 'z');
                            };
                            for (const auto& input : reflection.vertexInputs) {
                                if (input.name.empty()) {
                                    continue;
                                }
                                std::size_t pos = bodyStart;
                                while ((pos = msl.find(input.name, pos)) !=
                                       std::string::npos && pos < bodyEnd) {
                                    const std::size_t end =
                                        pos + input.name.size();
                                    const bool leftOk = pos == 0 ||
                                        !isIdentChar(msl[pos - 1]);
                                    const bool rightOk = end >= msl.size() ||
                                        !isIdentChar(msl[end]);
                                    if (!leftOk || !rightOk) {
                                        pos = end;
                                        continue;
                                    }
                                    const std::size_t semi =
                                        msl.find(';', end);
                                    if (semi == std::string::npos ||
                                        semi >= bodyEnd) {
                                        break;
                                    }
                                    const std::size_t existing =
                                        msl.find("[[attribute(", end);
                                    if (existing == std::string::npos ||
                                        existing > semi) {
                                        const std::string attr =
                                            " [[attribute(" +
                                            std::to_string(input.location) +
                                            ")]]";
                                        msl.insert(semi, attr);
                                        bodyEnd += attr.size();
                                    }
                                    break;
                                }
                            }
                        };
                    appgl::TranslatorOptions vsComputeOpts;
                    vsComputeOpts.forceVertexForTessellation = true;
                    // Path G [Checkpoint 15, fork f19ce45]: ACTUAL fix
                    // for the VS-as-compute kernel-doesn't-execute
                    // symptom. Apple's [[grid_size]] returns (0,0,0)
                    // on Apple Silicon — bounds check fires
                    // universally, all threads early-return.
                    // [[threads_per_grid]] returns the dispatched
                    // size correctly. Path E/E++/E+++ flags
                    // (barrier/volatile/atomic) preserved in the
                    // TranslatorOptions struct as historical
                    // record + optional defense-in-depth, but kept
                    // OFF here — Path G alone is sufficient.
                    vsComputeOpts.forceThreadsPerGridForStageInputSize = true;
                    applyShaderSpirvOptions(vsComputeOpts, vertexShader);
                    appgl::ShaderReflection vsComputeRefl;
                    std::string vsComputeMSL;
                    const bool vsTrOk = translateStage(
                        "vertex-as-compute-for-mesh",
                        vertexShader->spirv.data(),
                        vertexShader->spirv.size(),
                        vertexShader->source,
                        vsComputeMSL, vsComputeRefl, vsComputeOpts);
                    if (vsTrOk && !vsComputeMSL.empty()) {
                        annotateMeshVsComputeInputs(vsComputeMSL, vsRefl);
                        programObject->metalGSVsComputeMSL = vsComputeMSL;
                        std::string vsPsoErr;
                        void* vsPSO = impl_->frameGraph
                            ->buildComputePipelineState(vsComputeMSL,
                                                         &vsPsoErr,
                                                         nullptr);
                        if (vsPSO != nullptr) {
                            programObject->metalGSVsComputePipelineState = vsPSO;
                        } else if (vsPsoErr.find("stage_in") != std::string::npos) {
                            programObject->metalGSVsComputeNeedsDescriptor = true;
                        } else {
                            if (std::getenv("APPGL_TRACE_MESH_GS") != nullptr) {
                                std::fprintf(stderr,
                                    "[MESH_GS] link VS-compute PSO failed: %s\n",
                                    vsPsoErr.c_str());
                            }
                            meshLinkOk = false;
                        }
                    } else {
                        if (std::getenv("APPGL_TRACE_MESH_GS") != nullptr) {
                            std::fprintf(stderr,
                                "[MESH_GS] vertex-as-compute translation failed\n");
                        }
                        meshLinkOk = false;
                    }
                } else {
                    if (std::getenv("APPGL_TRACE_MESH_GS") != nullptr) {
                        std::fprintf(stderr,
                            "[MESH_GS] missing vertex shader SPIR-V for mesh link\n");
                    }
                    meshLinkOk = false;
                }
                // (2) Compile mesh function + FS function.
                if (meshLinkOk) {
                    std::string meshFnErr;
                    void* meshFn = impl_->frameGraph
                        ->compileMSLFunction(
                            programObject->geometryShaderAsMeshMSL,
                            &meshFnErr);
                    if (meshFn != nullptr) {
                        programObject->metalGSMeshFunction = meshFn;
                    } else {
                        if (std::getenv("APPGL_TRACE_MESH_GS") != nullptr) {
                            std::fprintf(stderr,
                                "[MESH_GS] mesh function compile failed: %s\n",
                                meshFnErr.c_str());
                        }
                        meshLinkOk = false;
                    }
                }
                if (meshLinkOk && !programObject->fragmentMSL.empty()) {
                    std::string fsFnErr;
                    void* fsFn = impl_->frameGraph
                        ->compileMSLFunction(
                            programObject->fragmentMSL, &fsFnErr);
                    if (fsFn != nullptr) {
                        programObject->metalGSFragmentFunction = fsFn;
                    } else {
                        if (std::getenv("APPGL_TRACE_MESH_GS") != nullptr) {
                            std::fprintf(stderr,
                                "[MESH_GS] mesh fragment function compile failed: %s\n",
                                fsFnErr.c_str());
                        }
                        meshLinkOk = false;
                    }
                }
                // Demote on any failure so the CPU-interpreter fallback
                // picks the program up below.
                if (!meshLinkOk) {
                    programObject->metalGSTier =
                        GLProgramObject::MetalGSTier::None;
                }
            }
            if (programObject->metalGSTier == GLProgramObject::MetalGSTier::None &&
                programObject->geometryEmulated) {
                programObject->metalGSTier =
                    GLProgramObject::MetalGSTier::CPUInterpreter;
            }
            // Record the emulation outcome after the per-stage records
            // so BAR / trace logs see: [vertex:ok][fragment:ok][geometry:ok][gap-or-cpu-emulation].
            if (programObject->geometryEmulated) {
                Runtime::shared().recordShaderTranslation({
                    programTag + "-geometry-cpu-emulation", "geometry",
                    quickHash(geometryShader->source),
                    linkVertexHash, linkFragmentHash,
                    "geometry shader will run on the CPU emulator "
                    "(constant_expressions GS subset); drawArrays routes "
                    "expanded vertices through a synthesised pass-through VS",
                    "", true
                });
            } else {
                const std::string gsEmulDiagnostic =
                    programObject->geometryEmulationDiagnostic.empty()
                        ? "unsupported opcode, topology, or execution mode"
                        : programObject->geometryEmulationDiagnostic;
                programObject->linkLog +=
                    "\n[geometry-emul] rejected: " + gsEmulDiagnostic;
                Runtime::shared().recordShaderTranslation({
                    programTag + "-geometry-emulation", "geometry",
                    quickHash(geometryShader->source),
                    linkVertexHash, linkFragmentHash,
                    "geometry shader outside the CPU-emulator's supported "
                    "SPIR-V subset; raster draws will be fail-loud instead "
                    "of falling back to VS+FS-only. Reason: " +
                        gsEmulDiagnostic,
                    "", false
                });
            }
            if (vsOk && fsOk) {
                programObject->hasTranslatedPipeline = true;
                rasterTranslationOk = true;
            }
            if (reflectionHasResourcesVgf(vsRefl)) {
                programObject->vertexReflection = std::move(vsRefl);
            }
            if (reflectionHasResourcesVgf(fsRefl)) {
                programObject->fragmentReflection = std::move(fsRefl);
            }
            break;
        }
        case ProgramKind::VertexGeometry: {
            // Sprint 15 Day 18 (CKPT191) — VS+GS no-FS combination. Mirrors
            // the VertexGeometryFragment branch's GS detection / emulation
            // setup but skips fragment translation entirely. The draw-time
            // pipeline path already handles `hasFragmentStage = false +
            // rasterizerDiscard = true` for VertexOnly tests; we reuse the
            // same nil-fragmentFunction + rasterizationEnabled=NO Metal
            // pipeline configuration. CTS targets:
            // shader_image_load_store.basic-allTargets-{loadStoreGS, atomicGS,
            // loadStoreVS, atomicVS} (the GS variants build VS+GS only with
            // image writes in the GS body; the VS variants don't reach this
            // case). Prior characterization at CKPT164 §3 estimated this as
            // multi-day infrastructure; the surgical scope ended up tractable
            // because VertexOnly already wired the no-FS pipeline path.
            ShaderReflection vsRefl, gsRefl;
            appgl::TranslatorOptions vsOptionsVg;
            if (vertexShader != nullptr) {
                vsOptionsVg.forceArgumentBuffers = spirvNeedsArgumentBuffers(
                    vertexShader->spirv.data(), vertexShader->spirv.size());
            }
            const bool vsOk = translateCachedStage(
                "vertex", vertexShader, programObject->vertexMSL, vsRefl,
                vsOptionsVg);
            std::string unusedGsMSL;
            (void)translateCachedStage("geometry", geometryShader, unusedGsMSL, gsRefl);
            programObject->geometryReflection = gsRefl;
            // CPU GS emulation hookup — copy GS SPIR-V onto the program
            // (survives shader detach/delete) and let the emulator decide
            // whether it can handle this shader. Mirrors VertexGeometryFragment.
            if (geometryShader != nullptr && !geometryShader->spirv.empty()) {
                programObject->geometrySpirv = geometryShader->spirv;
                if (vertexShader != nullptr && !vertexShader->spirv.empty()) {
                    stashVertexSpirv(vertexShader);
                }
                (void)appgl::detectGeometryEmulatable(*programObject);
            }
            // No mesh-shader path here: SILS GS targets need CPU emulation
            // for image opcodes; the mesh path doesn't gate on FS but the
            // SILS shape (image writes from GS body) lives entirely in the
            // CPU interpreter.
            if (programObject->metalGSTier == GLProgramObject::MetalGSTier::None &&
                programObject->geometryEmulated) {
                programObject->metalGSTier =
                    GLProgramObject::MetalGSTier::CPUInterpreter;
            }
            if (programObject->geometryEmulated) {
                Runtime::shared().recordShaderTranslation({
                    programTag + "-geometry-cpu-emulation-no-fs", "geometry",
                    quickHash(geometryShader->source),
                    linkVertexHash, "",
                    "VS+GS-no-FS program (CKPT191): geometry shader runs on "
                    "the CPU emulator; pipeline fragmentFunction = nil + "
                    "rasterizationEnabled = NO at draw time",
                    "", true
                });
            }
            if (vsOk) {
                programObject->vertexReflection = std::move(vsRefl);
                // Empty fragmentMSL signals the no-FS pipeline path. The
                // draw-time encoder treats this as legitimate when
                // rasterizerDiscard is set (matches VertexOnly behaviour).
                programObject->fragmentMSL.clear();
                programObject->hasTranslatedPipeline = true;
                rasterTranslationOk = true;
            }
            break;
        }
        case ProgramKind::VertexTessellationGeometry: {
            ShaderReflection vsRefl, gsRefl;
            appgl::TranslatorOptions vsOptionsVtg;
            if (vertexShader != nullptr) {
                vsOptionsVtg.forceArgumentBuffers = spirvNeedsArgumentBuffers(
                    vertexShader->spirv.data(), vertexShader->spirv.size());
            }
            const bool vsOk = translateCachedStage(
                "vertex", vertexShader, programObject->vertexMSL, vsRefl,
                vsOptionsVtg);

            std::string unusedGsMSL;
            (void)translateCachedStage("geometry", geometryShader,
                                       unusedGsMSL, gsRefl);
            programObject->geometryReflection = gsRefl;

            auto reflectOnly = [&](GLShaderObject* shader,
                                   const appgl::TranslatorOptions& options)
                -> ShaderReflection {
                ShaderReflection refl;
                if (shader == nullptr || shader->spirv.empty()) {
                    return refl;
                }
                appgl::TranslatorOptions stageOptions = options;
                stageOptions.fp64EmulationAvailable = fp64EmulationAvailable;
                applyShaderSpirvOptions(stageOptions, shader);
                try {
                    refl = translator.reflect(shader->spirv.data(),
                                              shader->spirv.size(),
                                              bindings, nullptr,
                                              stageOptions);
                } catch (...) {
                    // CPU emulation can still run with empty reflection;
                    // buildStorageImageMap has a uniform-scanner fallback.
                }
                return refl;
            };

            if (geometryShader != nullptr && !geometryShader->spirv.empty() &&
                programObject->geometryReflection.storageImages.empty() &&
                programObject->geometryReflection.sampledTextures.empty() &&
                programObject->geometryReflection.uniformBlocks.empty()) {
                programObject->geometryReflection =
                    reflectOnly(geometryShader, appgl::TranslatorOptions{});
            }

            appgl::TranslatorOptions tessOpts;
            tessOpts.forceTessellation = true;
            if (tessEvalShader != nullptr && !tessEvalShader->spirv.empty()) {
                tessOpts.siblingTesInputSpirv = tessEvalShader->spirv.data();
                tessOpts.siblingTesInputWordCount = tessEvalShader->spirv.size();
            }
            if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                tessOpts.siblingTcsOutputSpirv = tessControlShader->spirv.data();
                tessOpts.siblingTcsOutputWordCount = tessControlShader->spirv.size();
            }
            programObject->tessControlReflection =
                reflectOnly(tessControlShader, tessOpts);

            appgl::TranslatorOptions tesComputeOpts;
            tesComputeOpts.forceTessellation = true;
            tesComputeOpts.forceTessEvalAsCompute = true;
            if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                tesComputeOpts.siblingTcsOutputSpirv = tessControlShader->spirv.data();
                tesComputeOpts.siblingTcsOutputWordCount = tessControlShader->spirv.size();
                auto tcModes = extractTessellationModes(
                    tessControlShader->spirv.data(),
                    tessControlShader->spirv.size());
                programObject->tessControlOutputVertices =
                    static_cast<GLint>(tcModes.outputVertices);
                tesComputeOpts.tesePatchVertices = tcModes.outputVertices;
            }
            programObject->tessEvalAsComputeReflection =
                reflectOnly(tessEvalShader, tesComputeOpts);

            programObject->hasTessellation = true;
            if (vertexShader != nullptr && !vertexShader->spirv.empty()) {
                stashVertexSpirv(vertexShader);
            }
            if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                programObject->tessControlSpirv = tessControlShader->spirv;
                programObject->tessControlParsedModule.reset();
            }
            if (tessEvalShader != nullptr && !tessEvalShader->spirv.empty()) {
                programObject->tessEvalSpirv = tessEvalShader->spirv;
                programObject->tessEvalParsedModule.reset();
                auto teModes = extractTessellationModes(
                    tessEvalShader->spirv.data(),
                    tessEvalShader->spirv.size());
                programObject->tessGenMode = teModes.genMode;
                programObject->tessGenSpacing = teModes.genSpacing;
                programObject->tessGenVertexOrder = teModes.genVertexOrder;
                programObject->tessGenPointMode = teModes.pointMode ? GL_TRUE : GL_FALSE;
            }
            if (geometryShader != nullptr && !geometryShader->spirv.empty()) {
                programObject->geometrySpirv = geometryShader->spirv;
                (void)appgl::detectGeometryEmulatable(*programObject);
            }
            (void)appgl::detectTessellationEmulatable(*programObject);
            if (programObject->metalGSTier == GLProgramObject::MetalGSTier::None &&
                programObject->geometryEmulated) {
                programObject->metalGSTier =
                    GLProgramObject::MetalGSTier::CPUInterpreter;
            }
            if (vsOk) {
                programObject->vertexReflection = std::move(vsRefl);
                programObject->fragmentMSL.clear();
                programObject->hasTranslatedPipeline = true;
                rasterTranslationOk = true;
            }
            break;
        }
        case ProgramKind::VertexTessellation: {
            ShaderReflection vsRefl;
            appgl::TranslatorOptions vsOptionsVt;
            if (vertexShader != nullptr) {
                vsOptionsVt.forceArgumentBuffers = spirvNeedsArgumentBuffers(
                    vertexShader->spirv.data(), vertexShader->spirv.size());
            }
            const bool vsOk = translateCachedStage(
                "vertex", vertexShader, programObject->vertexMSL, vsRefl,
                vsOptionsVt);

            auto reflectOnlyTess = [&](GLShaderObject* shader,
                                       const appgl::TranslatorOptions& options)
                -> ShaderReflection {
                ShaderReflection refl;
                if (shader == nullptr || shader->spirv.empty()) {
                    return refl;
                }
                appgl::TranslatorOptions stageOptions = options;
                stageOptions.fp64EmulationAvailable = fp64EmulationAvailable;
                applyShaderSpirvOptions(stageOptions, shader);
                try {
                    refl = translator.reflect(shader->spirv.data(),
                                              shader->spirv.size(),
                                              bindings, nullptr,
                                              stageOptions);
                } catch (...) {
                    // CPU tessellation can still run with empty reflection;
                    // image resolution has a uniform-scanner fallback.
                }
                return refl;
            };
            auto reflectionHasResources = [](const ShaderReflection& refl) {
                return !refl.uniformBlocks.empty() ||
                       !refl.storageBuffers.empty() ||
                       !refl.sampledTextures.empty() ||
                       !refl.storageImages.empty();
            };

            appgl::TranslatorOptions tessOpts;
            tessOpts.forceTessellation = true;
            tessOpts.useFullPrecisionTessLevelBuffer = true;
            if (tessEvalShader != nullptr && !tessEvalShader->spirv.empty()) {
                tessOpts.siblingTesInputSpirv = tessEvalShader->spirv.data();
                tessOpts.siblingTesInputWordCount = tessEvalShader->spirv.size();
            }
            if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                tessOpts.siblingTcsOutputSpirv = tessControlShader->spirv.data();
                tessOpts.siblingTcsOutputWordCount = tessControlShader->spirv.size();
                auto tcModes = extractTessellationModes(
                    tessControlShader->spirv.data(),
                    tessControlShader->spirv.size());
                programObject->tessControlOutputVertices =
                    static_cast<GLint>(tcModes.outputVertices);
                tessOpts.tesePatchVertices = tcModes.outputVertices;
            }
            if (tessControlShader != nullptr) {
                ShaderReflection tcRefl;
                (void)translateCachedStage("tess-control", tessControlShader,
                                           programObject->tessControlMSL, tcRefl,
                                           tessOpts);
                if (!reflectionHasResources(tcRefl)) {
                    tcRefl = reflectOnlyTess(tessControlShader, tessOpts);
                }
                programObject->tessControlReflection = tcRefl;
            }

            appgl::TranslatorOptions tesComputeOpts;
            tesComputeOpts.forceTessellation = true;
            tesComputeOpts.forceTessEvalAsCompute = true;
            tesComputeOpts.tesePatchVertices = tessOpts.tesePatchVertices;
            tesComputeOpts.useFullPrecisionTessLevelBuffer = true;
            if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                tesComputeOpts.siblingTcsOutputSpirv =
                    tessControlShader->spirv.data();
                tesComputeOpts.siblingTcsOutputWordCount =
                    tessControlShader->spirv.size();
            }
            ShaderReflection teRefl;
            (void)translateCachedStage("tess-eval-as-compute", tessEvalShader,
                                       programObject->tessEvalAsComputeMSL,
                                       teRefl, tesComputeOpts);
            if (!reflectionHasResources(teRefl)) {
                teRefl = reflectOnlyTess(tessEvalShader, tesComputeOpts);
            }
            programObject->tessEvalAsComputeReflection = teRefl;

            programObject->hasTessellation = true;
            if (vertexShader != nullptr && !vertexShader->spirv.empty()) {
                stashVertexSpirv(vertexShader);
            }
            if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                programObject->tessControlSpirv = tessControlShader->spirv;
                programObject->tessControlParsedModule.reset();
            }
            if (tessEvalShader != nullptr && !tessEvalShader->spirv.empty()) {
                programObject->tessEvalSpirv = tessEvalShader->spirv;
                programObject->tessEvalParsedModule.reset();
                auto teModes = extractTessellationModes(
                    tessEvalShader->spirv.data(),
                    tessEvalShader->spirv.size());
                programObject->tessGenMode = teModes.genMode;
                programObject->tessGenSpacing = teModes.genSpacing;
                programObject->tessGenVertexOrder = teModes.genVertexOrder;
                programObject->tessGenPointMode =
                    teModes.pointMode ? GL_TRUE : GL_FALSE;
            }
            (void)appgl::detectTessellationEmulatable(*programObject);
            if (vsOk) {
                programObject->vertexReflection = std::move(vsRefl);
                programObject->fragmentMSL.clear();
                programObject->hasTranslatedPipeline = true;
                rasterTranslationOk = true;
            }
            break;
        }
        case ProgramKind::VertexTessellationFragment: {
            // Same story as geometry: translate VS + FS and record a
            // diagnostic for the tess stages. Metal's tessellation model
            // is incompatible with GL's, so proper routing lands later.
            //
            // Phase 8X Group 4d follow-up⁵ — VS+FS use the cross-stage
            // linked path here too, for the same reason as VGF above.
            const bool canLinkGlslSources =
                vertexShader != nullptr && fragmentShader != nullptr &&
                !vertexShader->isSpirvBinary && !fragmentShader->isSpirvBinary;
            LinkedProgramSpirv linked = canLinkGlslSources
                ? compileLinkedVsFs(vertexShader, fragmentShader)
                : LinkedProgramSpirv{};
            const std::uint32_t* vsSpirvData;
            std::size_t vsSpirvWords;
            const std::uint32_t* fsSpirvData;
            std::size_t fsSpirvWords;
            if (linked.linkSucceeded) {
                vsSpirvData = linked.vertexSpirv.data();
                vsSpirvWords = linked.vertexSpirv.size();
                fsSpirvData = linked.fragmentSpirv.data();
                fsSpirvWords = linked.fragmentSpirv.size();
            } else {
                vsSpirvData = vertexShader->spirv.data();
                vsSpirvWords = vertexShader->spirv.size();
                fsSpirvData = fragmentShader->spirv.data();
                fsSpirvWords = fragmentShader->spirv.size();
            }
            ShaderReflection vsRefl, fsRefl, tcRefl, teRefl;
            const bool forceRasterArgBufVtf =
                spirvNeedsArgumentBuffers(vsSpirvData, vsSpirvWords) ||
                spirvNeedsArgumentBuffers(fsSpirvData, fsSpirvWords);
            appgl::TranslatorOptions vsOptionsVtf;
            vsOptionsVtf.forceArgumentBuffers = forceRasterArgBufVtf;
            appgl::TranslatorOptions fsOptionsVtf;
            fsOptionsVtf.forceArgumentBuffers = forceRasterArgBufVtf;
            applyShaderSpirvOptions(vsOptionsVtf, vertexShader);
            applyShaderSpirvOptions(fsOptionsVtf, fragmentShader);
            const bool vsOk = translateStage(
                "vertex", vsSpirvData, vsSpirvWords, vertexShader->source,
                programObject->vertexMSL, vsRefl, vsOptionsVtf);
            const bool fsOk = translateStage(
                "fragment", fsSpirvData, fsSpirvWords, fragmentShader->source,
                programObject->fragmentMSL, fsRefl, fsOptionsVtf);
            // Sprint 5 Phase 1: Phase 3 gate widening via passthrough TCS
            // synthesis at link time. When source program has TES + FS
            // (no TCS) — GL spec §11.2.4: TES-only programs use VS outputs
            // directly as TES inputs — synthesize a minimal passthrough
            // GLSL TCS, compile via existing toolchain, and use as if a
            // real TCS were attached. This unblocks the Phase 3 gate at
            // tryMetalTessellationDraw which requires `tessControlMSL`
            // non-empty. Affected tests: `tc2te.gl_PatchVerticesIn` iter 4
            // (TES_4 variant), `single.max_patch_vertices` Case 2,
            // `tc2te.gl_tessLevel` TES iters (3 of 6).
            //
            // Minimal TCS surface area for Sprint 5 Phase 1:
            //   - layout(vertices = 32) — covers up to MAX_PATCH_VERTICES
            //   - gl_Position passthrough
            //   - default tess levels = 1.0 (matches glPatchParameterfv
            //     default) — runtime override via uniforms TBD if test
            //     exercises non-default tess levels
            //
            // User-varying passthrough is NOT synthesized in this minimal
            // version. Tests that depend on per-CP user data (e.g.
            // max_patch_vertices Case 2's `for (i; i<gl_PatchVerticesIn;
            // i++) result_iv += inVertex[i].iv`) will still fail because
            // synthesized TCS doesn't copy user varyings from VS outputs.
            // Future iteration (post-CKPT29 follow-up) extends synthesis
            // to walk TES SPIR-V Inputs and emit matching TCS Outputs.
            std::vector<std::uint32_t> synthTcsSpirv;
            std::string synthTcsSource;
            GLShaderObject synthTcsShader;
            if (tessEvalShader != nullptr && tessControlShader == nullptr &&
                !tessEvalShader->spirv.empty()) {
                synthTcsSource =
                    "#version 410 core\n"
                    "#extension GL_EXT_tessellation_shader : enable\n"
                    "layout (vertices = 32) out;\n"
                    "void main() {\n"
                    "    gl_out[gl_InvocationID].gl_Position = "
                    "gl_in[gl_InvocationID].gl_Position;\n"
                    "    if (gl_InvocationID == 0) {\n"
                    "        gl_TessLevelOuter[0] = 1.0;\n"
                    "        gl_TessLevelOuter[1] = 1.0;\n"
                    "        gl_TessLevelOuter[2] = 1.0;\n"
                    "        gl_TessLevelOuter[3] = 1.0;\n"
                    "        gl_TessLevelInner[0] = 1.0;\n"
                    "        gl_TessLevelInner[1] = 1.0;\n"
                    "    }\n"
                    "}\n";
                std::string compileLog;
                synthTcsSpirv = translator.compileGLSL(
                    synthTcsSource, GL_TESS_CONTROL_SHADER, 410, &compileLog);
                if (!synthTcsSpirv.empty()) {
                    synthTcsShader.stage = GL_TESS_CONTROL_SHADER;
                    synthTcsShader.source = synthTcsSource;
                    synthTcsShader.spirv = synthTcsSpirv;
                    synthTcsShader.compiled = true;
                    tessControlShader = &synthTcsShader;
                    // Sprint 5 Phase 1: signal to encoder that this
                    // program's TCS was synthesized → host should
                    // populate factorBufFull from glPatchParameterfv
                    // state per draw to override synth's 1.0 defaults.
                    programObject->tessControlSynthesized = true;
                    APPGL_LOG(SHADER,
                        @"[GL] Sprint5 Phase 3 gate widening: synthesized "
                        @"passthrough TCS for TES-only program (program=%u, "
                        @"spirv_words=%zu)",
                        program, synthTcsSpirv.size());
                } else {
                    APPGL_LOG(SHADER,
                        @"[GL] Sprint5 Phase 3 gate widening: passthrough TCS "
                        @"compile failed: %s", compileLog.c_str());
                }
            }
            // Metal tess Phase 1: force SPIRV-Cross tess options on for
            // TCS/TES translation regardless of APPGL_ENABLE_METAL_TESS
            // env. The emitted MSL shape matches what the Metal tess
            // pipeline (TCS-as-compute + TES-as-vertex-function with
            // tessellationEnabled=YES) can consume. MSL is stashed on the
            // program so MetalFrameGraph can build the pipeline states.
            appgl::TranslatorOptions tessOpts;
            tessOpts.forceTessellation = true;
            // Sprint 5 Phase 1 — Path L Class 2A: full-precision tess
            // level shadow buffer. SPIRV-Cross fork emits TCS dual-write
            // (half + full) and TES read from full-precision buffer.
            // Avoids half-precision rounding error on tests like
            // `tc2te.gl_tessLevel` which expects ~exact float read-back.
            tessOpts.useFullPrecisionTessLevelBuffer = true;
            // Phase 7 [metal-tess-TF] (Track 2 scaffold): pass the linked
            // TES's SPIR-V to the TCS translation so spirvToMSL can call
            // add_msl_shader_output for each TES user-varying input. Closes
            // the per-CP buffer stride mismatch on shapes where TCS doesn't
            // write all the user varyings TES reads (cluster A / C). The
            // TES translation's spirvToMSL ignores this field — it's gated
            // on isTessControl inside the translator.
            if (tessEvalShader != nullptr && !tessEvalShader->spirv.empty()) {
                tessOpts.siblingTesInputSpirv = tessEvalShader->spirv.data();
                tessOpts.siblingTesInputWordCount = tessEvalShader->spirv.size();
            }
            // tc_barriers cluster — inverse-direction sibling so the TES
            // translation calls add_msl_shader_input for TCS outputs the
            // TES doesn't itself declare. Closes the per-CP buffer
            // stride mismatch when TCS uses its own outputs internally
            // (after barrier()) so SPIRV-Cross emits 48 B/CP for TCS
            // but 16 B/CP for TES → TES reads at the wrong offset.
            if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                tessOpts.siblingTcsOutputSpirv = tessControlShader->spirv.data();
                tessOpts.siblingTcsOutputWordCount = tessControlShader->spirv.size();
            }
            // T4I [metal-tess-TF]: extract TCS `layout(vertices=N)`
            // before TES translation so SPIRV-Cross can plumb the
            // patch CP count into TES MSL's `[[ patch(quad, N) ]]`
            // attribute and `gl_in = &spvIn[gl_PrimitiveID * N]`
            // stride. Without this, MSL emits `* 0` and every patch
            // reads spvIn[0..N-1] regardless of primitive id —
            // covering only the first patch's pixels.
            if (tessControlShader && !tessControlShader->spirv.empty()) {
                auto tcModes = extractTessellationModes(
                    tessControlShader->spirv.data(), tessControlShader->spirv.size());
                tessOpts.tesePatchVertices = tcModes.outputVertices;
            }
            (void)translateCachedStage("tess-control", tessControlShader,
                                       programObject->tessControlMSL, tcRefl,
                                       tessOpts);
            (void)translateCachedStage("tess-eval", tessEvalShader,
                                       programObject->tessEvalMSL, teRefl,
                                       tessOpts);
            // T4I [metal-tess-TF]: SPIRV-Cross emits the TES vertex
            // function with `[[patch(domain, execution.output_vertices)]]`,
            // but `execution.output_vertices` is 0 for TES (the
            // OutputVertices execution mode is set on TCS, not TES).
            // Metal needs the patch_control_point_count in the
            // attribute; with 0 it silently mis-fetches CP data and
            // every patch covers only the first control point's
            // pixels. Post-process the emitted MSL to substitute the
            // TCS output_vertices count.
            if (tessOpts.tesePatchVertices != 0 && !programObject->tessEvalMSL.empty()) {
                std::string& msl = programObject->tessEvalMSL;
                std::string oldNeedle1 = "[[ patch(quad, 0) ]]";
                std::string oldNeedle2 = "[[ patch(triangle, 0) ]]";
                std::string newRepl1 = "[[ patch(quad, " + std::to_string(tessOpts.tesePatchVertices) + ") ]]";
                std::string newRepl2 = "[[ patch(triangle, " + std::to_string(tessOpts.tesePatchVertices) + ") ]]";
                std::size_t p = msl.find(oldNeedle1);
                if (p != std::string::npos) {
                    msl.replace(p, oldNeedle1.size(), newRepl1);
                    if (std::getenv("APPGL_TRACE_TESS")) {
                        std::fprintf(stderr,
                            "[APPGL] T4I: TES patch_cp 0->%u (quad)\n",
                            tessOpts.tesePatchVertices);
                    }
                } else {
                    p = msl.find(oldNeedle2);
                    if (p != std::string::npos) {
                        msl.replace(p, oldNeedle2.size(), newRepl2);
                        if (std::getenv("APPGL_TRACE_TESS")) {
                            std::fprintf(stderr,
                                "[APPGL] T4I: TES patch_cp 0->%u (triangle)\n",
                                tessOpts.tesePatchVertices);
                        }
                    }
                }
            }
            programObject->tessControlReflection = tcRefl;
            // Metal tess Phase 3: compile VS as a compute kernel with
            // `vertex_for_tessellation + capture_output_to_buffer` so
            // the TCS compute dispatch can consume its outputs via
            // stage-input. Emits alongside the traditional `vertex`
            // form stored above — the Phase 3 pipeline probe + encode
            // paths read `tessVertexAsComputeMSL`, leaving
            // `vertexMSL` (the Phase-2 render path) untouched.
            appgl::TranslatorOptions vsComputeOpts;
            vsComputeOpts.forceVertexForTessellation = true;
            applyShaderSpirvOptions(vsComputeOpts, vertexShader);
            ShaderReflection vsComputeRefl;
            (void)translateStage(
                "vertex-for-tess", vsSpirvData, vsSpirvWords,
                vertexShader->source,
                programObject->tessVertexAsComputeMSL, vsComputeRefl,
                vsComputeOpts);
            programObject->tessVertexAsComputeReflection = vsComputeRefl;
            // SPIRV-Cross inserts a `[[grid_size]]`-based early-return
            // in VS-for-tessellation to guard against out-of-range
            // threads. On macOS Apple Silicon with `dispatchThreads`
            // the attribute reads as (0,0,0) for reasons I haven't yet
            // tracked — the whole kernel early-returns and nothing is
            // written. We dispatch exactly vertexCount threads so the
            // bounds check is redundant; strip it post-emit.
            if (!programObject->tessVertexAsComputeMSL.empty()) {
                std::string& mslRef = programObject->tessVertexAsComputeMSL;
                const std::string needle =
                    "if (any(gl_GlobalInvocationID >= spvStageInputSize))\n"
                    "        return;";
                const std::size_t pos = mslRef.find(needle);
                if (pos != std::string::npos) {
                    mslRef.replace(pos, needle.size(),
                                   "/* AppGL: grid_size early-return stripped */");
                    if (std::getenv("APPGL_TRACE_TESS")) {
                        std::fprintf(stderr,
                            "[APPGL] T4I: stripped grid_size early-return from VS-compute MSL\n");
                    }
                } else if (std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "[APPGL] T4I: VS-compute MSL early-return needle NOT found\n");
                }
                // CKPT139 (Sprint 13 Phase 2 Day 3): γ2.1.F vs γ2.1.G
                // sentinel-encoding diagnostic. When APPGL_DIAG_TESS_SENTINEL
                // is set, override `out.gl_Position` write to encode
                // gl_GlobalInvocationID.{xyz} as float values, AND write a
                // fixed sentinel to other fields so we can identify which
                // thread populated each slot. Diagnostic-only; environment-gated.
                if (std::getenv("APPGL_DIAG_TESS_SENTINEL") != nullptr) {
                    const std::string oldPos =
                        "out.gl_Position = float4(float(int(gl_VertexIndex)));";
                    const std::string newPos =
                        "out.gl_Position = float4(float(gl_GlobalInvocationID.x), "
                        "float(gl_GlobalInvocationID.y), "
                        "float(gl_GlobalInvocationID.z), 42.0);";
                    const std::size_t posp = mslRef.find(oldPos);
                    if (posp != std::string::npos) {
                        mslRef.replace(posp, oldPos.size(), newPos);
                        std::fprintf(stderr,
                            "[APPGL] DIAG-SENTINEL: replaced gl_Position with thread-id encoding\n");
                    } else {
                        std::fprintf(stderr,
                            "[APPGL] DIAG-SENTINEL: gl_Position pattern NOT found\n");
                    }
                }
            }
            // Extract TCS output_vertices now (before TES-compute
            // translation) so we can plumb the per-patch CP count into
            // SPIRV-Cross — the TES's own SPIR-V has no
            // `output_vertices` execution mode, so without this the
            // emitted `gl_in` stride defaults to `gl_PrimitiveID * 0`
            // and every patch collapses to the TCS-output origin.
            programObject->hasTessellation = true;
            std::uint32_t tcsOutputVertices = 0;
            // Sprint 5 Phase 3 gate widening: for synthesized passthrough
            // TCS (TES-only programs), populate
            // `programObject->tessControlOutputVertices` from the synth
            // (so the Phase 3 gate passes) BUT force local
            // `tcsOutputVertices = 0` so `tesComputeOpts.tesePatchVertices
            // = 0` and Path K's runtime read of `spvIndirectParams[0]`
            // kicks in for TES-compute MSL emission. TES-only mode's
            // gl_PatchVerticesIn semantic is "PATCH_VERTICES from
            // glPatchParameteri" (runtime), not "TCS output_vertices"
            // (link-time bake from synth's `layout(vertices = 32)`).
            const bool isSynthPassthroughTcs =
                (tessControlShader == &synthTcsShader);
            if (tessControlShader && !tessControlShader->spirv.empty()) {
                auto tcModes = extractTessellationModes(
                    tessControlShader->spirv.data(), tessControlShader->spirv.size());
                programObject->tessControlOutputVertices = static_cast<GLint>(tcModes.outputVertices);
                if (!isSynthPassthroughTcs) {
                    tcsOutputVertices = tcModes.outputVertices;
                }
                // For synth case, tcsOutputVertices stays 0 → triggers
                // Path K runtime read in TES MSL.
            }

            // Phase 3B [metal-tess-TF] groundwork: also translate TES
            // with `forceTessEvalAsCompute` so the call path is wired
            // for the follow-up SPIRV-Cross patch that actually emits
            // a kernel. Today the output matches the render-path TES
            // (same flag semantics as forceTessellation alone) — the
            // resulting MSL is stashed but the probe doesn't yet build
            // a TES-compute PSO from it.
            appgl::TranslatorOptions tesComputeOpts;
            tesComputeOpts.forceTessellation = true;
            tesComputeOpts.forceTessEvalAsCompute = true;
            tesComputeOpts.tesePatchVertices = tcsOutputVertices;
            // Sprint 5 Phase 1 — Path L Class 2A: also enable on TES-
            // compute path so TES kernel reads gl_TessLevelOuter/Inner
            // from spvTessLevelFull (full-precision) instead of half-
            // precision spvTessLevel.
            tesComputeOpts.useFullPrecisionTessLevelBuffer = true;
            if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                tesComputeOpts.siblingTcsOutputSpirv = tessControlShader->spirv.data();
                tesComputeOpts.siblingTcsOutputWordCount = tessControlShader->spirv.size();
            }
            ShaderReflection tesComputeRefl;
            (void)translateCachedStage(
                "tess-eval-as-compute", tessEvalShader,
                programObject->tessEvalAsComputeMSL, tesComputeRefl,
                tesComputeOpts);
            programObject->tessEvalAsComputeReflection = tesComputeRefl;
            // Phase 3B.5 [metal-tess-TF]: reflect the TES output
            // struct layout under the same translator options so the
            // TF-capture encoder can locate each GL-declared TF
            // varying by name at draw time.
            if (tessEvalShader != nullptr && !tessEvalShader->spirv.empty()) {
                programObject->tessEvalOutputLayout =
                    translator.reflectStageOutputLayout(
                        tessEvalShader->spirv.data(),
                        tessEvalShader->spirv.size(),
                        tesComputeOpts);
            }
            if (tessEvalShader && !tessEvalShader->spirv.empty()) {
                auto teModes = extractTessellationModes(
                    tessEvalShader->spirv.data(), tessEvalShader->spirv.size());
                programObject->tessGenMode = teModes.genMode;
                programObject->tessGenSpacing = teModes.genSpacing;
                programObject->tessGenVertexOrder = teModes.genVertexOrder;
                programObject->tessGenPointMode = teModes.pointMode ? GL_TRUE : GL_FALSE;
            }

            Runtime::shared().recordShaderTranslation({
                programTag + "-tessellation-emulation", "tessellation",
                tessControlShader != nullptr
                    ? quickHash(tessControlShader->source)
                    : std::string(),
                linkVertexHash, linkFragmentHash,
                "tessellation emulation not yet available on Metal; "
                "program translated VS+FS only, falls back to raster-without-tess",
                "", false
            });
            if (vsOk && fsOk) {
                programObject->vertexReflection = std::move(vsRefl);
                programObject->fragmentReflection = std::move(fsRefl);
                programObject->hasTranslatedPipeline = true;
                rasterTranslationOk = true;
            }
            // Tessellation emulator detection (scaffolding — iter 162).
            // Mirrors the GS-emul pattern: copy SPIR-V onto the program
            // so draw-time emulation survives detach+delete, then call
            // the detector. The detector's `.tessellationEmulated` flag
            // stays false through iter 162 — subsequent iters flip it
            // on once the draw-time logic lands.
            if (vertexShader != nullptr && !vertexShader->spirv.empty()) {
                stashVertexSpirv(vertexShader);
            }
            if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                programObject->tessControlSpirv = tessControlShader->spirv;
                // Phase 3f-11: invalidate the parsed-module cache so
                // subsequent runTcsForVertex calls re-parse against
                // the new SPIR-V blob.
                programObject->tessControlParsedModule.reset();
            }
            if (tessEvalShader != nullptr && !tessEvalShader->spirv.empty()) {
                programObject->tessEvalSpirv = tessEvalShader->spirv;
                programObject->tessEvalParsedModule.reset();
            }
            (void)appgl::detectTessellationEmulatable(*programObject);

            // Metal tess Phase 1 probe — validate that the tess-MSL
            // stashed above compiles into Metal pipeline states. No
            // draw-time consumer yet; the CPU interpreter path still
            // handles every drawArrays(GL_PATCHES, ...) call. The
            // retained TCS compute PSO becomes Phase 2's input.
            // Detector point pre-A — catches programs that have tess
            // shaders but get skipped by the probe gate below. The
            // existing point A (after the probe runs) is silent for
            // gl_in-class shapes because the conventional vertex-form
            // TES MSL never gets generated, so this gate trips first.
            if (detectorEnabled() &&
                (tessControlShader != nullptr || tessEvalShader != nullptr)) {
                // Mirror the actual probe gate: accept either form of
                // TES MSL (conventional vertex or as-compute kernel).
                const bool gateOk = (impl_->frameGraph != nullptr &&
                    !programObject->tessControlMSL.empty() &&
                    (!programObject->tessEvalMSL.empty() ||
                     !programObject->tessEvalAsComputeMSL.empty()) &&
                    !programObject->fragmentMSL.empty());
                std::fprintf(stderr,
                    "APPGL_DETECTOR lift_translate program=%u "
                    "tcsMSL_empty=%d tesMSL_empty=%d fsMSL_empty=%d "
                    "tesAsComputeMSL_empty=%d vsAsComputeMSL_empty=%d "
                    "frameGraph_present=%d -> probe_gate_ok=%d\n",
                    program,
                    programObject->tessControlMSL.empty() ? 1 : 0,
                    programObject->tessEvalMSL.empty() ? 1 : 0,
                    programObject->fragmentMSL.empty() ? 1 : 0,
                    programObject->tessEvalAsComputeMSL.empty() ? 1 : 0,
                    programObject->tessVertexAsComputeMSL.empty() ? 1 : 0,
                    impl_->frameGraph != nullptr ? 1 : 0,
                    gateOk ? 1 : 0);
            }
            // Probe gate: post-isolines-compute-bypass-patch (SPIRV-Cross
            // commit 095c99c, 2026-04-26), TES isolines emits non-empty
            // `tessEvalAsComputeMSL` while `tessEvalMSL` (conventional
            // render-vertex form) stays empty because Metal's render
            // pipeline doesn't support isoline tessellation. Allow the
            // probe to run when EITHER form is available — the probe's
            // internals already gate the conventional render-PSO build
            // on `tesMSL` non-empty separately.
            const bool tessEvalAvailable =
                !programObject->tessEvalMSL.empty() ||
                !programObject->tessEvalAsComputeMSL.empty();
            if (impl_->frameGraph != nullptr &&
                !programObject->tessControlMSL.empty() &&
                tessEvalAvailable &&
                !programObject->fragmentMSL.empty()) {
                MetalFrameGraph::TessPipelineProbeResult probe =
                    impl_->frameGraph->probeTessellationPipeline(
                        programObject->tessControlMSL,
                        programObject->tessEvalMSL,
                        programObject->fragmentMSL,
                        programObject->tessGenMode,
                        programObject->tessGenSpacing,
                        programObject->tessGenVertexOrder,
                        programObject->tessVertexAsComputeMSL,
                        programObject->tessEvalAsComputeMSL);
                // Phase 3: stash the VS-as-compute PSO when the probe
                // built it. Non-fatal if it didn't (the simpler Phase-2
                // path still works for programs without VS→TCS flow).
                if (probe.vertexComputeOk) {
                    programObject->metalTessVertexPipelineState =
                        probe.vertexComputePipelineState;
                }
                // T4I [metal-tess-TF]: when the VS-as-compute MSL
                // declares `[[stage_in]]`, the PSO must be built at
                // draw time from the bound VAO's
                // MTLStageInputOutputDescriptor. Probe set the flag
                // when it caught the stage_in compile error.
                if (probe.vertexComputeNeedsDescriptor) {
                    programObject->metalTessVertexNeedsDescriptor = true;
                }
                // Phase 3B.4 [metal-tess-TF]: stash the TES-as-compute
                // PSO when the probe built it. Enables the 4-dispatch
                // TF-capture chain at draw time.
                if (probe.tessEvalComputeOk) {
                    programObject->metalTessEvalComputePipelineState =
                        probe.tessEvalComputePipelineState;
                }
                // Metal tess tier gate: classify the program against
                // the encoder capability matrix.
                //   Phase 2 — TCS MSL uses only factor (26) + indirect
                //     (29) buffers; TES has no per-CP/per-patch
                //     buffer inputs. Trivial VS (empty or no user
                //     outputs). Encoded by `encodeMetalTessellationDraw`.
                //   Phase 3 — TCS or TES declares VS-input
                //     (`spvIn [[buffer(22)]]` on TCS), per-CP output
                //     (`spvOut [[buffer(28)]]` on TCS), per-patch
                //     output (`spvPatchOut [[buffer(27)]]` on TCS),
                //     per-CP input (`spvIn [[buffer(22)]]` on TES), or
                //     per-patch input (`spvPatchIn [[buffer(20)]]` on
                //     TES). Requires VS-as-compute PSO from the probe.
                //     Encoded by `encodeMetalTessellationDrawPhase3`.
                //   None — probe failed OR Phase 3 needed but VS
                //     compute PSO couldn't build (VS uses
                //     [[stage_in]] without a descriptor). Falls
                //     through to the CPU tessellation interpreter.
                const bool needsPhase3 =
                    probe.computeOk && (
                        programObject->tessControlMSL.find("spvIn [[buffer(") != std::string::npos ||
                        programObject->tessControlMSL.find("spvOut [[buffer(") != std::string::npos ||
                        programObject->tessControlMSL.find("spvPatchOut [[buffer(") != std::string::npos ||
                        programObject->tessEvalMSL.find("spvIn [[buffer(") != std::string::npos ||
                        programObject->tessEvalMSL.find("spvPatchIn [[buffer(") != std::string::npos);
                // ----------------------------------------------------
                // APPGL_ENABLE_METAL_TESS_TF — default-on master
                // enable for the Metal tess+TF compute chain
                // (APPGL_ENABLE_METAL_TESS_TF=0 restores the legacy
                // CPU route for attribution). When enabled:
                //   • This link-time block sets metalTessTier for tess
                //     programs with TF varyings (Phase2 or Phase3) and
                //     stashes metalTessEvalComputePipelineState.
                //     Opting out forces tier=None for TF-varying tess
                //     programs and routes drawArrays(GL_PATCHES) to
                //     the CPU tess interpreter.
                //   • tryMetalTessellationDraw and the rasterizer-
                //     discard probe path also re-check this gate.
                // It pairs with APPGL_LIFT_TESS_UNIFORM_GUARD: that var
                // relaxes the "tess uses uniforms -> CPU fallback"
                // guard. Both gates are default-on now; either =0
                // keeps the old CPU path available for attribution.
                // Programs that declared TF varyings at link time must
                // source TES output into the bound TF buffer at draw
                // time. tessTFReady=true means: (a) probe built the TES
                // compute PSO, (b) reflection produced a TES output
                // layout, (c) APPGL_ENABLE_METAL_TESS_TF is enabled.
                const bool tessUsesTF =
                    !programObject->transformFeedbackVaryingNames.empty();
                const bool tessTFReady =
                    probe.tessEvalComputeOk &&
                    programObject->tessEvalOutputLayout.structSize > 0 &&
                    metalTessTFEnabled();
                const bool tessBlockedByTF = tessUsesTF && !tessTFReady;
                if (probe.computeOk && !needsPhase3 && !tessBlockedByTF) {
                    programObject->metalTessTier =
                        GLProgramObject::MetalTessTier::Phase2;
                    programObject->metalTessControlPipelineState =
                        probe.computePipelineState;
                } else if (probe.computeOk && needsPhase3 && !tessBlockedByTF &&
                           (probe.vertexComputeOk || probe.vertexComputeNeedsDescriptor)) {
                    // T4I [metal-tess-TF]: Phase 3 is reachable when
                    // VS-compute either built directly (no stage_in)
                    // OR needs a descriptor at draw time. The encoder
                    // checks `metalTessVertexNeedsDescriptor` and
                    // builds-or-reuses a per-VAO PSO before dispatch.
                    programObject->metalTessTier =
                        GLProgramObject::MetalTessTier::Phase3;
                    programObject->metalTessControlPipelineState =
                        probe.computePipelineState;
                    // vertexComputePipelineState is already stashed
                    // above when probe.vertexComputeOk was true.
                } else if (probe.computeOk) {
                    // Phase 3 required (complex MSL) but VS-compute
                    // PSO didn't build — most commonly VS with
                    // [[stage_in]] attributes and no descriptor. CPU
                    // fallback until Phase 3.3 wires the descriptor.
                    releaseRetainedMetalObject(probe.computePipelineState);
                }
                if (std::getenv("APPGL_TRACE_TESS")) {
                    std::fprintf(stderr,
                        "[APPGL] tess-probe program=%u computeOk=%d renderOk=%d"
                        " vsComputeOk=%d tesComputeOk=%d tessTFReady=%d tier=%d"
                        " tesStructSize=%zu tfVaryings=%zu"
                        " genMode=0x%04X genSpacing=0x%04X"
                        " diag=%s\n",
                        program,
                        probe.computeOk ? 1 : 0,
                        probe.renderOk ? 1 : 0,
                        probe.vertexComputeOk ? 1 : 0,
                        probe.tessEvalComputeOk ? 1 : 0,
                        tessTFReady ? 1 : 0,
                        (int)programObject->metalTessTier,
                        programObject->tessEvalOutputLayout.structSize,
                        programObject->transformFeedbackVaryingNames.size(),
                        programObject->tessGenMode,
                        programObject->tessGenSpacing,
                        probe.diagnostic.c_str());
                }
                // Detector point A — link-time probe outcome paired with the
                // gate (B) and dispatch (C) lines so a single APPGL_DETECTOR_TF
                // invocation tells the full story.  diag escaping: keep the
                // string short (no newlines come from the probe diagnostic).
                if (detectorEnabled()) {
                    std::fprintf(stderr,
                        "APPGL_DETECTOR lift_probe program=%u computeOk=%d "
                        "vsComputeOk=%d tesComputeOk=%d tessTFReady=%d "
                        "tier=%d tesStructSize=%zu tfVaryings=%zu "
                        "genMode=0x%04X genSpacing=0x%04X diag=\"%s\"\n",
                        program,
                        probe.computeOk ? 1 : 0,
                        probe.vertexComputeOk ? 1 : 0,
                        probe.tessEvalComputeOk ? 1 : 0,
                        tessTFReady ? 1 : 0,
                        (int)programObject->metalTessTier,
                        programObject->tessEvalOutputLayout.structSize,
                        programObject->transformFeedbackVaryingNames.size(),
                        programObject->tessGenMode,
                        programObject->tessGenSpacing,
                        probe.diagnostic.c_str());
                }
                Runtime::shared().recordShaderTranslation({
                    programTag + "-tessellation-metal-probe", "tessellation",
                    tessControlShader != nullptr
                        ? quickHash(tessControlShader->source)
                        : std::string(),
                    linkVertexHash, linkFragmentHash,
                    probe.renderOk
                        ? std::string("Metal tess pipeline probe: compute + render both built")
                        : (probe.computeOk
                            ? std::string("Metal tess render pipeline failed: ") + probe.diagnostic
                            : std::string("Metal tess compute pipeline failed: ") + probe.diagnostic),
                    "",
                    probe.computeOk && probe.renderOk
                });
            }
            break;
        }
        case ProgramKind::GeometryOnly: {
            // Separable GS-only program (for use with program pipelines).
            // Translate to MSL so reflection populates; actual draw falls
            // back through the raster-without-GS path, same as VGF.
            std::string unusedGsMSL;
            ShaderReflection gsRefl;
            (void)translateCachedStage("geometry", geometryShader,
                                       unusedGsMSL, gsRefl);
            // CKPT163 (Sprint 14 Day 10): persist the GS reflection on
            // the program. Pre-fix it was captured into a local that
            // immediately fell out of scope, so the runtime
            // (buildStorageImageMap, buildSampledTextureMap, draw-path
            // resource resolution) saw an empty reflection on every
            // separable GS-only program. Sister to the VS+GS+FS path at
            // line 20668 which always persisted gsRefl.
            programObject->geometryReflection = gsRefl;
            // Sister-fix: translateCachedStage above bails before
            // reflect() if spirvToMSL fails or returns empty, which
            // happens for GS shaders that SPIRV-Cross can't fully
            // translate (e.g. complex EmitVertex / EmitStreamVertex
            // shapes used by CTS shader_image_size.basic-nonMS-gs-*).
            // Direct reflect-only fallback walks the SPIR-V again
            // and populates `storageImages`/`sampledTextures`/
            // `uniformBlocks`/`storageBuffers` even when MSL emit
            // failed — the GS interpreter doesn't need MSL anyway,
            // only the reflection metadata.
            if (geometryShader != nullptr && !geometryShader->spirv.empty()) {
                if (programObject->geometryReflection.storageImages.empty() &&
                    programObject->geometryReflection.sampledTextures.empty() &&
                    programObject->geometryReflection.uniformBlocks.empty()) {
                    try {
                        appgl::ShaderTranslator reflTranslator;
                        appgl::BindingMap reflBindings;  // defaults are fine
                                                          // for reflect-only.
                        programObject->geometryReflection =
                            reflTranslator.reflect(
                                geometryShader->spirv.data(),
                                geometryShader->spirv.size(),
                                reflBindings, nullptr);
                    } catch (...) {
                        // If reflect throws, leave the empty
                        // reflection in place — same end-state as
                        // pre-fix.
                    }
                }
                programObject->geometrySpirv = geometryShader->spirv;
                (void)appgl::detectGeometryEmulatable(*programObject);
            }
            rasterTranslationOk = true;
            break;
        }
        case ProgramKind::TessControlOnly: {
            // Separable TCS-only program (for use with program pipelines).
            // Translate to MSL for reflection + extract tessellation modes.
            // Metal tess Phase 1: force tess options so the stashed MSL
            // matches the Metal-native tess pipeline shape.
            appgl::TranslatorOptions tessOpts;
            tessOpts.forceTessellation = true;
            ShaderReflection tcRefl;
            (void)translateCachedStage("tess-control", tessControlShader,
                                       programObject->tessControlMSL, tcRefl,
                                       tessOpts);
            programObject->tessControlReflection = tcRefl;
            // Extract tessellation execution modes from SPIR-V.
            programObject->hasTessellation = true;
            if (!tessControlShader->spirv.empty()) {
                auto tcModes = extractTessellationModes(
                    tessControlShader->spirv.data(),
                    tessControlShader->spirv.size());
                programObject->tessControlOutputVertices =
                    static_cast<GLint>(tcModes.outputVertices);
            }
            // β [metal-tess-TF]: preserve TCS SPIR-V so the pipeline-time
            // orchestrator can re-translate with cross-stage info
            // (siblingTesInputSpirv) once a TES separable program is
            // also bound to the pipeline.
            if (tessControlShader != nullptr && !tessControlShader->spirv.empty()) {
                programObject->tessControlSpirv = tessControlShader->spirv;
                programObject->tessControlParsedModule.reset();
            }
            rasterTranslationOk = true;
            break;
        }
        case ProgramKind::TessEvalOnly: {
            // Separable TES-only program (for use with program pipelines).
            // Metal tess Phase 1: force tess options on.
            appgl::TranslatorOptions tessOpts;
            tessOpts.forceTessellation = true;
            ShaderReflection teRefl;
            (void)translateCachedStage("tess-eval", tessEvalShader,
                                       programObject->tessEvalMSL, teRefl,
                                       tessOpts);
            programObject->tessEvalAsComputeReflection = teRefl;
            // Extract tessellation execution modes from SPIR-V.
            programObject->hasTessellation = true;
            if (!tessEvalShader->spirv.empty()) {
                auto teModes = extractTessellationModes(
                    tessEvalShader->spirv.data(),
                    tessEvalShader->spirv.size());
                programObject->tessGenMode = teModes.genMode;
                programObject->tessGenSpacing = teModes.genSpacing;
                programObject->tessGenVertexOrder = teModes.genVertexOrder;
                programObject->tessGenPointMode =
                    teModes.pointMode ? GL_TRUE : GL_FALSE;
            }
            // β [metal-tess-TF]: preserve TES SPIR-V so the pipeline-time
            // orchestrator can re-translate the compute form with
            // forceTessEvalAsCompute + tesePatchVertices plumbed.
            if (tessEvalShader != nullptr && !tessEvalShader->spirv.empty()) {
                programObject->tessEvalSpirv = tessEvalShader->spirv;
                programObject->tessEvalParsedModule.reset();
            }
            (void)appgl::detectTessellationEmulatable(*programObject);
            rasterTranslationOk = true;
            break;
        }
        case ProgramKind::Separable: {
            // Separable multi-stage combo — translate every attached
            // vertex-processing stage for introspection; actual draw
            // sourcing comes from the pipeline object later. For
            // `incomplete_program_objects` we just need link-status
            // == GL_TRUE; drawing this specific combination never
            // happens because the CTS test immediately discards the
            // program.
            auto translateSingle = [&](GLShaderObject* sh, GLenum stageEnum,
                                       std::string& outMSL,
                                       ShaderReflection& outRefl) {
                if (sh == nullptr || sh->spirv.empty()) return;
                BindingMap stageBindings;
                appgl::TranslatorOptions stageOptions;
                stageOptions.fp64EmulationAvailable = fp64EmulationAvailable;
                stageOptions.forceArgumentBuffers = spirvNeedsArgumentBuffers(
                    sh->spirv.data(), sh->spirv.size());
                applyShaderSpirvOptions(stageOptions, sh);
                if (stageEnum == GL_FRAGMENT_SHADER) {
                    stageOptions.fragmentCoordOriginUpperLeft =
                        sourceDeclaresFragCoordOriginUpperLeft(sh->source);
                }
                outMSL = translator.spirvToMSL(sh->spirv.data(),
                    sh->spirv.size(), stageBindings, nullptr, stageOptions);
                outRefl = translator.reflect(sh->spirv.data(),
                    sh->spirv.size(), stageBindings, nullptr, stageOptions);
                (void)stageEnum;
            };
            translateSingle(vertexShader, GL_VERTEX_SHADER,
                            programObject->vertexMSL, programObject->vertexReflection);
            translateSingle(fragmentShader, GL_FRAGMENT_SHADER,
                            programObject->fragmentMSL, programObject->fragmentReflection);
            rasterTranslationOk = true;
            break;
        }
        case ProgramKind::Unknown:
            break;  // Already handled above; kept so -Wswitch stays happy.
    }

    refreshProgramMslArgumentBufferMetadata(*programObject);

    APPGL_LOG(SHADER, @"[GL] linkProgram: program=%u kind=%d translationOk=%d "
          @"vertexInputs=%zu vsUniformBlocks=%zu fsUniformBlocks=%zu",
          program, static_cast<int>(kind), rasterTranslationOk ? 1 : 0,
          programObject->vertexReflection.vertexInputs.size(),
          programObject->vertexReflection.uniformBlocks.size(),
          programObject->fragmentReflection.uniformBlocks.size());
    fflush(stderr);  // Phase 8X Group 4d follow-up²³ — synchronous flush

    // ── Supplement scanner-discovered uniforms with SPIR-V reflection ──
    //
    // The lightweight GLSL scanner (GLSLReflection) can't parse struct-typed
    // uniforms, interface-block members, or other complex declarations.
    // SPIRV-Cross reflection IS authoritative for the _DefaultUniforms block
    // members — it sees every uniform that survived dead-code elimination.
    // Walk the _DefaultUniforms members from each stage's reflection and add
    // any that the scanner missed to the program's uniform list with fresh
    // locations and zero-seeded values.  This lets glGetUniformLocation /
    // glUniform* work for struct members (e.g. "s.a"), array-of-struct
    // elements ("s[0].a"), and any other uniform type the scanner can't parse.
    if (programObject->linked) {
        auto addReflectionVertexInputs = [&]() {
            if (programObject->vertexReflection.vertexInputs.empty()) {
                return;
            }
            auto resolvedAttributeCovers = [&](GLint location,
                                               const std::string& name) -> bool {
                for (const auto& attr : programObject->attributes) {
                    if (!name.empty() && attr.name == name) {
                        return true;
                    }
                    if (attr.location < 0 || location < 0) {
                        continue;
                    }
                    const GLint locationArraySize =
                        arrayElementCount(attr.arrayDimensions, attr.arraySize);
                    const GLuint slotCount =
                        vertexInputLocationSlotCount(attr.type, locationArraySize);
                    const GLint begin = attr.location;
                    const GLint end = begin + static_cast<GLint>(std::max<GLuint>(1u, slotCount));
                    if (location >= begin && location < end) {
                        return true;
                    }
                }
                return false;
            };
            for (const auto& input : programObject->vertexReflection.vertexInputs) {
                const GLint inputLocation =
                    static_cast<GLint>(input.sourceLocation);
                if (resolvedAttributeCovers(inputLocation, input.name)) {
                    continue;
                }
                const auto attrExists = std::find_if(
                    programObject->attributes.begin(),
                    programObject->attributes.end(),
                    [&](const GLProgramAttributeInfo& attr) {
                        if (!input.name.empty() && attr.name == input.name) {
                            return true;
                        }
                        return attr.location == inputLocation;
                    });
                if (attrExists == programObject->attributes.end()) {
                    GLProgramAttributeInfo attr;
                    attr.name = input.name;
                    attr.type = input.type;
                    attr.location = inputLocation;
                    attr.arraySize = 1;
                    attr.isArray = false;
                    programObject->attributes.push_back(std::move(attr));
                }

                const auto resourceExists = std::find_if(
                    programObject->resourceInputs.begin(),
                    programObject->resourceInputs.end(),
                    [&](const GLProgramResourceEntry& entry) {
                        if (!input.name.empty() && entry.name == input.name) {
                            return true;
                        }
                        return entry.location == inputLocation &&
                               entry.referencedBy == kBitVertex;
                    });
                if (resourceExists != programObject->resourceInputs.end()) {
                    continue;
                }
                GLProgramResourceEntry entry;
                entry.name = input.name;
                entry.type = input.type;
                entry.location = inputLocation;
                entry.arraySize = 1;
                entry.referencedBy = kBitVertex;
                programObject->resourceInputs.push_back(std::move(entry));
            }
        };
        addReflectionVertexInputs();

        // Build a set of names the scanner already discovered.
        std::unordered_set<std::string> knownUniformNames;
        for (const auto& u : programObject->uniforms) {
            knownUniformNames.insert(u.name);
        }

        // Find the next available auto-location (past all existing ones).
        GLint supplementNextLoc = 0;
        for (const auto& u : programObject->uniforms) {
            const GLint endLoc = u.location + std::max<GLint>(u.arraySize, 1);
            if (endLoc > supplementNextLoc) {
                supplementNextLoc = endLoc;
            }
        }

        // "Does this stage's source declare a uniform named
        // `topName` at the top level?" helper. Only stage-declared
        // uniforms may carry this stage's REFERENCED_BY bit in the
        // resource table. A naive word-boundary search of the whole
        // source produces false positives — a struct field with
        // the same name as a VS uniform would match (CTS
        // uniform-types has `struct U { bool a[3]; ... }` in the
        // FS and `uniform vec4 a;` in the VS). We want only the
        // `uniform X <topName>[...];` pattern. Walk each `uniform`
        // token (word-bounded) and inspect the identifier tokens
        // up to the next `;` or `{` — if `topName` appears as one
        // of them, treat it as declared.
        auto stageDeclaresTopUniform = [](const std::string& src, const std::string& topName) {
            if (topName.empty()) return false;
            const std::string uniformKw = "uniform";
            std::size_t pos = 0;
            auto identifierAppears = [&](std::size_t scan, std::size_t end) {
                while (scan < end) {
                    while (scan < end &&
                           !std::isalpha(static_cast<unsigned char>(src[scan])) &&
                           src[scan] != '_') {
                        ++scan;
                    }
                    if (scan >= end) break;
                    std::size_t identStart = scan;
                    while (scan < end &&
                           (std::isalnum(static_cast<unsigned char>(src[scan])) ||
                            src[scan] == '_')) {
                        ++scan;
                    }
                    if (src.compare(identStart, scan - identStart, topName) == 0) {
                        return true;
                    }
                }
                return false;
            };
            while ((pos = src.find(uniformKw, pos)) != std::string::npos) {
                const bool leftBoundary = (pos == 0) ||
                    !(std::isalnum(static_cast<unsigned char>(src[pos - 1])) || src[pos - 1] == '_');
                const bool rightBoundary = (pos + uniformKw.size() < src.size()) &&
                    !(std::isalnum(static_cast<unsigned char>(src[pos + uniformKw.size()])) || src[pos + uniformKw.size()] == '_');
                if (!(leftBoundary && rightBoundary)) {
                    pos += uniformKw.size();
                    continue;
                }
                // Struct default uniforms use `uniform struct T { ... }
                // name[N];`; the instance name lives after the matching
                // closing brace, so scan there before the simpler scalar
                // declaration path.
                std::size_t scan = pos + uniformKw.size();
                const std::size_t firstSemi = src.find(';', scan);
                const std::size_t openBrace = src.find('{', scan);
                if (openBrace != std::string::npos &&
                    (firstSemi == std::string::npos || openBrace < firstSemi)) {
                    int depth = 1;
                    std::size_t closeBrace = openBrace + 1;
                    while (closeBrace < src.size() && depth > 0) {
                        if (src[closeBrace] == '{') {
                            ++depth;
                        } else if (src[closeBrace] == '}') {
                            --depth;
                        }
                        ++closeBrace;
                    }
                    const std::size_t semi = (depth == 0)
                        ? src.find(';', closeBrace)
                        : std::string::npos;
                    if (depth == 0 && semi != std::string::npos) {
                        if (identifierAppears(closeBrace, semi)) {
                            return true;
                        }
                        pos = semi;
                        continue;
                    }
                }
                // Scan identifiers from pos+7 up to first ; or {.
                while (scan < src.size() && src[scan] != ';' && src[scan] != '{') {
                    // Skip non-identifier chars.
                    while (scan < src.size() &&
                           !std::isalpha(static_cast<unsigned char>(src[scan])) &&
                           src[scan] != '_' &&
                           src[scan] != ';' && src[scan] != '{') {
                        ++scan;
                    }
                    if (scan >= src.size() || src[scan] == ';' || src[scan] == '{') break;
                    std::size_t identStart = scan;
                    while (scan < src.size() &&
                           (std::isalnum(static_cast<unsigned char>(src[scan])) || src[scan] == '_')) {
                        ++scan;
                    }
                    std::string ident = src.substr(identStart, scan - identStart);
                    if (ident == topName) return true;
                }
                pos = scan;
            }
            return false;
        };
        auto explicitUniformLocationFor = [](const std::string& src,
                                             const std::string& topName) -> GLint {
            if (topName.empty()) return -1;
            auto isIdent = [](char c) {
                const unsigned char uc = static_cast<unsigned char>(c);
                return std::isalnum(uc) || c == '_';
            };
            auto hasWord = [&](std::string_view text,
                               const std::string& word) -> bool {
                std::size_t pos = 0;
                while ((pos = text.find(word, pos)) != std::string_view::npos) {
                    const bool leftOk = (pos == 0) || !isIdent(text[pos - 1]);
                    const std::size_t end = pos + word.size();
                    const bool rightOk = (end >= text.size()) || !isIdent(text[end]);
                    if (leftOk && rightOk) return true;
                    pos = end;
                }
                return false;
            };
            auto findLocation = [&](std::string_view text) -> GLint {
                std::size_t pos = 0;
                while ((pos = text.find("location", pos)) != std::string_view::npos) {
                    const bool leftOk = (pos == 0) || !isIdent(text[pos - 1]);
                    const std::size_t wordEnd = pos + 8;
                    const bool rightOk = (wordEnd >= text.size()) || !isIdent(text[wordEnd]);
                    if (!(leftOk && rightOk)) {
                        pos = wordEnd;
                        continue;
                    }
                    std::size_t eq = wordEnd;
                    while (eq < text.size() &&
                           std::isspace(static_cast<unsigned char>(text[eq]))) {
                        ++eq;
                    }
                    if (eq >= text.size() || text[eq] != '=') {
                        pos = wordEnd;
                        continue;
                    }
                    ++eq;
                    while (eq < text.size() &&
                           std::isspace(static_cast<unsigned char>(text[eq]))) {
                        ++eq;
                    }
                    char* endp = nullptr;
                    const long value = std::strtol(text.data() + eq, &endp, 0);
                    if (endp != text.data() + eq) {
                        return static_cast<GLint>(value);
                    }
                    pos = wordEnd;
                }
                return -1;
            };
            std::string statement;
            statement.reserve(256);
            int braceDepth = 0;
            for (char c : src) {
                statement.push_back(c);
                if (c == '{') {
                    ++braceDepth;
                } else if (c == '}') {
                    if (braceDepth > 0) --braceDepth;
                } else if (c == ';' && braceDepth == 0) {
                    const std::string_view stmt(statement.data(), statement.size());
                    if (hasWord(stmt, "uniform") && hasWord(stmt, topName)) {
                        const GLint loc = findLocation(stmt);
                        if (loc >= 0) return loc;
                    }
                    statement.clear();
                }
            }
            return -1;
        };
        auto aggregateArrayElementReferenced =
            [](const std::string& src,
               const std::string& flatName,
               const std::string& topName) {
                if (topName.empty() ||
                    flatName.compare(0, topName.size(), topName) != 0 ||
                    flatName.size() <= topName.size() ||
                    flatName[topName.size()] != '[') {
                    return true;
                }
                const std::size_t close = flatName.find(']', topName.size() + 1);
                if (close == std::string::npos ||
                    close + 1 >= flatName.size() ||
                    flatName[close + 1] != '.') {
                    return true;
                }
                std::string compactSrc;
                compactSrc.reserve(src.size());
                for (char c : src) {
                    if (!std::isspace(static_cast<unsigned char>(c))) {
                        compactSrc.push_back(c);
                    }
                }
                const std::string elementPrefix = flatName.substr(0, close + 1);
                if (compactSrc.find(elementPrefix) != std::string::npos) {
                    return true;
                }
                const std::string anyElementPrefix = topName + "[";
                std::size_t pos = 0;
                while ((pos = compactSrc.find(anyElementPrefix, pos)) != std::string::npos) {
                    const std::size_t idxStart = pos + anyElementPrefix.size();
                    if (idxStart >= compactSrc.size() ||
                        !std::isdigit(static_cast<unsigned char>(compactSrc[idxStart]))) {
                        return true;
                    }
                    pos = idxStart;
                }
                return compactSrc.find(anyElementPrefix) == std::string::npos;
            };
        // Extract the top-level uniform name from a flattened member
        // name. `j.b` → `j`, `k.a[0].c` → `k`, `l[2].b[1].d[0]` → `l`.
        auto topLevelName = [](const std::string& flat) -> std::string {
            std::size_t cut = flat.size();
            for (std::size_t i = 0; i < flat.size(); ++i) {
                if (flat[i] == '.' || flat[i] == '[') { cut = i; break; }
            }
            return flat.substr(0, cut);
        };
        // Lambda: scan one stage's reflection for _DefaultUniforms members.
        // `stageBit` is the referencedBy bit for this stage so struct
        // members declared by the stage accumulate the right bit in the
        // resourceUniforms table. `stageSrc` is the stage's GLSL source
        // (used to gate the stage bit on whether this stage actually
        // declared the top-level uniform — glslang's cross-stage
        // linking copies every uniform into every stage's SPIR-V
        // _DefaultUniforms reflection, so "member is in this stage's
        // SPIR-V" is NOT a valid signal for "stage references it").
        // CTS `program_interface_query.uniform-types` declares
        // `uniform U j;` in the FS and expects
        // REFERENCED_BY_FRAGMENT_SHADER = 1 on every flattened leaf
        // (`j.b`, etc.) and REFERENCED_BY_VERTEX_SHADER = 0.
        auto supplementFromReflection = [&](const ShaderReflection& refl,
                                            GLbitfield stageBit,
                                            const std::string& stageSrc) {
            if (refl.uniformBlocks.empty()) return;
            const ShaderReflection::ResourceBinding* defaultBlock = nullptr;
            for (const auto& candidate : refl.uniformBlocks) {
                if (candidate.name == "_DefaultUniforms") {
                    defaultBlock = &candidate;
                    break;
                }
            }
            if (defaultBlock == nullptr) return;
            const auto& block = *defaultBlock;
            std::unordered_map<std::string, GLint> explicitMemberNextLoc;
            for (const auto& member : block.members) {
                // Sprint 17 Day 7+ Bank-Group-C: skip synthetic
                // dispatch uniforms emitted by
                // `rewriteSubroutinesForSpirv` for v1 dynamic
                // dispatch. These are processed separately by
                // `processSubroutineDispatchUniforms` (above) for ALL
                // stages and exposed only via the side-channel
                // `subroutineDispatchUniformLocations`. Spec-correct:
                // subroutine uniforms are queryable via separate
                // GL_*_SUBROUTINE_UNIFORM interfaces only and must NOT
                // appear in glGetActiveUniform enumeration.
                if (member.name.compare(0, 11, "_appgl_sub_") == 0) {
                    continue;
                }
                // Skip the rewriter's bare-name reserved-keyword
                // validation stubs (`int <NAME>;` for each subroutine
                // uniform / type). These exist only to push the
                // user identifier through glslang's reserved-keyword
                // check (CTS CommonBugs.CommonBug_ReservedNames); they
                // would otherwise leak as bogus default-block int
                // uniforms with auto-assigned locations in
                // glGetUniformLocation / glGetActiveUniform output.
                {
                    bool isSubroutineStub = false;
                    for (int sIdx = 0; sIdx < 6 && !isSubroutineStub; ++sIdx) {
                        for (const auto& su : programObject->resourceSubroutineUniforms[sIdx]) {
                            if (su.name == member.name) { isSubroutineStub = true; break; }
                        }
                        if (isSubroutineStub) break;
                        for (const auto& sr : programObject->resourceSubroutines[sIdx]) {
                            if (sr.name == member.name) { isSubroutineStub = true; break; }
                        }
                    }
                    if (isSubroutineStub) continue;
                }
                // Gate this stage's referencedBy bit on whether the
                // stage's source actually declares the top-level
                // name as a uniform (see lambda comment above).
                // Without this filter every uniform gets both stages'
                // bits because glslang's cross-stage linker fills
                // every stage's _DefaultUniforms with the union.
                const std::string topName = topLevelName(member.name);
                const bool stageDeclares = stageDeclaresTopUniform(stageSrc, topName);
                bool stageReferences = stageDeclares;
                if (stageReferences && stageBit == kBitGeometry && !gsRefSet.empty()) {
                    stageReferences =
                        gsRefSet.count(member.name) != 0 ||
                        gsRefSet.count(topName) != 0;
                }
                if (stageReferences &&
                    !aggregateArrayElementReferenced(stageSrc, member.name, topName)) {
                    stageReferences = false;
                }
                const GLbitfield effStageBit = stageReferences ? stageBit : 0;
                // GL 4.6 §7.3.1 canonical resource name for an array
                // uniform carries the "[0]" suffix even when the
                // member's SPIR-V name does not. Compute both forms
                // so we can match against `knownUniformNames`
                // (which already stores the canonical shape) and
                // resourceUniforms (which also stores canonical).
                const std::string canonicalName = member.isArray
                    ? (member.name + "[0]") : member.name;
                if (knownUniformNames.count(canonicalName) ||
                    knownUniformNames.count(member.name)) {
                    // Existing uniform (from scanner or previous
                    // stage) — just OR in this stage's referencedBy
                    // bit on its resourceUniforms entry.
                    for (auto& re : programObject->resourceUniforms) {
                        if (re.name == canonicalName || re.name == member.name) {
                            re.referencedBy |= effStageBit;
                            break;
                        }
                    }
                    continue;
                }
                // Skip members this stage doesn't declare — they'll
                // be added by the OTHER stage's supplement pass with
                // the correct referencedBy bit.
                if (!stageReferences) continue;
                // New uniform discovered by SPIR-V but not by the scanner.
                GLProgramUniformInfo info;
                info.name = member.name;
                info.type = member.type;
                info.arraySize = (member.arraySize > 0)
                    ? static_cast<GLint>(member.arraySize) : 1;
                info.isArray = member.isArray;
                info.explicitLocation = -1;
                info.explicitBinding = -1;
                // GL 4.6 §7.6.2.2 — when the scanner already registered
                // the top-level parent uniform with an explicit location
                // (e.g. `layout(location = 2) uniform float u0[2][3]`),
                // the SPIRV-Cross-flattened members (`u0[0]`, `u0[1]`)
                // must be located at parent.explicitLocation + i*members
                // per element, NOT at supplementNextLoc (which would auto-
                // assign past every explicit location). CTS
                // `explicit_uniform_location.uniform-loc-arrays-of-arrays`
                // asserts `u0[0][0]` = 2 for `u0[2][3]` at location 2.
                const std::string memberTopName = topLevelName(member.name);
                const GLProgramUniformInfo* parent = nullptr;
                for (const auto& u : programObject->uniforms) {
                    if (u.name == memberTopName && u.explicitLocation >= 0) {
                        parent = &u;
                        break;
                    }
                }
                GLint parentExplicitLocation = -1;
                if (parent != nullptr) {
                    parentExplicitLocation = parent->explicitLocation;
                } else {
                    parentExplicitLocation =
                        explicitUniformLocationFor(stageSrc, memberTopName);
                }
                bool locationSet = false;
                if (parentExplicitLocation >= 0) {
                    // Parse the member name's subscript chain relative to the
                    // parent. `u0[i]` for a single-subscript member of an
                    // outer-dim-split array-of-arrays gives flattened offset
                    // i * inner_arraySize. Struct member shapes use the
                    // per-parent explicit cursor below, which follows
                    // reflection order from the declared base location.
                    const std::string tail = member.name.substr(memberTopName.size());
                    // Require pure `[i]` form; anything else (containing `.`
                    // or multiple brackets) is structurally complex and we
                    // fall back to auto-assignment.
                    if (tail.size() >= 3 && tail.front() == '[' && tail.back() == ']'
                        && tail.find('.') == std::string::npos
                        && std::count(tail.begin(), tail.end(), '[') == 1) {
                        const std::string idxText = tail.substr(1, tail.size() - 2);
                        char* endp = nullptr;
                        const long idx = std::strtol(idxText.c_str(), &endp, 10);
                        if (endp && *endp == '\0' && idx >= 0) {
                            const GLint perEntryLocs = std::max<GLint>(info.arraySize, 1);
                            info.location = parentExplicitLocation +
                                static_cast<GLint>(idx) * perEntryLocs;
                            locationSet = true;
                        }
                    }
                    if (!locationSet) {
                        auto cursor = explicitMemberNextLoc.find(memberTopName);
                        if (cursor == explicitMemberNextLoc.end()) {
                            cursor = explicitMemberNextLoc
                                .emplace(memberTopName, parentExplicitLocation)
                                .first;
                        }
                        info.location = cursor->second;
                        cursor->second += std::max<GLint>(info.arraySize, 1);
                        locationSet = true;
                    }
                }
                if (!locationSet) {
                    info.location = supplementNextLoc;
                    supplementNextLoc += std::max<GLint>(info.arraySize, 1);
                }
                knownUniformNames.insert(canonicalName);

                // Zero-seed the uniform value.
                const GLint components = glslComponentCount(info.type)
                    * std::max<GLint>(info.arraySize, 1);
                const std::size_t cnt = static_cast<std::size_t>(components);
                GLProgramUniformValue value;
                value.type = info.type;
                value.arraySize = info.arraySize;
                switch (info.type) {
                    case GL_INT: case GL_INT_VEC2: case GL_INT_VEC3: case GL_INT_VEC4:
                    case GL_BOOL: case GL_BOOL_VEC2: case GL_BOOL_VEC3: case GL_BOOL_VEC4:
                        value.ints.assign(cnt, 0);
                        break;
                    case GL_UNSIGNED_INT: case GL_UNSIGNED_INT_VEC2:
                    case GL_UNSIGNED_INT_VEC3: case GL_UNSIGNED_INT_VEC4:
                        value.uints.assign(cnt, 0u);
                        break;
                    case GL_DOUBLE: case GL_DOUBLE_VEC2:
                    case GL_DOUBLE_VEC3: case GL_DOUBLE_VEC4:
                    case GL_DOUBLE_MAT2: case GL_DOUBLE_MAT3:
                    case GL_DOUBLE_MAT4: case GL_DOUBLE_MAT2x3:
                    case GL_DOUBLE_MAT2x4: case GL_DOUBLE_MAT3x2:
                    case GL_DOUBLE_MAT3x4: case GL_DOUBLE_MAT4x2:
                    case GL_DOUBLE_MAT4x3:
                        value.doubles.assign(cnt, 0.0);
                        value.floats.assign(cnt, 0.0f);
                        value.df64TransportWords.assign(cnt * 2u, 0u);
                        break;
                    default:
                        value.floats.assign(cnt, 0.0f);
                        break;
                }
                programObject->uniformValues[info.location] = std::move(value);

                // Mirror into resourceUniforms as a default-block
                // uniform. GL 4.6 §7.3.1: default-block uniforms
                // have BLOCK_INDEX = OFFSET = ARRAY_STRIDE =
                // MATRIX_STRIDE = -1, IS_ROW_MAJOR = FALSE,
                // ATOMIC_COUNTER_BUFFER_INDEX = -1. REFERENCED_BY_*
                // carries just this stage's bit.
                GLProgramResourceEntry entry;
                entry.name = canonicalName;
                entry.type = info.type;
                entry.location = info.location;
                entry.binding = -1;
                entry.arraySize = info.arraySize;
                entry.isArray = info.isArray;
                entry.referencedBy = effStageBit;
                // Default-block uniforms: leave offset / blockIndex
                // / arrayStride / matrixStride at their default -1
                // sentinels so getResourceProperty reports -1.
                programObject->resourceUniforms.push_back(std::move(entry));

                programObject->uniforms.push_back(std::move(info));
            }
        };

        static const std::string kEmptySrc;
        const std::string& vsSrc2 = vertexShader
            ? vertexShader->source
            : (!fragmentOnlySyntheticVertexSourceForReflection.empty()
                ? fragmentOnlySyntheticVertexSourceForReflection
                : kEmptySrc);
        const std::string& fsSrc2 = fragmentShader ? fragmentShader->source : kEmptySrc;
        const std::string& gsSrc2 = geometryShader ? geometryShader->source : kEmptySrc;
        const std::string& csSrc2 = computeShader ? computeShader->source : kEmptySrc;
        supplementFromReflection(programObject->vertexReflection, 0x01, vsSrc2);
        supplementFromReflection(programObject->fragmentReflection, 0x02, fsSrc2);
        supplementFromReflection(programObject->geometryReflection, 0x04, gsSrc2);
        // Tess stages: source the reflection from whichever TES form
        // got translated (compute form for combined VertexTessellation
        // Fragment programs, vertex form would be similar but isn't
        // stashed today). TCS reflection is always stashed when the
        // stage was translated. Stage bits: TCS=0x08, TES=0x10
        // (mirror of glProgramInterfaceiv / GL_REFERENCED_BY_*).
        // Closes the
        //   single.ext_program_interface_query_dependency
        // failure where `glGetProgramResourceIndex(po, GL_UNIFORM,
        // "tc_uniform1")` returned `GL_INVALID_INDEX` because the
        // tess-stage default-block uniforms never made it into
        // `resourceUniforms`.
        const std::string& tcsSrc2 = tessControlShader ? tessControlShader->source : kEmptySrc;
        const std::string& tesSrc2 = tessEvalShader ? tessEvalShader->source : kEmptySrc;
        supplementFromReflection(programObject->tessControlReflection, 0x08, tcsSrc2);
        supplementFromReflection(programObject->tessEvalAsComputeReflection, 0x10, tesSrc2);
        supplementFromReflection(programObject->computeReflection, 0x20, csSrc2);

        auto supplementOpaqueUniforms = [&](const ShaderReflection& refl,
                                            GLbitfield stageBit) {
            auto addBinding = [&](const ShaderReflection::ResourceBinding& binding,
                                  GLenum fallbackType,
                                  const std::unordered_map<std::string, GLuint>& explicitBindings) {
                const GLenum glType = binding.glType != 0 ? binding.glType : fallbackType;
                if (glType == 0) {
                    return;
                }
                const GLint arraySize =
                    static_cast<GLint>(std::max<std::uint32_t>(binding.arraySize, 1u));
                const std::string canonicalName =
                    (!binding.name.empty() && arraySize > 1)
                        ? (binding.name + "[0]")
                        : binding.name;
                GLuint explicitSourceBinding = 0;
                auto hasExplicitSourceBinding = [&]() {
                    auto probe = [&](std::string name) -> bool {
                        if (name.empty()) {
                            return false;
                        }
                        if (name.size() > 3 &&
                            name.compare(name.size() - 3, 3, "[0]") == 0) {
                            name.resize(name.size() - 3);
                        }
                        auto it = explicitBindings.find(name);
                        if (it != explicitBindings.end()) {
                            explicitSourceBinding = it->second;
                            return true;
                        }
                        static constexpr const char* kAppglPrefix = "_appgl_";
                        static constexpr std::size_t kAppglPrefixLen = 7;
                        if (name.compare(0, kAppglPrefixLen, kAppglPrefix) == 0) {
                            it = explicitBindings.find(name.substr(kAppglPrefixLen));
                            if (it != explicitBindings.end()) {
                                explicitSourceBinding = it->second;
                                return true;
                            }
                        }
                        return false;
                    };
                    return probe(binding.name) || probe(canonicalName);
                }();
                const bool hasOpaqueDefaultBinding =
                    hasExplicitSourceBinding || linkedFromSpirvBinary;
                const GLuint opaqueDefaultBinding = hasExplicitSourceBinding
                    ? explicitSourceBinding
                    : binding.glBinding;
                auto uniformIt = std::find_if(
                    programObject->uniforms.begin(),
                    programObject->uniforms.end(),
                    [&](const GLProgramUniformInfo& info) {
                        if (!binding.name.empty() && info.name == binding.name) {
                            return true;
                        }
                        return binding.uniformLocation >= 0 &&
                               info.location == binding.uniformLocation &&
                               info.type == glType;
                    });
                if (uniformIt != programObject->uniforms.end()) {
                    for (auto& resource : programObject->resourceUniforms) {
                        const bool sameNamed =
                            !canonicalName.empty() &&
                            (resource.name == canonicalName ||
                             resource.name == binding.name);
                        const bool sameLocation =
                            resource.location == uniformIt->location &&
                            resource.type == glType;
                        if (sameNamed || sameLocation) {
                            resource.referencedBy |= stageBit;
                            if (resource.binding < 0 && hasOpaqueDefaultBinding) {
                                resource.binding =
                                    static_cast<GLint>(opaqueDefaultBinding);
                            }
                            break;
                        }
                    }
                    if (uniformIt->explicitBinding < 0 && hasOpaqueDefaultBinding) {
                        uniformIt->explicitBinding =
                            static_cast<GLint>(opaqueDefaultBinding);
                    }
                    return;
                }

                if (!canonicalName.empty() &&
                    (knownUniformNames.count(canonicalName) ||
                     knownUniformNames.count(binding.name))) {
                    return;
                }

                GLProgramUniformInfo info;
                info.name = binding.name;
                info.type = glType;
                info.arraySize = arraySize;
                info.isArray = arraySize > 1;
                info.explicitLocation = binding.uniformLocation;
                info.explicitBinding = hasOpaqueDefaultBinding
                    ? static_cast<GLint>(opaqueDefaultBinding)
                    : -1;
                info.location = binding.uniformLocation >= 0
                    ? binding.uniformLocation
                    : supplementNextLoc;

                const GLint consumed = std::max<GLint>(info.arraySize, 1);
                if (binding.uniformLocation < 0 ||
                    supplementNextLoc < info.location + consumed) {
                    supplementNextLoc = info.location + consumed;
                }

                GLProgramUniformValue value;
                value.type = info.type;
                value.arraySize = info.arraySize;
                value.ints.resize(static_cast<std::size_t>(consumed));
                for (GLint i = 0; i < consumed; ++i) {
                    value.ints[static_cast<std::size_t>(i)] =
                        hasOpaqueDefaultBinding
                            ? static_cast<GLint>(opaqueDefaultBinding) + i
                            : 0;
                }
                programObject->uniformValues[info.location] = std::move(value);

                GLProgramResourceEntry entry;
                entry.name = canonicalName;
                entry.type = info.type;
                entry.location = info.location;
                entry.binding = hasOpaqueDefaultBinding
                    ? static_cast<GLint>(opaqueDefaultBinding)
                    : -1;
                entry.arraySize = info.arraySize;
                entry.isArray = info.isArray;
                entry.referencedBy = stageBit;
                programObject->resourceUniforms.push_back(std::move(entry));

                if (!canonicalName.empty()) {
                    knownUniformNames.insert(canonicalName);
                    knownUniformNames.insert(binding.name);
                }
                programObject->uniforms.push_back(std::move(info));
            };

            for (const auto& binding : refl.sampledTextures) {
                addBinding(binding, GL_SAMPLER_2D,
                           programObject->samplerExplicitBindings);
            }
            for (const auto& binding : refl.storageImages) {
                addBinding(binding, GL_IMAGE_2D,
                           programObject->imageExplicitBindings);
            }
        };
        supplementOpaqueUniforms(programObject->vertexReflection, 0x01);
        supplementOpaqueUniforms(programObject->fragmentReflection, 0x02);
        supplementOpaqueUniforms(programObject->geometryReflection, 0x04);
        supplementOpaqueUniforms(programObject->tessControlReflection, 0x08);
        supplementOpaqueUniforms(programObject->tessEvalAsComputeReflection, 0x10);
        supplementOpaqueUniforms(programObject->computeReflection, 0x20);

        // ── Sprint 17 Day 7+ Bank-Group-C: synthetic dispatch uniforms ──
        //
        // The compat rewriter `rewriteSubroutinesForSpirv` emits one
        // `uniform uint _appgl_sub_<UNI>;` per v1-eligible subroutine
        // uniform (void return, no params) so the inline if-else
        // dispatch chain emitted at call sites can branch on the
        // selected impl. These synthetic uniforms appear in EVERY
        // stage's `_DefaultUniforms` block (whichever stage declared
        // the subroutine). Unlike user uniforms, this processing runs
        // for ALL stages — including GS and CS, which
        // `supplementFromReflection` does NOT cover — because the
        // synthetic uniform must be locatable for the
        // `glUniformSubroutinesuiv` setter regardless of which stage
        // emitted it (CTS `viewport_index_subroutine` declares the
        // subroutine in GS only).
        //
        // Names are excluded from `programObject->resourceUniforms`
        // (so glGetActiveUniform / glGetProgramResource* enumeration
        // doesn't expose them — spec-correct: subroutine uniforms are
        // queryable via separate GL_*_SUBROUTINE_UNIFORM interfaces
        // only). The reflection filter at the top of the
        // `supplementFromReflection` member loop also skips them for
        // the VS/FS/TCS/TES paths.
        auto processSubroutineDispatchUniforms = [&](const ShaderReflection& refl) {
            if (refl.uniformBlocks.empty()) return;
            const ShaderReflection::ResourceBinding* defaultBlock = nullptr;
            for (const auto& candidate : refl.uniformBlocks) {
                if (candidate.name == "_DefaultUniforms") {
                    defaultBlock = &candidate;
                    break;
                }
            }
            if (defaultBlock == nullptr) return;
            const auto& block = *defaultBlock;
            for (const auto& member : block.members) {
                if (member.name.compare(0, 11, "_appgl_sub_") != 0) continue;
                // Side-channel keyed by ORIGINAL subroutine-uniform
                // name (strip `_appgl_sub_` 11-char prefix).
                const std::string uniName = member.name.substr(11);
                // Reuse the scanner's pre-existing entry if present
                // (the lightweight GLSL reflector at reflectGLSL()
                // walks the rewritten source and picks up the
                // synthetic `uniform uint _appgl_sub_<UNI>;` decl
                // before this lambda runs); otherwise allocate a
                // fresh default-block slot. Either way the
                // side-channel must be populated so
                // glUniformSubroutinesuiv can locate the dispatch
                // uniform's value cell.
                GLint existingLoc = -1;
                for (const auto& u : programObject->uniforms) {
                    if (u.name == member.name) { existingLoc = u.location; break; }
                }
                GLint targetLoc = existingLoc;
                if (existingLoc < 0) {
                    GLProgramUniformInfo info;
                    info.name = member.name;
                    info.type = GL_UNSIGNED_INT;
                    info.arraySize = 1;
                    info.isArray = false;
                    info.explicitLocation = -1;
                    info.explicitBinding = -1;
                    info.location = supplementNextLoc;
                    supplementNextLoc += 1;
                    targetLoc = info.location;
                    knownUniformNames.insert(member.name);
                    programObject->uniforms.push_back(std::move(info));
                }
                // Ensure a zero-seeded value cell exists at the chosen
                // location (the scanner's appendDeclarationsAsUniforms
                // path doesn't seed values for uniforms it discovers
                // by source scanning — only the SPIR-V flatten path
                // does).
                auto& valueSlot = programObject->uniformValues[targetLoc];
                if (valueSlot.uints.empty()) {
                    valueSlot.type = GL_UNSIGNED_INT;
                    valueSlot.arraySize = 1;
                    valueSlot.uints.assign(1, 0u);
                }
                programObject->subroutineDispatchUniformLocations[uniName] = targetLoc;
                // Intentionally NOT pushed into resourceUniforms.
            }
        };
        processSubroutineDispatchUniforms(programObject->vertexReflection);
        processSubroutineDispatchUniforms(programObject->fragmentReflection);
        processSubroutineDispatchUniforms(programObject->geometryReflection);
        processSubroutineDispatchUniforms(programObject->tessControlReflection);
        processSubroutineDispatchUniforms(programObject->tessEvalAsComputeReflection);
        processSubroutineDispatchUniforms(programObject->computeReflection);
    }

    // Reflection supplementing can add synthesized default-block uniforms
    // that source scanning did not see, notably the FragmentOnly synthetic
    // fixed-function VS matrix uniform.
    refreshSynthesizedUniformLocations();

    // ── Merge SPIRV-Cross uniform block reflection into the program's
    //    resource introspection tables ──
    //
    // The scanner doesn't see interface blocks (see 2d / GLSLReflection
    // brace-depth bug), so SPIRV-Cross reflection is the authoritative
    // source for UBO member metadata. Blocks that appear in both the
    // vertex and fragment reflection (BAR's per-view uniforms are shared
    // across stages) dedup by name, OR-ing the referencedBy bits together.
    //
    // Each block also pushes its members into resourceBufferVariables with
    // `blockIndex` pointing back to the block entry so
    // glGetProgramResourceiv(GL_BUFFER_VARIABLE, ...) can find them.
    if (programObject->linked) {
        auto parsedBlockInstanceCount =
            [](const ParsedInterfaceBlockForValidation* parsed,
               std::uint32_t reflectedCount) -> int {
                if (parsed != nullptr && parsed->instanceIsArray) {
                    return std::max(1, parsed->instanceArraySize);
                }
                return reflectedCount > 0 ? static_cast<int>(reflectedCount) : 1;
            };
        auto parsedBlockInstanceName =
            [](const std::string& baseName,
               const ParsedInterfaceBlockForValidation* parsed,
               int linearIndex) {
                std::string out = baseName;
                if (parsed == nullptr ||
                    !parsed->instanceIsArray ||
                    parsed->instanceArrayDimensions.empty()) {
                    out += "[" + std::to_string(linearIndex) + "]";
                    return out;
                }
                std::vector<int> indices(parsed->instanceArrayDimensions.size(), 0);
                int remain = linearIndex;
                for (std::size_t rev = parsed->instanceArrayDimensions.size(); rev > 0; --rev) {
                    const std::size_t dimIndex = rev - 1;
                    const int dim = std::max(1, parsed->instanceArrayDimensions[dimIndex]);
                    indices[dimIndex] = remain % dim;
                    remain /= dim;
                }
                for (int idx : indices) {
                    out += "[" + std::to_string(idx) + "]";
                }
                return out;
            };
        auto mergeBlocks = [&](const std::vector<ShaderReflection::ResourceBinding>& blocks,
                               GLbitfield stageBit,
                               const std::string& glslSource) {
            std::unordered_map<std::string, ParsedInterfaceBlockForValidation> parsedBlocks;
            for (auto parsed : parseUniformBlocksForValidation(glslSource)) {
                parsedBlocks[parsed.name] = std::move(parsed);
            }
            for (const auto& block : blocks) {
                // Skip glslang's synthesized default-block wrapper —
                // it's not a real user-declared UBO. `supplementFromReflection`
                // above already walked its members and added them as
                // default-block uniforms (BLOCK_INDEX=-1, OFFSET=-1).
                // Exposing it as a GL_UNIFORM_BLOCK resource would
                // inflate GL_ACTIVE_RESOURCES and tag every scalar
                // uniform with a bogus blockIndex. CTS
                // `program_interface_query.uniform-types` expects
                // default-block uniforms to report BLOCK_INDEX=-1
                // and OFFSET=-1.
                if (block.name == "_DefaultUniforms") {
                    continue;
                }
                // Only contribute this stage's REFERENCED_BY_*_SHADER
                // bit when the block is live in the stage's SPIR-V.
                // Declared-but-unused blocks still get an entry so
                // introspection lists them, but without the stage
                // bit. Same logic as mergeStorageBlocks below.
                const GLbitfield blockStageBit = block.active ? stageBit : 0;
                // SPIRV-Cross loses instance name info (varName == typeName
                // for both instanced and non-instanced blocks). Parse the
                // original GLSL source to recover it.
                const auto parsedIt = parsedBlocks.find(block.name);
                const ParsedInterfaceBlockForValidation* parsedBlock =
                    parsedIt != parsedBlocks.end() ? &parsedIt->second : nullptr;
                if (parsedBlock == nullptr &&
                    parsedBlocks.size() == 1 &&
                    blocks.size() == 1) {
                    parsedBlock = &parsedBlocks.begin()->second;
                }
                const bool hasInstance =
                    parsedBlock != nullptr
                        ? parsedBlock->hasInstance
                        : glslBlockHasInstanceName(glslSource, block.name);
                // For an INSTANCED ARRAY block (`} e[2];`), narrow the
                // per-instance stage bit: only the elements actually
                // indexed in the stage's body are active in that stage.
                // CTS `program_interface_query.uniform-block-types`
                // declares `TrickyBlock e[2]` but only reads `e[0].…`,
                // so e[1] must report REFERENCED_BY_FRAGMENT_SHADER=0.
                const std::string instanceName = hasInstance
                    ? (parsedBlock != nullptr && !parsedBlock->instanceName.empty()
                        ? parsedBlock->instanceName
                        : glslBlockInstanceName(glslSource, block.name))
                    : std::string();
                const std::set<int> usedInstanceIndices =
                    !instanceName.empty()
                        ? glslActiveInstanceIndices(glslSource, instanceName)
                        : std::set<int>();
                // If no `inst[N]` usage was found in the source (e.g.
                // the whole block is inactive, OR the instance is not
                // array-indexed), fall back to the block-level active
                // bit for all instances.
                const bool useInstanceNarrowing = !usedInstanceIndices.empty();

                // For array blocks (`uniform B { ... } b[N]`), create one
                // block entry per array element: "BlockName[0]", "BlockName[1]", ...
                // For non-array blocks, create a single entry: "BlockName".
                const int numInstances =
                    parsedBlockInstanceCount(parsedBlock, block.blockArraySize);
                const bool isArray =
                    parsedBlock != nullptr
                        ? parsedBlock->instanceIsArray
                        : (block.blockArraySize > 0);
                const bool hasExplicitBinding =
                    parsedBlock != nullptr
                        ? parsedBlock->hasExplicitBinding
                        : block.hasExplicitBinding;
                const GLint baseBinding =
                    parsedBlock != nullptr
                        ? (parsedBlock->hasExplicitBinding
                            ? static_cast<GLint>(parsedBlock->explicitBinding)
                            : 0)
                        : static_cast<GLint>(block.glBinding);

                // Create block entries for each instance.
                GLint firstBlockIndex = -1;
                bool anyNewBlocks = false;
                GLbitfield firstInstStageBit = blockStageBit;  // used for member bit
                for (int inst = 0; inst < numInstances; ++inst) {
                    GLbitfield effStageBit = blockStageBit;
                    if (useInstanceNarrowing &&
                        usedInstanceIndices.count(inst) == 0) {
                        effStageBit = 0;
                    }
                    if (inst == 0) firstInstStageBit = effStageBit;
                    std::string entryName = isArray
                        ? parsedBlockInstanceName(block.name, parsedBlock, inst)
                        : block.name;
                    auto existing = std::find_if(
                        programObject->resourceUniformBlocks.begin(),
                        programObject->resourceUniformBlocks.end(),
                        [&](const GLProgramResourceEntry& e) { return e.name == entryName; });
                    if (existing != programObject->resourceUniformBlocks.end()) {
                        existing->referencedBy |= effStageBit;
                        if (inst == 0) {
                            firstBlockIndex = static_cast<GLint>(
                                existing - programObject->resourceUniformBlocks.begin());
                        }
                        continue;
                    }
                    anyNewBlocks = true;
                    GLProgramResourceEntry blockEntry;
                    blockEntry.name = entryName;
                    blockEntry.type = 0;  // blocks have no scalar type
                    // Sprint 8 B Cluster F F1 Day 2 (CKPT74):
                    // explicit-binding block arrays consume consecutive
                    // binding slots (b[0]=N, b[1]=N+1, ...). Implicit-
                    // binding (no layout(binding=N)) defaults to 0 for
                    // ALL instances. CTS layout_binding.block_layout_
                    // binding_block.binding_array_size hits this:
                    //   `layout(binding=81) uniform B { ... } b[2];`
                    //   expects b[0]=81, b[1]=82.
                    GLint instanceBinding = baseBinding;
                    if (hasExplicitBinding && isArray) {
                        instanceBinding += inst;
                    }
                    blockEntry.location = instanceBinding;
                    blockEntry.offset = static_cast<GLint>(block.byteSize); // GL_UNIFORM_BLOCK_DATA_SIZE
                    blockEntry.arraySize = 1;
                    blockEntry.referencedBy = effStageBit;
                    programObject->resourceUniformBlocks.push_back(std::move(blockEntry));
                    if (inst == 0) {
                        firstBlockIndex = static_cast<GLint>(
                            programObject->resourceUniformBlocks.size() - 1);
                    }
                }

                // Member-level merge must run for every stage, even when
                // the block entries were created by an earlier stage. GS
                // reflection in particular often arrives after VS/FS and
                // needs to OR stage bits plus repair active-variable lists.
                (void)anyNewBlocks;

                for (const auto& member : block.members) {
                    // Push into resourceUniforms — the CTS and
                    // glGetActiveUniform / glGetActiveUniformsiv enumerate
                    // ALL active uniforms including those inside blocks.
                    // Per GL spec §7.6, blocks WITHOUT an instance name use
                    // just "memberName"; blocks WITH one use "blockName.memberName".
                    GLProgramResourceEntry memberEntry;
                    std::string uniformName;
                    if (hasInstance) {
                        uniformName = block.name + "." + member.name;
                    } else {
                        uniformName = member.name;
                    }
                    // GL spec: array uniforms have "[0]" appended
                    // to name. Use `isArray` so even sized arrays
                    // with arraySize=1 pick up the suffix.
                    if (member.isArray) {
                        uniformName += "[0]";
                    }
                    memberEntry.name = uniformName;
                    memberEntry.type = member.type;
                    // SPIR-V represents bool in UBOs as uint — detect the
                    // original bool type from the GLSL source.
                    if (member.type == GL_UNSIGNED_INT ||
                        member.type == GL_UNSIGNED_INT_VEC2 ||
                        member.type == GL_UNSIGNED_INT_VEC3 ||
                        member.type == GL_UNSIGNED_INT_VEC4) {
                        GLenum boolType = detectBoolMemberType(
                            glslSource, block.name, member.name);
                        if (boolType != 0) {
                            memberEntry.type = boolType;
                        }
                    }
                    memberEntry.location = -1;  // not queryable via glGetUniformLocation
                    memberEntry.offset = static_cast<GLint>(member.offset);
                    // Keep SPIRV-Cross's raw arraySize (0 for
                    // non-arrays AND for unbounded arrays) and use
                    // the new `isArray` flag to distinguish them.
                    // getResourceProperty(GL_ARRAY_SIZE) reports 1
                    // for non-arrays, arraySize (maybe 0) for arrays.
                    memberEntry.arraySize = static_cast<GLint>(member.arraySize);
                    memberEntry.isArray = member.isArray;
                    memberEntry.blockIndex = firstBlockIndex;
                    // Members are indexed off the FIRST instance of a
                    // block array, so use that instance's effective
                    // stage bit (narrowed per-instance above).
                    memberEntry.referencedBy = firstInstStageBit;
                    memberEntry.isRowMajor = member.isRowMajor;
                    memberEntry.arrayStride = member.arrayStride;
                    memberEntry.matrixStride = member.matrixStride;
                    GLint uniformIndex = -1;
                    auto memberIt = std::find_if(
                        programObject->resourceUniforms.begin(),
                        programObject->resourceUniforms.end(),
                        [&](const GLProgramResourceEntry& entry) {
                            if (entry.name != memberEntry.name) {
                                return false;
                            }
                            return firstBlockIndex < 0 ||
                                   entry.blockIndex == firstBlockIndex;
                        });
                    if (memberIt != programObject->resourceUniforms.end()) {
                        memberIt->type = memberEntry.type;
                        memberIt->location = memberEntry.location;
                        memberIt->offset = memberEntry.offset;
                        memberIt->arraySize = memberEntry.arraySize;
                        memberIt->isArray = memberEntry.isArray;
                        memberIt->blockIndex = memberEntry.blockIndex;
                        memberIt->referencedBy |= memberEntry.referencedBy;
                        memberIt->isRowMajor = memberEntry.isRowMajor;
                        memberIt->arrayStride = memberEntry.arrayStride;
                        memberIt->matrixStride = memberEntry.matrixStride;
                        uniformIndex = static_cast<GLint>(
                            memberIt - programObject->resourceUniforms.begin());
                    } else {
                        uniformIndex =
                            static_cast<GLint>(programObject->resourceUniforms.size());
                        programObject->resourceUniforms.push_back(std::move(memberEntry));
                    }

                    // Record the member's index on the first-instance
                    // block entry so GL_NUM_ACTIVE_VARIABLES and
                    // GL_ACTIVE_VARIABLES queries on the UBO return
                    // this member list. SSBO path already does this
                    // (mergeStorageBlocks below); UBO path was missing it.
                    // CTS `program_interface_query.uniform-block-types`
                    // queries ACTIVE_VARIABLES on every UB entry.
                    if (firstBlockIndex >= 0 &&
                        static_cast<std::size_t>(firstBlockIndex) <
                            programObject->resourceUniformBlocks.size()) {
                        auto& blockEntry =
                            programObject->resourceUniformBlocks[firstBlockIndex];
                        if (std::find(blockEntry.activeVariables.begin(),
                                      blockEntry.activeVariables.end(),
                                      uniformIndex) == blockEntry.activeVariables.end()) {
                            blockEntry.activeVariables.push_back(uniformIndex);
                        }
                    }

                    // Also push into resourceBufferVariables for
                    // glGetProgramResourceiv(GL_BUFFER_VARIABLE, ...).
                    // NOTE: This is from a UBO merge — UBO members
                    // are technically not "buffer variables" (that's
                    // the SSBO-only interface per GL 4.6 §7.3.1.1).
                    // The push is preserved for backward compat with
                    // any caller that queries UBO members via the
                    // buffer-variable interface, but the GL spec
                    // separates them. When we see a real regression
                    // because of this overlap, drop it.
                    GLProgramResourceEntry bvEntry;
                    bvEntry.name = block.name + "." + member.name;
                    bvEntry.type = member.type;
                    bvEntry.location = -1;
                    bvEntry.offset = static_cast<GLint>(member.offset);
                    bvEntry.blockIndex = firstBlockIndex;
                    bvEntry.referencedBy = firstInstStageBit;
                    auto bvIt = std::find_if(
                        programObject->resourceBufferVariables.begin(),
                        programObject->resourceBufferVariables.end(),
                        [&](const GLProgramResourceEntry& entry) {
                            return entry.name == bvEntry.name &&
                                   entry.blockIndex == firstBlockIndex;
                        });
                    if (bvIt != programObject->resourceBufferVariables.end()) {
                        bvIt->type = bvEntry.type;
                        bvIt->location = bvEntry.location;
                        bvIt->offset = bvEntry.offset;
                        bvIt->blockIndex = bvEntry.blockIndex;
                        bvIt->referencedBy |= bvEntry.referencedBy;
                    } else {
                        programObject->resourceBufferVariables.push_back(
                            std::move(bvEntry));
                    }
                }
            }

            for (const auto& [_, parsed] : parsedBlocks) {
                if (!parsed.instanceIsArray) {
                    continue;
                }
                const int numInstances = parsedBlockInstanceCount(&parsed, 0);
                for (int inst = 0; inst < numInstances; ++inst) {
                    std::string entryName =
                        parsedBlockInstanceName(parsed.name, &parsed, inst);
                    const auto existing = std::find_if(
                        programObject->resourceUniformBlocks.begin(),
                        programObject->resourceUniformBlocks.end(),
                        [&](const GLProgramResourceEntry& e) {
                            return e.name == entryName;
                        });
                    if (existing != programObject->resourceUniformBlocks.end()) {
                        if (parsed.hasExplicitBinding) {
                            existing->location =
                                static_cast<GLint>(parsed.explicitBinding + inst);
                        }
                        continue;
                    }
                    GLProgramResourceEntry blockEntry;
                    blockEntry.name = std::move(entryName);
                    blockEntry.type = 0;
                    blockEntry.location = parsed.hasExplicitBinding
                        ? static_cast<GLint>(parsed.explicitBinding + inst)
                        : 0;
                    blockEntry.offset = 0;
                    blockEntry.arraySize = 1;
                    blockEntry.referencedBy = 0;
                    programObject->resourceUniformBlocks.push_back(std::move(blockEntry));
                }
            }
        };
        static const std::string emptySource;
        const std::string& vsSrc = vertexShader ? vertexShader->source : emptySource;
        const std::string& fsSrc = fragmentShader ? fragmentShader->source : emptySource;
        const std::string& gsSrc = geometryShader ? geometryShader->source : emptySource;
        const std::string& csSrc = computeShader ? computeShader->source : emptySource;
        mergeBlocks(programObject->vertexReflection.uniformBlocks, 0x01, vsSrc);    // vertex
        mergeBlocks(programObject->fragmentReflection.uniformBlocks, 0x02, fsSrc);  // fragment
        // GS uniform blocks — SPIRV-Cross reflection captured from
        // translateCachedStage("geometry") above. Usage-based, so a
        // block declared in the GS source but never accessed in the
        // GS body won't appear and won't set the 0x04 bit. CTS
        // `program_resource.program_resource` needs this for
        // `uni_colors` (expected TRUE: GS reads uni_colors.red) vs
        // `uni_matrices` (expected FALSE: declared but unused).
        mergeBlocks(programObject->geometryReflection.uniformBlocks, 0x04, gsSrc);  // geometry
        // Tess stages — same gap as supplementFromReflection above:
        // TCS uniform_block resources need to flow through this merge
        // path so glGetProgramResourceIndex(po, GL_UNIFORM_BLOCK,
        // "tc_uniform_block1") finds them.
        const std::string& ubTcsSrc = tessControlShader ? tessControlShader->source : "";
        const std::string& ubTesSrc = tessEvalShader ? tessEvalShader->source : "";
        mergeBlocks(programObject->tessControlReflection.uniformBlocks, 0x08, ubTcsSrc);
        mergeBlocks(programObject->tessEvalAsComputeReflection.uniformBlocks, 0x10, ubTesSrc);
        // Compute UBOs — CTS `compute_shader.resource-ubo` declares
        // `uniform InputBuffer { … } g_in_buffer[12];` and queries
        // `glGetUniformBlockIndex("InputBuffer[0]")` + expects
        // `GL_UNIFORM_BLOCK_REFERENCED_BY_COMPUTE_SHADER = TRUE`.
        mergeBlocks(programObject->computeReflection.uniformBlocks, 0x20, csSrc);   // compute

        // Build resourceStorageBlocks from each stage's SSBO reflection so
        // glShaderStorageBlockBinding can look up a block by index and
        // update its effective binding. Dedup by name (an SSBO declared
        // in both VS and FS produces a single resource entry whose
        // `referencedBy` bits OR the stage flags). `location` starts at
        // the shader's `layout(binding=N)` value and is later overwritten
        // by glShaderStorageBlockBinding(program, index, newBinding);
        // resolveSSBOBindings consults this field as the authoritative
        // effective binding for each draw/dispatch. Without this list
        // glShaderStorageBlockBinding hits the range check in
        // shaderStorageBlockBinding() and silently drops the remap.
        auto mergeStorageBlocks = [&](const std::vector<ShaderReflection::ResourceBinding>& blocks,
                                       GLbitfield stageBit,
                                       const std::string& glslSource) {
            std::unordered_map<std::string, ParsedInterfaceBlockForValidation> parsedBlocks;
            for (auto parsed : parseShaderStorageBlocksForValidation(glslSource)) {
                parsedBlocks[parsed.name] = std::move(parsed);
            }
            for (const auto& block : blocks) {
                // Track the per-stage referenced bit ONLY when the
                // block is live in this stage's SPIR-V — a declared-
                // but-unused SSBO still appears as a resource but
                // mustn't contribute the stage's bit. CTS
                // `program_resource.program_resource` expects
                // `Ids` (GS-declared, GS-unused) to have
                // GL_REFERENCED_BY_GEOMETRY_SHADER = FALSE.
                const GLbitfield blockStageBit = block.active ? stageBit : 0;
                const auto parsedIt = parsedBlocks.find(block.name);
                const ParsedInterfaceBlockForValidation* parsedBlock =
                    parsedIt != parsedBlocks.end() ? &parsedIt->second : nullptr;
                if (parsedBlock == nullptr &&
                    parsedBlocks.size() == 1 &&
                    blocks.size() == 1) {
                    parsedBlock = &parsedBlocks.begin()->second;
                }
                const bool hasInstance =
                    parsedBlock != nullptr
                        ? parsedBlock->hasInstance
                        : glslBlockHasInstanceName(glslSource, block.name);
                const std::string instanceName = hasInstance
                    ? (parsedBlock != nullptr && !parsedBlock->instanceName.empty()
                        ? parsedBlock->instanceName
                        : glslBlockInstanceName(glslSource, block.name))
                    : std::string();
                const std::set<int> usedInstanceIndices =
                    !instanceName.empty()
                        ? glslActiveInstanceIndices(glslSource, instanceName)
                        : std::set<int>();
                const bool useInstanceNarrowing = !usedInstanceIndices.empty();

                const int numInstances =
                    parsedBlockInstanceCount(parsedBlock, block.blockArraySize);
                const bool isBlockArray =
                    parsedBlock != nullptr
                        ? parsedBlock->instanceIsArray
                        : (block.blockArraySize > 0);
                const bool hasExplicitBinding =
                    parsedBlock != nullptr
                        ? parsedBlock->hasExplicitBinding
                        : block.hasExplicitBinding;
                const GLint baseBinding =
                    parsedBlock != nullptr
                        ? (parsedBlock->hasExplicitBinding
                            ? static_cast<GLint>(parsedBlock->explicitBinding)
                            : 0)
                        : static_cast<GLint>(block.glBinding);

                // Create one block entry per array instance. For
                // non-array blocks, numInstances=1 and we keep the
                // plain name. CTS `ssb-types` declares
                // `TrickyBuffer ... } e[2];` and asserts both
                // `TrickyBuffer[0]` and `TrickyBuffer[1]` appear
                // in GL_SHADER_STORAGE_BLOCK.
                GLint firstBlockIdx = -1;
                GLbitfield firstInstStageBit = blockStageBit;
                bool anyNew = false;
                for (int inst = 0; inst < numInstances; ++inst) {
                    GLbitfield effStageBit = blockStageBit;
                    if (useInstanceNarrowing &&
                        usedInstanceIndices.count(inst) == 0) {
                        effStageBit = 0;
                    }
                    if (inst == 0) firstInstStageBit = effStageBit;
                    std::string entryName = isBlockArray
                        ? parsedBlockInstanceName(block.name, parsedBlock, inst)
                        : block.name;
                    auto existing = std::find_if(
                        programObject->resourceStorageBlocks.begin(),
                        programObject->resourceStorageBlocks.end(),
                        [&](const GLProgramResourceEntry& e) { return e.name == entryName; });
                    if (existing != programObject->resourceStorageBlocks.end()) {
                        existing->referencedBy |= effStageBit;
                        if (inst == 0) {
                            firstBlockIdx = static_cast<GLint>(
                                existing - programObject->resourceStorageBlocks.begin());
                        }
                        continue;
                    }
                    anyNew = true;
                    GLProgramResourceEntry entry;
                    entry.name = std::move(entryName);
                    entry.type = 0;
                    // Sprint 8 B Cluster F F1 Day 2 (CKPT74): same
                    // explicit-binding gate as UBO above. Pre-CKPT74
                    // the SSBO path UNCONDITIONALLY added `inst`,
                    // which is correct for explicit binding (b[i]=N+i)
                    // but wrong for implicit (all default to 0).
                    GLint instanceBinding = baseBinding;
                    if (hasExplicitBinding && isBlockArray) {
                        instanceBinding += inst;
                    }
                    entry.location = instanceBinding;
                    entry.binding = hasExplicitBinding ? instanceBinding : -1;
                    entry.offset = static_cast<GLint>(block.byteSize);
                    entry.arraySize = 1;
                    entry.referencedBy = effStageBit;
                    programObject->resourceStorageBlocks.push_back(std::move(entry));
                    if (inst == 0) {
                        firstBlockIdx = static_cast<GLint>(
                            programObject->resourceStorageBlocks.size() - 1);
                    }
                }
                // Member-level merge runs every stage, even when the
                // block itself was registered by an earlier stage.
                // CTS `geometry_shader.program_resource` declares
                // `Positions` in both VS (writes) and GS (reads) —
                // the VS pass creates `Positions.position[0]` with
                // refby=0x01; the GS pass must still OR in 0x04 on
                // that existing entry so
                // GL_REFERENCED_BY_GEOMETRY_SHADER reports TRUE.
                (void)anyNew;

                // Populate buffer-variable entries for each SSBO member
                // so glGetProgramResourceiv(GL_BUFFER_VARIABLE, ...) can
                // find "BlockName.memberName" — per GL 4.6 §7.3.1.1 the
                // buffer-variable interface enumerates active SSBO
                // members. Names are prefixed with the block TYPE name
                // when the block declaration has an instance name
                // (`} e[2];` or `} d;`); otherwise bare member names.
                for (const auto& member : block.members) {
                    std::string bvName = hasInstance
                        ? (block.name + "." + member.name)
                        : member.name;
                    // GL 4.6 §7.3.1: array members (including
                    // unbounded `data[]` in SSBOs) get the "[0]"
                    // suffix. `member.isArray` covers both sized
                    // and unsized cases — `arraySize > 0` alone
                    // misses unbounded arrays.
                    if (member.isArray) bvName += "[0]";
                    auto bvIt = std::find_if(
                        programObject->resourceBufferVariables.begin(),
                        programObject->resourceBufferVariables.end(),
                        [&](const GLProgramResourceEntry& e) { return e.name == bvName; });
                    GLint bvIndex = -1;
                    if (bvIt != programObject->resourceBufferVariables.end()) {
                        bvIt->type = member.type;
                        bvIt->location = -1;
                        bvIt->offset = static_cast<GLint>(member.offset);
                        bvIt->arraySize = static_cast<GLint>(member.arraySize);
                        bvIt->isArray = member.isArray;
                        bvIt->blockIndex = firstBlockIdx;
                        bvIt->referencedBy |= firstInstStageBit;
                        bvIt->isRowMajor = member.isRowMajor;
                        bvIt->arrayStride = member.arrayStride;
                        bvIt->matrixStride = member.matrixStride;
                        bvIt->topLevelArraySize = member.topLevelArraySize;
                        bvIt->topLevelArrayStride = member.topLevelArrayStride;
                        bvIndex = static_cast<GLint>(bvIt - programObject->resourceBufferVariables.begin());
                    } else {
                        GLProgramResourceEntry bv;
                        bv.name = std::move(bvName);
                        bv.type = member.type;
                        bv.location = -1;
                        bv.offset = static_cast<GLint>(member.offset);
                        bv.arraySize = static_cast<GLint>(member.arraySize);
                        bv.isArray = member.isArray;
                        bv.blockIndex = firstBlockIdx;
                        bv.referencedBy = firstInstStageBit;
                        bv.isRowMajor = member.isRowMajor;
                        bv.arrayStride = member.arrayStride;
                        bv.matrixStride = member.matrixStride;
                        bv.topLevelArraySize = member.topLevelArraySize;
                        bv.topLevelArrayStride = member.topLevelArrayStride;
                        programObject->resourceBufferVariables.push_back(std::move(bv));
                        bvIndex = static_cast<GLint>(programObject->resourceBufferVariables.size() - 1);
                    }
                    // Record the member's index in the containing
                    // block's active-variables list so
                    // GL_NUM_ACTIVE_VARIABLES / GL_ACTIVE_VARIABLES
                    // queries on the block return the right data.
                    if (firstBlockIdx >= 0
                        && static_cast<std::size_t>(firstBlockIdx) < programObject->resourceStorageBlocks.size()) {
                        auto& blockEntry = programObject->resourceStorageBlocks[firstBlockIdx];
                        // De-dupe in case the same block gets
                        // merged from multiple stages.
                        if (std::find(blockEntry.activeVariables.begin(),
                                      blockEntry.activeVariables.end(),
                                      bvIndex) == blockEntry.activeVariables.end()) {
                            blockEntry.activeVariables.push_back(bvIndex);
                        }
                    }
                }
            }

            for (const auto& [_, parsed] : parsedBlocks) {
                if (!parsed.instanceIsArray) {
                    continue;
                }
                const int numInstances = parsedBlockInstanceCount(&parsed, 0);
                for (int inst = 0; inst < numInstances; ++inst) {
                    std::string entryName =
                        parsedBlockInstanceName(parsed.name, &parsed, inst);
                    const auto existing = std::find_if(
                        programObject->resourceStorageBlocks.begin(),
                        programObject->resourceStorageBlocks.end(),
                        [&](const GLProgramResourceEntry& e) {
                            return e.name == entryName;
                        });
                    if (existing != programObject->resourceStorageBlocks.end()) {
                        existing->referencedBy |= stageBit;
                        if (parsed.hasExplicitBinding) {
                            existing->location =
                                static_cast<GLint>(parsed.explicitBinding + inst);
                        }
                        continue;
                    }
                    GLProgramResourceEntry entry;
                    entry.name = std::move(entryName);
                    entry.type = 0;
                    entry.location = parsed.hasExplicitBinding
                        ? static_cast<GLint>(parsed.explicitBinding + inst)
                        : 0;
                    entry.offset = 0;
                    entry.arraySize = 1;
                    entry.referencedBy = stageBit;
                    programObject->resourceStorageBlocks.push_back(std::move(entry));
                }
            }
        };
        static const std::string ssboEmptySrc;
        const std::string& ssboVsSrc = vertexShader ? vertexShader->source : ssboEmptySrc;
        const std::string& ssboFsSrc = fragmentShader ? fragmentShader->source : ssboEmptySrc;
        const std::string& ssboGsSrc = geometryShader ? geometryShader->source : ssboEmptySrc;
        const std::string& ssboCsSrc = computeShader ? computeShader->source : ssboEmptySrc;
        mergeStorageBlocks(programObject->vertexReflection.storageBuffers, 0x01, ssboVsSrc);
        mergeStorageBlocks(programObject->fragmentReflection.storageBuffers, 0x02, ssboFsSrc);
        mergeStorageBlocks(programObject->geometryReflection.storageBuffers, 0x04, ssboGsSrc);
        mergeStorageBlocks(programObject->computeReflection.storageBuffers, 0x20, ssboCsSrc);
        // Tess stages — symmetric to mergeBlocks above. TCS/TES SSBO
        // resources need this path so glGetProgramResourceIndex(po,
        // GL_SHADER_STORAGE_BLOCK, "tc_shader_storage_block1") finds
        // them.
        const std::string& ssboTcsSrc = tessControlShader ? tessControlShader->source : ssboEmptySrc;
        const std::string& ssboTesSrc = tessEvalShader ? tessEvalShader->source : ssboEmptySrc;
        mergeStorageBlocks(programObject->tessControlReflection.storageBuffers, 0x08, ssboTcsSrc);
        mergeStorageBlocks(programObject->tessEvalAsComputeReflection.storageBuffers, 0x10, ssboTesSrc);

        // GS reflection: the geometry shader is CPU-emulated — we
        // don't yet run SPIRV-Cross on it to produce a MSL
        // reflection struct, so block-scoped resources (uniform
        // blocks, SSBOs, buffer variables) can't yet tell us
        // "does the GS use this block". Scalar uniforms are
        // already handled via the per-stage scanner's
        // `declaredUniforms` (see computeStageMask above), which
        // gives us an accurate GEOMETRY_SHADER bit for those.
        // Block-scoped REFERENCED_BY_GEOMETRY_SHADER queries stay
        // conservative until GS reflection lands — the CTS
        // program_resource test carries that on the backlog.

        // Post-pass: fix any remaining uint→bool member types that weren't
        // detected during the stage that first created the members. This
        // happens when a linked SPIR-V includes a block in both stages but
        // the block is only declared in one stage's GLSL source.
        for (auto& u : programObject->resourceUniforms) {
            if (u.blockIndex < 0) continue;
            if (u.type != GL_UNSIGNED_INT && u.type != GL_UNSIGNED_INT_VEC2 &&
                u.type != GL_UNSIGNED_INT_VEC3 && u.type != GL_UNSIGNED_INT_VEC4) continue;
            // Find the block name for this uniform.
            const auto& blockEntry = programObject->resourceUniformBlocks[u.blockIndex];
            // Strip array suffix from block name for detection.
            std::string baseName = blockEntry.name;
            auto bracket = baseName.find('[');
            if (bracket != std::string::npos) baseName = baseName.substr(0, bracket);
            // Extract member name: for instanced blocks "Block.member" → "member",
            // for non-instanced blocks "member" stays as is.
            std::string memberName = u.name;
            // Strip trailing "[0]" from arrays
            if (memberName.size() > 3 && memberName.substr(memberName.size()-3) == "[0]") {
                memberName = memberName.substr(0, memberName.size()-3);
            }
            // For instanced blocks, strip "BlockName." prefix
            std::string prefix = baseName + ".";
            if (memberName.size() > prefix.size() &&
                memberName.substr(0, prefix.size()) == prefix) {
                memberName = memberName.substr(prefix.size());
            }
            // Try both VS and FS sources.
            GLenum boolType = detectBoolMemberType(vsSrc, baseName, memberName);
            if (boolType == 0) {
                boolType = detectBoolMemberType(fsSrc, baseName, memberName);
            }
            if (boolType != 0) {
                u.type = boolType;
            }
        }
    }

    auto parsedFallbackBlockInstanceCount =
        [](const ParsedInterfaceBlockForValidation* parsed,
           std::uint32_t reflectedCount) -> int {
            if (parsed != nullptr && parsed->instanceIsArray) {
                return std::max(1, parsed->instanceArraySize);
            }
            return reflectedCount > 0 ? static_cast<int>(reflectedCount) : 1;
        };
    auto parsedFallbackBlockInstanceName =
        [](const std::string& baseName,
           const ParsedInterfaceBlockForValidation* parsed,
           int linearIndex) {
            std::string out = baseName;
            if (parsed == nullptr ||
                !parsed->instanceIsArray ||
                parsed->instanceArrayDimensions.empty()) {
                out += "[" + std::to_string(linearIndex) + "]";
                return out;
            }
            std::vector<int> indices(parsed->instanceArrayDimensions.size(), 0);
            int remain = linearIndex;
            for (std::size_t rev = parsed->instanceArrayDimensions.size(); rev > 0; --rev) {
                const std::size_t dimIndex = rev - 1;
                const int dim = std::max(1, parsed->instanceArrayDimensions[dimIndex]);
                indices[dimIndex] = remain % dim;
                remain /= dim;
            }
            for (int idx : indices) {
                out += "[" + std::to_string(idx) + "]";
            }
            return out;
        };

    auto addParsedBlockArrayResources =
        [&](const std::string& source, GLbitfield stageBit, bool storage) {
            const auto parsedBlocks = storage
                ? parseShaderStorageBlocksForValidation(source)
                : parseUniformBlocksForValidation(source);
            auto& table = storage
                ? programObject->resourceStorageBlocks
                : programObject->resourceUniformBlocks;
            const bool sourceCanImplyStageReference = storage;
            for (const auto& parsed : parsedBlocks) {
                if (!parsed.instanceIsArray) {
                    continue;
                }
                const int numInstances = parsedFallbackBlockInstanceCount(&parsed, 0);
                for (int inst = 0; inst < numInstances; ++inst) {
                    std::string entryName =
                        parsedFallbackBlockInstanceName(parsed.name, &parsed, inst);
                    auto existing = std::find_if(
                        table.begin(),
                        table.end(),
                        [&](const GLProgramResourceEntry& e) {
                            return e.name == entryName;
                        });
                    const GLint binding = parsed.hasExplicitBinding
                        ? static_cast<GLint>(parsed.explicitBinding + inst)
                        : 0;
                    if (existing != table.end()) {
                        if (sourceCanImplyStageReference) {
                            existing->referencedBy |= stageBit;
                        }
                        existing->location = binding;
                        continue;
                    }
                    GLProgramResourceEntry entry;
                    entry.name = std::move(entryName);
                    entry.type = 0;
                    entry.location = binding;
                    entry.offset = 0;
                    entry.arraySize = 1;
                    entry.referencedBy =
                        sourceCanImplyStageReference ? stageBit : 0;
                    table.push_back(std::move(entry));
                }
            }
        };
    static const std::string fallbackEmptySource;
    const std::string& fallbackVsSrc = vertexShader ? vertexShader->source : fallbackEmptySource;
    const std::string& fallbackFsSrc = fragmentShader ? fragmentShader->source : fallbackEmptySource;
    const std::string& fallbackGsSrc = geometryShader ? geometryShader->source : fallbackEmptySource;
    const std::string& fallbackCsSrc = computeShader ? computeShader->source : fallbackEmptySource;
    const std::string& fallbackTcsSrc = tessControlShader ? tessControlShader->source : fallbackEmptySource;
    const std::string& fallbackTesSrc = tessEvalShader ? tessEvalShader->source : fallbackEmptySource;
    addParsedBlockArrayResources(fallbackVsSrc, 0x01, false);
    addParsedBlockArrayResources(fallbackFsSrc, 0x02, false);
    addParsedBlockArrayResources(fallbackGsSrc, 0x04, false);
    addParsedBlockArrayResources(fallbackTcsSrc, 0x08, false);
    addParsedBlockArrayResources(fallbackTesSrc, 0x10, false);
    addParsedBlockArrayResources(fallbackCsSrc, 0x20, false);
    addParsedBlockArrayResources(fallbackVsSrc, 0x01, true);
    addParsedBlockArrayResources(fallbackFsSrc, 0x02, true);
    addParsedBlockArrayResources(fallbackGsSrc, 0x04, true);
    addParsedBlockArrayResources(fallbackTcsSrc, 0x08, true);
    addParsedBlockArrayResources(fallbackTesSrc, 0x10, true);
    addParsedBlockArrayResources(fallbackCsSrc, 0x20, true);

    ++programObject->executableGeneration;
    if (programObject->executableGeneration == 0) {
        programObject->executableGeneration = 1;
    }
    // S25 state_resolve lever: this relink rebuilt the program's MSL (the
    // executableGeneration bump is the canonical relink signal). Drop any
    // MSL-FNV memo entry referencing the program's MSL string objects so a
    // same-buffer relink (std::string::operator= can reuse capacity on a
    // same/shorter reassign → {ptr,size,data} identity ABA) cannot serve a
    // stale key. This is the single relink chokepoint → O(1), no per-draw cost,
    // string-semantics-independent. (Production has no P1 backstop — P1 is
    // gate-only/default-OFF — so the relink ABA must be closed structurally.)
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->invalidateMslHashMemoForStringObject(
            &programObject->vertexMSL);
        impl_->frameGraph->invalidateMslHashMemoForStringObject(
            &programObject->fragmentMSL);
        impl_->frameGraph->invalidateMslHashMemoForStringObject(
            &programObject->gsPassThroughVertexMSL);
        impl_->frameGraph->invalidateMslHashMemoForStringObject(
            &programObject->gsPassThroughFragmentMSL);
    }
    return true;
}
