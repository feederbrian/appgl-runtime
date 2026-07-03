// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext compute-dispatch and barrier method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_COMPUTE_MEMORY_BARRIER)
bool GLContext::memoryBarrier(GLbitfield barriers) {
    // All valid GL 4.2/4.3/4.4 barrier bits. 4.4 added
    // `GL_CLIENT_MAPPED_BUFFER_BARRIER_BIT` (ARB_buffer_storage) —
    // without it here, `buffer_storage.map_persistent_read_pixels`
    // raises INVALID_VALUE on its post-readback barrier.
    constexpr GLbitfield kValidBarrierBits =
        GL_VERTEX_ATTRIB_ARRAY_BARRIER_BIT |
        GL_ELEMENT_ARRAY_BARRIER_BIT |
        GL_UNIFORM_BARRIER_BIT |
        GL_TEXTURE_FETCH_BARRIER_BIT |
        GL_SHADER_IMAGE_ACCESS_BARRIER_BIT |
        GL_COMMAND_BARRIER_BIT |
        GL_PIXEL_BUFFER_BARRIER_BIT |
        GL_TEXTURE_UPDATE_BARRIER_BIT |
        GL_BUFFER_UPDATE_BARRIER_BIT |
        GL_FRAMEBUFFER_BARRIER_BIT |
        GL_TRANSFORM_FEEDBACK_BARRIER_BIT |
        GL_ATOMIC_COUNTER_BARRIER_BIT |
        GL_SHADER_STORAGE_BARRIER_BIT |
        GL_CLIENT_MAPPED_BUFFER_BARRIER_BIT;

    if (barriers != GL_ALL_BARRIER_BITS && (barriers & ~kValidBarrierBits) != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }

    // For CPU-visible barrier bits (BUFFER_UPDATE | TEXTURE_UPDATE |
    // PIXEL_BUFFER | CLIENT_MAPPED_BUFFER) we need to commit + wait so
    // subsequent glMapBuffer* / glGetTexImage / glReadPixels calls see
    // the GPU writes. Image/texture barriers also need a wait when image
    // atomics are emulated through sidecar buffers, because the sidecar
    // contents must be copied back into the texture before later image,
    // texture, or CPU reads observe them. Metal handles ordinary GPU-to-GPU
    // ordering implicitly, but there's no implicit sync to CPU, and SSBO
    // writes via a VS under GL_RASTERIZER_DISCARD (CTS
    // shader_storage_buffer_object.*-vs) are only readable after the draw's
    // command buffer completes.
    constexpr GLbitfield kCpuVisibleBarriers =
        GL_BUFFER_UPDATE_BARRIER_BIT |
        GL_TEXTURE_UPDATE_BARRIER_BIT |
        GL_PIXEL_BUFFER_BARRIER_BIT |
        GL_CLIENT_MAPPED_BUFFER_BARRIER_BIT;
    constexpr GLbitfield kImageAtomicSidecarBarriers =
        GL_SHADER_IMAGE_ACCESS_BARRIER_BIT |
        GL_TEXTURE_FETCH_BARRIER_BIT |
        GL_TEXTURE_UPDATE_BARRIER_BIT |
        GL_FRAMEBUFFER_BARRIER_BIT;
    const bool requiresCpuSync =
        (barriers == GL_ALL_BARRIER_BITS) ||
        (barriers & (kCpuVisibleBarriers | kImageAtomicSidecarBarriers)) != 0;
    if (requiresCpuSync && impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushForReadback();
        impl_->flushTextureImageAtomicSidecars();
        impl_->flushImageBinding3DLayerSidecars();
    }
    // GPU-to-GPU barriers (UNIFORM / TEXTURE_FETCH / SHADER_STORAGE / etc.)
    // are implicit on Metal's command queue — same-queue ordering is
    // preserved so the next pipeline's reads see the previous pipeline's
    // writes without an explicit fence.
    return true;
}

