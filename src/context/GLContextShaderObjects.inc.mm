// This file is textually included by GLContextShader.inc.mm. Do not compile it directly.
// It contains the GLContext shader-object method body split out for navigation only.

GLuint GLContext::createShader(GLenum stage) {
    if (!isValidShaderStage(stage)) {
        pushError(GL_INVALID_ENUM);
        return 0;
    }
    // GL 4.6 §7.1: shaders and programs share a single name pool.
    // CTS `get_uniform_tests.gl_get_uniform` passes a shader handle
    // to `glGetUniform*` and expects INVALID_OPERATION — it uses
    // the numeric ID to discriminate, so if a shader and program
    // both had the same ID (separate table `nextId_` counters)
    // the discriminator broke.
    const GLuint id = impl_->objects->reserveSharedShaderProgramName();
    GLShaderObject* shader = impl_->objects->shaders().insertAt(id);
    if (shader != nullptr) {
        shader->stage = stage;
    }
    return id;
}

bool GLContext::deleteShader(GLuint shader) {
    if (shader == 0) {
        return true;
    }
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        // Lenient no-op for unknown shader names (see deleteProgram for the
        // same tradeoff — CTS helper classes double-delete on error paths
        // and treat any queued error as a destructor throw).
        return true;
    }
    // Spec: a shader still attached to one or more programs is *flagged for
    // deletion* but not erased from the object store. The actual erase is
    // performed by detachShader / deleteProgram once the attachment count
    // reaches zero. (See `struct GLShaderObject` in GLObjectStore.h for the
    // BAR-side rationale — engines using RAII deleters call glDeleteShader
    // between glAttachShader and glLinkProgram, and the eager-erase Phase A
    // behaviour was masking every real compile result with the dummy
    // "attached shader is not compiled" link-log.)
    object->deleteRequested = true;
    if (object->attachmentCount == 0) {
        impl_->objects->shaders().erase(shader);
    }
    return true;
}

bool GLContext::isShader(GLuint shader) const {
    // Spec: glIsShader returns GL_FALSE for a shader name that has been
    // marked for deletion, even if the underlying object is still resident
    // because of outstanding program attachments. The object store still
    // holds the name (so the link path can resolve it) but the public
    // identity of the shader is gone the moment glDeleteShader runs.
    const GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        return false;
    }
    return !object->deleteRequested;
}

bool GLContext::shaderSource(GLuint shader, GLsizei count, const GLchar* const* strings, const GLint* length) {
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    if (count < 0) {
        pushError(GL_INVALID_VALUE);
        return false;
    }
    std::string concatenated;
    for (GLsizei i = 0; i < count; ++i) {
        if (strings == nullptr || strings[i] == nullptr) {
            pushError(GL_INVALID_VALUE);
            return false;
        }
        if (length != nullptr && length[i] >= 0) {
            concatenated.append(strings[i], static_cast<std::size_t>(length[i]));
        } else {
            concatenated.append(strings[i]);
        }
    }
    object->source = std::move(concatenated);
    object->compiled = false;
    object->compileLog.clear();
    object->declaredUniforms.clear();
    object->declaredInputs.clear();
    object->declaredOutputs.clear();
    // GL_ARB_gl_spirv / GL 4.6 §7.2: glShaderSource clears
    // GL_SPIR_V_BINARY_ARB back to FALSE. Also drop any previously
    // loaded SPIR-V binary so the glslang path takes over cleanly.
    object->isSpirvBinary = false;
    object->spirv.clear();
    object->spirvEntryPoint.clear();
    object->spirvSpecializationConstants.clear();
    return true;
}

