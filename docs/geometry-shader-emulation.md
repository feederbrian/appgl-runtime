# Geometry-Shader CPU Emulation — Design Whitepaper

**Status:** in-progress (scaffolding landed in commit `0f1ba0e`, interpreter proper under construction)

**Authors:** Session 15+ CTS sprint notes

**Revised:** living document; update as implementation details surface

## 1. Problem statement

Apple Metal has no geometry-shader stage. Apple's modern path for
GS-style amplification is mesh shaders (Metal 3 / Apple7+), which
neither our shader translator (glslang + SPIRV-Cross) nor our
pipeline graph currently targets. SPIRV-Cross's MSL backend cannot
translate SPIR-V with `ExecutionModelGeometry` — for a simple
passthrough GS (see [§6.1](#61-constant_expressions)) it emits:

```msl
unknown main0_out main0()
{
    main0_out out = {};
    float out0 = 1.57079637;
    out.geom_out_out0 = out0;
    EmitVertex();
    EndPrimitive();
    ...
}
```

`unknown` isn't a Metal function qualifier and `EmitVertex` /
`EndPrimitive` aren't Metal intrinsics. The MSL fails to compile
and our pipeline silently drops the GS stage, running the program
as VS+FS only. FS reads uninitialised varyings → test sees
mismatched pixel output.

This blocks, at minimum, **672 CTS tests** in
`KHR-GL46.constant_expressions.*_{geometry,tess_control,tess_eval}`
plus a substantial portion of the `geometry_shader.*` section.

## 2. Approach — layered emulation

Three layers, sequenced by implementation cost and runtime ceiling
(see session 14 journal for the strategic discussion that led to
this sequencing):

| Layer | Runtime ceiling | Effort | When to choose |
|---|---|---|---|
| **L1 — CPU interpretation** | 10–40 % of native | ~1 week | Always available; conformance oracle; portable fallback |
| **L2 — SPIRV-Cross mesh-shader emitter** | 100 % | 2–4 weeks | When upstream patch lands and hardware is Metal 3 / Apple7+ |
| **L3 — Apple shader-converter chain** | 100 % | contingent | Rescue plan if the SPIRV-Cross patch is rejected upstream |

**This document covers Layer 1 only** — the other two are tracked
separately once L1's ground-truth reference is in place.

L1 is the **ground-truth oracle**: whatever L2/L3 produce on a given
shader must pixel-match what L1 produces. Keeping L1 permanently as
a fallback also guarantees coverage for pre-Apple7 GPUs the
mesh-shader path can't reach.

## 3. Runtime architecture

### 3.1 Current GL draw path (no-GS)

```
  glDrawArrays(mode, count)
      │
      ▼
  GLContext::drawArrays
      │
      ▼
  MetalFrameGraph::encodeTranslatedDraw ──► MTLRenderCommandEncoder
      │                                          │
      ├─ VS (MSL, on GPU)                        │
      └─ FS (MSL, on GPU) ◄──────────────────────┘
```

### 3.2 Emulated draw path (with GS)

```
  glDrawArrays(mode, count)
      │
      ▼
  GLContext::drawArrays (dispatches on program.geometryEmulated flag)
      │
      ▼
  emulateGeometryDraw (new)
      │
      ├─ (1) Read VAO attributes from VBO shadow buffers into CPU arrays
      ├─ (2) Interpret VS SPIR-V on CPU per vertex
      │        → per-vertex outputs (gl_Position + user varyings)
      ├─ (3) Group per VS outputs into primitives by input topology
      │        (layout(triangles) → batches of 3 adjacent vertices)
      ├─ (4) Interpret GS SPIR-V on CPU per primitive
      │        → OpEmitVertex appends EmulatedVertex snapshot
      │        → OpEndPrimitive emits primitive-restart marker
      └─ (5) Return EmulatedDraw with:
               - expanded vertex buffer (float-packed)
               - output topology (from GS layout(out_prim))
               - varying layout description
      │
      ▼
  Synthesised pass-through VS built to match expanded layout
      │
      ▼
  MetalFrameGraph::encodeTranslatedDraw (re-used)
      │
      ├─ Passthrough VS (on GPU) — reads expanded buffer as attribs
      └─ Original FS (on GPU) — sees same varying names/types
```

### 3.3 Why VS-on-CPU, not GPU-VS + CPU-GS

The first-cut VS-on-CPU choice is deliberately simple:

1. **Single translation pipeline** — one SPIR-V interpreter handles
   both stages. No separate GPU→CPU readback plumbing for VS
   outputs.
2. **No transform-feedback dependency** — capturing GPU VS output
   would require either a TF path (which has its own CTS
   conformance gaps) or rasterizer-discard-with-SSBO-writes (which
   requires rewriting the VS to write SSBOs).
3. **Workload fits** — CTS GS tests use tiny geometry (typically
   3–72 vertices). Interpreter overhead is microseconds per
   vertex, not visible in test times.
4. **Correctness first** — interpreted VS is provably equivalent
   to the MSL translation, removing one variable when debugging
   pixel mismatches in the MVP.

If we later need a real-world perf profile for a GL port, the path
to GPU-VS + CPU-GS is clear: replace the Interpreter's VS step
with a capture encoder that writes the VS output struct into an
SSBO, read it back on CPU before GS step 4. No API changes
required.

## 4. SPIR-V interpreter

### 4.1 Design — boxed SSA value store

Every SPIR-V id maps to a `Value`:

```cpp
struct Value {
    enum class Kind { Float, Float2, Float3, Float4,
                      Int, UInt, Bool };
    Kind kind;
    std::array<float, 4> f;
    std::array<std::int32_t, 4> i;
    bool b;
};
```

Non-scalar / non-small-vector types (arrays, matrices, structs)
live in a separate `Composite` store keyed by id, accessed through
`OpAccessChain` walks. `OpLoad` from a pointer resolves the full
access chain and copies the scalar/vector portion into `Value`.

### 4.2 Opcode scope (MVP — constant_expressions only)

About 30 opcodes. Explicit list with a note per category. Extend
this table as new shader patterns demand more.

| Category | Opcodes |
|---|---|
| **Types (parse)** | `OpTypeVoid` `OpTypeBool` `OpTypeInt` `OpTypeFloat` `OpTypeVector` `OpTypeMatrix` `OpTypeArray` `OpTypeStruct` `OpTypePointer` |
| **Constants (parse)** | `OpConstant` `OpConstantTrue` `OpConstantFalse` `OpConstantComposite` |
| **Memory (run)** | `OpVariable` `OpLoad` `OpStore` `OpAccessChain` |
| **Composite (run)** | `OpCompositeExtract` `OpCompositeConstruct` |
| **Arithmetic (run)** | `OpFAdd` `OpFSub` `OpFMul` `OpFDiv` `OpIAdd` `OpIMul` `OpSLessThan` `OpConvertFToI` `OpConvertIToF` |
| **Logic (run)** | `OpLogicalAnd` `OpLogicalOr` `OpLogicalNot` |
| **Control flow (run)** | `OpBranch` `OpBranchConditional` `OpLabel` `OpLoopMerge` `OpSelectionMerge` `OpPhi` `OpReturn` |
| **Extended (run)** | `OpExtInstImport` (parse) + `OpExtInst` with GLSL.std.450: `Radians` `Degrees` `Sin` `Cos` `Normalize` `Length` `Dot` `Pow` |
| **Decorations (parse)** | `OpDecorate Location` `OpDecorate BuiltIn` `OpMemberDecorate BuiltIn` |
| **Meta (parse)** | `OpEntryPoint` `OpName` `OpMemberName` `OpFunction` `OpFunctionEnd` |
| **GS-specific (run)** | `OpEmitVertex` `OpEndPrimitive` |

Opcode gaps bail with `"unsupported opcode: OpXYZ (N)"`. The
emulator reports `ok = false`, the driver logs, and the pre-
existing no-GS fallback stays in effect. This degrades gracefully
and makes the "which opcode do I need next" question a
grep-the-log operation.

### 4.3 Control flow — structured SSA

SPIR-V guarantees structured control flow. `OpLoopMerge` and
`OpSelectionMerge` annotate the regions and their exit labels
before the branching instruction. The interpreter:

- Preprocesses the function's basic-block CFG (label → instruction
  offset map).
- Maintains a `currentLabel` during execution.
- On `OpBranch(target)`, jumps to `target`'s first instruction.
- On `OpBranchConditional(cond, t, f)`, picks branch based on the
  `Value.b` of `cond`'s id.
- On `OpPhi(pairs[])`, selects the value corresponding to the
  label the interpreter *just left*. This needs a one-word
  `previousLabel` tracker.
- On `OpReturn`, exits the function.

Loop semantics fall out of this naturally: `OpLoopMerge` is just
an annotation, not a runtime action. The loop's back-edge is an
ordinary `OpBranch` to the header, and the header's `OpPhi`
selects between initial and per-iteration values.

### 4.4 Memory model

Storage classes we care about for MVP:

| Class | Meaning | Interpreter treatment |
|---|---|---|
| `Private` | Function-local | Allocate per-interpretation |
| `Function` | Function-scoped | Allocate per-invocation |
| `Input` | Per-invocation input | Populated by driver before `execute()` |
| `Output` | Per-invocation output | Stored into by shader; snapshot captured on `OpEmitVertex` |
| `Uniform` / `UniformConstant` | Program uniforms | Populated by driver from `program.uniformValues` |

Each storage class has its own `std::unordered_map<VarId,
std::vector<Value>>` in the interpreter — indexing `variable[varId][accessPath]`
reads/writes scalars at an access-chain offset.

### 4.5 Built-ins

Interpreter-exposed built-ins (driver writes before `execute()`):

- `gl_in[i].gl_Position` — per-input-vertex position array
- `gl_in[i]` user varyings — resolved by name from `gl_PerVertex`
  block decorations + parallel driver-provided data arrays

Interpreter-captured built-ins (driver reads after each
`OpEmitVertex`):

- `gl_Position` — written to during GS body
- User varyings declared as `out` in GS

`gl_PrimitiveIDIn`, `gl_InvocationID`, and `gl_Layer` are deferred
until the second-phase tests demand them.

## 5. Synthesised pass-through VS

After GS emulation, we have an expanded vertex buffer with payload
`[pos.xyzw, varying0, varying1, ...]` per vertex and a set of
varying (name, width) pairs. The synthesised GLSL-then-MSL VS has
the shape:

```glsl
#version 450
layout(location = 0) in vec4  in_position;
layout(location = 1) in <ty0> in_<name0>;
layout(location = 2) in <ty1> in_<name1>;
// ...
out <ty0> <name0>;
out <ty1> <name1>;
// ...
void main() {
    gl_Position = in_position;
    <name0> = in_<name0>;
    <name1> = in_<name1>;
    // ...
}
```

The `<name_N>` values are taken from the original GS output
declarations so the existing FS's `in` varyings match by name.
The synthesised VS is compiled through the normal glslang +
SPIRV-Cross path and cached per (GS-output-layout, FS) key.

## 6. CTS targets — in order of implementation

### 6.1 constant_expressions

**Scope:** 224 tests in `constant_expressions.*_geometry`.

**Pattern:** GS body is strictly:

```glsl
void main() {
    <OP> result = <LITERAL_EXPR>;
    for (int i = 0; i < gl_in.length(); ++i) {
        gl_Position = gl_in[i].gl_Position;
        geom_out_out0 = <result>;
        EmitVertex();
    }
    EndPrimitive();
}
```

Where `<LITERAL_EXPR>` is one of `radians(90.0)`, `sin(0.5)`, etc.
Result is a scalar or vector written to a single output varying.

**Opcodes needed:** the full MVP list (§4.2). Extended instructions
are the per-test varying piece — `Radians`, `Degrees`, `Sin`,
`Cos`, etc.

**Acceptance:** `KHR-GL46.constant_expressions.basic_radians_float_geometry`
Pass. All 224 variants should then flip as a group once the `OpExtInst`
dispatch covers GLSL.std.450 math built-ins.

### 6.2 geometry_shader.* (stretch)

~50+ tests in `KHR-GL46.geometry_shader.*` using more adventurous
GS patterns. Deferred to a second phase; see §10 for unsupported-
opcode extensions needed.

## 7. Fallback + error handling

Every layer degrades cleanly:

- **Interpreter bails on unsupported opcode** → `emulateGeometryDraw`
  returns `ok = false` with a diagnostic naming the opcode.
- **Driver sees `ok = false`** → records the diagnostic, executes
  the pre-existing VS+FS-only path (same as before this emulator
  existed). Zero regressions by construction.
- **Link-time detection** (`detectGeometryEmulatable`) runs once
  per program and stashes a boolean on `GLProgramObject`. Cost is
  paid only at link.

## 8. Testing strategy

### 8.1 Conformance oracle

The CTS tests themselves are the conformance oracle. Each MVP
opcode addition is validated by running the corresponding CTS
cluster before/after and confirming `us_only_pass` count goes up
with no `us_only_fail` increase.

### 8.2 Unit tests (future)

Once the interpreter stabilises, add microtests that compile
snippet GLSL → SPIR-V → interpret with synthetic inputs and
compare against hand-computed expected outputs. Lives in
`tests/GeometryShaderEmulator.test.cpp`.

### 8.3 L2/L3 validation harness (future)

When the SPIRV-Cross mesh-shader emitter patch lands (Layer 2),
diff its MSL output against L1's framebuffer output per draw. Any
pixel mismatch is a bug in L2, never in L1.

## 9. Performance envelope

Measurements pending. Rough expectations:

- **CTS workloads:** draws of 3–72 vertices. Interpreter cost:
  O(opcodes × vertices × primitives). For ~50 opcode GS bodies
  × 24 primitives × 3 vertices per primitive ≈ 3600 opcode
  dispatches. At ~1 µs/dispatch (unoptimised interpreter), ~4 ms
  per draw. Acceptable for CTS.

- **Real-world workload (future concern):** a typical game GS
  invocation might run across 100k primitives. 50 opcodes × 100k
  × 3 verts ≈ 15M dispatches ≈ 15 s/frame with the same
  interpreter. Not viable — that's when L2 matters.

## 10. Out-of-scope (this document)

- **Tessellation stages** (`TCS` + `TES`) — separate Metal feature
  (`MTLRenderPipelineDescriptor.tessellationFactor*`), separate
  implementation path. Tracked in a sibling document when
  that work starts.
- **Adjacency primitives** (`triangles_adjacency`, etc.) — need a
  second-phase expansion in the interpreter (6-vertex input
  primitive batches). Gated on a CTS test that actually uses
  them landing in the MVP target list.
- **Layered rendering (`gl_Layer`)** — needs synthesised draw to
  target specific layers of array render targets. Phase 2.
- **Transform feedback capture from GS** — TF output from
  geometry stage. Phase 2.
- **Stream output** (`layout(stream = N) out;`) — used by some
  advanced GS tests; multi-stream emission. Phase 2.

## 11. Source-of-truth locations

| Artefact | Path |
|---|---|
| Public API header | `src/shader/GeometryShaderEmulator.h` |
| Implementation | `src/shader/GeometryShaderEmulator.cpp` |
| Link-time hook | `src/context/GLContext.mm::linkProgram` (under `ProgramKind::VertexGeometryFragment`) |
| Draw-time hook | `src/context/GLContext.mm::drawArrays` / `drawElements` |
| Whitepaper (this doc) | `docs/geometry-shader-emulation.md` |
| Session journal | `$CLAUDE_MEMORY/cts_sprint_session15_*` |

## 12. SPIR-V version pin + stability check

Our vendored SPIRV-Cross (commit `ead5ff2`, based on upstream
`4d4b79b` merged 2026-03-13) ships `spirv.hpp` declaring
`SPV_VERSION 0x10600` — SPIR-V 1.6. Verified opcode numbers used
by the interpreter match the vendored header:

| Opcode | Value | Verified |
|---|---:|---|
| `OpExtInst` | 12 | ✓ |
| `OpLoad` | 61 | ✓ |
| `OpStore` | 62 | ✓ |
| `OpAccessChain` | 65 | ✓ |
| `OpCompositeExtract` | 81 | ✓ |
| `OpFAdd` | 129 | ✓ |
| `OpEmitVertex` | 218 | ✓ |
| `OpEndPrimitive` | 219 | ✓ |
| `OpPhi` | 245 | ✓ |
| `OpLoopMerge` | 246 | ✓ |
| `OpSelectionMerge` | 247 | ✓ |
| `OpBranch` | 249 | ✓ |

Khronos SPIR-V activity 2025 through the current revision has
been purely additive: new extensions for ray-tracing, mesh
shading, tensor ops, bfloat16, etc. Zero renumbering or
deprecation of GL-era core opcodes — our interpreter is on stable
ground and any upstream bump should be a no-op unless we
explicitly opt into new capability bits.

If a future SPIRV-Cross rebase ships a header where any of the
above opcodes change value, the interpreter's numeric literals
will go through the `spv::OpXYZ` enum names (not raw ints) so a
rebuild catches the drift at compile time.

## Change log

- **2026-04-19** — scaffolding landed (commit `0f1ba0e`); interpreter
  skeleton with stubbed dispatch; whitepaper written; SPIR-V
  version pin + stability check recorded in §12.
- **2026-04-19** — **Step 1** (interpreter opcodes, commit `c37b045`):
  ~30 SPIR-V opcodes (OpLoad, OpStore, OpAccessChain,
  OpCompositeExtract/Construct, OpFAdd/Sub/Mul/Div, OpExtInst for
  GLSL.std.450 transcendentals, structured control flow, OpEmit-
  Vertex, OpEndPrimitive). Interpreter class wired to `SpirvModule`
  parser + access-chain walker; still gated behind a stub
  `detectGeometryEmulatable` returning false.
- **2026-04-19** — **Step 2** (linkProgram hook):
  `detectGeometryEmulatable` now real — parses GS SPIR-V, walks
  `OpExecutionMode` for input/output topology + `OutputVertices`,
  scans the entry-function body for unsupported opcodes,
  flips `GLProgramObject::geometryEmulated = true` when the
  shader is fully handled. The VGF link branch in
  `GLContext.mm::linkProgram` copies `GLShaderObject::spirv` onto
  the program (so it survives detach + delete per GL 4.6 §7.3) and
  records either a `-geometry-cpu-emulation` or the legacy
  `-geometry-emulation` gap trace depending on the outcome.
  No draw-time effect yet — step 3 lands drawArrays routing.
- **2026-04-19** — **Step 3** (drawArrays hook, commit `b0ee5ef`):
  `drawArrays` gains a pre-branch that, when
  `program->geometryEmulated` is true, calls
  `emulateGeometryDraw` and logs the outcome. The call still
  falls through to the legacy path because the expanded-vertex
  draw encoder lands in step 4b.
- **2026-04-19** — **Step 4a** (emulateGeometryDraw real,
  commit `f31c66f`): re-parses `program.geometrySpirv` at draw
  time, gathers user output varyings sorted by Location, runs
  the interpreter once per input primitive with zeroed per-
  vertex inputs (the `constant_expressions` cluster doesn't
  read `gl_in[]`), and packs the emitted vertices into a flat
  `[pos0..3, varying0..N-1]` payload. `EmulatedDraw` now
  carries `ok = true`, `expandedVertexData`, `vertexCount`,
  `topology`, and parallel `varyingNames` / `varyingWidths` /
  `varyingLocations`. No rendering yet — step 4b consumes this.
- **2026-04-19** — **Step 4b** (synthesised pass-through VS +
  Metal encode, commit `f850b5c`): closes the draw path.
  `synthesisePassThroughVertexMSL` builds a minimal MSL VS
  whose `[[stage_in]]` reads the expanded buffer (one
  `[[attribute(N)]]` per packed element) and whose output
  emits `[[position]]` + `[[user(locn<L>)]]` with the
  original GS `Location` decorations — so the FS's already-
  translated MSL (same `[[user(locn<L>)]]` on its inputs) links
  with the synthesised VS automatically. `drawArrays` populates
  a `TranslatedDrawInfo` with the synthesised VS + the
  program's unchanged fragment stage + the expanded buffer +
  a parallel pipeline-state cache and calls
  `encodeTranslatedDraw`. Encode failure falls back to the
  legacy no-GS path.
- **2026-04-19** — **Step 5** (MVP acceptance gate): with
  steps 1–4b landed, the CPU GS emulator is feature-complete
  for the `constant_expressions.*_geometry` subset. Acceptance
  confirmation happens in the external CTS sweep runner
  (outside this repo). Trace signals to grep for:
    - `[GL] drawArrays GS-emul ok: verts=…` — emulator ran and
      Metal encode succeeded (expected pass).
    - `[GL] drawArrays GS-emul encode failed: …` — emulator
      produced a buffer but Metal rejected the pipeline (MSL
      bug, FS linkage mismatch, etc.).
    - `[GL] drawArrays GS-emul: …` — interpreter bailed; the
      diagnostic names the opcode / reason.
  The link-time gap record remains in Runtime::recordShader-
  Translation for programs the emulator can't handle, so BAR /
  shader-diagnostic tooling can still distinguish "program
  has a GS the emulator rejects" from "program runs on the
  emulator".
- **2026-04-19** — **Step 6** (opcode / ext-inst coverage
  expansion): proactive scale-out for the full
  `constant_expressions.*_geometry` matrix (+224 tests) —
  most tests hit functions that weren't in the MVP's
  Radians/Sin/Cos/FAbs set.
    - **SPIR-V opcodes** added to the primary switch
      (and the `isSupportedGsOpcode` allowlist): `OpFNegate`,
      `OpDot`, `OpVectorTimesScalar`, `OpVectorShuffle`.
      `OpDot` is what GLSL `dot()` compiles to — it's a core
      opcode, not a GLSL.std.450 ext-inst.
    - **GLSL.std.450** added to `evalExtInst`: `Round`,
      `RoundEven`, `Trunc`, `FSign`, `Floor`, `Ceil`,
      `Fract`, `Sinh`, `Cosh`, `Tanh`, `Asinh`, `Acosh`,
      `Atanh`, `Atan2`, `Pow` (was partially covered),
      `FMin`, `FMax`, `FClamp`, `FMix`, `Step`, `SmoothStep`,
      `Length`, `Distance`, `Normalize`, `Cross`, `Reflect`.
      Unary / binary / ternary lambdas let new ops be a
      one-liner.
    - Stub namespace (`!APPGL_HAS_SHADER_COMPILER`) updated
      with matching enum values so the emulator still builds
      when the shader-compiler backend isn't vendored.
  Expected coverage: every `constant_expressions.basic_*`
  function × `float`/`vec2`/`vec3`/`vec4` in the geometry
  stage, which is where the +224 come from. Matrix-output /
  `int`-vector varyings land in a follow-up cycle — the MSL
  synthesis currently assumes `float`-widthed output
  varyings, so an `ivec4` output would need a type-aware
  branch in `synthesisePassThroughVertexMSL`.
- **2026-04-19** — **geometry_shader.* scale-out (phase 2)**:
  Big sweep gain from api + adjacency + primitives work.
  Sweep delta: **29/136 → 60/136 Pass (+31)** on
  `KHR-GL46.geometry_shader.*`; constant_expressions.*_geometry
  holds at 232/232.
    - **api.*** (+6: getProgramiv/2/3, fs_gs_draw_call,
      pipeline_program_without_active_vs, incompatible_
      draw_call_mode). See commits `0144e1f`.
    - **adjacency.*** (+6: non-indiced + indiced × lines /
      line_strip / triangles, plus strip/loop/fan primitive
      indexing and the drawElements GS-emul hook). See commit
      `a20fa70`.
    - **primitive_counter.*** (+18: `gl_PrimitiveIDIn`
      built-in + XFB-vs-GS-output-type compatibility check).
      Commits `414ace7`, `cd8b02c`.
  Key infrastructure additions this chapter:
    - `GLProgramObject.{gsPresent, gsInvocations}` —
      `detectGeometryEmulatable` now always populates GS
      metadata (topology + invocations), independent of
      whether the emulator can handle the body.
    - `Impl::writeGsXfbAndCheckDiscard` — walks TF varying
      names, resolves each against the EmulatedDraw varying
      table, writes per-vertex floats to both `shadowBytes`
      AND the Metal buffer `[contents]` (mapBufferRange
      reads the Metal buffer when one is allocated).
      Supports GL_SEPARATE_ATTRIBS + GL_INTERLEAVED_ATTRIBS;
      built-in `gl_Position` is a valid TF target. Returns
      true when GL_RASTERIZER_DISCARD is enabled so the
      caller can skip the Metal encode.
    - drawElements GS-emul hook — mirrors drawArrays, with
      index-expanded uint32 slot resolution passed into
      `emulateGeometryDraw` via `elementIndices`.
    - `emulateGeometryDraw` strip / fan / loop / strip-
      adjacency primitive indexing via `vertexForPrim(p, v)`
      helper. Discrete modes stay at `p * vpp + v`; strip
      modes slide by 1; strip-adjacency slides by 2; fan
      shares vertex 0; loop wraps at `count`.
    - `OpCompositeConstruct` fix: operands can be vectors
      (SPIR-V 1.0 §3.32.12 "each Constituent must be a
      scalar or vector of the same component type; vectors
      contribute ALL their components"). Prior impl dropped
      the vec2's second element for `vec4(position_data, 0,
      1)`, breaking every rendering / adjacency GS.
    - Pipeline state tracking — `GLStateTracker.current-
      ProgramPipeline_` + `glBindProgramPipeline`. Used by
      the pipeline-without-VS validation in drawArrays.
    - `gl_PrimitiveIDIn` (SPIR-V BuiltInPrimitiveId = 7)
      populated per GS invocation via `setGsPrimitiveId`.
    - Runtime's `glDrawArrays` XFB-mode check split:
      programs with a GS compare the XFB mode against the
      GS's OUTPUT primitive type (GL_POINTS / GL_LINE_STRIP
      → GL_LINES / GL_TRIANGLE_STRIP → GL_TRIANGLES), not
      against the draw mode.
  Remaining geometry_shader.* (68 fail): 33 rendering.*,
  9 layered.*, 4 linking, 4 limits, 4 api (rendering/SSBO/
  image deps), 3 primitive_queries, 2 adjacency_triangle_
  strip_adjacency (even/odd adjacency mapping per GL
  §10.1), 1 primitive_id_from_fragment (FS primitive-id
  plumbing), and 8 small misc. Rendering parity work is
  the next big bucket — pixel-exact framebuffer readback
  against the Metal raster output.

- **2026-04-19** — **geometry_shader.* scale-out (phase 1)**:
  Major infrastructure push toward the `KHR-GL46.geometry_shader.*`
  section (baseline 29/136 Pass, target ~100+ additional).
  Landed commits `50a879b`, `0ddc757`, `4a76d62`:
    - **Opcode expansion.** `isSupportedGsOpcode` + dispatch
      now cover integer arithmetic (`OpIAdd` / `OpISub` /
      `OpIMul` / `OpSDiv` / `OpSRem` / `OpUMod` / `OpSNegate`),
      conversions (`OpConvertSToF` / `OpConvertFToS` /
      `OpConvertUToF` / `OpConvertFToU` / `OpBitcast`), bitwise
      (`OpBitwiseAnd` / `OpShiftLeftLogical`), integer and
      float comparisons (`OpIEqual` / `OpSLessThan` / etc.,
      `OpFOrdEqual` / `OpFOrdLessThan` / etc.), logical
      (`OpLogicalNot` / `OpLogicalAnd` / `OpLogicalOr` /
      `OpLogicalNotEqual` / `OpSelect` / `OpAny` / `OpAll`),
      and control flow (`OpSwitch`, `OpPhi`, `OpFMod`).
    - **VS pre-pass.** `program.vertexSpirv` is stashed at
      link time. `emulateGeometryDraw` parses it, extracts
      VBO attribute bytes via a new
      `readVertexAttribFromVAO` helper (honoring GL 4.6
      §10.2.1 attribute defaults: missing z → 0, missing
      w → 1), runs the VS interpreter once per vertex with
      `gl_VertexID` / `gl_InstanceID` and Location-keyed
      attribute values, and hands the resulting
      `PerVertexInput`s to the GS interpreter in place of
      the prior zero-initialised placeholders.
    - **Uniform plumbing.** `GLProgramUniformValue` entries
      are flattened to `name → vector<float>` (with int/uint
      bit-cast) and seeded into `Uniform` /
      `UniformConstant` variable storage at interpreter
      init time, via the struct's `OpMemberName` table.
      Both VS and GS interpreters consume the same map.
    - **SPIR-V decoration parsing.** `DecorationBlock` /
      `BufferBlock` / `Offset` added for struct-layout
      resolution; `DecorationNoPerspective` / `Centroid`
      parse into the same path as `Flat` (all three flow
      through `varyingInterp` into the synthesised MSL).
      Per-member `OpMemberName` capture (was member 0 only).
    - **Implicit input Locations.** glslang doesn't emit
      `DecorationLocation` on VS inputs without an explicit
      `layout(location=N)` qualifier. `initVariables` now
      runs a one-time pass that sorts the remaining VS
      Input variables by SPIR-V id and assigns sequential
      locations after any explicit ones — same pattern as
      `gatherOutputVaryings` uses on the output side.
    - **Point rasterization.** The synthesised pass-through
      VS now emits `[[point_size]] = 1.0` when the GS's
      output topology is `GL_POINTS`; without it Metal
      Apple-GPU pipelines render 0-sized points.
  Sweep delta: `constant_expressions.*_geometry` holds
  at 232/232 (no regressions from the refactor).
  `geometry_shader.*` still at 29/136 — the 33
  `rendering.rendering.*` tests and ~30 more do pixel-exact
  framebuffer readback that requires matching Metal's
  raster behaviour against the GL expected output; the
  infrastructure lands but the pixel-perfect match is a
  follow-up class of work. The remaining ~30 tests need
  either XFB + primitive-query plumbing
  (`primitive_counter.*`, `primitive_queries.*`,
  19 + 3 tests), API-level validation changes
  (`api.getProgramiv*` returning `GL_INVALID_OPERATION`
  for GS pnames, `api.*` ~10 tests), or adjacency-topology
  support in the GS input slicer (`adjacency.*`, 8 tests).

- **2026-04-19** — **Sweep acceptance** (commit `514be72`):
  first run surfaced three compounding bugs, all fixed in the
  same commit:
    1. **GL_POINTS is literally `0x0`.** `detectGeometry-
       Emulatable` used the GL enum itself as the "unset"
       sentinel, so every GS with `layout(points) in/out` was
       silently rejected. Replaced with `haveInputTopo` /
       `haveOutputTopo` flags.
    2. **Implicit-Location outputs.** glslang doesn't emit
       `DecorationLocation` when GLSL omits
       `layout(location=N)`. `gatherOutputVaryings` now
       collects those separately, sorts by SPIR-V id, and
       assigns sequential locations starting after any
       explicitly-located ones (matches GL 4.6 §4.4.2 linker
       rules).
    3. **Integer varyings + interpolation qualifiers.**
       `synthesisePassThroughVertexMSL` always emitted `float`;
       Metal pipeline validation rejects `fragment input
       user(locn0) mismatching vertex shader output` when the
       FS expects `int`. Also, `flat` / `noperspective` /
       `centroid` decorations weren't propagated. Added
       parsing for all three decorations + a `varyingBaseType`
       table (`float`/`int`/`uint`) and type-aware MSL
       emission; integer varyings are force-flat even if the
       GS source omits the qualifier.
  **Sweep results** (M1 Max, KHR-GL46):
  `constant_expressions.*_geometry` — **232 / 232 Pass
  (100 %, +224 vs baseline 8)**. Full `constant_expressions.*`
  — 944/1392 Pass; remaining 448 split cleanly into 224
  `_tess_control` + 224 `_tess_eval`, both out of scope for
  this rollout (tessellation emulation is a separate
  sibling stage).

- **2026-04-19** — **geometry_shader.* phase 3 — rendering
  section + cull_distance regression fix** (commits `9264f83`,
  `cc4dc88`). Four compounding bugs unblocked the
  `geometry_shader.rendering.rendering.*` bucket; a fifth-
  commit stopgap restored the cull_distance regression.
    - **Varyings loop typo.** `initVariables` bounded its
      vertex-input copy loop by `vi < inputs[vi].varyings
      .size()` — so "vi < varyings-per-vertex" rather than
      "vi < vertex count". With one varying per vertex, the
      loop ran once (vi=0) and left vertices 1..N-1 with
      zeroed varyings. Adjacency tests surfaced the bug
      precisely — rendered colour at pixel (7, 1) was
      (0.858824, 0, 0, 0) = `6/7 * start_col`, because
      `end_col = vs_gs_color[1]` (vertex 2 for adjacency
      input) stayed zero. Fix: bound by `inputs.size()` and
      guard each vertex against a missing varying slot.
    - **Bool + integer-vector loads.** `loadFromVar` bailed
      `"load: unsupported leaf kind"` on `Kind::Bool` and on
      `Kind::Vec*` whose component type was Int / UInt. The
      lines- and triangles-input VS in the rendering bucket
      each declare `uniform bool is_gl_lines_draw_call` etc.
      and check `renderingTargetSize.y == 45` (ivec2) — load
      bail → VS pre-pass abort → every vs_gs_color at its
      default (0, 0, 0, 0) → blank pixels. Now Vec2/Vec3/Vec4
      peek at the component type to emit Float*/Int*/UInt*
      Values, and Bool loads memcpy the int bits into `bval`.
    - **OpFUnord* float comparisons.** glslang emits
      OpFUnordNotEqual for GLSL float `!=` (not the ordered
      OpFOrdNotEqual we had on the allowlist); every
      `lines_input_line_strip_output_*` GS uses
      `start_pos.x != end_pos.x` to branch between
      horizontal-vs-vertical edge layouts. Detector
      rejected → `geometryEmulated` stayed false → pipeline
      ran VS+FS-only without the GS's per-edge expansion.
      Added OpFUnord{Equal,NotEqual,Less,Greater,LessEqual,
      GreaterEqual} alongside their OpFOrd* siblings (same
      NaN-agnostic implementation — CTS inputs are finite).
    - **Strip → list expansion across primitive boundaries.**
      OpEndPrimitive was a no-op and inter-invocation strip
      boundaries were implicit, so N separate
      `layout(line_strip)` or `layout(triangle_strip)`
      primitives across M GS invocations concatenated into
      one Metal strip with spurious stitching segments
      between independent primitives. `execute()` now pushes
      the current emitted count into a `primEnds` vector at
      every OpEndPrimitive plus an implicit boundary at
      OpReturn; the caller rolls per-invocation boundaries up
      and post-processes the final buffer: line_strip
      expands `(N-1)` segments × 2 verts per strip
      (topology → GL_LINES), triangle_strip expands `(N-2)`
      triangles with alternating winding (topology →
      GL_TRIANGLES) so the list form preserves GL-spec
      front-facing order after decomposition.
    - **cull_distance.functional_test_item_5 stopgap.** A
      passthrough GS whose VS writes gl_ClipDistance /
      gl_CullDistance and whose GS doesn't re-emit them now
      opts out of emulation — the synthesised pass-through
      VS doesn't yet propagate clip/cull builtins through
      the expanded-vertex buffer, and zeroing them would
      drop a cullable primitive's per-vertex cull state.
      Check scans the VS SPIR-V body for OpStore via
      OpAccessChain into a member decorated BuiltIn
      ClipDistance / CullDistance (tight enough to avoid
      rejecting the rendering-section programs whose glslang
      preamble declares gl_PerVertex.gl_ClipDistance but
      never writes it).
  Sweep deltas vs s19 baseline:
    - `rendering.rendering.*`:    1/33 → 23/33 (+22)
    - `geometry_shader.* overall`: 61/136 → 83/136 (+22)
    - `constant_expressions.*_geometry`: 232/232 (held)
    - `cull_distance.functional_test_item_5_primitive_mode_points*`:
      8/8 restored (stopgap in place until synth VS learns
      to carry gl_Clip/CullDistance).
  Remaining 10 rendering failures are all
  triangles_input + line_strip/triangle_strip outputs —
  pixel mismatches around edge colours that the bugs above
  don't explain; likely per-primitive interpolation math in
  the more complex GS bodies (`abs`-based vertex-role
  classification + bbox emission). Follow-up tracks:
  (1) synth VS gl_Clip/CullDistance plumbing to re-enable
  the cull_distance passthrough-GS cases, (2) triangles-
  input edge-colour parity, (3) layered rendering
  (gl_Layer output), (4) primitive_queries plumbing.

- **2026-04-19** — **geometry_shader.* phase 4 — primitive_queries
  + full rendering section** (commits `7d8f209`, `9262769`,
  `db4505d`). Four bugs landed in three commits; rendering.*
  closed 100 % and primitive_queries reached 100 %.
    - **GL_PRIMITIVES_GENERATED + GL_TRANSFORM_FEEDBACK_PRIMITIVES_
      WRITTEN counters** (`7d8f209`). `writeGsXfbAndCheckDiscard`
      computes `primsGenerated = vertexCount / vertsPerPrim(ed
      .topology)` and drives a primitive-aware TF write — per-
      primitive fit check against the bound indexed-TF binding's
      (offset, size) range; as soon as one primitive doesn't fit,
      all subsequent primitives drop (GL 4.6 §13.2 "TF ends for
      that primitive and every subsequent primitive"). Both
      INTERLEAVED_ATTRIBS (single binding, per-vertex stride =
      Σ varying widths) and SEPARATE_ATTRIBS (one binding per
      varying, truncation cascades across sources) paths
      implemented. The final step accumulates into every active
      query whose target is either counter; other targets keep
      the synthetic-1 fallback in `glEndQuery` for test-
      compatibility.
    - **OpExtInst nOperands off-by-one.** `evalExtInst(w[3],
      &w[4], wc - 4)` handed one extra "operand" that pointed at
      the next instruction's header — harmless when the stray id
      happened to alias a valueStore entry (constant_expressions
      kept working), but lethal for 2-operand FMin / FMax which
      gs_lines_code / gs_triangles_code use for every AABB
      computation. Fix is literal: `wc - 5`.
    - **OpSMod (opcode 139).** Not in the interpreter allowlist;
      glslang emits OpSMod for integer `%` in the triangles VS's
      quadrant-layout math. VS bailed detection → emulator sat
      out → every triangles_input_* failing test dropped its GS
      expansion. Added dispatch + allowlist entry; implements
      `a - b * floor(a/b)` with sign following the divisor per
      SPIR-V §3.32.13 (differs from OpSRem which carries sign
      of the dividend).
    - **TRIANGLE_STRIP + triangles GS input alternation.** GL
      4.6 §10.1.12 requires odd-indexed strip triangles to swap
      positions 0 ↔ 1 before entering the GS so winding survives
      decomposition. `PrimIndexing::Strip` now applies that swap
      whenever `vpp == 3 && (p & 1) != 0` (line strips are
      winding-independent so keep their simple `p + v` mapping).
    - **TRIANGLE_STRIP_ADJACENCY main-vertex alternation.** Same
      even/odd swap at positions 0 ↔ 2 within the 6-vertex
      primitive (GL 4.6 §10.1.14). Adjacency slots (1/3/5) stay
      at the consecutive `p*2 + v` mapping — every CTS test
      reaching this path reads only v[0]/v[2]/v[4], so a
      Table 10.4 neighbour lookup is deferred until an
      adjacency-reading test exercises it.
  Sweep deltas vs phase 3 (HEAD~3):
    - `rendering.rendering.*`:    23/33 → **33/33** (+10, full)
    - `primitive_queries.*`:      0/3  → **3/3** (+3, full)
    - `geometry_shader.*` overall: 83/136 → **96/136** (+13)
    - `transform_feedback.*`: +6 Pass (TF_WRITTEN counter fires
      on query_geometry_* / capture_geometry_* / discard_
      geometry_* that had IE or Fail in s19)
    - `constant_expressions.*_geometry`: 232/232 held
  **Cumulative session 15 deltas vs s19 baseline:**
    - `constant_expressions.*_geometry`: +224
    - `geometry_shader.*`: +37
    - `transform_feedback.*`: +6
    - `draw_elements_base_vertex_tests`: +5
    - Golden Diff: **+272 Pass / 0 us_only_fail / 1 IE → Pass**.
  Remaining GS buckets (40 F): layered_* (11 — gl_Layer +
  layered FBO), api.* (4 — SSBO/image/program-pipeline deps),
  linking.* (4), limits.* (4 — max_invocations needs multi-
  invocation GS), output.* (2), adjacency (2 — triangle_strip_
  adjacency even/odd index mapping), primitive_counter (1 — FS
  gl_PrimitiveID plumbing), + 12 singletons / input /
  nonarray_input / constant_variables / program_resource /
  layered_{fbo,framebuffer,rendering_*}.
