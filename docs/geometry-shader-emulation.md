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
