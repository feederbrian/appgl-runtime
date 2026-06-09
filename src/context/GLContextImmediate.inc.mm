// This file is textually included by GLContext.mm. Do not compile it directly.
// It contains GLContext immediate-mode method definitions split out for navigation only.

#if defined(APPGL_GLCONTEXT_IMMEDIATE_MODE)
// Phase 8X Group 4d follow-up¹⁷ — immediate-mode entry points.
//
// See the block comment in GLContext.h alongside the declarations for
// the rationale. These five methods form a small state machine that
// captures `{position, color, texcoord}` tuples between glBegin/glEnd
// and drains them to a built-in Metal pipeline on glEnd. State lives
// in `impl_->immediate`. `currentColor` / `currentTexcoord` are
// per-vertex registers updated by glColor*/glTexCoord* without
// emitting a vertex; only glVertex* pushes into the capture vector.

void GLContext::beginImmediate(GLenum mode) {
    switch (mode) {
        case GL_TRIANGLES:
        case GL_TRIANGLE_STRIP:
        case GL_TRIANGLE_FAN:
        case GL_QUADS:
        case GL_LINES:
        case GL_LINE_STRIP:
        case GL_LINE_LOOP:
        case GL_POINTS:
            break;
        default:
            pushError(GL_INVALID_ENUM);
            return;
    }
    if (impl_->immediate.active) {
        // Nested glBegin is invalid in the GL spec.
        pushError(GL_INVALID_OPERATION);
        return;
    }
    impl_->immediate.active = true;
    impl_->immediate.mode = mode;
    impl_->immediate.vertices.clear();
}

void GLContext::immediateVertex(float x, float y, float z, float w) {
    if (!impl_->immediate.active) {
        // glVertex* outside glBegin/glEnd is silently ignored per GL 1.x.
        // (The function exists but does nothing when not inside a begin/end pair.)
        return;
    }
    Impl::ImmediateModeVertex v;
    v.position[0] = x;
    v.position[1] = y;
    v.position[2] = z;
    v.position[3] = w;
    v.color[0] = impl_->immediate.currentColor[0];
    v.color[1] = impl_->immediate.currentColor[1];
    v.color[2] = impl_->immediate.currentColor[2];
    v.color[3] = impl_->immediate.currentColor[3];
    v.texcoord[0] = impl_->immediate.currentTexcoord[0];
    v.texcoord[1] = impl_->immediate.currentTexcoord[1];
    impl_->immediate.vertices.push_back(v);
}

void GLContext::immediateColor(float r, float g, float b, float a) {
    // Per GL 1.x spec, glColor* is valid outside begin/end and simply
    // updates the current color register; it's read by the next glVertex*
    // inside a begin/end pair.
    impl_->immediate.currentColor[0] = r;
    impl_->immediate.currentColor[1] = g;
    impl_->immediate.currentColor[2] = b;
    impl_->immediate.currentColor[3] = a;
}

void GLContext::immediateTexCoord(unsigned int unit, float s, float t, float /*r*/, float /*q*/) {
    // Only texture unit 0 is captured for the built-in immediate-mode
    // pipeline (Chobby/Chili UI only uses unit 0). Multi-texturing on
    // other units is silently ignored — this matches the single-
    // sampler pipeline we build in MetalFrameGraph.
    if (unit != 0) {
        return;
    }
    impl_->immediate.currentTexcoord[0] = s;
    impl_->immediate.currentTexcoord[1] = t;
}

void GLContext::endImmediate() {
    if (!impl_->immediate.active) {
        pushError(GL_INVALID_OPERATION);
        return;
    }
    impl_->immediate.active = false;

    const GLenum mode = impl_->immediate.mode;
    auto& captured = impl_->immediate.vertices;
    if (captured.empty()) {
        return;
    }
    if (impl_->frameGraph == nullptr) {
        return;
    }

    // GL_QUADS → GL_TRIANGLES CPU-side expansion. Metal core has no
    // quads primitive, so every 4 captured vertices become 6 output
    // vertices using the canonical {0,1,2, 0,2,3} fan pattern.
    std::vector<Impl::ImmediateModeVertex> expanded;
    const Impl::ImmediateModeVertex* drawVerts = captured.data();
    std::size_t drawCount = captured.size();
    GLenum drawMode = mode;
    if (mode == GL_QUADS) {
        const std::size_t quads = captured.size() / 4;
        expanded.reserve(quads * 6);
        for (std::size_t q = 0; q < quads; ++q) {
            const Impl::ImmediateModeVertex& v0 = captured[q * 4 + 0];
            const Impl::ImmediateModeVertex& v1 = captured[q * 4 + 1];
            const Impl::ImmediateModeVertex& v2 = captured[q * 4 + 2];
            const Impl::ImmediateModeVertex& v3 = captured[q * 4 + 3];
            expanded.push_back(v0);
            expanded.push_back(v1);
            expanded.push_back(v2);
            expanded.push_back(v0);
            expanded.push_back(v2);
            expanded.push_back(v3);
        }
        drawVerts = expanded.data();
        drawCount = expanded.size();
        drawMode = GL_TRIANGLES;
    }

    // Ensure any pending clear is flushed before the encode.
    impl_->ensureDefaultDrawableForViewportExtent();
    impl_->encodePendingWork();

    // Resolve the texture bound to unit 0 GL_TEXTURE_2D, if any.
    // The textured pipeline samples it; the untextured pipeline ignores
    // the slot entirely.
    void* metalTexture = nullptr;
    const GLuint texName = impl_->state->boundTextureOnUnit(0, GL_TEXTURE_2D);
    if (texName != 0) {
        GLTextureObject* tex = impl_->objects->textures().get(texName);
        if (tex != nullptr && tex->metalTexture != nullptr) {
            metalTexture = tex->metalTexture;
        }
    }

    // Build the MVP from the matrix mirror (proj · modelview); the
    // immediate-mode vertex shader applies it to each captured position.
    const Matrix4 mvp = impl_->matrixState.modelViewProjection();

    ImmediateDrawInfo info;
    info.mode = drawMode;
    info.vertices = drawVerts;
    info.vertexCount = drawCount;
    info.vertexStride = sizeof(Impl::ImmediateModeVertex);
    info.mvp = mvp;
    info.metalTexture = metalTexture;
    info.fragmentShadingRate = GL_SHADING_RATE_1X1_PIXELS_EXT;

    const bool ok = impl_->frameGraph->encodeImmediateModeDraw(info);
    if (ok) {
        impl_->markBoundDrawFramebufferWrites();
    }
    if (ok && impl_->state->boundDrawFramebuffer() == 0) {
        impl_->invalidateDefaultFramebufferShadow();
    }
    if (!ok) {
        emitDebugMessage(
            GL_DEBUG_SOURCE_API,
            GL_DEBUG_TYPE_ERROR,
            0,
            GL_DEBUG_SEVERITY_HIGH,
            "glEnd: MetalFrameGraph failed to encode immediate-mode draw"
        );
    }
}

#else
#error "GLContextImmediate.inc.mm included without an immediate-mode section selector"
#endif