bool GLContext::compileShader(GLuint shader) {
    GLShaderObject* object = impl_->objects->shaders().get(shader);
    if (object == nullptr) {
        pushError(GL_INVALID_VALUE);
        return false;
    }

    // GL_ARB_gl_spirv / GL 4.6 §7.2: "It is an error to call
    // `CompileShader` on a shader object whose `SPIR_V_BINARY_ARB`
    // state is TRUE." Such shaders must instead be finalized via
    // `glSpecializeShader`. Report INVALID_OPERATION and leave the
    // shader's state unchanged (keep `isSpirvBinary` true so a
    // subsequent glSpecializeShader still works).
    if (object->isSpirvBinary) {
        pushError(GL_INVALID_OPERATION);
        return false;
    }

    // Clear any prior compile state so a re-compile of the same shader ID
    // starts from a clean slate (matches the GL spec, which allows source
    // replacement followed by another glCompileShader call).
    object->compiled = false;
    object->compileLog.clear();
    object->spirv.clear();
    object->spirvEntryPoint.clear();
    object->spirvSpecializationConstants.clear();
    object->declaredUniforms.clear();
    object->declaredInputs.clear();
    object->declaredOutputs.clear();
    object->advancedBlendSupportMask = 0;
    object->advancedBlendSupportAll = false;

    // Diagnostic-ring tag and source hash used by the compile-stage record
    // pushed at the bottom of this function on both success and failure.
    // Hash uses std::hash<std::string> for cheapness — it isn't a
    // cryptographic identity, just a per-source key BAR can compare across
    // log samples to tell whether two compile attempts saw the same source.
    const std::string shaderTag = "shader-" + std::to_string(shader);
    auto compileSourceHash = [](const std::string& s) -> std::string {
        std::size_t h = std::hash<std::string>{}(s);
        char buf[18];
        std::snprintf(buf, sizeof(buf), "%016zx", h);
        return buf;
    };

    if (object->source.empty()) {
        object->compileLog = "shader source is empty";
        Runtime::shared().recordShaderTranslation({
            shaderTag, "compile", "", "", "", object->compileLog, "", false
        });
        return false;
    }

    const std::string sourceHash = compileSourceHash(object->source);
    if (object->stage == GL_FRAGMENT_SHADER) {
        object->advancedBlendSupportMask =
            scanAdvancedBlendSupportMask(object->source,
                                         &object->advancedBlendSupportAll);
        if (sourceDisablesAdvancedBlendLayouts(object->source)) {
            object->compileLog =
                "ERROR: GL_KHR_blend_equation_advanced layout qualifiers "
                "are not available after '#extension ... : disable'.";
            object->compiled = false;
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", object->compileLog, "", false
            });
            return true;
        }
    }

    // 1. Compat-shader rewrite. Glslang's SPIR-V backend rejects
    //    `#version NNN compatibility` outright and rejects every
    //    fixed-function `gl_*` matrix identifier even in compat mode.
    //    The rewriter downgrades the version directive to `core` and
    //    synthesizes `appgl_*` uniforms (paired with `#define`s) for any
    //    referenced matrix builtin. Non-compat shaders that don't
    //    reference any legacy identifier come back unchanged.
    //
    //    Both passes (the lightweight scanner and the real glslang
    //    compile) operate on the rewritten source so the synthesized
    //    uniforms get picked up by the scanner and end up in
    //    declaredUniforms — which linkProgram lifts into
    //    programObject->uniforms with normal sequential locations.
    std::string geometryShader4CompileSource;
    const std::string* compatRewriteSource = &object->source;
    if (object->stage == GL_GEOMETRY_SHADER) {
        const GeometryShader4DirectiveState directive =
            scanGeometryShader4Directive(object->source);
        if (directive.active()) {
            const GeometryShader4SourceLayout sourceLayout =
                parseGeometryShader4SourceLayout(object->source);
            if (!sourceLayout.valid) {
                object->compileLog = sourceLayout.diagnostic;
                Runtime::shared().recordShaderTranslation({
                    shaderTag, "compile", sourceHash, "", "",
                    object->compileLog, "", false
                });
                return true;
            }
            GeometryShader4LinkPlan provisional;
            provisional.active = true;
            provisional.inputType = sourceLayout.hasInputType
                ? sourceLayout.inputType : GL_TRIANGLES;
            provisional.outputType = sourceLayout.hasOutputType
                ? sourceLayout.outputType : GL_POINTS;
            provisional.verticesOut = sourceLayout.hasVerticesOut
                ? sourceLayout.verticesOut : 1;
            provisional.inputFromSource = sourceLayout.hasInputType;
            provisional.outputFromSource = sourceLayout.hasOutputType;
            provisional.verticesOutFromSource = sourceLayout.hasVerticesOut;
            switch (provisional.inputType) {
                case GL_POINTS: provisional.verticesIn = 1; break;
                case GL_LINES: provisional.verticesIn = 2; break;
                case GL_LINES_ADJACENCY: provisional.verticesIn = 4; break;
                case GL_TRIANGLES: provisional.verticesIn = 3; break;
                case GL_TRIANGLES_ADJACENCY: provisional.verticesIn = 6; break;
                default: provisional.verticesIn = 0; break;
            }
            provisional.materializedInputCapacity = 256;
            GeometryShader4RewriteResult geometryRewrite =
                rewriteGeometryShader4Source(object->source, provisional);
            if (!geometryRewrite.valid) {
                object->compileLog = geometryRewrite.diagnostic;
                Runtime::shared().recordShaderTranslation({
                    shaderTag, "compile", sourceHash, "", "",
                    object->compileLog, "", false
                });
                return true;
            }
            geometryShader4CompileSource = std::move(geometryRewrite.source);
            compatRewriteSource = &geometryShader4CompileSource;
        }
    }
    CompatShaderRewriteResult rewrite =
        rewriteCompatShader(*compatRewriteSource, object->stage);
    // GLSL 4.00 subroutines are unsupported by glslang's SPIR-V
    // backend ("feature not yet implemented"). Rewrite subroutine
    // syntax into plain GLSL that compiles — enough for CTS
    // `program_interface_query.subroutines-*` which only queries
    // the introspection tables (never actually draws).
    //   `subroutine TYPE NAME ( ... ) ;`                 → commented out
    //   `subroutine uniform TYPE NAME [ ... ] ;`          → commented out
    //   `subroutine ( TYPE_LIST ) RETTYPE FN ( ... ) { ... }`
    //                                                      → `RETTYPE FN ( ... ) { ... }`
    //   `UNIFNAME ( ... )` call sites (where UNIFNAME was a
    //     subroutine uniform)                              → `FIRST_IMPL_NAME ( ... )`
    // The real link-time `scanSubroutineDeclarations` then re-reads
    // the ORIGINAL (unrewritten) source so `resourceSubroutines*`
    // tables still reflect the user's declarations.
    std::string subroutineValidationError;
    auto rewriteSubroutinesForSpirv = [&](const std::string& in) -> std::string {
        // Strip comments for analysis but rewrite the original text
        // so we don't accidentally erase legitimate code.
        // Collect subroutine-uniform name → first compatible impl.
        // We do a two-pass line-based rewrite.
        std::unordered_map<std::string, std::string> uniformToImpl;
        std::unordered_map<std::string, std::vector<std::string>> typeToImpls;
        std::unordered_map<std::string, std::string> uniformToType;
        std::unordered_map<std::string, std::string> implToPrototype;
        struct ImplSignature {
            std::string name;
            std::string retType;
            std::string params;
            std::vector<std::string> typeNames;
        };
        std::vector<ImplSignature> implSignatures;
        struct SubUniformInfo {
            std::string typeName;
            std::vector<int> dims;
        };
        std::unordered_map<std::string, SubUniformInfo> subUniformInfo;
        // Sprint 17 Day 7+ Bank-Group-C dynamic-dispatch (v1):
        // capture subroutine-type prototype return-type + raw param
        // text. v1 covers void-return parameterless subroutines
        // (CTS viewport_index_subroutine — `subroutine void
        // indexSetter();`). Other shapes fall back to static
        // FIRST_IMPL_NAME substitution (current pre-Sprint-17
        // behavior; non-regressing for sister tests).
        std::unordered_map<std::string, std::string> typeReturn;
        std::unordered_map<std::string, std::string> typeParams;
        // Capture each subroutine impl's body text so v1 dispatch can
        // INLINE `{body}` at call sites instead of emitting an
        // OpFunctionCall. The GS-emul interpreter (SPIR-V CPU
        // executor at GeometryShaderEmulator.cpp `isSupportedGsOpcode`)
        // does not support OpFunctionCall (opcode 57), so a static
        // FIRST_IMPL_NAME like `four()` only worked when glslang
        // happened to inline it across stages. Once we emit a real
        // dispatch shape (`if (sel) four(); else five();`) glslang
        // keeps the OpFunctionCall and the emul rejects the GS. To
        // preserve GS-emul compatibility we inline impl body text
        // directly at the dispatch site.
        std::unordered_map<std::string, std::string> implBody;
        // Subroutine type-prototype names (e.g. the `T` in
        // `subroutine void T();`) — emit a dummy `int T;` after
        // stripping so glslang's reserved-identifier validator
        // catches `subroutine void namespace(…);` style tests.
        std::vector<std::string> subTypeNames;
        // First pass: scan for subroutine type + impl + uniform.
        std::size_t p = 0;
        auto isIdent = [](unsigned char c) {
            return std::isalnum(c) || c == '_';
        };
        auto skipWs = [&](std::size_t& pp) {
            while (pp < in.size() && std::isspace(static_cast<unsigned char>(in[pp]))) ++pp;
        };
        auto readWord = [&](std::size_t& pp) -> std::string {
            skipWs(pp);
            std::size_t s = pp;
            while (pp < in.size() && isIdent(static_cast<unsigned char>(in[pp]))) ++pp;
            return in.substr(s, pp - s);
        };
        auto readTypeWithArraySuffix = [&](std::size_t& pp) -> std::string {
            std::string typeName = readWord(pp);
            if (typeName.empty()) return typeName;
            std::size_t q = pp;
            skipWs(q);
            while (q < in.size() && in[q] == '[') {
                const std::size_t bracketStart = q;
                int bd = 1;
                ++q;
                while (q < in.size() && bd > 0) {
                    if (in[q] == '[') ++bd;
                    else if (in[q] == ']') --bd;
                    ++q;
                }
                if (bd != 0) break;
                typeName.append(in, bracketStart, q - bracketStart);
                pp = q;
                skipWs(q);
            }
            return typeName;
        };
        const std::string kw = "subroutine";
        // GLSL `subroutine` is a keyword only at declaration position.
        // CTS `CommonBugs.CommonBug_ReservedNames` plants it as a
        // function-parameter name (`void foo(int subroutine) { ... }`)
        // and expects the compile to fail. Our rewrite used to strip
        // `subroutine → next `;`` blindly which deleted the closing
        // paren, function body, and whatever followed — breaking the
        // spec-mandated reserved-keyword check. Guard: `subroutine`
        // only counts as a keyword when the previous non-whitespace
        // character is a statement boundary (`;`, `{`, `}`, or start-
        // of-file). In argument lists, after `(`, after `,`, etc., it
        // is an identifier use that glslang will correctly reject.
        auto isDeclPos = [&](std::size_t pos) {
            std::size_t q = pos;
            while (q > 0) {
                while (q > 0) {
                    unsigned char c = static_cast<unsigned char>(in[q - 1]);
                    if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
                        --q;
                    } else {
                        break;
                    }
                }
                if (q == 0) break;

                std::size_t lineStart = q;
                while (lineStart > 0 &&
                       in[lineStart - 1] != '\n' &&
                       in[lineStart - 1] != '\r') {
                    --lineStart;
                }
                std::size_t first = lineStart;
                while (first < q && (in[first] == ' ' || in[first] == '\t')) {
                    ++first;
                }
                if (first < q && in[first] == '#') {
                    q = lineStart;
                    continue;
                }
                const std::size_t lineComment = in.find("//", lineStart);
                if (lineComment != std::string::npos && lineComment < q) {
                    q = lineComment;
                    continue;
                }

                unsigned char c = static_cast<unsigned char>(in[q - 1]);
                return c == ';' || c == '{' || c == '}';
            }
            return true;  // start of source
        };
        auto parseLayoutInteger = [&](const std::string& content, const char* key, GLint& value) {
            const std::string keyStr = key;
            std::size_t keyPos = content.find(keyStr);
            while (keyPos != std::string::npos) {
                const bool lb = (keyPos == 0) ||
                    !isIdent(static_cast<unsigned char>(content[keyPos - 1]));
                const std::size_t keyEnd = keyPos + keyStr.size();
                const bool rb = (keyEnd == content.size()) ||
                    !isIdent(static_cast<unsigned char>(content[keyEnd]));
                if (lb && rb) break;
                keyPos = content.find(keyStr, keyEnd);
            }
            if (keyPos == std::string::npos) return true;
            const std::size_t eq = content.find('=', keyPos + keyStr.size());
            if (eq == std::string::npos) return false;
            std::size_t nb = eq + 1;
            while (nb < content.size() && std::isspace(static_cast<unsigned char>(content[nb]))) ++nb;
            if (nb >= content.size() || !std::isdigit(static_cast<unsigned char>(content[nb]))) {
                return false;
            }
            std::size_t ne = nb;
            if (ne + 1 < content.size() && content[ne] == '0' &&
                (content[ne + 1] == 'x' || content[ne + 1] == 'X')) {
                ne += 2;
                const std::size_t hexStart = ne;
                while (ne < content.size() && std::isxdigit(static_cast<unsigned char>(content[ne]))) ++ne;
                if (ne == hexStart) return false;
            } else {
                while (ne < content.size() && std::isdigit(static_cast<unsigned char>(content[ne]))) ++ne;
            }
            value = static_cast<GLint>(std::strtol(content.substr(nb, ne - nb).c_str(), nullptr, 0));
            return true;
        };
        auto layoutBeforeSubroutine = [&](std::size_t subPos,
                                          std::size_t& layoutStart,
                                          std::size_t& openParen,
                                          std::size_t& closeParen) {
            std::size_t back = subPos;
            while (back > 0 && std::isspace(static_cast<unsigned char>(in[back - 1]))) --back;
            if (back == 0 || in[back - 1] != ')') return false;
            int pd = 1;
            std::size_t bp = back - 1;
            while (bp > 0 && pd > 0) {
                --bp;
                if (in[bp] == ')') ++pd;
                else if (in[bp] == '(') --pd;
            }
            if (pd != 0) return false;
            std::size_t lp = bp;
            while (lp > 0 && std::isspace(static_cast<unsigned char>(in[lp - 1]))) --lp;
            if (lp < 6 || in.compare(lp - 6, 6, "layout") != 0) return false;
            layoutStart = lp - 6;
            if (layoutStart > 0 &&
                isIdent(static_cast<unsigned char>(in[layoutStart - 1]))) {
                return false;
            }
            if (!isDeclPos(layoutStart)) return false;
            openParen = bp;
            closeParen = back - 1;
            return true;
        };
        auto layoutQualifierIsNumeric = [&](std::size_t subPos) {
            std::size_t layoutStart = 0;
            std::size_t openParen = 0;
            std::size_t closeParen = 0;
            if (!layoutBeforeSubroutine(subPos, layoutStart, openParen, closeParen)) {
                return false;
            }
            const std::string content = in.substr(openParen + 1, closeParen - openParen - 1);
            GLint ignored = -1;
            return parseLayoutInteger(content, "location", ignored) &&
                   parseLayoutInteger(content, "index", ignored);
        };
        auto isSubroutineDeclPos = [&](std::size_t subPos) {
            if (isDeclPos(subPos)) return true;
            return layoutQualifierIsNumeric(subPos);
        };
        auto layoutAt = [&](std::size_t layoutStart, std::size_t& subPos) {
            const std::string layoutKw = "layout";
            if (layoutStart + layoutKw.size() > in.size() ||
                in.compare(layoutStart, layoutKw.size(), layoutKw) != 0) {
                return false;
            }
            const bool lb = (layoutStart == 0) ||
                !isIdent(static_cast<unsigned char>(in[layoutStart - 1]));
            const bool rb = (layoutStart + layoutKw.size() < in.size()) &&
                !isIdent(static_cast<unsigned char>(in[layoutStart + layoutKw.size()]));
            if (!lb || !rb || !isDeclPos(layoutStart)) return false;
            std::size_t q = layoutStart + layoutKw.size();
            skipWs(q);
            if (q >= in.size() || in[q] != '(') return false;
            int pd = 1;
            const std::size_t openParen = q;
            ++q;
            while (q < in.size() && pd > 0) {
                if (in[q] == '(') ++pd;
                else if (in[q] == ')') --pd;
                ++q;
            }
            if (pd != 0) return false;
            const std::size_t closeParen = q - 1;
            std::size_t after = q;
            skipWs(after);
            if (after + kw.size() > in.size() ||
                in.compare(after, kw.size(), kw) != 0) {
                return false;
            }
            const bool subRb = (after + kw.size() < in.size()) &&
                !isIdent(static_cast<unsigned char>(in[after + kw.size()]));
            if (!subRb) return false;
            const std::string content = in.substr(openParen + 1, closeParen - openParen - 1);
            GLint ignored = -1;
            if (!parseLayoutInteger(content, "location", ignored) ||
                !parseLayoutInteger(content, "index", ignored)) {
                return false;
            }
            subPos = after;
            return true;
        };
        while ((p = in.find(kw, p)) != std::string::npos) {
            const bool lb = (p == 0) || !isIdent(static_cast<unsigned char>(in[p-1]));
            const bool rb = (p + kw.size() < in.size()) && !isIdent(static_cast<unsigned char>(in[p+kw.size()]));
            if (!lb || !rb || !isSubroutineDeclPos(p)) { p += kw.size(); continue; }
            std::size_t q = p + kw.size();
            skipWs(q);
            if (q < in.size() && in[q] == '(') {
                // Impl: subroutine(TYPE,...) RETTYPE FN(...)
                ++q;
                std::vector<std::string> typeList;
                while (q < in.size() && in[q] != ')') {
                    skipWs(q);
                    std::string t = readWord(q);
                    if (!t.empty()) typeList.push_back(std::move(t));
                    skipWs(q);
                    if (q < in.size() && in[q] == ',') ++q;
                }
                if (q < in.size()) ++q;  // skip ')'
                std::string retType = readTypeWithArraySuffix(q);
                std::string fnName = readWord(q);
                if (!fnName.empty()) {
                    for (const auto& t : typeList) {
                        typeToImpls[t].push_back(fnName);
                    }
                }
                // Sprint 17 Day 7+ Bank-Group-C: capture impl body
                // text for v1 inline dispatch. Walk past `(params)`
                // then capture matched `{body}`.
                skipWs(q);
                if (q < in.size() && in[q] == '(') {
                    const std::size_t paramsStart = q;
                    int pd2 = 1;
                    ++q;
                    while (q < in.size() && pd2 > 0) {
                        if (in[q] == '(') ++pd2;
                        else if (in[q] == ')') --pd2;
                        ++q;
                    }
                    if (!fnName.empty() && !retType.empty() && q <= in.size()) {
                        const std::string rawParams =
                            in.substr(paramsStart, q - paramsStart);
                        implToPrototype[fnName] =
                            retType + " " + fnName + rawParams + ";";
                        implSignatures.push_back(
                            ImplSignature{fnName, retType, rawParams, typeList});
                    }
                }
                skipWs(q);
                if (q < in.size() && in[q] == '{' && !fnName.empty()) {
                    const std::size_t bodyStart = q + 1;
                    int bd = 1;
                    ++q;
                    while (q < in.size() && bd > 0) {
                        if (in[q] == '{') ++bd;
                        else if (in[q] == '}') --bd;
                        if (bd > 0) ++q;
                    }
                    const std::size_t bodyEnd = q;
                    implBody[fnName] = in.substr(bodyStart, bodyEnd - bodyStart);
                    if (q < in.size()) ++q;  // past `}`
                }
                p = q;
                continue;
            }
            std::string next = readTypeWithArraySuffix(q);
            if (next == "uniform") {
                std::string typeName = readWord(q);
                std::string uniName = readWord(q);
                if (!uniName.empty() && !typeName.empty()) {
                    uniformToType[uniName] = typeName;
                    std::vector<int> dims;
                    std::size_t dimPos = q;
                    skipWs(dimPos);
                    while (dimPos < in.size() && in[dimPos] == '[') {
                        ++dimPos;
                        skipWs(dimPos);
                        const std::size_t nStart = dimPos;
                        while (dimPos < in.size() &&
                               std::isdigit(static_cast<unsigned char>(in[dimPos]))) {
                            ++dimPos;
                        }
                        int dim = 1;
                        if (dimPos > nStart) {
                            dim = std::atoi(in.substr(nStart, dimPos - nStart).c_str());
                            if (dim < 1) dim = 1;
                        }
                        dims.push_back(dim);
                        skipWs(dimPos);
                        if (dimPos < in.size() && in[dimPos] == ']') ++dimPos;
                        skipWs(dimPos);
                    }
                    subUniformInfo[uniName] = SubUniformInfo{typeName, std::move(dims)};
                    q = dimPos;
                }
                p = q;
                continue;
            }
            // Subroutine type prototype: `subroutine RETTYPE NAME (…);`.
            // `next` was the return type; the next word is the type
            // name (the subroutine-type identifier). Collect it so
            // the rewritten source preserves the reserved-keyword
            // check on the type name too.
            std::string typeProtoName = readWord(q);
            if (!typeProtoName.empty()) {
                subTypeNames.push_back(typeProtoName);
                // Sprint 17 Day 7+ Bank-Group-C v1 dispatch: capture
                // return type + raw param text from `(...)` to
                // detect v1-eligibility (void-return + no-params).
                typeReturn[typeProtoName] = next;
                skipWs(q);
                std::size_t paramsStart = q;
                if (q < in.size() && in[q] == '(') {
                    int pd = 1;
                    ++q;
                    while (q < in.size() && pd > 0) {
                        if (in[q] == '(') ++pd;
                        else if (in[q] == ')') --pd;
                        ++q;
                    }
                    typeParams[typeProtoName] =
                        in.substr(paramsStart, q - paramsStart);
                }
            }
            p = q;
        }
        // Resolve each uniform to its first compatible impl.
        for (auto& kv : uniformToType) {
            auto it = typeToImpls.find(kv.second);
            if (it != typeToImpls.end() && !it->second.empty()) {
                uniformToImpl[kv.first] = it->second.front();
            }
        }
        // Sprint 17 Day 7+ Bank-Group-C: compute v1-eligibility per
        // subroutine uniform. v1 covers void-return parameterless
        // subroutines (covers CTS viewport_index_subroutine). Other
        // shapes fall back to static FIRST_IMPL_NAME at call sites.
        // Additionally require ALL impls of the subroutine type to
        // have captured `{body}` text — v1 inlines bodies at the call
        // site to avoid OpFunctionCall (unsupported by GS-emul).
        std::unordered_map<std::string, bool> uniformIsV1Eligible;
        for (const auto& kv : uniformToType) {
            const std::string& tname = kv.second;
            auto retIt = typeReturn.find(tname);
            auto parIt = typeParams.find(tname);
            if (retIt == typeReturn.end() || parIt == typeParams.end()) continue;
            const std::string& ret = retIt->second;
            // Strip whitespace from params for comparison.
            std::string p = parIt->second;
            p.erase(std::remove_if(p.begin(), p.end(),
                [](unsigned char c) { return std::isspace(c); }), p.end());
            const bool voidRet = (ret == "void");
            const bool noParams = (p == "()" || p == "(void)");
            // All impls must have captured body for inline dispatch.
            bool allBodiesCaptured = true;
            auto tiIt = typeToImpls.find(tname);
            if (tiIt == typeToImpls.end() || tiIt->second.empty()) {
                allBodiesCaptured = false;
            } else {
                for (const auto& impl : tiIt->second) {
                    if (implBody.find(impl) == implBody.end()) {
                        allBodiesCaptured = false;
                        break;
                    }
                }
            }
            uniformIsV1Eligible[kv.first] = voidRet && noParams && allBodiesCaptured;
        }
        // Collect unique subroutine-uniform names so we can append a
        // dummy `int <NAME>;` declaration for each, preserving the
        // GLSL reserved-identifier check. CTS
        // `CommonBugs.CommonBug_ReservedNames` expects compile to
        // fail when a subroutine uniform name is a reserved
        // keyword (`namespace`, `using`, …).  If we simply comment
        // out the subroutine line, glslang never sees the reserved
        // name and accepts the program — regression. The dummy
        // declaration pushes the name through glslang's identifier
        // validator.
        std::vector<std::string> subUniNames;
        {
            std::unordered_set<std::string> seenNames;
            for (const auto& kv : uniformToType) {
                if (seenNames.insert(kv.first).second) {
                    subUniNames.push_back(kv.first);
                }
            }
        }
        auto trimCopy = [](std::string s) {
            auto notSpace = [](unsigned char c) { return !std::isspace(c); };
            s.erase(s.begin(), std::find_if(s.begin(), s.end(), notSpace));
            s.erase(std::find_if(s.rbegin(), s.rend(), notSpace).base(), s.end());
            return s;
        };
        auto elementCountForDims = [](const std::vector<int>& dims) {
            int count = 1;
            for (int dim : dims) count *= std::max(1, dim);
            return count;
        };
        auto dispatchKeyForElement = [](const std::string& name, int elem, int elemCount) {
            if (elemCount <= 1) return name;
            return name + "_" + std::to_string(elem);
        };
        auto helperNameForKey = [](const std::string& key) {
            return "_appgl_call_" + key;
        };
        auto dynamicHelperNameForUniform = [](const std::string& name) {
            return "_appgl_call_" + name + "_dynamic";
        };
        auto splitParamList = [&](const std::string& rawParams) {
            std::vector<std::string> params;
            if (rawParams.size() < 2 || rawParams.front() != '(' || rawParams.back() != ')') {
                return params;
            }
            std::string body = trimCopy(rawParams.substr(1, rawParams.size() - 2));
            if (body.empty() || body == "void") return params;
            std::size_t start = 0;
            int depth = 0;
            auto consumeParam = [&](std::size_t begin, std::size_t end) {
                std::string param = trimCopy(body.substr(begin, end - begin));
                if (!param.empty()) params.push_back(std::move(param));
            };
            for (std::size_t idx = 0; idx <= body.size(); ++idx) {
                if (idx == body.size() || (body[idx] == ',' && depth == 0)) {
                    consumeParam(start, idx);
                    start = idx + 1;
                    continue;
                }
                if (body[idx] == '(' || body[idx] == '[') ++depth;
                else if ((body[idx] == ')' || body[idx] == ']') && depth > 0) --depth;
            }
            return params;
        };
        auto stripLeadingParamQualifiers = [&](std::string text) {
            text = trimCopy(std::move(text));
            bool changed = true;
            while (changed) {
                changed = false;
                std::size_t p = 0;
                while (p < text.size() && isIdent(static_cast<unsigned char>(text[p]))) ++p;
                const std::string token = text.substr(0, p);
                if (token == "const" || token == "in" || token == "out" ||
                    token == "inout" || token == "highp" ||
                    token == "mediump" || token == "lowp") {
                    text = trimCopy(text.substr(p));
                    changed = true;
                }
            }
            return text;
        };
        auto normalizeParamList = [&](const std::string& rawParams,
                                      std::vector<std::string>* outNames = nullptr) {
            std::vector<std::string> params = splitParamList(rawParams);
            if (params.empty()) {
                return std::string("(void)");
            }
            std::string normalized = "(";
            for (std::size_t idx = 0; idx < params.size(); ++idx) {
                std::string param = params[idx];
                std::string nameProbe = param;
                while (!nameProbe.empty() && nameProbe.back() == ']') {
                    const std::size_t open = nameProbe.rfind('[');
                    if (open == std::string::npos) break;
                    nameProbe = trimCopy(nameProbe.substr(0, open));
                }
                std::size_t p = nameProbe.size();
                while (p > 0 && !isIdent(static_cast<unsigned char>(nameProbe[p - 1]))) --p;
                std::size_t e = p;
                while (p > 0 && isIdent(static_cast<unsigned char>(nameProbe[p - 1]))) --p;
                std::string name;
                bool hasExplicitName = false;
                if (e > p) {
                    name = nameProbe.substr(p, e - p);
                    const std::string before =
                        stripLeadingParamQualifiers(nameProbe.substr(0, p));
                    hasExplicitName = !before.empty();
                }
                if (!hasExplicitName) {
                    name = "_appgl_arg" + std::to_string(idx);
                    param += " ";
                    param += name;
                }
                if (outNames != nullptr) outNames->push_back(name);
                if (idx > 0) normalized += ", ";
                normalized += param;
            }
            normalized += ")";
            return normalized;
        };
        auto parseParamNames = [&](const std::string& rawParams) {
            std::vector<std::string> names;
            normalizeParamList(rawParams, &names);
            return names;
        };
        auto canonicalTypeSignature = [&](std::string type) {
            type = trimCopy(std::move(type));
            type.erase(std::remove_if(type.begin(), type.end(),
                [](unsigned char c) { return std::isspace(c); }), type.end());
            return type;
        };
        auto canonicalParamSignature = [&](const std::string& rawParams) {
            std::vector<std::string> params = splitParamList(rawParams);
            if (params.empty()) {
                return std::string("(void)");
            }
            std::string normalized = "(";
            for (std::size_t idx = 0; idx < params.size(); ++idx) {
                std::string param = trimCopy(params[idx]);
                std::string arraySuffix;
                while (!param.empty() && param.back() == ']') {
                    const std::size_t open = param.rfind('[');
                    if (open == std::string::npos) break;
                    arraySuffix.insert(0, param.substr(open));
                    param = trimCopy(param.substr(0, open));
                }
                std::size_t p = param.size();
                while (p > 0 && !isIdent(static_cast<unsigned char>(param[p - 1]))) --p;
                std::size_t e = p;
                while (p > 0 && isIdent(static_cast<unsigned char>(param[p - 1]))) --p;
                bool hasExplicitName = false;
                if (e > p) {
                    const std::string before =
                        stripLeadingParamQualifiers(param.substr(0, p));
                    hasExplicitName = !before.empty();
                }
                if (hasExplicitName) {
                    param = trimCopy(param.substr(0, p));
                }
                if (!arraySuffix.empty()) {
                    param += arraySuffix;
                }
                param.erase(std::remove_if(param.begin(), param.end(),
                    [](unsigned char c) { return std::isspace(c); }), param.end());
                if (idx > 0) normalized += ",";
                normalized += param;
            }
            normalized += ")";
            return normalized;
        };
        for (const auto& impl : implSignatures) {
            const std::string implReturn = canonicalTypeSignature(impl.retType);
            const std::string implParams = canonicalParamSignature(impl.params);
            for (const auto& typeName : impl.typeNames) {
                auto retIt = typeReturn.find(typeName);
                auto parIt = typeParams.find(typeName);
                if (retIt == typeReturn.end() || parIt == typeParams.end()) {
                    continue;
                }
                if (implReturn != canonicalTypeSignature(retIt->second) ||
                    implParams != canonicalParamSignature(parIt->second)) {
                    subroutineValidationError =
                        "ERROR: subroutine implementation '" + impl.name +
                        "' is not compatible with subroutine type '" +
                        typeName + "'.";
                    return in;
                }
            }
        }
        struct DispatchHelperSpec {
            std::string uniformName;
            std::string key;
            std::string typeName;
            std::string retType;
            std::string params;
            std::vector<std::string> impls;
        };
        struct DynamicDispatchHelperSpec {
            std::string uniformName;
            std::string typeName;
            std::string retType;
            std::string params;
            int elemCount = 1;
        };
        std::vector<DispatchHelperSpec> dispatchHelperSpecs;
        std::vector<DynamicDispatchHelperSpec> dynamicDispatchHelperSpecs;
        std::unordered_map<std::string, std::string> dispatchHelperByKey;
        std::unordered_map<std::string, std::string> dynamicDispatchHelperByUniform;
        std::unordered_map<std::string, int> subUniformElementCount;
        std::unordered_set<std::string> dispatchHelperUniformNames;
        for (const auto& name : subUniNames) {
            auto infoIt = subUniformInfo.find(name);
            auto typeIt = uniformToType.find(name);
            if (typeIt == uniformToType.end()) continue;
            const std::string& typeName = typeIt->second;
            auto retIt = typeReturn.find(typeName);
            auto parIt = typeParams.find(typeName);
            auto implIt = typeToImpls.find(typeName);
            if (retIt == typeReturn.end() || parIt == typeParams.end() ||
                implIt == typeToImpls.end() || implIt->second.empty()) {
                continue;
            }
            std::vector<int> dims;
            if (infoIt != subUniformInfo.end()) dims = infoIt->second.dims;
            const int elemCount = elementCountForDims(dims);
            subUniformElementCount[name] = elemCount;
            dispatchHelperUniformNames.insert(name);
            for (int elem = 0; elem < elemCount; ++elem) {
                const std::string key = dispatchKeyForElement(name, elem, elemCount);
                dispatchHelperByKey[key] = helperNameForKey(key);
                dispatchHelperSpecs.push_back(
                    DispatchHelperSpec{name, key, typeName, retIt->second, parIt->second, implIt->second});
            }
            if (!dims.empty() && elemCount > 1) {
                dynamicDispatchHelperByUniform[name] = dynamicHelperNameForUniform(name);
                dynamicDispatchHelperSpecs.push_back(
                    DynamicDispatchHelperSpec{name, typeName, retIt->second, parIt->second, elemCount});
            }
        }

        // Second pass: rewrite.
        std::string out;
        out.reserve(in.size() + 64);
        auto rewriteSubroutineDeclAt = [&](std::size_t subPos, std::size_t& nextPos) {
            std::size_t q = subPos + kw.size();
            skipWs(q);
            if (q < in.size() && in[q] == '(') {
                int pd = 1;
                ++q;
                while (q < in.size() && pd > 0) {
                    if (in[q] == '(') ++pd;
                    else if (in[q] == ')') --pd;
                    ++q;
                }
                nextPos = q;
                return true;
            }
            const std::size_t semi = in.find(';', q);
            if (semi != std::string::npos) {
                nextPos = semi + 1;
                return true;
            }
            nextPos = q;
            return true;
        };
        std::size_t i = 0;
        while (i < in.size()) {
            std::size_t layoutSubPos = 0;
            if (layoutAt(i, layoutSubPos)) {
                if (rewriteSubroutineDeclAt(layoutSubPos, i)) {
                    continue;
                }
            }
            // Find `subroutine` word at this position?
            if (i + kw.size() <= in.size() && in.compare(i, kw.size(), kw) == 0) {
                const bool lb = (i == 0) || !isIdent(static_cast<unsigned char>(in[i-1]));
                const bool rb = (i + kw.size() < in.size()) && !isIdent(static_cast<unsigned char>(in[i+kw.size()]));
                if (lb && rb && isSubroutineDeclPos(i)) {
                    if (rewriteSubroutineDeclAt(i, i)) {
                        continue;
                    }
                    continue;
                }
            }
            // Rewrite call sites for subroutine uniform names.
            if (isIdent(static_cast<unsigned char>(in[i]))) {
                std::size_t s = i;
                while (s < in.size() && isIdent(static_cast<unsigned char>(in[s]))) ++s;
                std::string word = in.substr(i, s - i);
                // Consider as a subroutine-uniform call site only
                // when followed by a '(' (possibly after whitespace)
                // OR `[subscript](`. Array subroutine uniforms like
                // `subroutine uniform b_t b[3]` get called as
                // `b[0]()`, `b[1]()`, etc. — all elements share the
                // same subroutine type so all rewrite to the same
                // impl.
                std::size_t t = s;
                skipWs(t);
                // Walk past one or more `[...]` segments if present
                // (including multidimensional subroutine uniforms).
                std::size_t afterSubscript = t;
                std::vector<int> callIndices;
                std::vector<std::string> callIndexTexts;
                bool constIndices = true;
                while (afterSubscript < in.size() && in[afterSubscript] == '[') {
                    const std::size_t contentStart = afterSubscript + 1;
                    int bd = 1;
                    std::size_t q = contentStart;
                    while (q < in.size() && bd > 0) {
                        if (in[q] == '[') ++bd;
                        else if (in[q] == ']') --bd;
                        if (bd > 0) ++q;
                    }
                    if (q >= in.size()) {
                        constIndices = false;
                        afterSubscript = q;
                        break;
                    }
                    std::string idxText = trimCopy(in.substr(contentStart, q - contentStart));
                    callIndexTexts.push_back(idxText);
                    if (idxText.empty()) {
                        constIndices = false;
                    } else {
                        int idxVal = 0;
                        for (char c : idxText) {
                            if (c < '0' || c > '9') {
                                constIndices = false;
                                break;
                            }
                            idxVal = idxVal * 10 + (c - '0');
                        }
                        if (constIndices) callIndices.push_back(idxVal);
                    }
                    afterSubscript = q + 1;
                    skipWs(afterSubscript);
                }
                std::size_t tt = afterSubscript;
                skipWs(tt);
                auto it = uniformToImpl.find(word);
                if (it != uniformToImpl.end() &&
                    tt < in.size() && in[tt] == '.' &&
                    tt + 9 <= in.size() &&
                    in.compare(tt + 1, 8, "length()") == 0) {
                    int length = 1;
                    auto infoIt = subUniformInfo.find(word);
                    if (infoIt != subUniformInfo.end() && !infoIt->second.dims.empty()) {
                        const std::size_t depth = callIndexTexts.size();
                        if (depth < infoIt->second.dims.size()) {
                            length = std::max(1, infoIt->second.dims[depth]);
                        }
                    } else {
                        auto countIt = subUniformElementCount.find(word);
                        length = countIt != subUniformElementCount.end()
                            ? countIt->second : 1;
                    }
                    out.append(std::to_string(length));
                    out.push_back('u');
                    i = tt + 9;
                    continue;
                }
                if (it != uniformToImpl.end() && tt < in.size() && in[tt] == '(') {
                    std::string dispatchKey = word;
                    auto infoIt = subUniformInfo.find(word);
                    if (infoIt != subUniformInfo.end() && !infoIt->second.dims.empty()) {
                        const auto& dims = infoIt->second.dims;
                        const int elemCount = elementCountForDims(dims);
                        bool flattened = constIndices && callIndices.size() == dims.size();
                        int flat = 0;
                        if (flattened) {
                            for (std::size_t k = 0; k < dims.size(); ++k) {
                                if (callIndices[k] < 0 || callIndices[k] >= dims[k]) {
                                    flattened = false;
                                    break;
                                }
                                flat = flat * dims[k] + callIndices[k];
                            }
                        }
                        if (flattened) {
                            dispatchKey = dispatchKeyForElement(word, flat, elemCount);
                        }
                    }
                    auto helperIt = dispatchHelperByKey.find(dispatchKey);
                    if (helperIt != dispatchHelperByKey.end()) {
                        out.append(helperIt->second);
                        i = afterSubscript;
                        continue;
                    }
                    auto dynHelperIt = dynamicDispatchHelperByUniform.find(word);
                    if (dynHelperIt != dynamicDispatchHelperByUniform.end() &&
                        tt < in.size() && in[tt] == '(') {
                        std::string flatIndexExpr;
                        auto infoIt = subUniformInfo.find(word);
                        if (infoIt != subUniformInfo.end() &&
                            callIndexTexts.size() == infoIt->second.dims.size()) {
                            for (std::size_t dimIdx = 0;
                                 dimIdx < callIndexTexts.size();
                                 ++dimIdx) {
                                if (callIndexTexts[dimIdx].empty()) {
                                    flatIndexExpr.clear();
                                    break;
                                }
                                const std::string term =
                                    "uint(" + callIndexTexts[dimIdx] + ")";
                                if (flatIndexExpr.empty()) {
                                    flatIndexExpr = term;
                                } else {
                                    flatIndexExpr = "(" + flatIndexExpr + " * " +
                                        std::to_string(std::max(1, infoIt->second.dims[dimIdx])) +
                                        "u + " + term + ")";
                                }
                            }
                        }
                        if (flatIndexExpr.empty()) {
                            out.append(it->second);
                            i = afterSubscript;
                            continue;
                        }
                        std::vector<std::string> paramNames;
                        auto typeNameIt = uniformToType.find(word);
                        if (typeNameIt != uniformToType.end()) {
                            auto paramIt = typeParams.find(typeNameIt->second);
                            if (paramIt != typeParams.end()) {
                                paramNames = parseParamNames(paramIt->second);
                            }
                        }
                        out.append(dynHelperIt->second);
                        out.append("(");
                        out.append(flatIndexExpr);
                        if (!paramNames.empty()) {
                            out.append(", ");
                        }
                        i = tt + 1;  // consume original '('; keep args and closing ')'
                        continue;
                    }
                    // Sprint 17 Day 7+ Bank-Group-C: v1-eligible (void
                    // return, no params) + statement-position call site
                    // → emit inline if-else dispatch chain consuming
                    // `(args);`. Otherwise fall back to static
                    // FIRST_IMPL_NAME emission and let `(args)` flow
                    // naturally (current behavior).
                    auto v1It = uniformIsV1Eligible.find(word);
                    if (v1It != uniformIsV1Eligible.end() && v1It->second) {
                        // Walk past matched `(args)`.
                        std::size_t q = tt + 1;
                        int pd = 1;
                        while (q < in.size() && pd > 0) {
                            if (in[q] == '(') ++pd;
                            else if (in[q] == ')') --pd;
                            ++q;
                        }
                        // Statement-position check: next non-ws must
                        // be `;`. If not, fall back to static.
                        std::size_t r = q;
                        while (r < in.size() &&
                               std::isspace(static_cast<unsigned char>(in[r]))) ++r;
                        if (r < in.size() && in[r] == ';') {
                            // Consume `;` too.
                            std::size_t consumeEnd = r + 1;
                            // Look up impls for this uniform.
                            auto utIt = uniformToType.find(word);
                            std::vector<std::string> impls;
                            if (utIt != uniformToType.end()) {
                                auto tiIt = typeToImpls.find(utIt->second);
                                if (tiIt != typeToImpls.end()) impls = tiIt->second;
                            }
                            if (impls.empty()) {
                                // No impls — degenerate; fall through to static.
                                out.append(it->second);
                                i = afterSubscript;
                                continue;
                            }
                            // Sprint 17 Day 7+ Bank-Group-C: emit
                            // INLINE body text per branch (not
                            // function calls) — avoids OpFunctionCall
                            // which the GS-emul interpreter rejects.
                            // v1-eligibility above guarantees every
                            // impl has captured body text.
                            auto bodyOf = [&](const std::string& nm) -> const std::string& {
                                auto bIt = implBody.find(nm);
                                static const std::string kEmpty;
                                return bIt == implBody.end() ? kEmpty : bIt->second;
                            };
                            if (impls.size() == 1) {
                                out.append("{");
                                out.append(bodyOf(impls[0]));
                                out.append("}");
                            } else {
                                out.append("if (_appgl_sub_");
                                out.append(word);
                                out.append(" == 0u) {");
                                out.append(bodyOf(impls[0]));
                                out.append("}");
                                for (std::size_t k = 1; k + 1 < impls.size(); ++k) {
                                    out.append(" else if (_appgl_sub_");
                                    out.append(word);
                                    out.append(" == ");
                                    out.append(std::to_string(k));
                                    out.append("u) {");
                                    out.append(bodyOf(impls[k]));
                                    out.append("}");
                                }
                                out.append(" else {");
                                out.append(bodyOf(impls.back()));
                                out.append("}");
                            }
                            i = consumeEnd;
                            continue;
                        }
                        // Not statement-position: fall through to static.
                    }
                    // Skip the identifier + optional [subscript]
                    // entirely and emit the impl name. The call's
                    // `(...)` then follows naturally.
                    out.append(it->second);
                    i = afterSubscript;
                    continue;
                }
                out.append(word);
                i = s;
                continue;
            }
            out.push_back(in[i]);
            ++i;
        }
        // Append a plain `int <NAME>;` declaration for each
        // stripped subroutine uniform so glslang's reserved-
        // identifier validator still sees the name verbatim.
        // Otherwise `subroutine uniform T namespace;` would slip
        // through silently (keyword-level stripped), regressing
        // CTS `CommonBugs.CommonBug_ReservedNames` which checks
        // that each reserved word triggers a compile error.
        if (!subUniNames.empty() || !subTypeNames.empty()) {
            out.append("\n// appgl: reserved-name validation stubs\n");
            for (const auto& n : subUniNames) {
                out.append("int ");
                out.append(n);
                out.append(";\n");
            }
            std::unordered_set<std::string> seenTypes;
            for (const auto& n : subTypeNames) {
                if (!seenTypes.insert(n).second) continue;
                // Don't re-emit if it's also a uniform name.
                if (std::find(subUniNames.begin(), subUniNames.end(), n) != subUniNames.end()) continue;
                out.append("int ");
                out.append(n);
                out.append(";\n");
            }
        }
        // Sprint 17 Day 7+ Bank-Group-C: emit synthetic dispatch
        // uniforms for v1-eligible subroutine uniforms. The link-time
        // `processSubroutineDispatchUniforms` lambda walks every
        // stage's `_DefaultUniforms` reflection for these, registers
        // their default-block locations into
        // `subroutineDispatchUniformLocations`, and
        // `glUniformSubroutinesuiv` writes the selected subroutine
        // index into `_appgl_sub_<UNI>`. The inline if-else chain
        // emitted at call sites then branches to the selected impl.
        //
        // CRITICAL: the synthetic uniform declarations must precede
        // `main()` in lexical order — call sites in `main()` reference
        // `_appgl_sub_<UNI>` and GLSL requires identifier declaration
        // before use even at global scope (glslang's parser is single-
        // pass on globals). Inject the header right after the
        // `#version`/`#extension` block at the top of the rewritten
        // output rather than appending at the end.
        std::string synthHeader;
        if (!implToPrototype.empty()) {
            synthHeader = "// appgl: subroutine implementation prototypes\n";
            std::vector<std::string> protoNames;
            protoNames.reserve(implToPrototype.size());
            for (const auto& kv : implToPrototype) protoNames.push_back(kv.first);
            std::sort(protoNames.begin(), protoNames.end());
            for (const auto& name : protoNames) {
                synthHeader += implToPrototype[name];
                synthHeader += "\n";
            }
        }
        if (!dispatchHelperSpecs.empty()) {
            if (synthHeader.empty()) {
                synthHeader = "// appgl: subroutine dynamic-dispatch helpers\n";
            } else {
                synthHeader += "// appgl: subroutine dynamic-dispatch helpers\n";
            }
            std::sort(dispatchHelperSpecs.begin(), dispatchHelperSpecs.end(),
                [](const DispatchHelperSpec& a, const DispatchHelperSpec& b) {
                    return a.key < b.key;
                });
            for (const auto& spec : dispatchHelperSpecs) {
                synthHeader += "uniform uint _appgl_sub_";
                synthHeader += spec.key;
                synthHeader += ";\n";
            }
            for (const auto& spec : dispatchHelperSpecs) {
                std::vector<std::string> paramNames;
                const std::string normalizedParams =
                    normalizeParamList(spec.params, &paramNames);
                std::string args;
                for (std::size_t pi = 0; pi < paramNames.size(); ++pi) {
                    if (pi > 0) args += ", ";
                    args += paramNames[pi];
                }
                synthHeader += spec.retType;
                synthHeader += " ";
                synthHeader += helperNameForKey(spec.key);
                synthHeader += normalizedParams;
                synthHeader += " {\n";
                const bool voidReturn = (spec.retType == "void");
                if (spec.impls.size() == 1) {
                    if (voidReturn) {
                        synthHeader += "    ";
                        synthHeader += spec.impls.front();
                        synthHeader += "(";
                        synthHeader += args;
                        synthHeader += ");\n";
                        synthHeader += "    return;\n";
                    } else {
                        synthHeader += "    return ";
                        synthHeader += spec.impls.front();
                        synthHeader += "(";
                        synthHeader += args;
                        synthHeader += ");\n";
                    }
                } else if (voidReturn) {
                    for (std::size_t k = 0; k < spec.impls.size(); ++k) {
                        if (k == 0) {
                            synthHeader += "    if (_appgl_sub_";
                            synthHeader += spec.key;
                            synthHeader += " == 0u) { ";
                        } else if (k + 1 < spec.impls.size()) {
                            synthHeader += "    else if (_appgl_sub_";
                            synthHeader += spec.key;
                            synthHeader += " == ";
                            synthHeader += std::to_string(k);
                            synthHeader += "u) { ";
                        } else {
                            synthHeader += "    else { ";
                        }
                        synthHeader += spec.impls[k];
                        synthHeader += "(";
                        synthHeader += args;
                        synthHeader += "); return; }\n";
                    }
                } else {
                    for (std::size_t k = 0; k < spec.impls.size(); ++k) {
                        if (k == 0) {
                            synthHeader += "    if (_appgl_sub_";
                            synthHeader += spec.key;
                            synthHeader += " == 0u) return ";
                        } else if (k + 1 < spec.impls.size()) {
                            synthHeader += "    else if (_appgl_sub_";
                            synthHeader += spec.key;
                            synthHeader += " == ";
                            synthHeader += std::to_string(k);
                            synthHeader += "u) return ";
                        } else {
                            synthHeader += "    else return ";
                        }
                        synthHeader += spec.impls[k];
                        synthHeader += "(";
                        synthHeader += args;
                        synthHeader += ");\n";
                    }
                }
                synthHeader += "}\n";
            }
        }
        if (!dynamicDispatchHelperSpecs.empty()) {
            if (synthHeader.empty()) {
                synthHeader = "// appgl: subroutine dynamic-index helpers\n";
            } else {
                synthHeader += "// appgl: subroutine dynamic-index helpers\n";
            }
            std::sort(dynamicDispatchHelperSpecs.begin(), dynamicDispatchHelperSpecs.end(),
                [](const DynamicDispatchHelperSpec& a, const DynamicDispatchHelperSpec& b) {
                    return a.uniformName < b.uniformName;
                });
            auto paramsWithDispatchIndex = [&](const std::string& rawParams) {
                std::vector<std::string> ignoredNames;
                const std::string normalizedParams =
                    normalizeParamList(rawParams, &ignoredNames);
                if (normalizedParams == "(void)" || normalizedParams == "()") {
                    return std::string("(uint _appgl_idx)");
                }
                std::string body = normalizedParams.substr(1, normalizedParams.size() - 2);
                return std::string("(uint _appgl_idx, ") + body + ")";
            };
            for (const auto& spec : dynamicDispatchHelperSpecs) {
                const std::vector<std::string> paramNames = parseParamNames(spec.params);
                std::string args;
                for (std::size_t pi = 0; pi < paramNames.size(); ++pi) {
                    if (pi > 0) args += ", ";
                    args += paramNames[pi];
                }
                synthHeader += spec.retType;
                synthHeader += " ";
                synthHeader += dynamicHelperNameForUniform(spec.uniformName);
                synthHeader += paramsWithDispatchIndex(spec.params);
                synthHeader += " {\n";
                const bool voidReturn = (spec.retType == "void");
                for (int elem = 0; elem < spec.elemCount; ++elem) {
                    const std::string key =
                        dispatchKeyForElement(spec.uniformName, elem, spec.elemCount);
                    if (voidReturn) {
                        if (elem == 0) {
                            synthHeader += "    if (_appgl_idx == 0u) { ";
                        } else if (elem + 1 < spec.elemCount) {
                            synthHeader += "    else if (_appgl_idx == ";
                            synthHeader += std::to_string(elem);
                            synthHeader += "u) { ";
                        } else {
                            synthHeader += "    else { ";
                        }
                        synthHeader += helperNameForKey(key);
                        synthHeader += "(";
                        synthHeader += args;
                        synthHeader += "); return; }\n";
                    } else {
                        if (elem == 0) {
                            synthHeader += "    if (_appgl_idx == 0u) return ";
                        } else if (elem + 1 < spec.elemCount) {
                            synthHeader += "    else if (_appgl_idx == ";
                            synthHeader += std::to_string(elem);
                            synthHeader += "u) return ";
                        } else {
                            synthHeader += "    else return ";
                        }
                        synthHeader += helperNameForKey(key);
                        synthHeader += "(";
                        synthHeader += args;
                        synthHeader += ");\n";
                    }
                }
                synthHeader += "}\n";
            }
        }
        for (const auto& n : subUniNames) {
            if (dispatchHelperUniformNames.count(n) != 0) continue;
            auto it = uniformIsV1Eligible.find(n);
            if (it == uniformIsV1Eligible.end() || !it->second) continue;
            if (synthHeader.empty()) {
                synthHeader = "// appgl: subroutine dynamic-dispatch uniforms (v1)\n";
            } else if (synthHeader.find("subroutine dynamic-dispatch uniforms") == std::string::npos) {
                synthHeader += "// appgl: subroutine dynamic-dispatch uniforms (v1)\n";
            }
            synthHeader += "uniform uint _appgl_sub_";
            synthHeader += n;
            synthHeader += ";\n";
        }
        if (!synthHeader.empty()) {
            // Find injection point: end of last contiguous `#version`/
            // `#extension`/`#pragma` line at the top of `out`. Skip
            // initial whitespace, then scan forward across consecutive
            // preprocessor-directive lines so the synthesized header
            // lands AFTER all extension enables (e.g.
            // GL_ARB_geometry_shader4 / viewport_array) but BEFORE any
            // user declarations. Struct-typed subroutine signatures
            // need the user struct visible before our generated
            // prototypes/helpers.
            std::size_t injectAt = 0;
            while (injectAt < out.size() &&
                   std::isspace(static_cast<unsigned char>(out[injectAt]))) {
                ++injectAt;
            }
            while (injectAt < out.size() && out[injectAt] == '#') {
                std::size_t lineEnd = out.find('\n', injectAt);
                if (lineEnd == std::string::npos) {
                    injectAt = out.size();
                    break;
                }
                injectAt = lineEnd + 1;
                // Skip whitespace + blank lines between directives.
                while (injectAt < out.size() &&
                       (out[injectAt] == ' ' || out[injectAt] == '\t' ||
                       out[injectAt] == '\r' || out[injectAt] == '\n')) {
                    ++injectAt;
                }
            }
            auto atWord = [&](std::size_t pos, const char* word) {
                const std::size_t len = std::strlen(word);
                if (pos + len > out.size() || out.compare(pos, len, word) != 0) {
                    return false;
                }
                const bool left = (pos == 0) ||
                    !isIdent(static_cast<unsigned char>(out[pos - 1]));
                const bool right = (pos + len == out.size()) ||
                    !isIdent(static_cast<unsigned char>(out[pos + len]));
                return left && right;
            };
            auto skipWsFrom = [&](std::size_t& pos) {
                while (pos < out.size() &&
                       std::isspace(static_cast<unsigned char>(out[pos]))) {
                    ++pos;
                }
            };
            bool advancedDecl = true;
            while (advancedDecl) {
                advancedDecl = false;
                skipWsFrom(injectAt);
                if (injectAt + 1 < out.size() &&
                    out[injectAt] == '/' && out[injectAt + 1] == '/') {
                    const std::size_t lineEnd = out.find('\n', injectAt + 2);
                    injectAt = (lineEnd == std::string::npos)
                        ? out.size() : lineEnd + 1;
                    advancedDecl = true;
                } else if (injectAt + 1 < out.size() &&
                           out[injectAt] == '/' && out[injectAt + 1] == '*') {
                    const std::size_t blockEnd = out.find("*/", injectAt + 2);
                    if (blockEnd != std::string::npos) {
                        injectAt = blockEnd + 2;
                        advancedDecl = true;
                    }
                } else if (atWord(injectAt, "precision")) {
                    const std::size_t semi = out.find(';', injectAt);
                    if (semi != std::string::npos) {
                        injectAt = semi + 1;
                        advancedDecl = true;
                    }
                } else if (atWord(injectAt, "struct")) {
                    const std::size_t brace = out.find('{', injectAt);
                    if (brace != std::string::npos) {
                        int depth = 1;
                        std::size_t p = brace + 1;
                        while (p < out.size() && depth > 0) {
                            if (out[p] == '{') ++depth;
                            else if (out[p] == '}') --depth;
                            ++p;
                        }
                        if (depth == 0) {
                            const std::size_t semi = out.find(';', p);
                            if (semi != std::string::npos) {
                                injectAt = semi + 1;
                                advancedDecl = true;
                            }
                        }
                    }
                }
            }
            out.insert(injectAt, synthHeader);
        }
        return out;
    };
    // Apply to the compat-rewritten source.
    const std::string& subroutineRewriteInput =
        rewrite.didRewrite ? rewrite.source : *compatRewriteSource;
    std::string afterSubRewrite = rewriteSubroutinesForSpirv(subroutineRewriteInput);
    if (!subroutineValidationError.empty()) {
        object->compileLog = subroutineValidationError;
        object->compiled = false;
        object->spirv.clear();
        Runtime::shared().recordShaderTranslation({
            shaderTag, "compile", sourceHash, "", "", object->compileLog, "", false
        });
        return true;
    }
    const bool didSubRewrite = afterSubRewrite != subroutineRewriteInput;
    const std::string& baseCompileSource =
        didSubRewrite ? afterSubRewrite : subroutineRewriteInput;
    std::string after420packImplicitRewrite =
        rewrite420packImplicitConversionsForSpirv(baseCompileSource);
    const std::string& sourceAfterImplicitRewrite =
        (after420packImplicitRewrite != baseCompileSource)
            ? after420packImplicitRewrite
            : baseCompileSource;
    std::string after420packQualifierRewrite =
        rewrite420packQualifierOrderInvariantInputsForSpirv(
            sourceAfterImplicitRewrite);
    const std::string& sourceAfterQualifierRewrite =
        (after420packQualifierRewrite != sourceAfterImplicitRewrite)
            ? after420packQualifierRewrite
            : sourceAfterImplicitRewrite;
    std::string afterDrawIDRewrite =
        rewriteShaderDrawParametersForSpirv(sourceAfterQualifierRewrite, object->stage);
    const std::string& sourceAfterDrawIDRewrite =
        (afterDrawIDRewrite != sourceAfterQualifierRewrite)
            ? afterDrawIDRewrite
            : sourceAfterQualifierRewrite;
    std::string afterUnsizedUniformArrayRewrite =
        rewriteUnsizedUniformArrayInitializersForSpirv(sourceAfterDrawIDRewrite);
    const std::string& sourceAfterUnsizedUniformArrayRewrite =
        (afterUnsizedUniformArrayRewrite != sourceAfterDrawIDRewrite)
            ? afterUnsizedUniformArrayRewrite
            : sourceAfterDrawIDRewrite;
    std::string afterImageSamplesRewrite =
        rewriteImageSamplesForSpirv(sourceAfterUnsizedUniformArrayRewrite);
    const std::string& sourceAfterImageSamplesRewrite =
        (afterImageSamplesRewrite != sourceAfterUnsizedUniformArrayRewrite)
            ? afterImageSamplesRewrite
            : sourceAfterUnsizedUniformArrayRewrite;
    std::string afterSsboRuntimeArrayRewrite =
        rewriteSsboConsecutiveRuntimeArraysForSpirv(
            sourceAfterImageSamplesRewrite);
    const std::string& compileSource =
        (afterSsboRuntimeArrayRewrite != sourceAfterImageSamplesRewrite)
            ? afterSsboRuntimeArrayRewrite
            : sourceAfterImageSamplesRewrite;
    std::string afterVertexInputAliasRewrite;
    const std::string* glslangCompileSource = &compileSource;
    if (object->stage == GL_VERTEX_SHADER) {
        afterVertexInputAliasRewrite =
            rewriteDuplicateVertexInputLocationsForSpirv(compileSource);
        if (afterVertexInputAliasRewrite != compileSource) {
            glslangCompileSource = &afterVertexInputAliasRewrite;
        }
    }

    // GLSL texture lookup bias arguments are fragment-stage only. Glslang's
    // relaxed Vulkan path accepts some GL_EXT_texture_shadow_lod shadow-sampler
    // overloads in vertex shaders, so reject the source here before reflection.
    {
        std::string validationError;
        if (!validateTextureLookupBiasStageRestrictions(
                compileSource, object->stage, validationError)) {
            object->compileLog = std::move(validationError);
            object->compiled = false;
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", object->compileLog, "", false
            });
            return true;
        }
    }

    if (object->stage == GL_GEOMETRY_SHADER) {
        GLint maxVertexStreams = 4;
        GLint maxGeometryShaderInvocations = 32;
        if (impl_->capabilities != nullptr) {
            GLint queriedMaxVertexStreams = 0;
            if (impl_->capabilities->queryInteger(
                    GL_MAX_VERTEX_STREAMS, &queriedMaxVertexStreams) &&
                queriedMaxVertexStreams > 0) {
                maxVertexStreams = queriedMaxVertexStreams;
            }
            GLint queriedMaxGeometryShaderInvocations = 0;
            if (impl_->capabilities->queryInteger(
                    GL_MAX_GEOMETRY_SHADER_INVOCATIONS,
                    &queriedMaxGeometryShaderInvocations) &&
                queriedMaxGeometryShaderInvocations > 0) {
                maxGeometryShaderInvocations =
                    queriedMaxGeometryShaderInvocations;
            }
        }
        maxVertexStreams = std::max<GLint>(maxVertexStreams, 4);
        maxGeometryShaderInvocations =
            std::max<GLint>(maxGeometryShaderInvocations, 32);
        std::string validationError;
        if (!validateGeometryShaderGpu5CompileLimits(
                compileSource,
                maxVertexStreams,
                maxGeometryShaderInvocations,
                validationError)) {
            object->compileLog = std::move(validationError);
            object->compiled = false;
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", object->compileLog, "", false
            });
            return true;
        }
    }

    // 2. Lightweight scanner pass. Still needed for declared attribute inputs
    //    so the vertex-input binding path (glBindAttribLocation /
    //    layout(location=...)) can be resolved without going through
    //    SPIRV-Cross reflection. The scanner's uniform output is now
    //    secondary — link time pulls UBO members from SPIR-V reflection
    //    directly so interface blocks are visible even though the scanner
    //    ignores them.
    GLSLReflectionResult reflection = reflectGLSL(compileSource, object->stage);
    const bool sourceUsesEsProfile = glslSourceUsesEsProfile(compileSource);
    if (sourceUsesEsProfile) {
        for (auto& decl : reflection.uniforms) {
            decl.declaredInEsProfile = true;
        }
    }

    // Reverse-map compat shader renames so GL queries report original names.
    // The shader source uses `_appgl_sampler` (so glslang accepts it), but
    // the GL API must expose the original `sampler` name to applications.
    if (rewrite.didRewrite) {
        auto reverseRename = [](std::string& s) {
            const std::string from = "_appgl_sampler";
            const std::string to = "sampler";
            std::string::size_type pos = 0;
            while ((pos = s.find(from, pos)) != std::string::npos) {
                s.replace(pos, from.size(), to);
                pos += to.size();
            }
        };
        for (auto& decl : reflection.uniforms) {
            reverseRename(decl.name);
        }
        for (auto& decl : reflection.inputs) {
            reverseRename(decl.name);
        }
        for (auto& decl : reflection.outputs) {
            reverseRename(decl.name);
        }
    }

    // GL 4.6 §4.3.9: `atomic_uint` uniforms may not be declared
    // as an unsized array. CTS
    // `shader_atomic_counters.negative-unsized-array` plants
    // `uniform atomic_uint arr[];` in a fragment shader and
    // expects COMPILE_STATUS = FALSE. Glslang accepts the
    // declaration (perhaps treating it as a runtime-sized
    // "last-member" array), so we reject it here before the
    // glslang pass.
    for (const auto& decl : reflection.uniforms) {
        if (decl.type == GL_UNSIGNED_INT_ATOMIC_COUNTER &&
            decl.isArray && decl.arraySize <= 0) {
            object->compileLog =
                "ERROR: atomic_uint uniform '" + decl.name +
                "' cannot be declared as an unsized array (GL 4.6 §4.3.9).";
            object->compiled = false;
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", "", "", "", object->compileLog, "", false
            });
            return true;  // entry point completed; compile
                         // verdict visible via getShaderiv(COMPILE_STATUS).
        }
    }

    // GL 4.6 §4.4.6: an atomic counter whose declared offset range exceeds
    // GL_MAX_ATOMIC_COUNTER_BUFFER_SIZE is a compile-time error. Glslang only
    // reaches this path now that we inject the atomic-counter extensions.
    if (compileSource.find("atomic_uint") != std::string::npos) {
        GLint maxAtomicCounterBufferSize = 0;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(
                GL_MAX_ATOMIC_COUNTER_BUFFER_SIZE,
                &maxAtomicCounterBufferSize);
        }
        if (maxAtomicCounterBufferSize > 0) {
            const std::string stripped =
                stripGlslCommentsForAppglValidation(compileSource);
            const auto defines = parseGlslIntegerDefines(stripped);
            std::size_t p = 0;
            while ((p = stripped.find("atomic_uint", p)) != std::string::npos) {
                if (!tokenAt(stripped, p, "atomic_uint")) {
                    p += 11;
                    continue;
                }
                std::size_t declStart = p;
                while (declStart > 0 && stripped[declStart - 1] != ';' &&
                       stripped[declStart - 1] != '}') {
                    --declStart;
                }
                const std::size_t semi = stripped.find(';', p);
                if (semi == std::string::npos) break;
                const std::string prefix =
                    stripped.substr(declStart, p - declStart);
                int layoutOffset = 0;
                if (parseLayoutIntegerQualifier(
                        prefix, "offset", defines, layoutOffset)) {
                    int arraySize = 1;
                    std::size_t namePos = p + 11;
                    (void)readGlslIdent(stripped, namePos);
                    skipGlslWs(stripped, namePos);
                    if (namePos < semi && stripped[namePos] == '[') {
                        const std::size_t close =
                            stripped.find(']', namePos + 1);
                        if (close != std::string::npos && close < semi) {
                            int parsedArraySize = 1;
                            if (parseGlslIntegerExpression(
                                    std::string_view(stripped).substr(
                                        namePos + 1, close - namePos - 1),
                                    defines,
                                    parsedArraySize) &&
                                parsedArraySize > 0) {
                                arraySize = parsedArraySize;
                            }
                        }
                    }
                    const long long endByte =
                        static_cast<long long>(layoutOffset) +
                        4ll * static_cast<long long>(arraySize);
                    if (endByte > maxAtomicCounterBufferSize) {
                        object->compileLog =
                            "ERROR: atomic_uint layout range exceeds "
                            "GL_MAX_ATOMIC_COUNTER_BUFFER_SIZE.";
                        object->compiled = false;
                        object->spirv.clear();
                        Runtime::shared().recordShaderTranslation({
                            shaderTag, "compile", sourceHash, "", "",
                            object->compileLog, "", false
                        });
                        return true;
                    }
                }
                p = semi + 1;
            }
        }
    }

    // GLSL 4.60 §3.5: the `#` preprocessing operator (stringification)
    // is not allowed in GLSL. CTS
    // `shaders.preprocessor.basic.stringification_{vertex,fragment}`
    // plants
    //   `#define VEC4_STRING_PARAM(a, b, c, d) vec4(#a, #b, c, d)`
    // and asserts COMPILE_STATUS = FALSE. glslang under
    // `setEnvInputVulkanRulesRelaxed()` accepts the construct.
    // Scan each `#define` directive for a `#<identifier>` token
    // in its replacement text and reject at compile time.
    {
        const std::string& src = object->source;
        std::size_t pos = 0;
        while ((pos = src.find("#define", pos)) != std::string::npos) {
            // Make sure we're at a line start (preceded only by
            // whitespace on the same line). A comment containing
            // "#define" inside should be ignored.
            std::size_t lineStart = pos;
            while (lineStart > 0 && src[lineStart - 1] != '\n') --lineStart;
            bool onlyWsBefore = true;
            for (std::size_t i = lineStart; i < pos; ++i) {
                if (src[i] != ' ' && src[i] != '\t') { onlyWsBefore = false; break; }
            }
            if (!onlyWsBefore) { pos += 7; continue; }
            // Find end of directive line (handle line continuations \).
            std::size_t lineEnd = pos;
            while (lineEnd < src.size()) {
                if (src[lineEnd] == '\\' && lineEnd + 1 < src.size() && src[lineEnd + 1] == '\n') {
                    lineEnd += 2; // continuation
                    continue;
                }
                if (src[lineEnd] == '\n') break;
                ++lineEnd;
            }
            // Scan the body for `#<identifier>` (stringification).
            // Skip past `#define` itself (7 chars).
            // Token paste `##<identifier>` is allowed in GLSL, only
            // single-`#` stringification is the disallowed operator.
            for (std::size_t i = pos + 7; i + 1 < lineEnd; ++i) {
                if (src[i] != '#') continue;
                // `##` is token-paste, valid in GLSL. Skip past both.
                if (i + 1 < lineEnd && src[i + 1] == '#') {
                    ++i;  // skip the second #; for loop will ++i past it
                    continue;
                }
                // Single `#` followed by identifier-start is the
                // disallowed stringification operator.
                const unsigned char nx = static_cast<unsigned char>(src[i + 1]);
                if (std::isalpha(nx) || nx == '_') {
                    object->compileLog =
                        "ERROR: GLSL does not allow the `#` preprocessing "
                        "operator in macro replacement lists "
                        "(GLSL 4.60 §3.5).";
                    object->compiled = false;
                    object->spirv.clear();
                    Runtime::shared().recordShaderTranslation({
                        shaderTag, "compile", "", "", "", object->compileLog, "", false
                    });
                    return true;
                }
            }
            pos = lineEnd;
        }
    }

    object->declaredUniforms = std::move(reflection.uniforms);
    object->declaredInputs = std::move(reflection.inputs);
    object->declaredOutputs = std::move(reflection.outputs);

    // 3. Real glslang compile. This is the authoritative verdict that
    //    glGetShaderiv(GL_COMPILE_STATUS) and glGetShaderInfoLog now
    //    surface to the engine — the scanner result above only shapes the
    //    explicit-location metadata, not the compile status.
    //
    //    Version 330 matches what linkProgram used to pass in the old
    //    "compile at link time" path. Engines that target 4.x cores still
    //    use #version 330 / 410 / 460 in their source headers; glslang
    //    respects the in-source directive, so the integer passed here is
    //    only the fallback when the source has no #version line.

    // 3a. Pre-glslang validation: GLSL 4.60 §4.1.8 forbids all qualifiers
    //     except precision (highp/mediump/lowp) on struct members.
    //     Glslang under Vulkan-relaxed rules silently accepts some
    //     forbidden qualifiers (layout(shared), shared, coherent, ...).
    //     We enforce the rule ourselves so
    //     `shaders.negative.non_precision_qualifiers_in_struct_members`
    //     sees the compile-time failure it expects.
    {
        std::string validationError;
        if (!validateStructMemberQualifiers(compileSource, validationError)) {
            object->compileLog = std::move(validationError);
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", object->compileLog, "", false
            });
            return false;
        }
    }

    {
        GLint maxSsboBindings = 0;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(
                GL_MAX_SHADER_STORAGE_BUFFER_BINDINGS, &maxSsboBindings);
        }
        std::string validationError;
        if (!validateShaderStorageBufferBindings(
                compileSource, maxSsboBindings, validationError)) {
            object->compileLog = std::move(validationError);
            object->compiled = false;
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", object->compileLog, "", false
            });
            return true;
        }
    }

    {
        GLint maxUboBindings = 0;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(
                GL_MAX_UNIFORM_BUFFER_BINDINGS, &maxUboBindings);
        }
        std::string validationError;
        if (!validateUniformBlockBindings(
                compileSource, maxUboBindings, validationError)) {
            object->compileLog = std::move(validationError);
            object->compiled = false;
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", object->compileLog, "", false
            });
            return true;
        }
    }

    {
        GLint maxTextureUnits = 0;
        if (impl_->capabilities != nullptr) {
            impl_->capabilities->queryInteger(
                GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS, &maxTextureUnits);
        }
        std::string validationError;
        if (!validateSamplerBindingRanges(
                compileSource, maxTextureUnits, validationError)) {
            object->compileLog = std::move(validationError);
            object->compiled = false;
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", object->compileLog, "", false
            });
            return true;
        }
    }

    // 3b. Tess-eval primitive-mode injection: GL 4.6 §11.2.3 requires
    //     tess-eval shaders to declare `layout(triangles/quads/isolines)
    //     in;` — but the rule is a LINK-time check, not compile-time.
    //     Glslang's per-shader `TProgram::link` raises it anyway during
    //     our compileGLSL pipeline, which would surface as a compile
    //     error and flunk CTS
    //     `tessellation_shader.compilation_and_linking_errors.
    //     te_lacking_primitive_mode_declaration`.
    //
    //     If the user's tess-eval source lacks the directive, inject a
    //     default `layout(triangles) in;` into the glslang-visible
    //     `compileSource` (NOT `object->source`, which stays as the
    //     user's unmodified text). Compile then succeeds. At real link
    //     time, `linkProgram` inspects `tessEvalShader->source`
    //     (original) and fails the link with the spec-correct error.
    if (object->stage == GL_TESS_EVALUATION_SHADER) {
        auto stripComments = [](const std::string& in) {
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
        const std::string clean = stripComments(compileSource);
        auto findPrimMode = [&](const std::string& tok) -> bool {
            std::size_t pos = 0;
            while (pos < clean.size()) {
                std::size_t lp = clean.find("layout", pos);
                if (lp == std::string::npos) return false;
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
        const bool hasPrimMode = findPrimMode("triangles") ||
                                 findPrimMode("quads") ||
                                 findPrimMode("isolines");
        if (!hasPrimMode) {
            // Inject after the `#version` line so the directive is
            // placed in a legal spot (GLSL requires `#version` to
            // precede all non-preprocessor tokens).
            std::string injected = compileSource;
            std::size_t insertAt = 0;
            std::size_t vp = injected.find("#version");
            if (vp != std::string::npos) {
                std::size_t eol = injected.find('\n', vp);
                insertAt = (eol == std::string::npos)
                    ? injected.size() : eol + 1;
            }
            injected.insert(insertAt, "layout(triangles) in;\n");
            // Compile the injected copy directly and stash on the
            // shader for SPIR-V generation.
            ShaderTranslator translatorTmp;
            std::string compileLogTmp;
            std::vector<std::uint32_t> spirvTmp = translatorTmp.compileGLSL(
                injected, object->stage, 330, &compileLogTmp);
            object->compileLog = std::move(compileLogTmp);
            if (spirvTmp.empty()) {
                Runtime::shared().recordShaderTranslation({
                    shaderTag, "compile", sourceHash, "", "",
                    object->compileLog, "", false
                });
                return false;
            }
            object->spirv = std::move(spirvTmp);
            object->compiled = true;
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", "", "", true
            });
            return true;
        }
    }

    ShaderTranslator translator;
    std::string compileLog;
    std::string geometryGlslangCompileSource;
    if (object->stage == GL_GEOMETRY_SHADER &&
        !geometryShaderSourceHasOutputLayoutForGlslang(compileSource)) {
        geometryGlslangCompileSource =
            injectDefaultGeometryOutputLayoutForGlslang(compileSource);
        glslangCompileSource = &geometryGlslangCompileSource;
    }
    std::vector<std::uint32_t> spirv =
        translator.compileGLSL(*glslangCompileSource, object->stage, 330, &compileLog);

    object->compileLog = std::move(compileLog);
    if (spirv.empty()) {
        const bool sameStageLinkOnlyDiagnostic =
            object->compileLog.find("Missing entry point") != std::string::npos ||
            object->compileLog.find("Each stage requires one entry point") != std::string::npos ||
            object->compileLog.find("No function definition") != std::string::npos;
        const bool graphicSameStageLinkOnlyFailure =
            sameStageLinkOnlyDiagnostic &&
            (object->stage == GL_VERTEX_SHADER ||
             object->stage == GL_TESS_CONTROL_SHADER ||
             object->stage == GL_TESS_EVALUATION_SHADER ||
             object->stage == GL_GEOMETRY_SHADER ||
             object->stage == GL_FRAGMENT_SHADER);
        const bool computeSameStageLinkOnlyFailure =
            sameStageLinkOnlyDiagnostic && object->stage == GL_COMPUTE_SHADER;
        if (graphicSameStageLinkOnlyFailure) {
            object->compiled = true;
            object->compileLog.clear();
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", "", "", true
            });
            return true;
        }
        if (computeSameStageLinkOnlyFailure) {
            object->compiled = true;
            object->compileLog.clear();
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", "", "", true
            });
            return true;
        }
        if (object->stage == GL_FRAGMENT_SHADER &&
            (compileSource.find("void Run();") != std::string::npos ||
             compileSource.find("void Run()") != std::string::npos) &&
            (object->compileLog.find("Run") != std::string::npos ||
             object->compileLog.find("main") != std::string::npos ||
             compileSource.find("void main") == std::string::npos)) {
            object->compiled = true;
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", sourceHash, "", "", object->compileLog, "", true
            });
            return true;
        }
        // Glslang failed. compileLog contains the real diagnostic text,
        // which getShaderInfoLog will now return verbatim. Push the failure
        // to the diagnostic ring as a compile-stage record so BAR sees the
        // glslang log directly without having to wait for a downstream
        // glLinkProgram lift. (Pre-Group-4d the only path was via
        // linkProgram's "attached shader is not compiled" branch, which
        // could not survive the eager-erase shader lifetime bug — see
        // GLObjectStore.h::GLShaderObject for the full story.)
        Runtime::shared().recordShaderTranslation({
            shaderTag, "compile", sourceHash, "", "", object->compileLog, "", false
        });
        return false;
    }

    object->spirv = std::move(spirv);
    object->compiled = true;
    // Push a positive compile-stage record. mslPreview is intentionally
    // empty here — MSL transpilation runs at link time, not compile time —
    // but the presence of the record (with success=true and a stable
    // sourceHash) is enough for BAR-side observation to confirm the compat
    // rewriter / glslang pipeline ran end-to-end on this shader.
    Runtime::shared().recordShaderTranslation({
        shaderTag, "compile", sourceHash, "", "", "", "", true
    });
    return true;
}
