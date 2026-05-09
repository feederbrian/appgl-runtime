# Tessellation Interpreter Plumbing

Reference document for AppGL's CPU tessellation emulator — the
`emulateTessellationDraw` path that sits between GL's tess API and
Metal's lack of a tess stage. Captures the end-state of phases
3f-1 → 3f-15 so a future pass that replaces this with a direct
SPIR-V → MSL path (or overlays one on top) has a single spec to
diff against.

Target reader: someone about to refactor, optimize, or replace this
subsystem. Not a user guide — there is no "user" of the internals.

---

## 1. Why a CPU interpreter

Metal has no tessellation-shader stage. Apple's recommended path is
to run the tessellation on the CPU and feed Metal a pre-expanded
vertex buffer. The CTS's `constant_expressions.*_tess_*` cluster and
the `tessellation_shader.*` cluster both issue real
`glDrawArrays(GL_PATCHES, …)` calls with TES / TCS stages attached
that compute vertex positions and per-patch side effects (SSBO
writes, XFB captures). To pass any meaningful fraction of those
tests we need SOMETHING that actually executes the GLSL semantics.

Three options considered:

| Path | Cost | Correctness ceiling |
|---|---|---|
| Silently drop the tess stages | trivial | Useless — breaks any test that checks output |
| Rewrite TCS+TES into Metal compute + expanded-VS MSL | 2-4 weeks | Can match GPU perf; SPIRV-Cross + Apple converter lift required |
| Run TCS+TES on CPU, rasterize Metal VS+FS | 1-2 weeks | Spec-correct for tests that don't exercise a huge shader matrix |

The interpreter is the third option. It's what the current tree
does. A future "replace with SPIRV-MSL" direction is option two,
and this document's purpose is to make that transition clean.

---

## 2. High-level architecture

```
┌──────────────────── GL API (glDrawArrays(GL_PATCHES, …))
│
├── GLContext::drawArrays ────────────────────────┐
│    └── if (program->tessellationEmulated       │
│           || program->tessellationInterpreted) │
│        → appgl::emulateTessellationDraw        │
│              produces EmulatedDraw (position  + │
│              varyings + topology, all flat     │
│              scalar floats)                    │
│    └── Impl::writeGsXfbAndCheckDiscard (reused │
│         from the GS emul — same EmulatedDraw   │
│         shape)                                  │
│    └── Impl::encodeEmulatedGsDraw              │
│         → Metal VS (synth pass-through) + FS   │
│
└──────── Legacy translated pipeline (fallback)
           — kicks in when ok=false OR classifier
             rejects the program at link time
```

Key observation: the draw path REUSES the GS emulator's downstream
plumbing (`writeGsXfbAndCheckDiscard`, `encodeEmulatedGsDraw`,
`synthesisePassThroughVertexMSL`). The tess emulator's job is to
produce an `EmulatedDraw` with the right byte layout; everything
below that is shared with the GS path.

---

## 3. File layout

| File | Role |
|---|---|
| `src/shader/TessellationEmulator.h` | Public API: `emulateTessellationDraw`, classifiers, `TessDomainOutput`, `generateTessDomain`, `detectTessellationEmulatable` |
| `src/shader/TessellationEmulator.cpp` | Detection, matcher, classifier, domain generator, emit loop |
| `src/shader/GeometryShaderEmulator.h` | Public: `runTesForVertex`, `runTcsForVertex`, `TesSsboMap`, `TesUniformMap`, `TesPatchVaryingMap`, `synthesisePassThroughVertexMSL` |
| `src/shader/GeometryShaderEmulator.cpp` | Interpreter class (anon namespace), all three runners, synth VS emitter |
| `src/shader/ShaderInterpreter.{h,cpp}` | `SpirvModule` parser, shared types (`TypeInfo`, `DecorationSet`, `Value`) |
| `src/objects/GLObjectStore.h` | `GLProgramObject` fields: tess*Spirv blobs, tess*ParsedModule caches, tessVaryings, tessellationEmulated/Interpreted/tessControlInterpreted flags |

