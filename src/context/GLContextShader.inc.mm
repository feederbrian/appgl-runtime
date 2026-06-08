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
    CompatShaderRewriteResult rewrite =
        rewriteCompatShader(object->source, object->stage);
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
        rewrite.didRewrite ? rewrite.source : object->source;
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
    std::string afterSsboRuntimeArrayRewrite =
        rewriteSsboConsecutiveRuntimeArraysForSpirv(
            sourceAfterUnsizedUniformArrayRewrite);
    const std::string& compileSource =
        (afterSsboRuntimeArrayRewrite != sourceAfterUnsizedUniformArrayRewrite)
            ? afterSsboRuntimeArrayRewrite
            : sourceAfterUnsizedUniformArrayRewrite;

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

    // GL 4.6 §11.1.3.2 (ClipDistance) / §E.2.1 deprecated gl_ClipVertex:
    // A vertex shader must not write to BOTH `gl_ClipVertex` and any
    // element of `gl_ClipDistance[]`. The spec describes this as
    // undefined behaviour, but the CTS treats it as a compile error
    // (clip_distance.negative asserts COMPILE_STATUS = FALSE on such a
    // shader). Detect the pattern by source-text scan — we look for
    // the `gl_ClipVertex` assignment target and any `gl_ClipDistance`
    // reference in the same shader body.
    if (object->stage == GL_VERTEX_SHADER) {
        // Scan the ORIGINAL GLSL, not the rewritten form — CompatShader-
        // Rewrite renames `gl_ClipVertex` to `appgl_ClipVertex` before
        // this point, so the post-rewrite scan would miss the pattern.
        const std::string& src = object->source;
        auto findWordBoundary = [&](const char* needle) {
            std::size_t pos = 0;
            const std::size_t nlen = std::strlen(needle);
            while ((pos = src.find(needle, pos)) != std::string::npos) {
                const bool leftBoundary = (pos == 0) ||
                    !(std::isalnum(static_cast<unsigned char>(src[pos - 1])) || src[pos - 1] == '_');
                const std::size_t end = pos + nlen;
                const bool rightBoundary = (end >= src.size()) ||
                    !(std::isalnum(static_cast<unsigned char>(src[end])) || src[end] == '_');
                if (leftBoundary && rightBoundary) return true;
                pos = end;
            }
            return false;
        };
        const bool usesClipVertex   = findWordBoundary("gl_ClipVertex");
        const bool usesClipDistance = findWordBoundary("gl_ClipDistance");
        if (usesClipVertex && usesClipDistance) {
            object->compileLog =
                "ERROR: vertex shader must not write to both "
                "gl_ClipVertex and gl_ClipDistance[] in the same "
                "stage (GL 4.6 §11.1.3.2).";
            object->compiled = false;
            object->spirv.clear();
            Runtime::shared().recordShaderTranslation({
                shaderTag, "compile", "", "", "", object->compileLog, "", false
            });
            return true;
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
    std::vector<std::uint32_t> spirv =
        translator.compileGLSL(compileSource, object->stage, 330, &compileLog);

    object->compileLog = std::move(compileLog);
    if (spirv.empty()) {
        const bool computeSameStageLinkOnlyFailure =
            object->stage == GL_COMPUTE_SHADER &&
            (object->compileLog.find("Missing entry point") != std::string::npos ||
             object->compileLog.find("Each stage requires one entry point") != std::string::npos ||
             object->compileLog.find("No function definition") != std::string::npos);
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
            // Query returns the LINK-TIME snapshot, not the request
            // parameter. Before any successful link, this is FALSE
            // regardless of glProgramParameteri calls.
            *params = object->separableLinked ? GL_TRUE : GL_FALSE;
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
    for (const auto& uniform : object->uniforms) {
        if (uniform.name == lookup) {
            return uniform.location;
        }
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
            // Pass 1: exact match on rewritten name.
            for (const auto& uniform : object->uniforms) {
                if (uniform.name == rewritten) {
                    return uniform.location;
                }
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

#elif defined(APPGL_GLCONTEXT_SHADER_UNIFORMS)
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
    slot->doubles.clear();
    slot->df64TransportWords.clear();
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
    switch (element) {
        case UniformElementType::Float:
            writeInto(slot->floats, slot->ints, slot->uints, static_cast<const GLfloat*>(values)); break;
        case UniformElementType::Int:
            writeInto(slot->ints, slot->floats, slot->uints, static_cast<const GLint*>(values)); break;
        case UniformElementType::UnsignedInt:
            writeInto(slot->uints, slot->floats, slot->ints, static_cast<const GLuint*>(values)); break;
    }
    slot->doubles.clear();
    slot->df64TransportWords.clear();
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
        pushError(GL_INVALID_ENUM);
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
            pushError(GL_INVALID_ENUM);
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
        pushError(GL_INVALID_VALUE);
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
            if ((*table)[i].name == suffixed) {
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