#elif defined(APPGL_GLCONTEXT_COMPUTE_DISPATCH_DIRECT)
bool GLContext::dispatchCompute(GLuint num_groups_x, GLuint num_groups_y, GLuint num_groups_z) {
    constexpr GLuint kMaxWorkGroups = 65535;

    if (num_groups_x == 0 || num_groups_y == 0 || num_groups_z == 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (num_groups_x > kMaxWorkGroups || num_groups_y > kMaxWorkGroups || num_groups_z > kMaxWorkGroups) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // Resolve the currently-bound program. GL 4.6 §17.1 requires
    // GL_INVALID_OPERATION when there's no active program OR when
    // the active program doesn't contain a compute shader. We detect
    // both by checking whether `metalComputePipelineState` is non-null
    // — linkProgram only populates it for programs with ProgramKind
    // ::Compute. This surfaces the compute-shader.api-no-active-program
    // / api-program negative tests as spec-correct failures.
    //
    // CKPT119: when the current program is 0 but a program pipeline is
    // bound with a compute stage (glUseProgramStages(...,
    // GL_COMPUTE_SHADER_BIT, prog)), use the pipeline's compute slot.
    // CTS shader_image_size.basic-nonMS-cs-* relies on this path.
    GLuint progName = impl_->state->currentProgram();
    GLProgramObject* programObject = progName == 0 ? nullptr
        : impl_->objects->programs().get(progName);
    if (programObject == nullptr || !programObject->linked
        || programObject->metalComputePipelineState == nullptr) {
        const GLuint pipelineName = impl_->state->currentProgramPipeline();
        if (pipelineName != 0) {
            GLProgramPipelineObject* ppo =
                impl_->objects->programPipelines().get(pipelineName);
            if (ppo != nullptr && ppo->computeProgram != 0) {
                GLProgramObject* csProg =
                    impl_->objects->programs().get(ppo->computeProgram);
                if (csProg != nullptr && csProg->linked
                    && (csProg->metalComputePipelineState != nullptr ||
                        csProg->ssboStdLayoutRawCopyFallback)) {
                    programObject = csProg;
                    progName = ppo->computeProgram;
                }
            }
        }
        const bool hasComputePipeline =
            programObject != nullptr && programObject->linked &&
            programObject->metalComputePipelineState != nullptr;
        const bool hasRawCopyFallback =
            programObject != nullptr && programObject->linked &&
            programObject->ssboStdLayoutRawCopyFallback;
        if (!hasComputePipeline && !hasRawCopyFallback) {
            pushError(GL_INVALID_OPERATION);
            return false;
        }
    }
    // GL 4.6 §2.3.3 — conditional render predicate. Skipped dispatches
    // do not advance query counters or update shader-visible storage.
    if (impl_->shouldSkipDrawForConditionalRender()) {
        return true;
    }
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::Dispatch);

    // GL 4.6 §22.4 — credit COMPUTE_SHADER_INVOCATIONS for every
    // active query by the total workgroup-invocation count
    // (groups × local-size). Done before dispatch so the counter
    // advances even if pipeline encode fails.
    impl_->objects->queries().forEach([&](GLuint /*id*/, GLQueryObject& q) {
        if (!q.active || q.target != GL_COMPUTE_SHADER_INVOCATIONS) return;
        const GLuint64 local = static_cast<GLuint64>(programObject->computeLocalSizeX) *
                               static_cast<GLuint64>(programObject->computeLocalSizeY) *
                               static_cast<GLuint64>(programObject->computeLocalSizeZ);
        const GLuint64 groups = static_cast<GLuint64>(num_groups_x) *
                                static_cast<GLuint64>(num_groups_y) *
                                static_cast<GLuint64>(num_groups_z);
        q.result += groups * (local == 0 ? 1 : local);
    });

    if (programObject->metalComputePipelineState == nullptr &&
        programObject->ssboStdLayoutRawCopyFallback) {
        return impl_->runSSBOStdLayoutRawCopyFallback();
    }
    if (impl_->frameGraph == nullptr) {
        // Pipeline was built but the frame graph is torn down — no
        // dispatch is possible. Treat as a silent no-op to avoid
        // spurious errors during teardown paths.
        return true;
    }

    ComputeDispatchInfo info;
    info.metalComputePipelineState = programObject->metalComputePipelineState;
    info.metalComputeFunction = programObject->metalComputeFunction;
    info.needsSSBOSizeBuffer =
        programObject->computeMSL.find("spvBufferSizeConstants") != std::string::npos;
    info.groupsX = num_groups_x;
    info.groupsY = num_groups_y;
    info.groupsZ = num_groups_z;
    info.localX = programObject->computeLocalSizeX;
    info.localY = programObject->computeLocalSizeY;
    info.localZ = programObject->computeLocalSizeZ;

    struct Fp64ComputeSidecarSync {
        GLBufferObject* buffer = nullptr;
        const ShaderReflection::ResourceBinding* binding = nullptr;
        GLBufferObject::Fp64TransportSidecar* sidecar = nullptr;
    };
    std::vector<Fp64ComputeSidecarSync> fp64SsboSidecars;
    GLContext::Impl::GpuResourceReadSet computeReads;
    GLContext::Impl::GpuResourceWriteSet computeWrites;

    // Pack default uniforms (bare GL uniforms in the _DefaultUniforms
    // block) for the compute stage. Mirrors the graphics-stage path:
    // lazy layout compute + per-dispatch rebuild of the byte buffer
    // from uniformValues. Without this, location-based glUniform*
    // updates for a compute program never reach the MSL kernel.
    // KHR-GL46.explicit_uniform_location.* with a compute variant
    // specifically relies on this.
    thread_local std::vector<std::uint8_t> computeUniformScratch;
    if (!programObject->uniformLayoutComputed
        || programObject->computeUniformLayout.empty()) {
        // Only (re)build the layout vector when we haven't seen this
        // program before OR the compute-side layout is still empty on
        // a program that previously had graphics stages computed.
        computeStageUniformLayout(programObject->computeUniformLayout,
            programObject->computeReflection, programObject->uniforms);
        programObject->uniformLayoutComputed = true;
    }
    if (pushSynthesizedMatrixUniforms(*programObject, impl_->matrixState)) {
        programObject->markUniformsDirty();
    }
    buildStageUniformBuffer(computeUniformScratch,
        programObject->computeReflection, programObject->uniformValues,
        programObject->computeUniformLayout);
    if (!computeUniformScratch.empty()) {
        info.computeUniformData = computeUniformScratch.data();
        info.computeUniformSize = computeUniformScratch.size();
        if (reflectionNeedsFp64BindingShim(programObject->computeReflection) &&
            defaultUniformBlockContainsFp64(programObject->computeReflection)) {
            ExtensionContext extensionContext(*this);
            extensions::fp64::recordDoubleUniformBacking(
                extensionContext, info.computeUniformSize);
        }
    }

    // Resolve shader-storage buffer bindings. For each SSBO the shader
    // declares, look up whatever buffer the app has bound to
    // GL_SHADER_STORAGE_BUFFER at its layout(binding=N) slot via
    // glBindBufferBase / glBindBufferRange, and forward the Metal
    // buffer + offset into the dispatch info. SSBOs with no binding
    // are simply omitted — Metal's unbound-slot behaviour is undefined
    // but won't crash, and the test will fail verification cleanly.
    // Sprint 17 Day 4+ BONUS-2 Phase 2-r [gpu_shader5 ssbo_array_indexing]:
    // SSBO array element iteration. SPIRV-Cross emits a GLSL SSBO array
    // (`buffer B { ... } b[N]`) as N separate `[[buffer(M)]] / [[buffer(
    // M+1)]] ... [[buffer(M+N-1)]]` slots — same shape as the UBO array
    // emit. Each element binds independently at GL slot
    // (effectiveBinding+inst) and Metal slot (ssbo.metalBinding+inst).
    // Sister to the UBO array iteration loop further below (line 29871+,
    // CKPT143 lineage) and the graphics-path resolveUBOBindings array
    // iteration (line 5111+).
    for (const auto& ssbo : programObject->computeReflection.storageBuffers) {
        // Effective binding may be remapped by glShaderStorageBlockBinding;
        // consult resourceStorageBlocks (same pattern as the graphics
        // path's resolveSSBOBindings).
        GLuint effectiveBinding = ssbo.glBinding;
        for (const auto& rb : programObject->resourceStorageBlocks) {
            if (rb.name == ssbo.name && rb.location >= 0) {
                effectiveBinding = static_cast<GLuint>(rb.location);
                break;
            }
        }
        const int numInstances = (ssbo.blockArraySize > 0)
            ? static_cast<int>(ssbo.blockArraySize) : 1;
        const bool isArray = (ssbo.blockArraySize > 0);
        for (int inst = 0; inst < numInstances; ++inst) {
            // Build the lookup name: "B" or "B[0]"/"B[1]"… so
            // glShaderStorageBlockBinding-driven binding overrides on a
            // specific element honor the resourceStorageBlocks map.
            std::string lookupName = ssbo.name;
            if (isArray) lookupName += "[" + std::to_string(inst) + "]";
            // Default per-element binding is effectiveBinding+inst
            // (consecutive slots, GL 4.6 §7.8). Override with
            // resourceStorageBlocks location if remapped.
            GLuint glBindingPoint = effectiveBinding + static_cast<GLuint>(inst);
            for (const auto& rb : programObject->resourceStorageBlocks) {
                if (rb.name == lookupName && rb.location >= 0) {
                    glBindingPoint = static_cast<GLuint>(rb.location);
                    break;
                }
            }
            const GLIndexedBufferBinding binding = impl_->state->indexedBufferBinding(
                GL_SHADER_STORAGE_BUFFER, glBindingPoint);
            if (binding.buffer == 0) continue;
            GLBufferObject* bufObj = impl_->objects->buffers().get(binding.buffer);
            if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
            computeReads.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                    binding.buffer, kProducerAll});
            computeWrites.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                     binding.buffer,
                                     kProducerComputeWrite |
                                         kProducerShaderStorageWrite});

            ComputeDispatchInfo::BufferBinding bb;
            bb.metalBuffer = bufObj->metalBuffer;
            bb.offset = static_cast<std::size_t>(binding.offset);
            if (binding.size > 0) {
                bb.size = static_cast<std::size_t>(binding.size);
            } else if (binding.offset >= 0 && bufObj->size > binding.offset) {
                bb.size = static_cast<std::size_t>(bufObj->size - binding.offset);
            }
            bb.metalSlot = ssbo.metalBinding + static_cast<std::uint32_t>(inst);
            if (resourceNeedsFp64BindingShim(programObject->computeReflection, ssbo)) {
                auto* sidecar = impl_->ensureFp64TransportSidecar(
                    *bufObj, programObject->computeReflection, ssbo,
                    static_cast<GLintptr>(binding.offset),
                    static_cast<GLsizeiptr>(bb.size));
                if (sidecar != nullptr && sidecar->metalBuffer != nullptr) {
                    bb.metalBuffer = sidecar->metalBuffer;
                    bb.offset = 0;
                    fp64SsboSidecars.push_back({bufObj, &ssbo, sidecar});
                    ExtensionContext extensionContext(*this);
                    extensions::fp64::recordDoubleSsboBacking(
                        extensionContext, bb.size);
                }
            }
            info.buffers.push_back(bb);
        }
    }

    // Resolve uniform-block bindings for the compute stage. Compute
    // shaders rarely use UBOs (the CTS compute tests almost always go
    // through SSBOs exclusively) but the path is symmetric with the
    // graphics uboBindings resolver — walk each reflected block,
    // look up the bound buffer via glBindBufferBase, forward it.
    //
    // CKPT143 (Sprint 13 Day 7): UBO array support. SPIRV-Cross emits a
    // UBO array (`uniform B { ... } b[N]`) as N separate `[[buffer(M)]]`
    // / `[[buffer(M+1)]]` … `[[buffer(M+N-1)]]` slots. CTS
    // shading_language_420pack.binding_uniform_block_array binds 14
    // separate UBOs to GL slots 2..15 and expects each shader element
    // `goku[i]` to read from the bound buffer at GL slot 2+i. Pre-fix
    // only the first element resolved; the other 13 stayed unbound and
    // returned zero, failing the per-element verification. Mirrors the
    // graphics-path resolveUBOBindings array iteration at line 5111+.
    for (const auto& ubo : programObject->computeReflection.uniformBlocks) {
        if (ubo.name == "_DefaultUniforms") continue;
        const int numInstances = (ubo.blockArraySize > 0)
            ? static_cast<int>(ubo.blockArraySize) : 1;
        const bool isArray = (ubo.blockArraySize > 0);
        for (int inst = 0; inst < numInstances; ++inst) {
            // Build the lookup name: "B" or "B[0]", "B[1]" … so
            // glUniformBlockBinding-driven binding overrides on a
            // specific element honor the resourceUniformBlocks map.
            std::string lookupName = ubo.name;
            if (isArray) {
                lookupName += "[" + std::to_string(inst) + "]";
            }
            // Default per-element binding is glBinding+inst (consecutive
            // slots, GL 4.6 §7.6.2). Override with resourceUniformBlocks
            // location if the app has called glUniformBlockBinding.
            GLuint glBindingPoint = ubo.glBinding + static_cast<GLuint>(inst);
            for (std::size_t bi = 0; bi < programObject->resourceUniformBlocks.size(); ++bi) {
                if (programObject->resourceUniformBlocks[bi].name == lookupName) {
                    GLint bp = programObject->resourceUniformBlocks[bi].location;
                    if (bp >= 0) {
                        glBindingPoint = static_cast<GLuint>(bp);
                    }
                    break;
                }
            }
            const GLIndexedBufferBinding binding = impl_->state->indexedBufferBinding(
                GL_UNIFORM_BUFFER, glBindingPoint);
            if (binding.buffer == 0) continue;
            GLBufferObject* bufObj = impl_->objects->buffers().get(binding.buffer);
            if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
            computeReads.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                    binding.buffer, kProducerAll});

            ComputeDispatchInfo::BufferBinding bb;
            bb.metalBuffer = bufObj->metalBuffer;
            bb.offset = static_cast<std::size_t>(binding.offset);
            bb.metalSlot = ubo.metalBinding + static_cast<std::uint32_t>(inst);
            bb.descriptorSet = 1;
            if (resourceNeedsFp64BindingShim(programObject->computeReflection, ubo)) {
                GLsizeiptr rangeSize = binding.size;
                if (rangeSize <= 0 && binding.offset >= 0 && bufObj->size > binding.offset) {
                    rangeSize = bufObj->size - binding.offset;
                }
                auto* sidecar = impl_->ensureFp64TransportSidecar(
                    *bufObj, programObject->computeReflection, ubo,
                    static_cast<GLintptr>(binding.offset), rangeSize);
                if (sidecar != nullptr && sidecar->metalBuffer != nullptr) {
                    bb.metalBuffer = sidecar->metalBuffer;
                    bb.offset = 0;
                    ExtensionContext extensionContext(*this);
                    extensions::fp64::recordDoubleUniformBacking(
                        extensionContext, static_cast<std::size_t>(rangeSize));
                }
            }
            info.buffers.push_back(bb);
        }
    }

    // Sprint 17 Day 4+ BONUS-2 Phase 3-r [gpu_shader5 atomic_counters_array_indexing]:
    // atomic counter buffer binding for compute. SPIRV-Cross emits AC
    // into a dedicated direct-buffer slot range. Walk the program's
    // atomic-counter buffer resource list and bind each
    // GL_ATOMIC_COUNTER_BUFFER-backed buffer at the matching Metal slot.
    // Without this binding, atomicCounter* operations execute against an
    // unbound MTLBuffer and produce undefined (typically zero) reads.
    for (const auto& ac : programObject->resourceAtomicCounterBuffers) {
        if (ac.binding < 0) continue;
        const GLuint glBinding = static_cast<GLuint>(ac.binding);
        const GLIndexedBufferBinding binding = impl_->state->indexedBufferBinding(
            GL_ATOMIC_COUNTER_BUFFER, glBinding);
        if (binding.buffer == 0) continue;
        const GLBufferObject* bufObj = impl_->objects->buffers().get(binding.buffer);
        if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
        computeReads.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                binding.buffer, kProducerAll});
        computeWrites.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                 binding.buffer,
                                 kProducerComputeWrite |
                                     kProducerAtomicCounterWrite});

        ComputeDispatchInfo::BufferBinding bb;
        bb.metalBuffer = bufObj->metalBuffer;
        bb.offset = static_cast<std::size_t>(binding.offset);
        // Atomic counters are emitted after the compute SSBO spec-floor
        // range so they cannot alias SSBOs or the high UBO slots.
        bb.metalSlot = computeAtomicCounterMetalSlot(glBinding);
        info.buffers.push_back(bb);
    }

    // Texture/sampler bindings for compute stage. Less common than
    // SSBOs but real — image-processing compute shaders sample from
    // textures. Walk each reflected sampler uniform, resolve the
    // texture unit via the shader's sampler uniform value, and bind
    // the resulting (texture, sampler) pair at the reflected slot.
    // The logic mirrors resolveSamplerBindings but targets the
    // compute slot space.
    // CKPT144 (Sprint 13 Day 8): sampler-type-aware texture target lookup
    // for compute. The pre-fix code probed GL_TEXTURE_2D first then fell
    // back to boundTextureOnUnitAny — which iterates targets in
    // {2D, 2D_ARRAY, CUBE_MAP, …, 1D, 1D_ARRAY, …} order and returns the
    // first non-zero binding. CTS shading_language_420pack.binding_samplers_
    // texture_type_{1D,1D_array,2D_array,2D_rect,3D,cube} declares the
    // sampler with a non-2D type. gluStateReset binds a default texture
    // (name 0) to every (unit, target) pair before each test, so the
    // unit always has a 2D entry. Pre-fix: a `sampler1D` lookup hit the
    // GL_TEXTURE_2D probe first and returned the default-2D texture
    // (which Metal then refused to bind to a `texture1d` slot, or
    // sampling returned zeros). Mirrors the graphics-path resolveSamplerBindings
    // sampler-type → preferredTarget mapping at line 4607+.
    auto preferredTargetForSamplerType = [](GLenum samplerGLType) -> GLenum {
        switch (samplerGLType) {
            case GL_SAMPLER_1D:
            case GL_INT_SAMPLER_1D:
            case GL_UNSIGNED_INT_SAMPLER_1D:
            case GL_SAMPLER_1D_SHADOW:
                return GL_TEXTURE_1D;
            case GL_SAMPLER_2D:
            case GL_INT_SAMPLER_2D:
            case GL_UNSIGNED_INT_SAMPLER_2D:
            case GL_SAMPLER_2D_SHADOW:
                return GL_TEXTURE_2D;
            case GL_SAMPLER_3D:
            case GL_INT_SAMPLER_3D:
            case GL_UNSIGNED_INT_SAMPLER_3D:
                return GL_TEXTURE_3D;
            case GL_SAMPLER_CUBE:
            case GL_INT_SAMPLER_CUBE:
            case GL_UNSIGNED_INT_SAMPLER_CUBE:
            case GL_SAMPLER_CUBE_SHADOW:
                return GL_TEXTURE_CUBE_MAP;
            case GL_SAMPLER_1D_ARRAY:
            case GL_INT_SAMPLER_1D_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY:
            case GL_SAMPLER_1D_ARRAY_SHADOW:
                return GL_TEXTURE_1D_ARRAY;
            case GL_SAMPLER_2D_ARRAY:
            case GL_INT_SAMPLER_2D_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY:
            case GL_SAMPLER_2D_ARRAY_SHADOW:
                return GL_TEXTURE_2D_ARRAY;
            case GL_SAMPLER_2D_RECT:
            case GL_INT_SAMPLER_2D_RECT:
            case GL_UNSIGNED_INT_SAMPLER_2D_RECT:
            case GL_SAMPLER_2D_RECT_SHADOW:
                return GL_TEXTURE_RECTANGLE;
            case GL_SAMPLER_BUFFER:
            case GL_INT_SAMPLER_BUFFER:
            case GL_UNSIGNED_INT_SAMPLER_BUFFER:
                return GL_TEXTURE_BUFFER;
            case GL_SAMPLER_CUBE_MAP_ARRAY:
            case GL_INT_SAMPLER_CUBE_MAP_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY:
            case GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW:
                return GL_TEXTURE_CUBE_MAP_ARRAY;
            case GL_SAMPLER_2D_MULTISAMPLE:
            case GL_INT_SAMPLER_2D_MULTISAMPLE:
            case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE:
                return GL_TEXTURE_2D_MULTISAMPLE;
            case GL_SAMPLER_2D_MULTISAMPLE_ARRAY:
            case GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                return GL_TEXTURE_2D_MULTISAMPLE_ARRAY;
            default:
                return 0;
        }
    };

    thread_local std::vector<std::uint32_t> msImageSampleCounts;
    msImageSampleCounts.assign(128, 1u);
    bool hasMSImageSampleCounts = false;
    ExtensionContext extensionContext(*this);
    const bool usesMSSampledSidecars =
        programObject->computeMSL.find("appgl_ms_sampled_sidecar_") != std::string::npos;
    const bool usesSparseSampledSidecars =
        programObject->computeMSL.find("appgl_sparse_sampled_sidecar_") != std::string::npos;
    const bool usesMSStorageSparseResidency =
        programObject->computeMSL.find("appgl_ms_storage_sparse_") != std::string::npos;

    const bool traceCompSamp = std::getenv("APPGL_TRACE_COMP_SAMP") != nullptr;
    for (const auto& samp : programObject->computeReflection.sampledTextures) {
        // Find the matching uniform to read its texture-unit value AND
        // its sampler GL type (drives preferredTarget below).
        GLint uniformLoc = -1;
        GLenum samplerGLType = 0;
        GLint samplerArraySize = 1;
        auto matchComputeSamplerUniform = [&](const std::string& name) -> bool {
            for (const auto& u : programObject->uniforms) {
                if (u.name != name) {
                    continue;
                }
                uniformLoc = u.location;
                samplerGLType = u.type;
                samplerArraySize = std::max<GLint>(u.arraySize, 1);
                return true;
            }
            return false;
        };
        if (!matchComputeSamplerUniform(samp.name)) {
            constexpr const char* kAppglPrefix = "_appgl_";
            constexpr std::size_t kAppglPrefixLen = 7;
            if (samp.name.compare(0, kAppglPrefixLen, kAppglPrefix) == 0) {
                matchComputeSamplerUniform(samp.name.substr(kAppglPrefixLen));
            }
        }
        if (uniformLoc < 0) {
            if (traceCompSamp) std::fprintf(stderr, "[CMP-SAMP] name=%s SKIP=no_uniform\n", samp.name.c_str());
            continue;
        }
        auto uvIt = programObject->uniformValues.find(uniformLoc);
        const GLProgramUniformValue* samplerValue =
            (uvIt != programObject->uniformValues.end()) ? &uvIt->second : nullptr;

        GLenum preferredTarget = preferredTargetForSamplerType(samplerGLType);

        // CKPT145 (Sprint 13 Day 9): sampler array iteration. SPIRV-Cross
        // emits a sampler array (`uniform sampler2D goku[7]`) as N
        // separate `[[texture(M+i)]]` slots. CTS shading_language_420pack.
        // binding_sampler_array binds 7 distinct textures at GL units 1..7
        // and expects each shader element `goku[i]` to read from the bound
        // texture at GL unit 1+i. Pre-fix: only goku[0] resolved (compute
        // path read `ints[0]` once); goku[1..6] unbound → wrong values.
        // Mirrors the graphics-path resolveSamplerBindings array iteration
        // at GLContext.mm:4683+.
        for (GLint arrayElement = 0; arrayElement < samplerArraySize; ++arrayElement) {
            GLuint unit = 0;
            if (samplerValue != nullptr &&
                static_cast<std::size_t>(arrayElement) < samplerValue->ints.size()) {
                unit = static_cast<GLuint>(samplerValue->ints[arrayElement]);
            }

            // Probe the sampler-type-derived target FIRST. Falls back to
            // GL_TEXTURE_2D probe + any-target if the preferred target has
            // no binding.
            GLenum discoveredTarget = preferredTarget != 0 ? preferredTarget : GL_TEXTURE_2D;
            GLuint texName = preferredTarget != 0
                ? impl_->state->boundTextureOnUnit(unit, preferredTarget) : 0;
            if (texName == 0) {
                texName = impl_->state->boundTextureOnUnit(unit, GL_TEXTURE_2D);
                if (texName != 0) discoveredTarget = GL_TEXTURE_2D;
            }
            if (texName == 0) {
                texName = impl_->state->boundTextureOnUnitAny(unit, &discoveredTarget);
            }
            if (traceCompSamp) {
                std::fprintf(stderr, "[CMP-SAMP] name=%s[%d] loc=%d type=0x%X unit=%u prefTgt=0x%X tex=%u tgt=0x%X metalSlot=%u",
                    samp.name.c_str(), arrayElement, uniformLoc, samplerGLType, unit, preferredTarget,
                    texName, discoveredTarget, samp.metalBinding + arrayElement);
            }
            if (texName == 0) {
                if (traceCompSamp) std::fprintf(stderr, " SKIP=no_texture\n");
                continue;
            }

            GLTextureObject* texObj = impl_->objects->textures().get(texName);
            if (texObj != nullptr &&
                texObj->target == GL_TEXTURE_BUFFER &&
                texObj->desc.sourceBuffer != 0) {
                (void)impl_->refreshBufferTextureView(*texObj);
            }
            if (texObj != nullptr && texObj->viewSourceTexture == 0) {
                (void)impl_->restoreR5PrimaryTextureIfNeeded(*texObj,
                                                             texName);
            }
            if (texObj == nullptr || texObj->metalTexture == nullptr) {
                if (traceCompSamp) std::fprintf(stderr, " SKIP=null_metalTexture\n");
                continue;
            }
            computeReads.push_back({Impl::GpuResourceAccess::Kind::Texture,
                                    texName, kProducerAll});
            if (texObj->target == GL_TEXTURE_BUFFER &&
                texObj->desc.sourceBuffer != 0) {
                computeReads.push_back(
                    {Impl::GpuResourceAccess::Kind::Buffer,
                     texObj->desc.sourceBuffer, kProducerAll});
            }
            void* metalSamplerState = nullptr;
            const GLuint samplerName = impl_->state->boundSampler(unit);
            if (samplerName != 0) {
                GLSamplerObject* samplerObj =
                    impl_->objects->samplers().get(samplerName);
                if (samplerObj != nullptr) {
                    if (samplerObj->dirty || samplerObj->metalSampler == nullptr) {
                        (void)impl_->rebuildSamplerState(*samplerObj);
                    }
                    metalSamplerState = samplerObj->metalSampler;
                }
            }
            if (metalSamplerState == nullptr) {
                if (texObj->samplerDirty || texObj->metalSampler == nullptr) {
                    (void)impl_->rebuildTextureSamplerState(texName, *texObj);
                }
                metalSamplerState = texObj->metalSampler;
            }

            ComputeDispatchInfo::TextureBinding tb;
            tb.metalTexture = texObj->metalTexture;
            tb.metalSamplerState = metalSamplerState;
            if (texObj->target == GL_TEXTURE_BUFFER &&
                texObj->desc.sourceBuffer != 0) {
                tb.textureBufferLogicalSize =
                    impl_->textureBufferLogicalTexelCount(*texObj);
                if (texObj->textureBufferExpandedMetalBuffer != nullptr) {
                    tb.textureBufferBackingMetalBuffer =
                        texObj->textureBufferExpandedMetalBuffer;
                } else {
                    GLBufferObject* backingBuffer =
                        impl_->objects->buffers().get(texObj->desc.sourceBuffer);
                    if (backingBuffer != nullptr) {
                        tb.textureBufferBackingMetalBuffer =
                            backingBuffer->metalBuffer;
                    }
                }
            }
            tb.metalSlot = samp.metalBinding + static_cast<std::uint32_t>(arrayElement);
            info.textures.push_back(tb);
            if (usesMSSampledSidecars &&
                extensions::sparse_texture::isMultisampleStorageImageTarget(preferredTarget)) {
                extensions::sparse_texture::MultisampleStorageImageSidecarInfo sidecarInfo;
                const std::uint32_t slot =
                    samp.metalBinding + static_cast<std::uint32_t>(arrayElement);
                if (slot >= msImageSampleCounts.size()) {
                    msImageSampleCounts.resize(static_cast<std::size_t>(slot) + 1u, 0u);
                }
                hasMSImageSampleCounts = true;
                msImageSampleCounts[slot] = 0u;
                if (extensions::sparse_texture::getMultisampleStorageImageSidecar(
                        extensionContext, *texObj, sidecarInfo)) {
                    ComputeDispatchInfo::TextureBinding sidecarBinding;
                    sidecarBinding.metalTexture = sidecarInfo.metalTexture;
                    sidecarBinding.metalSamplerState = nullptr;
                    sidecarBinding.metalSlot =
                        slot + kMultisampleSampledSidecarTextureSlotOffset;
                    info.textures.push_back(sidecarBinding);
                    msImageSampleCounts[slot] =
                        static_cast<std::uint32_t>(std::max<GLsizei>(sidecarInfo.samples, 1));
                }
            }
            const GLenum sparseSidecarTarget =
                preferredTarget != 0 ? preferredTarget : discoveredTarget;
            if (usesSparseSampledSidecars &&
                extensions::sparse_texture::isSparseStorageImageSidecarTarget(
                    sparseSidecarTarget)) {
                extensions::sparse_texture::SparseStorageImageSidecarInfo sidecarInfo;
                const auto sparseRoute =
                    extensions::sparse_texture::resolveSparseStorageImageSidecarBinding(
                        extensionContext, *texObj, sparseSidecarTarget, &sidecarInfo);
                const std::uint32_t slot =
                    samp.metalBinding + static_cast<std::uint32_t>(arrayElement);
                ComputeDispatchInfo::TextureBinding sidecarBinding;
                sidecarBinding.metalSamplerState = nullptr;
                sidecarBinding.metalSlot =
                    slot + kMultisampleSampledSidecarTextureSlotOffset;
                sidecarBinding.metalTexture =
                    sparseRoute ==
                            extensions::sparse_texture::SparseStorageImageBindingRoute::SidecarTexture
                        ? sidecarInfo.metalTexture
                        : texObj->metalTexture;
                if (sidecarBinding.metalTexture != nullptr) {
                    info.textures.push_back(sidecarBinding);
                }
            }
            if (traceCompSamp) std::fprintf(stderr, " BOUND\n");
        }
    }

    // Storage images (imageLoad/imageStore). Bound via
    // glBindImageTexture(unit, …) rather than a sampler uniform. The
    // shader's `layout(binding=N)` is the DEFAULT image unit; GL 4.6
    // §7.6 allows glUniform1i(loc, K) to change the effective image
    // unit to K at runtime (same mechanism as sampler uniforms). CTS
    // shading_language_420pack.binding_images_* relies on this — only
    // one of the three images has an explicit layout binding, and the
    // others rely on glUniform1i to set the unit.
    for (const auto& img : programObject->computeReflection.storageImages) {
        // CKPT145 (Sprint 13 Day 9): storage image array iteration. SPIRV-
        // Cross emits an image array (`uniform image2D goku[7]`) as N
        // separate `[[texture(M+i)]]` slots. Pre-fix: only goku[0] resolved;
        // goku[1..N-1] unbound → wrong values. CTS shading_language_420pack.
        // binding_image_array exercises this with 7 elements.
        // Look up the matching uniform to read array size + per-element
        // uniform-value (glUniform1i overrides).
        GLint imageArraySize = 1;
        const GLProgramUniformValue* imageValue = nullptr;
        for (const auto& u : programObject->uniforms) {
            if (u.name == img.name) {
                imageArraySize = std::max<GLint>(u.arraySize, 1);
                auto uvIt = programObject->uniformValues.find(u.location);
                if (uvIt != programObject->uniformValues.end()) {
                    imageValue = &uvIt->second;
                }
                break;
            }
        }
        for (GLint arrayElement = 0; arrayElement < imageArraySize; ++arrayElement) {
            // GL 4.6 §7.6: per-element effective unit. Default is
            // glBinding+arrayElement (consecutive layout). Override per
            // element via glUniform1i(loc[i], K).
            GLuint effectiveUnit = img.glBinding + static_cast<GLuint>(arrayElement);
            if (imageValue != nullptr &&
                static_cast<std::size_t>(arrayElement) < imageValue->ints.size()) {
                effectiveUnit = static_cast<GLuint>(imageValue->ints[arrayElement]);
            }
            if (effectiveUnit >= Impl::kMaxImageUnits) continue;
            auto& ib = impl_->imageBindings[effectiveUnit];
            if (ib.texture == 0) continue;
            GLTextureObject* texObj = impl_->objects->textures().get(ib.texture);
            if (texObj != nullptr && texObj->viewSourceTexture == 0) {
                (void)impl_->restoreR5PrimaryTextureIfNeeded(*texObj,
                                                             ib.texture);
            }
            if (texObj != nullptr &&
                texObj->target == GL_TEXTURE_BUFFER &&
                texObj->desc.sourceBuffer != 0) {
                (void)impl_->refreshBufferTextureView(*texObj);
            }
            if (texObj == nullptr || texObj->metalTexture == nullptr) continue;
            if (!impl_->imageBindingLevelAvailable(ib, texObj)) continue;
            const bool textureBufferImage =
                texObj->target == GL_TEXTURE_BUFFER &&
                texObj->desc.sourceBuffer != 0;
            if (ib.access != GL_WRITE_ONLY) {
                computeReads.push_back({Impl::GpuResourceAccess::Kind::Texture,
                                        ib.texture, kProducerAll});
                if (textureBufferImage) {
                    computeReads.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                            texObj->desc.sourceBuffer,
                                            kProducerAll});
                }
            }
            if (ib.access != GL_READ_ONLY) {
                computeWrites.push_back(
                    {Impl::GpuResourceAccess::Kind::Texture,
                     ib.texture,
                     kProducerComputeWrite | kProducerStorageImageWrite});
                if (textureBufferImage) {
                    computeWrites.push_back(
                        {Impl::GpuResourceAccess::Kind::Buffer,
                         texObj->desc.sourceBuffer,
                         kProducerComputeWrite | kProducerStorageImageWrite});
                }
            }
            ComputeDispatchInfo::TextureBinding tb;
            if (img.multisampleStorageImage) {
                extensions::sparse_texture::MultisampleStorageImageSidecarInfo sidecarInfo;
                if (!extensions::sparse_texture::ensureMultisampleStorageImageSidecar(
                        extensionContext, *texObj, &sidecarInfo)) {
                    continue;
                }
                tb.metalTexture = sidecarInfo.metalTexture;
                const std::uint32_t slot =
                    img.metalBinding + static_cast<std::uint32_t>(arrayElement);
                if (slot >= msImageSampleCounts.size()) {
                    msImageSampleCounts.resize(static_cast<std::size_t>(slot) + 1u, 1u);
                }
                msImageSampleCounts[slot] =
                    static_cast<std::uint32_t>(std::max<GLsizei>(sidecarInfo.samples, 1));
                hasMSImageSampleCounts = true;
                if (usesMSStorageSparseResidency && texObj->metalTexture != nullptr) {
                    ComputeDispatchInfo::TextureBinding sparseResidencyBinding;
                    sparseResidencyBinding.metalTexture = texObj->metalTexture;
                    sparseResidencyBinding.metalSamplerState = nullptr;
                    sparseResidencyBinding.metalSlot =
                        slot + kMultisampleStorageSparseResidencyTextureSlotOffset;
                    info.textures.push_back(sparseResidencyBinding);
                }
            } else {
                extensions::sparse_texture::SparseStorageImageSidecarInfo sidecarInfo;
                const bool sparseWritableBound =
                    extensions::sparse_texture::textureSparse(extensionContext, texObj) == GL_TRUE &&
                    extensions::sparse_texture::isSparseStorageImageSidecarTarget(img.storageImageTarget) &&
                    texObj->target == img.storageImageTarget &&
                    ib.access != GL_READ_ONLY;
                const bool sparseSidecarAccess =
                    img.sparseStorageImageWrite || sparseWritableBound;
                const auto sparseRoute = sparseSidecarAccess
                    ? extensions::sparse_texture::resolveSparseStorageImageSidecarBinding(
                          extensionContext, *texObj, img.storageImageTarget, &sidecarInfo)
                    : extensions::sparse_texture::SparseStorageImageBindingRoute::NativeTexture;
                if (sparseRoute ==
                    extensions::sparse_texture::SparseStorageImageBindingRoute::SidecarTexture) {
                    tb.metalTexture =
                        impl_->resolveSparseSidecarImageMetalTexture(
                            ib, texObj, sidecarInfo);
                } else if (sparseRoute ==
                           extensions::sparse_texture::SparseStorageImageBindingRoute::SparseSidecarUnavailable) {
                    continue;
                } else {
                    if (ib.access != GL_READ_ONLY) {
                        (void)extensions::sparse_texture::ensureSparseStorageImageSidecar(
                            extensionContext, *texObj);
                    }
                    // CKPT119: level-restricted view when ib.level > 0.
                    tb.metalTexture = impl_->resolveImageMetalTexture(
                        ib, texObj, img.storageImageTarget);
                }
            }
            tb.metalSamplerState = nullptr;  // no sampler for storage images
            tb.metalSlot = img.metalBinding + static_cast<std::uint32_t>(arrayElement);
            if (textureBufferImage) {
                tb.textureBufferLogicalSize =
                    impl_->textureBufferLogicalTexelCount(*texObj);
                if (texObj->textureBufferExpandedMetalBuffer != nullptr) {
                    tb.textureBufferBackingMetalBuffer =
                        texObj->textureBufferExpandedMetalBuffer;
                } else {
                    GLBufferObject* backingBuffer =
                        impl_->objects->buffers().get(texObj->desc.sourceBuffer);
                    if (backingBuffer != nullptr) {
                        tb.textureBufferBackingMetalBuffer =
                            backingBuffer->metalBuffer;
                    }
                }
            }
            if (img.metalAtomicBufferBinding != 0xFFFFFFFFu) {
                const std::string atomicNeedle = img.name + "_atomic";
                const bool usesImageAtomic =
                    programObject->computeMSL.find(atomicNeedle) != std::string::npos ||
                    programObject->computeMSL.find("_appgl_" + atomicNeedle) !=
                        std::string::npos;
                if (usesImageAtomic) {
                    tb.imageAtomicBufferSlot =
                        img.metalAtomicBufferBinding +
                        static_cast<std::uint32_t>(arrayElement);
                    if (texObj->target == GL_TEXTURE_BUFFER &&
                        texObj->desc.sourceBuffer != 0) {
                        GLBufferObject* backingBuffer =
                            impl_->objects->buffers().get(texObj->desc.sourceBuffer);
                        if (backingBuffer != nullptr &&
                            backingBuffer->metalBuffer != nullptr) {
                            tb.imageAtomicMetalBuffer =
                                backingBuffer->metalBuffer;
                            tb.imageAtomicBufferOffset =
                                static_cast<std::size_t>(
                                    std::max<GLintptr>(
                                        texObj->desc.bufferOffset, 0));
                        }
                    } else {
                        tb.imageAtomicMetalBuffer =
                            impl_->ensureTextureImageAtomicBuffer(*texObj);
                        tb.imageAtomicBufferOffset = 0;
                        if (tb.imageAtomicMetalBuffer != nullptr &&
                            ib.access != GL_READ_ONLY) {
                            texObj->imageAtomicBufferDirtyToTexture = true;
                        }
                    }
                }
            }
            info.textures.push_back(tb);
        }
    }
    if (hasMSImageSampleCounts) {
        info.multisampleStorageImageSampleCounts = msImageSampleCounts.data();
        info.multisampleStorageImageSampleCountBytes =
            msImageSampleCounts.size() * sizeof(std::uint32_t);
        info.multisampleStorageImageSampleCountSlot =
            multisampleStorageImageSampleCountSlotForMSL(programObject->computeMSL);
    }

    impl_->declareComputeDispatchSubmissionGroup(info, computeReads, computeWrites);
    impl_->drainPendingGpuProducers(computeReads);
    const bool encoded = impl_->frameGraph->encodeComputeDispatch(info);
    if (encoded) {
        impl_->markGpuResourceWrites(computeWrites);
        for (const auto& sync : fp64SsboSidecars) {
            if (sync.buffer != nullptr && sync.binding != nullptr &&
                sync.sidecar != nullptr) {
                impl_->syncFp64TransportSidecarBack(
                    *sync.buffer, *sync.binding, *sync.sidecar);
            }
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_COMPUTE_DISPATCH_INDIRECT)
bool GLContext::dispatchComputeIndirect(GLintptr indirect) {
    if (indirect < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if ((indirect % 4) != 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // GL 4.6 §17.2: GL_INVALID_OPERATION when no active compute program
    // (matches dispatchCompute's spec-correct check below). Without
    // this, the compute_shader.api-indirect / api-no-active-program
    // negative tests see GL_NO_ERROR and fail.
    const GLuint progName = impl_->state->currentProgram();
    GLProgramObject* programObject = progName == 0 ? nullptr
        : impl_->objects->programs().get(progName);
    if (programObject == nullptr || !programObject->linked
        || programObject->metalComputePipelineState == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // GL 4.6 §17.2: also INVALID_OPERATION when no buffer is bound
    // to the GL_DISPATCH_INDIRECT_BUFFER target, or when the command
    // would read past the end of the bound buffer.
    const GLuint dispatchBufName = impl_->state->boundBuffer(GL_DISPATCH_INDIRECT_BUFFER);
    if (dispatchBufName == 0) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    const GLBufferObject* dispatchBuf = impl_->objects->buffers().get(dispatchBufName);
    if (dispatchBuf == nullptr) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }
    // Three GLuints (x, y, z work-group counts) at `indirect`.
    constexpr GLsizeiptr kIndirectDispatchSize = 3 * sizeof(GLuint);
    if (indirect > dispatchBuf->size
        || kIndirectDispatchSize > dispatchBuf->size - indirect) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // GL 4.6 §2.3.3 — conditional render predicate. Skipped dispatches
    // do not advance query counters or update shader-visible storage.
    if (impl_->shouldSkipDrawForConditionalRender()) {
        return true;
    }
    impl_->touchR5Residency(MetalR5ResidencyTouchKind::Dispatch);

    // GL 4.6 §22.4 — credit COMPUTE_SHADER_INVOCATIONS for every
    // active query, mirroring the direct-dispatch path above. The
    // indirect buffer is CPU-mapped on Apple silicon so we can read
    // the (x, y, z) groups for a real count; if that read fails we
    // fall back to local-size × 1-group to satisfy EQUAL_OR_GREATER.
    // CTS `pipeline_statistics_query_tests_ARB.functional_compute_
    // shader_invocations` runs the query over dispatchCompute +
    // dispatchComputeIndirect and expects result >= 1 on both.
    {
        GLuint64 groups = 0;
        if (dispatchBuf->metalBuffer != nullptr) {
            id<MTLBuffer> mtl = (__bridge id<MTLBuffer>)dispatchBuf->metalBuffer;
            const void* ptr = [mtl contents];
            if (ptr != nullptr) {
                const GLuint* args = reinterpret_cast<const GLuint*>(
                    reinterpret_cast<const std::uint8_t*>(ptr) +
                    static_cast<std::size_t>(indirect));
                groups = static_cast<GLuint64>(args[0]) *
                         static_cast<GLuint64>(args[1]) *
                         static_cast<GLuint64>(args[2]);
            }
        }
        if (groups == 0) groups = 1;
        const GLuint64 local = static_cast<GLuint64>(programObject->computeLocalSizeX) *
                               static_cast<GLuint64>(programObject->computeLocalSizeY) *
                               static_cast<GLuint64>(programObject->computeLocalSizeZ);
        const GLuint64 invocations = groups * (local == 0 ? 1 : local);
        impl_->objects->queries().forEach([&](GLuint /*id*/, GLQueryObject& q) {
            if (!q.active || q.target != GL_COMPUTE_SHADER_INVOCATIONS) return;
            q.result += invocations;
        });
    }

    // Route the indirect dispatch through the same encoder as the
    // direct path. Metal reads the (groupsX, groupsY, groupsZ) triple
    // out of the buffer at dispatch time via
    // dispatchThreadgroupsWithIndirectBuffer — we just hand it the
    // MTLBuffer + offset.
    if (impl_->frameGraph == nullptr) {
        return true;  // teardown — silently no-op, same as direct path
    }
    ComputeDispatchInfo info;
    info.metalComputePipelineState = programObject->metalComputePipelineState;
    info.metalComputeFunction = programObject->metalComputeFunction;
    info.needsSSBOSizeBuffer =
        programObject->computeMSL.find("spvBufferSizeConstants") != std::string::npos;
    info.localX = programObject->computeLocalSizeX;
    info.localY = programObject->computeLocalSizeY;
    info.localZ = programObject->computeLocalSizeZ;
    info.indirectBuffer = dispatchBuf->metalBuffer;
    info.indirectOffset = static_cast<std::size_t>(indirect);
    struct Fp64IndirectSidecarSync {
        GLBufferObject* buffer = nullptr;
        const ShaderReflection::ResourceBinding* binding = nullptr;
        GLBufferObject::Fp64TransportSidecar* sidecar = nullptr;
    };
    std::vector<Fp64IndirectSidecarSync> fp64SsboSidecars;
    GLContext::Impl::GpuResourceReadSet computeReads;
    GLContext::Impl::GpuResourceWriteSet computeWrites;
    computeReads.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                            dispatchBufName, kProducerAll});

    // Same resource plumbing as the direct dispatch path: SSBOs, UBOs,
    // default-uniform push constants, sampled textures. Keep in sync
    // with GLContext::dispatchCompute.
    for (const auto& ssbo : programObject->computeReflection.storageBuffers) {
        GLuint effectiveBinding = ssbo.glBinding;
        for (const auto& rb : programObject->resourceStorageBlocks) {
            if (rb.name == ssbo.name && rb.location >= 0) {
                effectiveBinding = static_cast<GLuint>(rb.location);
                break;
            }
        }
        const int numInstances = (ssbo.blockArraySize > 0)
            ? static_cast<int>(ssbo.blockArraySize) : 1;
        const bool isArray = (ssbo.blockArraySize > 0);
        for (int inst = 0; inst < numInstances; ++inst) {
            std::string lookupName = ssbo.name;
            if (isArray) lookupName += "[" + std::to_string(inst) + "]";
            GLuint glBindingPoint = effectiveBinding + static_cast<GLuint>(inst);
            for (const auto& rb : programObject->resourceStorageBlocks) {
                if (rb.name == lookupName && rb.location >= 0) {
                    glBindingPoint = static_cast<GLuint>(rb.location);
                    break;
                }
            }
            const GLIndexedBufferBinding binding = impl_->state->indexedBufferBinding(
                GL_SHADER_STORAGE_BUFFER, glBindingPoint);
            if (binding.buffer == 0) continue;
            GLBufferObject* bufObj = impl_->objects->buffers().get(binding.buffer);
            if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
            computeReads.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                    binding.buffer, kProducerAll});
            computeWrites.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                     binding.buffer,
                                     kProducerComputeWrite |
                                         kProducerShaderStorageWrite});
            ComputeDispatchInfo::BufferBinding bb;
            bb.metalBuffer = bufObj->metalBuffer;
            bb.offset = static_cast<std::size_t>(binding.offset);
            if (binding.size > 0) {
                bb.size = static_cast<std::size_t>(binding.size);
            } else if (binding.offset >= 0 && bufObj->size > binding.offset) {
                bb.size = static_cast<std::size_t>(bufObj->size - binding.offset);
            }
            bb.metalSlot = ssbo.metalBinding + static_cast<std::uint32_t>(inst);
            if (resourceNeedsFp64BindingShim(programObject->computeReflection, ssbo)) {
                auto* sidecar = impl_->ensureFp64TransportSidecar(
                    *bufObj, programObject->computeReflection, ssbo,
                    static_cast<GLintptr>(binding.offset),
                    static_cast<GLsizeiptr>(bb.size));
                if (sidecar != nullptr && sidecar->metalBuffer != nullptr) {
                    bb.metalBuffer = sidecar->metalBuffer;
                    bb.offset = 0;
                    fp64SsboSidecars.push_back({bufObj, &ssbo, sidecar});
                    ExtensionContext extensionContext(*this);
                    extensions::fp64::recordDoubleSsboBacking(
                        extensionContext, bb.size);
                }
            }
            info.buffers.push_back(bb);
        }
    }
    // CKPT143 (Sprint 13 Day 7): UBO array support — see direct-dispatch
    // path above for full rationale. Mirror here for dispatchComputeIndirect.
    for (const auto& ubo : programObject->computeReflection.uniformBlocks) {
        if (ubo.name == "_DefaultUniforms") continue;
        const int numInstances = (ubo.blockArraySize > 0)
            ? static_cast<int>(ubo.blockArraySize) : 1;
        const bool isArray = (ubo.blockArraySize > 0);
        for (int inst = 0; inst < numInstances; ++inst) {
            std::string lookupName = ubo.name;
            if (isArray) {
                lookupName += "[" + std::to_string(inst) + "]";
            }
            GLuint glBindingPoint = ubo.glBinding + static_cast<GLuint>(inst);
            for (std::size_t bi = 0; bi < programObject->resourceUniformBlocks.size(); ++bi) {
                if (programObject->resourceUniformBlocks[bi].name == lookupName) {
                    GLint bp = programObject->resourceUniformBlocks[bi].location;
                    if (bp >= 0) {
                        glBindingPoint = static_cast<GLuint>(bp);
                    }
                    break;
                }
            }
            const GLIndexedBufferBinding binding = impl_->state->indexedBufferBinding(
                GL_UNIFORM_BUFFER, glBindingPoint);
            if (binding.buffer == 0) continue;
            GLBufferObject* bufObj = impl_->objects->buffers().get(binding.buffer);
            if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
            computeReads.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                    binding.buffer, kProducerAll});
            ComputeDispatchInfo::BufferBinding bb;
            bb.metalBuffer = bufObj->metalBuffer;
            bb.offset = static_cast<std::size_t>(binding.offset);
            bb.metalSlot = ubo.metalBinding + static_cast<std::uint32_t>(inst);
            bb.descriptorSet = 1;
            if (resourceNeedsFp64BindingShim(programObject->computeReflection, ubo)) {
                GLsizeiptr rangeSize = binding.size;
                if (rangeSize <= 0 && binding.offset >= 0 && bufObj->size > binding.offset) {
                    rangeSize = bufObj->size - binding.offset;
                }
                auto* sidecar = impl_->ensureFp64TransportSidecar(
                    *bufObj, programObject->computeReflection, ubo,
                    static_cast<GLintptr>(binding.offset), rangeSize);
                if (sidecar != nullptr && sidecar->metalBuffer != nullptr) {
                    bb.metalBuffer = sidecar->metalBuffer;
                    bb.offset = 0;
                    ExtensionContext extensionContext(*this);
                    extensions::fp64::recordDoubleUniformBacking(
                        extensionContext, static_cast<std::size_t>(rangeSize));
                }
            }
            info.buffers.push_back(bb);
        }
    }
    for (const auto& ac : programObject->resourceAtomicCounterBuffers) {
        if (ac.binding < 0) continue;
        const GLuint glBinding = static_cast<GLuint>(ac.binding);
        const GLIndexedBufferBinding binding = impl_->state->indexedBufferBinding(
            GL_ATOMIC_COUNTER_BUFFER, glBinding);
        if (binding.buffer == 0) continue;
        const GLBufferObject* bufObj = impl_->objects->buffers().get(binding.buffer);
        if (bufObj == nullptr || bufObj->metalBuffer == nullptr) continue;
        computeReads.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                binding.buffer, kProducerAll});
        computeWrites.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                 binding.buffer,
                                 kProducerComputeWrite |
                                     kProducerAtomicCounterWrite});

        ComputeDispatchInfo::BufferBinding bb;
        bb.metalBuffer = bufObj->metalBuffer;
        bb.offset = static_cast<std::size_t>(binding.offset);
        bb.metalSlot = computeAtomicCounterMetalSlot(glBinding);
        info.buffers.push_back(bb);
    }
    thread_local std::vector<std::uint8_t> computeUniformScratchIndirect;
    if (!programObject->uniformLayoutComputed
        || programObject->computeUniformLayout.empty()) {
        computeStageUniformLayout(programObject->computeUniformLayout,
            programObject->computeReflection, programObject->uniforms);
        programObject->uniformLayoutComputed = true;
    }
    if (pushSynthesizedMatrixUniforms(*programObject, impl_->matrixState)) {
        programObject->markUniformsDirty();
    }
    buildStageUniformBuffer(computeUniformScratchIndirect,
        programObject->computeReflection, programObject->uniformValues,
        programObject->computeUniformLayout);
    if (!computeUniformScratchIndirect.empty()) {
        info.computeUniformData = computeUniformScratchIndirect.data();
        info.computeUniformSize = computeUniformScratchIndirect.size();
        if (reflectionNeedsFp64BindingShim(programObject->computeReflection) &&
            defaultUniformBlockContainsFp64(programObject->computeReflection)) {
            ExtensionContext extensionContext(*this);
            extensions::fp64::recordDoubleUniformBacking(
                extensionContext, info.computeUniformSize);
        }
    }
    // CKPT144 (Sprint 13 Day 8): sampler-type-aware target lookup —
    // see direct-dispatch path above for full rationale. Indirect mirror.
    auto preferredTargetForSamplerType2 = [](GLenum samplerGLType) -> GLenum {
        switch (samplerGLType) {
            case GL_SAMPLER_1D: case GL_INT_SAMPLER_1D: case GL_UNSIGNED_INT_SAMPLER_1D:
            case GL_SAMPLER_1D_SHADOW: return GL_TEXTURE_1D;
            case GL_SAMPLER_2D: case GL_INT_SAMPLER_2D: case GL_UNSIGNED_INT_SAMPLER_2D:
            case GL_SAMPLER_2D_SHADOW: return GL_TEXTURE_2D;
            case GL_SAMPLER_3D: case GL_INT_SAMPLER_3D: case GL_UNSIGNED_INT_SAMPLER_3D:
                return GL_TEXTURE_3D;
            case GL_SAMPLER_CUBE: case GL_INT_SAMPLER_CUBE: case GL_UNSIGNED_INT_SAMPLER_CUBE:
            case GL_SAMPLER_CUBE_SHADOW: return GL_TEXTURE_CUBE_MAP;
            case GL_SAMPLER_1D_ARRAY: case GL_INT_SAMPLER_1D_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY: case GL_SAMPLER_1D_ARRAY_SHADOW:
                return GL_TEXTURE_1D_ARRAY;
            case GL_SAMPLER_2D_ARRAY: case GL_INT_SAMPLER_2D_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY: case GL_SAMPLER_2D_ARRAY_SHADOW:
                return GL_TEXTURE_2D_ARRAY;
            case GL_SAMPLER_2D_RECT: case GL_INT_SAMPLER_2D_RECT:
            case GL_UNSIGNED_INT_SAMPLER_2D_RECT: case GL_SAMPLER_2D_RECT_SHADOW:
                return GL_TEXTURE_RECTANGLE;
            case GL_SAMPLER_BUFFER: case GL_INT_SAMPLER_BUFFER:
            case GL_UNSIGNED_INT_SAMPLER_BUFFER: return GL_TEXTURE_BUFFER;
            case GL_SAMPLER_CUBE_MAP_ARRAY: case GL_INT_SAMPLER_CUBE_MAP_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_CUBE_MAP_ARRAY: case GL_SAMPLER_CUBE_MAP_ARRAY_SHADOW:
                return GL_TEXTURE_CUBE_MAP_ARRAY;
            case GL_SAMPLER_2D_MULTISAMPLE: case GL_INT_SAMPLER_2D_MULTISAMPLE:
            case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE: return GL_TEXTURE_2D_MULTISAMPLE;
            case GL_SAMPLER_2D_MULTISAMPLE_ARRAY: case GL_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
            case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE_ARRAY:
                return GL_TEXTURE_2D_MULTISAMPLE_ARRAY;
            default: return 0;
        }
    };
    thread_local std::vector<std::uint32_t> msImageSampleCountsIndirect;
    msImageSampleCountsIndirect.assign(128, 1u);
    bool hasMSImageSampleCountsIndirect = false;
    ExtensionContext extensionContext(*this);
    const bool usesMSSampledSidecarsIndirect =
        programObject->computeMSL.find("appgl_ms_sampled_sidecar_") != std::string::npos;
    const bool usesSparseSampledSidecarsIndirect =
        programObject->computeMSL.find("appgl_sparse_sampled_sidecar_") != std::string::npos;
    const bool usesMSStorageSparseResidencyIndirect =
        programObject->computeMSL.find("appgl_ms_storage_sparse_") != std::string::npos;

    // CKPT145 (Sprint 13 Day 9): sampler array iteration — see direct
    // dispatch path for full rationale. Indirect mirror.
    for (const auto& samp : programObject->computeReflection.sampledTextures) {
        GLint uniformLoc = -1;
        GLenum samplerGLType = 0;
        GLint samplerArraySize = 1;
        for (const auto& u : programObject->uniforms) {
            if (u.name == samp.name) {
                uniformLoc = u.location;
                samplerGLType = u.type;
                samplerArraySize = std::max<GLint>(u.arraySize, 1);
                break;
            }
        }
        if (uniformLoc < 0) continue;
        auto uvIt = programObject->uniformValues.find(uniformLoc);
        const GLProgramUniformValue* samplerValue =
            (uvIt != programObject->uniformValues.end()) ? &uvIt->second : nullptr;
        GLenum preferredTarget = preferredTargetForSamplerType2(samplerGLType);
        for (GLint arrayElement = 0; arrayElement < samplerArraySize; ++arrayElement) {
            GLuint unit = 0;
            if (samplerValue != nullptr &&
                static_cast<std::size_t>(arrayElement) < samplerValue->ints.size()) {
                unit = static_cast<GLuint>(samplerValue->ints[arrayElement]);
            }
            GLenum discoveredTarget = preferredTarget != 0 ? preferredTarget : GL_TEXTURE_2D;
            GLuint texName = preferredTarget != 0
                ? impl_->state->boundTextureOnUnit(unit, preferredTarget) : 0;
            if (texName == 0) {
                texName = impl_->state->boundTextureOnUnit(unit, GL_TEXTURE_2D);
                if (texName != 0) discoveredTarget = GL_TEXTURE_2D;
            }
            if (texName == 0) {
                texName = impl_->state->boundTextureOnUnitAny(unit, &discoveredTarget);
            }
            if (texName == 0) continue;
            GLTextureObject* texObj = impl_->objects->textures().get(texName);
            if (texObj != nullptr &&
                texObj->target == GL_TEXTURE_BUFFER &&
                texObj->desc.sourceBuffer != 0) {
                (void)impl_->refreshBufferTextureView(*texObj);
            }
            if (texObj != nullptr && texObj->viewSourceTexture == 0) {
                (void)impl_->restoreR5PrimaryTextureIfNeeded(*texObj,
                                                             texName);
            }
            if (texObj == nullptr || texObj->metalTexture == nullptr) continue;
            computeReads.push_back({Impl::GpuResourceAccess::Kind::Texture,
                                    texName, kProducerAll});
            if (texObj->target == GL_TEXTURE_BUFFER &&
                texObj->desc.sourceBuffer != 0) {
                computeReads.push_back(
                    {Impl::GpuResourceAccess::Kind::Buffer,
                     texObj->desc.sourceBuffer, kProducerAll});
            }
            if (texObj->samplerDirty) {
                impl_->rebuildTextureSamplerState(texName, *texObj);
            }
            ComputeDispatchInfo::TextureBinding tb;
            tb.metalTexture = texObj->metalTexture;
            tb.metalSamplerState = texObj->metalSampler;
            if (texObj->target == GL_TEXTURE_BUFFER &&
                texObj->desc.sourceBuffer != 0) {
                tb.textureBufferLogicalSize =
                    impl_->textureBufferLogicalTexelCount(*texObj);
                if (texObj->textureBufferExpandedMetalBuffer != nullptr) {
                    tb.textureBufferBackingMetalBuffer =
                        texObj->textureBufferExpandedMetalBuffer;
                } else {
                    GLBufferObject* backingBuffer =
                        impl_->objects->buffers().get(texObj->desc.sourceBuffer);
                    if (backingBuffer != nullptr) {
                        tb.textureBufferBackingMetalBuffer =
                            backingBuffer->metalBuffer;
                    }
                }
            }
            tb.metalSlot = samp.metalBinding + static_cast<std::uint32_t>(arrayElement);
            info.textures.push_back(tb);
            if (usesMSSampledSidecarsIndirect &&
                extensions::sparse_texture::isMultisampleStorageImageTarget(preferredTarget)) {
                extensions::sparse_texture::MultisampleStorageImageSidecarInfo sidecarInfo;
                const std::uint32_t slot =
                    samp.metalBinding + static_cast<std::uint32_t>(arrayElement);
                if (slot >= msImageSampleCountsIndirect.size()) {
                    msImageSampleCountsIndirect.resize(
                        static_cast<std::size_t>(slot) + 1u, 0u);
                }
                hasMSImageSampleCountsIndirect = true;
                msImageSampleCountsIndirect[slot] = 0u;
                if (extensions::sparse_texture::getMultisampleStorageImageSidecar(
                        extensionContext, *texObj, sidecarInfo)) {
                    ComputeDispatchInfo::TextureBinding sidecarBinding;
                    sidecarBinding.metalTexture = sidecarInfo.metalTexture;
                    sidecarBinding.metalSamplerState = nullptr;
                    sidecarBinding.metalSlot =
                        slot + kMultisampleSampledSidecarTextureSlotOffset;
                    info.textures.push_back(sidecarBinding);
                    msImageSampleCountsIndirect[slot] =
                        static_cast<std::uint32_t>(std::max<GLsizei>(sidecarInfo.samples, 1));
                }
            }
            const GLenum sparseSidecarTarget =
                preferredTarget != 0 ? preferredTarget : discoveredTarget;
            if (usesSparseSampledSidecarsIndirect &&
                extensions::sparse_texture::isSparseStorageImageSidecarTarget(
                    sparseSidecarTarget)) {
                extensions::sparse_texture::SparseStorageImageSidecarInfo sidecarInfo;
                const auto sparseRoute =
                    extensions::sparse_texture::resolveSparseStorageImageSidecarBinding(
                        extensionContext, *texObj, sparseSidecarTarget, &sidecarInfo);
                const std::uint32_t slot =
                    samp.metalBinding + static_cast<std::uint32_t>(arrayElement);
                ComputeDispatchInfo::TextureBinding sidecarBinding;
                sidecarBinding.metalSamplerState = nullptr;
                sidecarBinding.metalSlot =
                    slot + kMultisampleSampledSidecarTextureSlotOffset;
                sidecarBinding.metalTexture =
                    sparseRoute ==
                            extensions::sparse_texture::SparseStorageImageBindingRoute::SidecarTexture
                        ? sidecarInfo.metalTexture
                        : texObj->metalTexture;
                if (sidecarBinding.metalTexture != nullptr) {
                    info.textures.push_back(sidecarBinding);
                }
            }
        }
    }
    // Storage images for the indirect path — mirror the direct path.
    for (const auto& img : programObject->computeReflection.storageImages) {
        GLint imageArraySize = 1;
        const GLProgramUniformValue* imageValue = nullptr;
        for (const auto& u : programObject->uniforms) {
            if (u.name == img.name) {
                imageArraySize = std::max<GLint>(u.arraySize, 1);
                auto uvIt = programObject->uniformValues.find(u.location);
                if (uvIt != programObject->uniformValues.end()) {
                    imageValue = &uvIt->second;
                }
                break;
            }
        }
        for (GLint arrayElement = 0; arrayElement < imageArraySize; ++arrayElement) {
            GLuint effectiveUnit = img.glBinding + static_cast<GLuint>(arrayElement);
            if (imageValue != nullptr &&
                static_cast<std::size_t>(arrayElement) < imageValue->ints.size()) {
                effectiveUnit = static_cast<GLuint>(imageValue->ints[arrayElement]);
            }
            if (effectiveUnit >= Impl::kMaxImageUnits) continue;
            auto& ib = impl_->imageBindings[effectiveUnit];
            if (ib.texture == 0) continue;
            GLTextureObject* texObj = impl_->objects->textures().get(ib.texture);
            if (texObj != nullptr && texObj->viewSourceTexture == 0) {
                (void)impl_->restoreR5PrimaryTextureIfNeeded(*texObj,
                                                             ib.texture);
            }
            if (texObj == nullptr || texObj->metalTexture == nullptr) continue;
            if (!impl_->imageBindingLevelAvailable(ib, texObj)) continue;
            const bool textureBufferImage =
                texObj->target == GL_TEXTURE_BUFFER &&
                texObj->desc.sourceBuffer != 0;
            if (ib.access != GL_WRITE_ONLY) {
                computeReads.push_back({Impl::GpuResourceAccess::Kind::Texture,
                                        ib.texture, kProducerAll});
                if (textureBufferImage) {
                    computeReads.push_back({Impl::GpuResourceAccess::Kind::Buffer,
                                            texObj->desc.sourceBuffer,
                                            kProducerAll});
                }
            }
            if (ib.access != GL_READ_ONLY) {
                computeWrites.push_back(
                    {Impl::GpuResourceAccess::Kind::Texture,
                     ib.texture,
                     kProducerComputeWrite | kProducerStorageImageWrite});
                if (textureBufferImage) {
                    computeWrites.push_back(
                        {Impl::GpuResourceAccess::Kind::Buffer,
                         texObj->desc.sourceBuffer,
                         kProducerComputeWrite | kProducerStorageImageWrite});
                }
            }
            ComputeDispatchInfo::TextureBinding tb;
            if (img.multisampleStorageImage) {
                extensions::sparse_texture::MultisampleStorageImageSidecarInfo sidecarInfo;
                if (!extensions::sparse_texture::ensureMultisampleStorageImageSidecar(
                        extensionContext, *texObj, &sidecarInfo)) {
                    continue;
                }
                tb.metalTexture = sidecarInfo.metalTexture;
                const std::uint32_t slot =
                    img.metalBinding + static_cast<std::uint32_t>(arrayElement);
                if (slot >= msImageSampleCountsIndirect.size()) {
                    msImageSampleCountsIndirect.resize(
                        static_cast<std::size_t>(slot) + 1u, 1u);
                }
                msImageSampleCountsIndirect[slot] =
                    static_cast<std::uint32_t>(std::max<GLsizei>(sidecarInfo.samples, 1));
                hasMSImageSampleCountsIndirect = true;
                if (usesMSStorageSparseResidencyIndirect && texObj->metalTexture != nullptr) {
                    ComputeDispatchInfo::TextureBinding sparseResidencyBinding;
                    sparseResidencyBinding.metalTexture = texObj->metalTexture;
                    sparseResidencyBinding.metalSamplerState = nullptr;
                    sparseResidencyBinding.metalSlot =
                        slot + kMultisampleStorageSparseResidencyTextureSlotOffset;
                    info.textures.push_back(sparseResidencyBinding);
                }
            } else {
                extensions::sparse_texture::SparseStorageImageSidecarInfo sidecarInfo;
                const bool sparseWritableBound =
                    extensions::sparse_texture::textureSparse(extensionContext, texObj) == GL_TRUE &&
                    extensions::sparse_texture::isSparseStorageImageSidecarTarget(img.storageImageTarget) &&
                    texObj->target == img.storageImageTarget &&
                    ib.access != GL_READ_ONLY;
                const bool sparseSidecarAccess =
                    img.sparseStorageImageWrite || sparseWritableBound;
                const auto sparseRoute = sparseSidecarAccess
                    ? extensions::sparse_texture::resolveSparseStorageImageSidecarBinding(
                          extensionContext, *texObj, img.storageImageTarget, &sidecarInfo)
                    : extensions::sparse_texture::SparseStorageImageBindingRoute::NativeTexture;
                if (sparseRoute ==
                    extensions::sparse_texture::SparseStorageImageBindingRoute::SidecarTexture) {
                    tb.metalTexture =
                        impl_->resolveSparseSidecarImageMetalTexture(
                            ib, texObj, sidecarInfo);
                } else if (sparseRoute ==
                           extensions::sparse_texture::SparseStorageImageBindingRoute::SparseSidecarUnavailable) {
                    continue;
                } else {
                    if (ib.access != GL_READ_ONLY) {
                        (void)extensions::sparse_texture::ensureSparseStorageImageSidecar(
                            extensionContext, *texObj);
                    }
                    // CKPT119: level-restricted view when ib.level > 0.
                    tb.metalTexture = impl_->resolveImageMetalTexture(
                        ib, texObj, img.storageImageTarget);
                }
            }
            tb.metalSamplerState = nullptr;
            tb.metalSlot = img.metalBinding + static_cast<std::uint32_t>(arrayElement);
            if (img.metalAtomicBufferBinding != 0xFFFFFFFFu) {
                const std::string atomicNeedle = img.name + "_atomic";
                const bool usesImageAtomic =
                    programObject->computeMSL.find(atomicNeedle) != std::string::npos ||
                    programObject->computeMSL.find("_appgl_" + atomicNeedle) !=
                        std::string::npos;
                if (usesImageAtomic) {
                    tb.imageAtomicBufferSlot =
                        img.metalAtomicBufferBinding +
                        static_cast<std::uint32_t>(arrayElement);
                    if (texObj->target == GL_TEXTURE_BUFFER &&
                        texObj->desc.sourceBuffer != 0) {
                        GLBufferObject* backingBuffer =
                            impl_->objects->buffers().get(texObj->desc.sourceBuffer);
                        if (backingBuffer != nullptr &&
                            backingBuffer->metalBuffer != nullptr) {
                            tb.imageAtomicMetalBuffer =
                                backingBuffer->metalBuffer;
                            tb.imageAtomicBufferOffset =
                                static_cast<std::size_t>(
                                    std::max<GLintptr>(
                                        texObj->desc.bufferOffset, 0));
                        }
                    } else {
                        tb.imageAtomicMetalBuffer =
                            impl_->ensureTextureImageAtomicBuffer(*texObj);
                        tb.imageAtomicBufferOffset = 0;
                        if (tb.imageAtomicMetalBuffer != nullptr &&
                            ib.access != GL_READ_ONLY) {
                            texObj->imageAtomicBufferDirtyToTexture = true;
                        }
                    }
                }
            }
            info.textures.push_back(tb);
        }
    }
    if (hasMSImageSampleCountsIndirect) {
        info.multisampleStorageImageSampleCounts = msImageSampleCountsIndirect.data();
        info.multisampleStorageImageSampleCountBytes =
            msImageSampleCountsIndirect.size() * sizeof(std::uint32_t);
        info.multisampleStorageImageSampleCountSlot =
            multisampleStorageImageSampleCountSlotForMSL(programObject->computeMSL);
    }

    impl_->declareComputeDispatchSubmissionGroup(info, computeReads, computeWrites);
    impl_->drainPendingGpuProducers(computeReads);
    const bool encoded = impl_->frameGraph->encodeComputeDispatch(info);
    if (encoded) {
        impl_->markGpuResourceWrites(computeWrites);
        for (const auto& sync : fp64SsboSidecars) {
            if (sync.buffer != nullptr && sync.binding != nullptr &&
                sync.sidecar != nullptr) {
                impl_->syncFp64TransportSidecarBack(
                    *sync.buffer, *sync.binding, *sync.sidecar);
            }
        }
    }
    return true;
}

#elif defined(APPGL_GLCONTEXT_COMPUTE_REGION_TEXTURE_BARRIERS)
bool GLContext::memoryBarrierByRegion(GLbitfield barriers) {
    (void)barriers;
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
    }
    return true;
}

bool GLContext::textureBarrier() {
    if (impl_->frameGraph != nullptr) {
        impl_->frameGraph->flushParallelEncodeBoundary();
        // S24 C50 fix (texture_barrier 8-case P->F): glTextureBarrier
        // requires ALL prior writes to a texture -- including clears --
        // visible to subsequent reads in the same rendering pass
        // sequence. The lazy-shadow texture axis routes full-surface
        // clears through the C48 registry, which defers them into a
        // LATER pass's load action; a barrier between the clear and the
        // feedback read must land them now (the old eager
        // replaceMetalTexture push made them immediately visible).
        impl_->frameGraph->materializeAllPendingFboClears();
    }
    return true;
}

#else
#error "GLContextCompute.inc.mm included without a compute section selector"
#endif