The `Interpreter` class sits inside the anonymous namespace of
`GeometryShaderEmulator.cpp`. Callers outside that TU reach it only
via the public `runTesForVertex` / `runTcsForVertex` / `runVsForVertex`
wrapper functions. This is intentional pimpl — if/when we replace
the interpreter with a SPIRV-MSL emitter, the wrappers are the
insertion point.

---

## 4. Enablement gating

Sprint 18 flips the emulator default-on. The environment variables are
kept as explicit fallback switches:

| Env var | Purpose |
|---|---|
| `APPGL_ENABLE_TESS_EMUL=0` | Forces the legacy translated-no-tess fallback instead of flipping `tessellationEmulated` / `tessellationInterpreted` in `detectTessellationEmulatable`. |
| `APPGL_ENABLE_TESS_EMUL_GLIN=0` | Rejects TES / TCS bodies that read `gl_in[]`, restoring the pre-Sprint-18 classifier fallback. |
| `APPGL_TESS_EMUL_DEBUG=1` | Stream-of-one-reason-per-draw bail diagnostics to stderr. |

Phase 3f originally kept these opt-in because tess_shader.* correctness
gaps surfaced only on the interpreter path. Sprint 18's cull_distance
closure keeps the escape hatches while making the reachable interpreter
path part of default coverage.

---

## 5. Per-program state (GLProgramObject)

Fields added for tess emul, grouped by phase:

```cpp
// Detection flags (phase 3f-1/3f-4/3f-13)
bool tessellationEmulated = false;            // passthrough matcher accepted
bool tessellationInterpreted = false;         // TES classifier accepted
bool tessControlInterpreted = false;          // TCS classifier accepted

// Passthrough affine mapping (phase 3c/3d)
int8_t tessPositionMapping[4];
float  tessPositionScale[4], tessPositionOffset[4], tessPositionConstant[4];
std::vector<TessVaryingSlot> tessVaryings;    // also populated from scan
                                              // for interpreter path (3f-6)

// SPIR-V blobs (3f-1/2) and parsed-module caches (3f-11)
std::vector<uint32_t> tessEvalSpirv;
std::vector<uint32_t> tessControlSpirv;
mutable unique_ptr<SpirvModule> tessEvalParsedModule;       // lazy cache
mutable unique_ptr<SpirvModule> tessControlParsedModule;

// Execution-mode metadata (parsed from SPIR-V at link time)
GLint  tessControlOutputVertices;
GLenum tessGenMode;               // GL_TRIANGLES / GL_QUADS / GL_ISOLINES
GLenum tessGenSpacing;            // GL_EQUAL / _FRACTIONAL_EVEN / _ODD
GLenum tessGenVertexOrder;        // GL_CCW / GL_CW
GLboolean tessGenPointMode;
```

`~GLProgramObject()` and move ops are declared in the header and
defined in GLObjectStore.cpp — necessary because `unique_ptr<SpirvModule>`
needs SpirvModule's full type at destructor instantiation, and
GLObjectStore.h can't include ShaderInterpreter.h (would create a
shader/ → objects/ → shader/ cycle).

---

## 6. Data flow per draw

```
emulateTessellationDraw(program, vao, objects, state, mode, count, first, ...)
│
├── (1) Early exits
│       mode != GL_PATCHES     → ok=false
│       tess levels == 0       → ok=false  (future — not yet handled)
│
├── (2) Tess-level resolution (3f-8)
│       outer[4] = state defaults
│       scanTessControlConstantLevels  → override from compile-time
│                                         TCS constants
│       runTcsForVertex(primID=0, inv=0, ssbo=nullptr, …) →
│            captures BuiltInTessLevel{Outer,Inner} via
│            Interpreter::captureTessLevels. Side-effect-free
│            dry-run; uniform map not built yet.
│
├── (3) generateTessDomain(domain, spacing, outer, inner, pointMode, cw)
│       produces coords (flat float), indices (uint32), topology
│       (GL_POINTS / GL_LINES / GL_TRIANGLES). Owns the cw/ccw flip
│       (3f-9).
│
├── (4) EmulatedDraw layout
│       floatsPerVertex = 4 (position) + Σ varyingWidths
│       expandedVertexData.resize(totalVerts × floatsPerVertex)
│
├── (5) SSBO map build (3f-3/3f-4)
│       Walk TES AND TCS SPIR-V for StorageBuffer / Uniform+BufferBlock
│       variables. For each, resolve binding via
│       GLStateTracker::indexedBufferBinding(GL_SHADER_STORAGE_BUFFER,
│       N). metalBufferContents() returns the host-visible pointer.
│       TesSsboMap keyed by binding → {ptr, size}.
│
├── (6) Uniform-map build (3f-12)
│       buildTesUniformMap(program) once. Passed into every
│       runTes/TcsForVertex call below.
│
├── (7) VS pre-pass (3f-5/3f-10)
│       For each (patch, pv) where pv ∈ [0, patchVertices):
│         runVsForVertex(…) → patchInputs[p][pv].{position, clip,cull}
│       Runs BEFORE TCS pre-pass so TCS gl_in[] reads see real VS data.
│
├── (8) TCS pre-pass (3f-4/3f-10/3f-14)
│       For each patch p:
│         For each iv ∈ [0, tessControlOutputVertices):
│           runTcsForVertex(primID=p, inv=iv,
│                           patchInputs[p], ssboMap, uniformMap,
│                           outVertex:tcsOutputs[p][iv],
│                           patchVaryingsOut:tcsPatchVaryings[p])
│       — SSBO writes happen here (real)
│       — gl_out[inv] captured into tcsOutputs[p][iv] for TES gl_in[]
│       — Patch-decorated Output vars accumulate into
│         tcsPatchVaryings[p] (last-write-wins per spec §11.2.2)
│
├── (9) TES emit loop
│       For each generated domain vertex (u, v, w):
│         emitVertexInterpreted(dst, patchIdx, u, v, w):
│           runTesForVertex(…, patchInputs=tcsOutputs[patchIdx],
│                           patchVaryings=tcsPatchVaryings[patchIdx])
│           on success:
│             expandedVertexData[dst..dst+4]  = gl_Position
│             expandedVertexData[dst+4..]     = flat varyings
│           on bail (3f-15):
│             *anyTesBailed = true
│             zero-fill this vertex slot
│
├── (10) Final gate
│       if (anyTesBailed) → ok=false, return (fall through to legacy)
│       else              → ok=true, return with complete EmulatedDraw
│
└── drawArrays dispatch:
      writeGsXfbAndCheckDiscard(*program, ed)  // reused from GS path
      encodeEmulatedGsDraw(*program, programName, ed)  // reused
```

---

## 7. Interpreter internals (GeometryShaderEmulator.cpp)

Class `Interpreter` in the anon namespace. Instantiated per
runTes/TcsForVertex call today (no reuse across invocations —
phase 3f-13+ perf item, not landed).

```cpp
class Interpreter {
    enum class Stage { Vertex, Geometry, TessEvaluation, TessControl };

    // Construction: module + outputVaryingNames + outputVaryingWidths
    // (stage-specific ctor variants).

    // Input setters (caller plumbs what the body needs)
    void setUniforms(const UniformValues*);
    void setVsInputs(const VertexAttribs*, vertexID, instanceID);
    void setGsPrimitiveId(int32_t);
    void setGsInvocationId(int32_t);
    void setTesInputs(tessCoord[3], primitiveID);
    void setTcsInputs(primitiveID, invocationID, patchVertices);
    void setStorageBuffers(const StorageBufferMap*);
    void setTesPatchInputs(const map<uint32_t, vector<float>>*);

    // Body-walk entry points
    bool execute(inputs, emittedList);      // GS — strip-aware
    bool executeVs(outVertex);              // VS + TES-no-gl_in shortcut
    bool executeTes(outVertex, patchInputs); // TES — gl_in[] init path

    // Output captures (post-execute)
    bool captureTessLevels(outer[4], inner[2]);
    void captureTcsPatchOutputs(map);
    bool captureTcsOutputForInvocation(invID, outVertex);
    void captureClipCull(clipOut, cullOut);
    optional<int32_t> captureLayer();
    optional<int32_t> capturePrimitiveID();
    optional<float>   capturePointSize();

    // Private state
    const SpirvModule& module_;
    Stage stage_;
    unordered_map<uint32_t, Value> valueStore_;         // SSA values
    unordered_map<uint32_t, vector<float>> varStorage_; // per-var flat storage
    unordered_map<uint32_t, AccessChainResult> accessChains_;
    array<float, 4> currentPosition_;
    vector<vector<float>> currentOutVaryings_;
    // SSBO meta, input builtins, diag state, …
};
```

Body walk: linear scan of `module_.words[funcBodyStart..funcBodyEnd]`
dispatching on opcode. OpLabel / OpBranch / OpBranchConditional
support labels → pc jumps via a pre-built labelMap. OpLoad / OpStore
dispatch on `AccessChainResult::isStorageBuffer` to route through
`loadFromSSBO`/`storeToSSBO` (byte-level memcpy into the caller's
map) vs `loadFromVar`/`storeToVar` (flat-scalar-float).

Opcodes currently supported: see GeometryShaderEmulator.cpp's
`execute()` switch. Covers the CE tess_eval + tess_control body
shape + typical passthrough TES/TCS. NOT covered: matrix ops
(OpMatrixTimesMatrix / OpMatrixTimesVector / OpTranspose) ,
`OpPhi`, `OpSwitch`, function calls (`OpFunctionCall`), image ops.

---

## 8. SPIR-V handling

### 8.1 `SpirvModule` parser (ShaderInterpreter.cpp)

Reads the module header + all declarative ops: OpName, OpMemberName,
OpDecorate, OpMemberDecorate, OpType*, OpConstant, OpVariable,
OpEntryPoint, OpExecutionMode. Function bodies are just
`{funcBodyStart, funcBodyEnd}` ranges — the Interpreter walks them
on demand; SpirvModule never decodes per-op state.

### 8.2 Decorations understood

| Decoration | Used by |
|---|---|
| BuiltIn (0..42) | built-in var seeding |
| Location | input/output varying slots |
| Block / BufferBlock | UBO / SSBO detection |
| Binding / DescriptorSet | SSBO binding resolution |
| Offset | SSBO std430 member offsets |
| ArrayStride | SSBO std430 runtime-array stride |
| Flat / NoPerspective / Centroid | synth VS interp tag emission |
| Patch (3f-13) | per-patch varying detection |

### 8.3 Storage classes understood

- `StorageClassInput` (1) — VAO attrib + gl_in[] + built-ins
- `StorageClassUniform` (2) — default uniforms + block uniforms + (BufferBlock → SSBO)
- `StorageClassOutput` (3) — gl_Position, user varyings, gl_out[]
- `StorageClassUniformConstant` (0) — samplers / images (passed through)
- `StorageClassPrivate` (6) / `Function` (7) — scratch
- `StorageClassStorageBuffer` (12) — explicit SSBO (glslang default)

---

## 9. Metal bridge (GLContext.mm side)

Two hooks connect the tess emul to the Metal half of AppGL:

| Function | Purpose |
|---|---|
| `appgl::metalBufferContents(void*)` | Casts the GLBufferObject's void* handle back to `id<MTLBuffer>` and returns `[buf contents]`. Used by the SSBO map builder. |
| `Impl::encodeEmulatedGsDraw` | Same GS-emul encoder. Takes an EmulatedDraw, builds a TranslatedDrawInfo, synthesises the pass-through VS, sets up pipeline state, and issues the Metal draw. |
| `Impl::writeGsXfbAndCheckDiscard` | Walks program.transformFeedbackVaryingNames against ed.varyingNames, writes per-vertex bytes to bound TF buffers, updates primitive-query counters, honours GL_RASTERIZER_DISCARD. |

All three are in `src/context/GLContext.mm`. Phase 3f never added a
new Metal-side function beyond `metalBufferContents` — everything
else is reused from the GS path.

---

## 10. Where the SPIRV-MSL replacement slots in

The cleanest replacement point is `runTesForVertex` /
`runTcsForVertex`. They're defined in GeometryShaderEmulator.cpp but
declared in GeometryShaderEmulator.h with stable signatures. A
future SPIRV-MSL path can:

### Option A: **Replace** the runners

Build a Metal compute pipeline that runs the TCS + TES bodies as a
batch (one thread per (patch, invocation) pair for TCS, one thread
per domain vertex for TES). Produce the same EmulatedDraw-shape
byte buffer in a Metal buffer. Replace the runner bodies with
"dispatch compute, wait, read back the buffer."

Pros:
- Huge perf win — GPU-parallel tess on Apple silicon
- Same EmulatedDraw shape means downstream (writeGsXfb,
  encodeEmulatedGsDraw) is unchanged
- One-shot per draw — no per-vertex CPU cost

Cons:
- Compute-shader setup complexity
- SSBO plumbing still needed (Metal compute can write buffers
  natively though)
- Probably need to keep the CPU interpreter as a fallback for
  shaders outside the SPIRV-Cross → MSL subset

### Option B: **Overlay** (use SPIRV-Cross MSL for the common case)

Detect at link time whether SPIRV-Cross can lower the TES/TCS to
Metal compute MSL. If yes, flip a new flag like
`tessellationComputeEmulated` and use the compute path. If no,
fall back to the current interpreter. Two draw paths coexist.

Pros:
- Incremental deploy — no regression risk on shaders the compute
  path can't handle
- CPU interpreter stays correct for fallback

Cons:
- Two paths to maintain
- Need a trusted classifier ("can SPIRV-Cross handle this?")

### Key invariants to preserve

Either option should honour these for the downstream Metal
pipeline to stay unchanged:

1. **EmulatedDraw layout**: position (4 floats) + flat
   varying bytes per vertex, `floatsPerVertex` stride, `topology`
   one of GL_POINTS / GL_LINES / GL_TRIANGLES.
2. **TCS patch-out → TES patch-in map**: same
   `TesPatchVaryingMap` shape. Keyed by Location.
3. **SSBO binding resolution**: walk SPIR-V for binding numbers,
   look up indexed-buffer-binding, use metalBufferContents. Both
   TCS and TES share the same map (3f-4 fix).
4. **Transform feedback capture**: writeGsXfbAndCheckDiscard
   expects the flat-vertex layout. Must still work.
5. **Domain output topology mapping**: GL_POINTS / GL_LINES /
   GL_TRIANGLES — compute path must emit indices/coords in the
   same order the CPU domain generator does, or the CW/CCW flip
   logic moves to the compute side.
6. **Tess-level precedence**: state defaults → compile-time TCS
   constants → runtime TCS writes. Compute path needs to capture
   runtime levels too if the shader computes them.
7. **Graceful bail**: if the compute path can't handle a shader at
   runtime (malformed output, validation error), return
   `ok = false` from the runner so drawArrays falls through to the
   CPU interpreter (or to legacy). Same contract 3f-15 enforces.

---

## 11. Phase 3f commit trail

Chronological, each commit scoped narrowly:

| Commit | Phase | What |
|---|---|---|
| 851b2eb | 3f-1 | Stage::TessEvaluation + runTesForVertex scaffolding |
| 2ac7fb2 | 3f-2 | Interpreter dispatch + TES classifier |
| 7d15574 | 3f-3 | SSBO byte-level plumbing (+448 CE: 944 → 1392) |
| bcef5d3 | 3f-4 | TCS interpreter (Stage::TessControl) |
| e7bbb32 | 3f-5 | gl_in[] infrastructure (originally opt-in gated) |
| db3e2f8 | 3f-6 | User varying capture on interpreter path |
| 08e4120 | 3f-7 | XFB capture via writeGsXfbAndCheckDiscard reuse |
| 5e6ce84 | 3f-8 | TCS runtime tess-level capture |
| 2de4a2e | 3f-9 | CW/CCW vertex ordering + TES bail diag |
| 555c027 | 3f-10 | TCS→TES data flow (gl_out → gl_in) |
| 2a7824d | 3f-11 | SpirvModule cache on program |
| 97e6bef | 3f-12 | Uniform-map hoist to draw entry |
| 712b74d | 3f-13 | Patch-decoration detection |
| c768643 | 3f-14 | Patch-varying data flow |
| a6b0912 | 3f-15 | Graceful interpreter bail |

Total: 15 commits, roughly 1500 LOC added to the shader/
directory. Pre-Sprint-18, net delta was visible by setting
`APPGL_ENABLE_TESS_EMUL=1`: +448 CE tests (944→1392), +4
tess_shader tests (37→41). `APPGL_ENABLE_TESS_EMUL_GLIN=1`
exposed another +12 tess tests (23→35). Sprint 18 made both paths
default-on while keeping `=0` fallback switches.

---

## 12. Known limitations (carried forward)

Ranked by blast radius if ignored:

1. **Perf on deep-glin cluster**: full tessellation_shader.*
   sweep through the default-on gl_in[] interpreter path may not
   complete in the CTS harness timeout. Phase 3f-11/3f-12 took the biggest
   static costs out (reparse + uniform rebuild) but per-invocation
   body-walk dominates. Next targets: Interpreter reuse across
   invocations of the same patch (avoid initVariables rebuild),
   body-walk opcode dispatch tightening.

2. **Domain-generation correctness bugs** surfaced by 3f-9 probe:
   - `vertex_spacing_primitive_mode_*`: "Invalid delta between
     segments" on fractional_{even,odd}_spacing isolines / quads.
     Our `tessellateIsolines` / `tessellateQuads` don't fully
     match GL 4.6 §11.2.2 Table 11.8's spacing formulas.
   - `tessellation_invariance.invariance_rule*`: primitive-count
     mismatches. Our domain generator's vertex counts per patch
     don't match the spec's for certain (primitive mode × spacing
     × level) combinations.

3. **Non-drawArrays dispatch**: `drawElements`, `drawRangeElements`,
   `multiDrawArrays`, `drawArraysInstanced`, `drawElementsInstanced`,
   `drawArraysIndirect`, `drawElementsIndirect` — none go through
   the tess-emul block. Only `drawArrays` is intercepted. GS-emul
   wires all of these; tess-emul needs the same dispatch.

4. **TES + GS**: `detectTessellationEmulatable` explicitly rejects
   programs with both. 5-stage pipeline support needs the tess
   emul's EmulatedDraw to feed into the GS emul's gl_in[].

5. **Per-patch domain regen**: when TCS produces gl_PrimitiveID-
   sensitive tess levels, all patches currently share patch-0's
   levels. Correct behaviour = regenerate domain per-patch when
   levels vary.

6. **Interpreter opcode gaps**: matrix ops (OpMatrixTimesVector,
   OpMatrixTimesMatrix, OpTranspose), OpPhi in loops, OpSwitch,
   OpFunctionCall (for user functions in the shader body), image
   ops (OpImageSampleExplicitLod etc.). Shaders that hit these
   now bail cleanly thanks to 3f-15.

---

## 13. Quick reference: adding a new SPIR-V opcode

Adding opcode support to the interpreter is the most common
incremental change. The path:

1. Find the opcode number in `glslang/SPIRV/spirv.hpp` or the
   SPIR-V spec.
2. Add a `case spv::OpYourOpcode:` to the main switch in
   `Interpreter::execute` (around line ~1900 of
   `GeometryShaderEmulator.cpp`).
3. For ops with a result id (most), read operand ids from `w[2..]`,
   resolve via `tryGetValue`, compute a `Value`, store into
   `valueStore_[w[1]]`.
4. For ops with side effects (OpStore into SSBO, atomics), read
   the access-chain result via `accessChains_[w[0]]`, route through
   `storeToSSBO` or `storeToVar`.
5. Bump the body-size classifier ceiling in
   `classifyTessEvalInterpretable` if the new op typically emits
   large word sequences.
6. Add a CTS probe (or find one that was failing on this op) to
   confirm the win.

Opcodes that come up most often in current CTS failures (3f-9 diag
hasn't fully enumerated these but the shapes suggest):

- OpMatrixTimesVector, OpMatrixTimesMatrix (any shader with MVP)
- OpPhi (loop-carried state)
- OpSwitch (rarer — typically only on enums)
- OpFunctionCall (user-defined GLSL functions)

---

## 14. Testing / probing a change

CE regression (should always stay at 100%; `APPGL_ENABLE_TESS_EMUL=0`
is now only for fallback attribution):
```
DYLD_LIBRARY_PATH=appgl-runtime/build \
  specs/VK-GL-CTS/build-appgl/external/openglcts/modules/glcts \
  --deqp-case='KHR-GL46.constant_expressions.*' \
  --deqp-log-filename=/tmp/ce.qpa
```

tess_shader baseline (historically 41/140 @ 3f-9 with the emulator
enabled by env; Sprint 18 runs this path by default):
```
... --deqp-case='KHR-GL46.tessellation_shader.*' ...
```

Interpreter bail tracing:
```
APPGL_TESS_EMUL_DEBUG=1 \
  ... 2>&1 | grep 'tess-emul'
```

GS regression (always 120/136 — safety net):
```
... --deqp-case='KHR-GL46.geometry_shader.*'
```

---

## 15. Open design questions

Points where the current design is the simplest thing that works
but not obviously the right long-term choice:

1. **Environment fallback switches vs. a runtime capability bit**:
   `APPGL_ENABLE_TESS_EMUL=0` and `APPGL_ENABLE_TESS_EMUL_GLIN=0`
   are coarse attribution tools. A runtime "advertise tess capability"
   would let apps decide per-frame, but it's a bigger API change and
   nothing outside CTS uses tess.

2. **Per-invocation Interpreter vs. per-draw reuse**: phase 3f-11
   cached the parsed module; 3f-12 hoisted the uniform map. Further
   reuse (per-draw single Interpreter with a `reset()` method) is
   speculated-about but not implemented. Could add 10-30% perf.

3. **Domain generator location**: currently in
   TessellationEmulator.cpp (`tessellateIsolines` / `tessellateQuads`
   / `tessellateTriangles`). Could be hoisted into a Metal compute
   shader even under the interpreter path, since the domain doesn't
   depend on the shader body. Separate concern from the main
   SPIRV-MSL replacement.

4. **Classifier strictness**: currently very strict (lots of
   rejection paths) to keep the interpreter from producing
   silently-wrong output. A more lax classifier combined with the
   3f-15 graceful-bail could reach more shaders, letting unrunnable
   ones fall through naturally instead of being rejected at link
   time. Tradeoff: more runtime validation vs. more link-time
   certainty.

---

End of document. Last updated alongside commit `a6b0912` (phase
3f-15). If this file drifts significantly from the code, treat
the code as source of truth and re-sync the doc.
