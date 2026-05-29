#ifndef APPGL_SHADER_GEOMETRY_SHADER_EMULATOR_H
#define APPGL_SHADER_GEOMETRY_SHADER_EMULATOR_H

#include "ShaderInterpreter.h"  // appgl::interp::UniformBufferMap (BONUS-2)

// Geometry-shader CPU emulator.
//
// Metal has no geometry-shader stage. For CTS conformance — starting with
// the KHR-GL46.constant_expressions.*_geometry cluster (224 F) — we
// emulate GS on the CPU:
//   1. VAO attribute data copied from VBO shadow buffers.
//   2. VS body interpreted on CPU per vertex, producing per-vertex
//      outputs (gl_Position + user varyings).
//   3. VS outputs grouped into primitives per the GS input topology.
//   4. GS body interpreted on CPU per primitive. EmitVertex appends
//      snapshot of current output state to an expanded-vertex buffer;
//      EndPrimitive writes a primitive-restart marker.
//   5. Expanded buffer uploaded to a Metal buffer; a synthetic pass-
//      through VS + the program's original FS draw the expanded
//      primitives on GPU.
//
// The interpreter handles a narrow subset of SPIR-V — enough for the
// constant_expressions.*_geometry tests — and fails loudly (with
// opcode names in the log) on anything else so the unsupported-opcode
// list is easy to extend.
//
// This path is CPU-bound; acceptable for CTS (tiny geometry) but not
// for production rendering. The plan is to use this as ground-truth
// for a future GPU emulation path (SPIRV-Cross mesh-shader emitter
// patch or Apple-converter chain).

#include <array>
#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <unordered_set>
#include <vector>

typedef unsigned int GLenum;
typedef int GLsizei;
typedef int GLint;
typedef unsigned int GLuint;

namespace appgl {

struct GLProgramObject;
struct GLVertexArrayObject;
struct GLObjectStore;
class GLStateTracker;

// One interpreted vertex output: gl_Position + concatenated user
// varyings, stored as a flat float32 payload. Layout is described by
// the companion `VaryingLayout`. `clipDistance` / `cullDistance`
// capture the gl_ClipDistance[] / gl_CullDistance[] arrays at the
// moment of OpEmitVertex so the synth pass-through VS can emit them
// as `[[clip_distance]]` outputs and Metal performs per-vertex
// clipping / culling the same way the legacy no-GS pipeline would.
// Sized dynamically — empty when the GS writes neither.
struct EmulatedVertex {
    float position[4] = {0, 0, 0, 1};
    std::vector<float> varyings;       // concatenated user varying values
    std::vector<double> doubleVaryings; // precise values for double TF writes
    std::vector<float> clipDistance;   // gl_ClipDistance[] at EmitVertex
    std::vector<float> cullDistance;   // gl_CullDistance[] at EmitVertex
    // gl_Layer value at EmitVertex (GL 4.6 §11.2.1 /
    // BuiltInLayer). Routed through the synth pass-through VS as
    // `[[render_target_array_index]]` to send each primitive to the
    // correct layer of a layered framebuffer attachment. The GS sets
    // gl_Layer per-vertex; per spec the value from the provoking
    // vertex is used for the whole primitive, but the per-vertex
    // snapshot lets us pick the right one on the MSL side.
    std::int32_t layer = 0;
    // Sprint 15 Day 10 [metal-viewport-array]: gl_ViewportIndex
    // value at EmitVertex (sister to `layer`). Captured by interpreter
    // when the GS writes BuiltInViewportIndex; routed through the
    // synth pass-through VS as `[[viewport_array_index]]` (gated on
    // routeViewportIndex && APPGL_ENABLE_METAL_VIEWPORT_INDEX env).
    // Day 9 surfaced a provoking-vertex-convention regression on
    // viewport_array.provoking_vertex when emission was unconditional;
    // Day 10 reintroduces the sister-pattern as opt-in groundwork
    // pending Day 11+ deeper Metal-API diagnosis.
    std::int32_t viewportIndex = 0;
    // gl_PointSize value at EmitVertex (BuiltInPointSize). Routed
    // through the synth pass-through VS as `[[point_size]]` on
    // GL_POINTS output topologies. Default 1.0 matches the value
    // the synth VS emitted before per-vertex capture landed —
    // preserves behaviour when the GS doesn't write gl_PointSize.
    float pointSize = 1.0f;
    // gl_PrimitiveID value written by the GS (OUTPUT side — not the
    // per-invocation INPUT gl_PrimitiveIDIn). Routed through the
    // synth VS as a flat `int` user varying that a post-processed
    // FS reads instead of Metal's rasteriser-provided
    // `[[primitive_id]]`. Default 0; only used when ed.hasPrimitiveID
    // is set (i.e. the GS source stores to gl_PrimitiveID anywhere).
    std::int32_t primitiveId = 0;
    // Sprint 8 #9-C (CKPT95) — vertex-stream tag. Default 0 preserves
    // single-stream behaviour (every OpEmitVertex == stream 0). Set by
    // OpEmitStreamVertex(N) so downstream TF write paths can filter
    // per-stream and update GLTransformFeedbackObject::
    // capturedVertexCount[stream]. Per GL 4.6 §11.3.4 only stream-0
    // vertices feed the rasterizer; streams 1..3 are TF-only.
    std::uint32_t stream = 0;
};

// CKPT162 (Sprint 14 Day 9): captured imageStore() write from the GS
// interpreter, deferred for sync-back to the bound Metal texture after
// GS execution completes. The interpreter cannot write directly because
// the storageImages_ map is const; instead it appends a record per
// `imageStore` call, and the runtime walks these and applies them via
// `replaceRegion:` on the bound MTLTexture. internalFormat drives the
// per-channel byte layout; coord packs (x, y, z/layer) for the texel
// position; value packs up to 4×u32 channels (covers the formats the
// CPU shadow already handles: GL_RGBA32{I,UI,F}, GL_R32{I,UI,F}, etc.).
struct PendingImageWrite {
    std::uint32_t arrayVarId = 0;
    std::uint32_t elementIdx = 0;
    std::uint32_t imageUnit = 0xFFFFFFFFu;
    std::uint32_t stage = 0;
    std::int32_t coord[3] = {0, 0, 0};
    std::uint32_t value[4] = {0, 0, 0, 0};
    std::uint32_t internalFormat = 0;
    bool valueIsFloat = false;
};

// Post-GS output topology + vertex buffer ready for GPU raster.
struct EmulatedDraw {
    GLenum topology = 0;              // one of GL_POINTS / GL_LINE_STRIP / GL_TRIANGLE_STRIP
    // Interleaved per-vertex payload: [pos0..pos3, varying0..N-1] per vertex.
    std::vector<float> expandedVertexData;
    // Same logical layout as expandedVertexData, used only when TF writes
    // 8-byte floating scalars and the interpreter has a precise double.
    std::vector<double> expandedVertexDoubleData;
    std::size_t vertexCount = 0;
    std::size_t floatsPerVertex = 0;   // 4 (position) + sum of varying widths
    // Per-output-varying widths (float count), in the order they appear
    // in the payload after the 4-wide position.
    std::vector<std::uint32_t> varyingWidths;
    // Varying names, parallel to varyingWidths. Used to synthesise the
    // pass-through VS and to map to the FS's input varyings by name.
    std::vector<std::string> varyingNames;
    // Per-varying SPIR-V Location decoration, parallel to varying-
    // Widths. The pass-through VS emits `[[user(locn<N>)]]` with these
    // values so the FS reads the varying at its original layout
    // qualifier — the FS MSL was translated against that location and
    // expects it to match.
    std::vector<std::uint32_t> varyingLocations;
    // Interpolation qualifier (per-varying). 0=smooth (default), 1=flat,
    // 2=noperspective, 3=centroid. Metal requires VS output qualifiers
    // to match FS input qualifiers or the pipeline-state validator
    // rejects the build — integer varyings must always be flat, and
    // any `flat out float` in the GS GLSL also needs the matching tag
    // on the synthesised VS output.
    std::vector<std::uint8_t> varyingInterp;
    // Scalar base type (per-varying): 0=float, 1=int, 2=uint. Width
    // combines with this to give the final MSL type (`float3`, `int2`,
    // etc.). CTS `array_*_geometry` tests surface integer outputs —
    // `flat out int geom_out_out0;` — that fail Metal pipeline-state
    // validation if the synthesised VS emits `float` on them.
    std::vector<std::uint8_t> varyingBaseType;
    // Scalar byte size (per-varying). Most varyings are 4-byte float/int
    // lanes; double-precision TF captures need 8-byte writes even though
    // the CPU interpreter stores their arithmetic value in float lanes.
    std::vector<std::uint8_t> varyingScalarByteSize;
    // Expanded raster-stage slots for the synthetic pass-through VS.
    // `varyingWidths` remains the flat logical payload used by the CPU
    // interpreter and transform feedback; arrays and matrices can occupy
    // multiple GL user locations, so rasterization needs this per-location
    // view to match SPIRV-Cross's fragment `main0_in` layout.
    std::vector<std::uint32_t> varyingStageSlotWidths;
    std::vector<std::uint32_t> varyingStageSlotLocations;
    std::vector<std::uint8_t> varyingStageSlotInterp;
    std::vector<std::uint8_t> varyingStageSlotBaseType;
    std::vector<std::uint8_t> varyingStageSlotScalarByteSize;
    // gl_ClipDistance / gl_CullDistance array sizes captured on the
    // last EmitVertex. Per GL 4.6 §7.1 these are per-vertex float
    // arrays with implementation-defined max length (we advertise 8).
    // When non-zero, the synth pass-through VS emits them as
    // `[[clip_distance]] [N]` outputs so Metal's rasteriser performs
    // the clip/cull stage — an emulated GS that doesn't touch the
    // builtins still propagates them from the VS pre-pass (each
    // emitted vertex is the snapshot of the GS interpreter's
    // current clip/cull state, which defaults to the input vertex's
    // values when the GS declares an `out gl_PerVertex { ... }`
    // passthrough). Both arrays share a single Metal
    // `[[clip_distance]] float[N]` slot; total N = clipDistanceLen +
    // cullDistanceLen with cull coming after clip.
    std::uint32_t clipDistanceLen = 0;
    std::uint32_t cullDistanceLen = 0;
    // True if any emitted vertex wrote gl_Layer. The synth pass-
    // through VS only emits the `[[render_target_array_index]]`
    // slot when this is set — emitting on every GS-emulated draw
    // would force Metal to treat every FBO as layered, which it
    // isn't. When false, the packed buffer omits the layer slot
    // entirely so existing (non-layered) pipelines remain binary-
    // compatible. When true, each vertex in expandedVertexData
    // carries an `int32` layer value appended after clip/cull.
    bool hasLayer = false;
    // Sprint 17 Day 1 (CKPT236) [Probe A 2DMSArray clamp]: maximum
    // gl_Layer value emitted by any vertex when hasLayer == true.
    // Consumed by `MetalFrameGraph::encodeTranslatedDraw` to clamp
    // `pass.renderTargetArrayLength` for `MTLTextureType2DMultisampleArray`
    // colour attachments — Apple Silicon's AGX driver asserts
    // `slice < getNumSlices()` when rTAL is set to the texture's
    // full arrayLength on MS-array layered draws (Codex Sprint 17
    // Day 1 forensics, h2DM-3 verdict; Clerk-validated). Setting
    // rTAL to (max+1) instead of arrayLength clears the assertion
    // for the active-layer-span. Zero when hasLayer is false.
    std::uint32_t maxEmittedLayer = 0;
    // Sprint 15 Day 10 [metal-viewport-array]: True if any emitted
    // vertex wrote gl_ViewportIndex. Sister to `hasLayer`. Synth VS
    // emits `[[viewport_array_index]]` only when this is true AND
    // routeViewportIndex (encoder bound multi-viewport) AND env-gate
    // `APPGL_ENABLE_METAL_VIEWPORT_INDEX` is set. Default-off keeps
    // baseline behavior (no regression on viewport_array.provoking_
    // vertex per CKPT181 finding).
    bool hasViewportIndex = false;
    // True when the GS wrote gl_PointSize on any primitive. Drives
    // whether the packed buffer carries a per-vertex point-size
    // slot + whether the synth VS emits `[[point_size]]` with that
    // value vs. its old hardcoded 1.0. Only relevant for GL_POINTS
    // output topology; other topologies have Metal-rejected
    // `[[point_size]]` slots so we gate the emission accordingly.
    bool hasPointSize = false;
    // True when the GS wrote gl_PrimitiveID on any emitted vertex.
    // Flips on the `[[user(locnK), flat]] int` output on the synth
    // VS and instructs the FS MSL post-processor to redirect
    // `gl_PrimitiveID` reads to that varying. When false, the FS
    // keeps Metal's rasteriser-generated `[[primitive_id]]` (= the
    // index of the current primitive in the expanded draw), which
    // is the right behaviour when the GS doesn't override it.
    bool hasPrimitiveID = false;
    // Location of the synth-VS `int vsout_prim_id` output varying
    // when hasPrimitiveID is set. Matched by the post-processed
    // FS's `int gs_prim_id [[user(locnN), flat]]` input. Computed
    // as `max(varyingLocations) + 1` so it doesn't collide with
    // the GS's regular user varyings (which flow through the FS
    // unchanged at their SPIR-V Location). Zero when hasPrimitiveID
    // is false.
    std::uint32_t primitiveIDLocation = 0;
    // True if emulation succeeded. False leaves expandedVertexData empty
    // and the caller should fall back to the existing no-GS path.
    bool ok = false;
    // Diagnostic: populated on failure with the reason (e.g. missing
    // opcode). Kept for surfacing in debug builds.
    std::string diagnostic;
    // Sprint 8 #9-C (CKPT95) — per-stream emitted-vertex counts (post-
    // expansion totals). Indexed by stream 0..3 (gl_MaxTransformFeedback-
    // Streams floor). For single-stream GS programs (no
    // OpEmitStreamVertex(N>0)) only [0] is non-zero. writeGsXfb-
    // AndCheckDiscard accumulates these into
    // GLTransformFeedbackObject::capturedVertexCount[stream] so
    // glDrawTransformFeedbackStreamInstanced(stream=N) reads the right
    // per-stream count. Day 24 (CKPT96) also uses this to filter TF
    // writes per-stream BO.
    std::array<std::size_t, 4> streamVertexCounts{};
    // Per-vertex stream tag, parallel to expandedVertexData (one entry
    // per vertex of expandedVertexData). Day 24 (CKPT96) uses this to
    // route per-vertex TF writes to the correct per-stream BO.
    std::vector<std::uint32_t> vertexStreams;
    // Sprint 8 #9-C (CKPT96) — per-output-varying stream tag, parallel
    // to varyingNames / varyingWidths / varyingLocations. Captured from
    // SPIR-V DecorationStream on the OpVariable (glslang emits this for
    // `layout(stream=N) out`). Default 0 (no decoration → stream 0).
    // writeGsXfbAndCheckDiscard reads this to determine per-buffer
    // stream ownership in the INTERLEAVED_ATTRIBS gl_NextBuffer-split
    // path so vertices write only to the buffer whose owner stream
    // matches the vertex's stream tag.
    std::vector<std::uint32_t> varyingStreams;
    // Tessellation-emulator metadata. Populated only by
    // emulateTessellationDraw so shared TF writing can recover
    // per-input-patch semantics after the tessellator has expanded
    // each patch into its output-domain vertex stream.
    std::size_t tessOutputVerticesPerPatch = 0;
    std::size_t tessPatchesPerInstance = 0;
    std::int32_t tessPatchVerticesIn = 0;
    // CKPT162 (Sprint 14 Day 9): captured imageStore() writes from the
    // GS interpreter. Appended by the OpImageWrite handler. The runtime
    // walks this list after GS execution and applies each write to the
    // bound Metal texture for the corresponding image binding via
    // replaceRegion: so subsequent glGetTexImage / pipeline reads see
    // the GS-emitted data. Empty when the GS doesn't use imageStore or
    // emulation runs along the no-image path.
    std::vector<PendingImageWrite> pendingImageWrites;
};

// Detect whether a program's GS stage can be emulated. Called once
// at link time. The decision is stored on the GLProgramObject
// (`program.geometryEmulation.*`) so drawArrays can branch without
// re-parsing the SPIR-V. Also populates the program's GS metadata
// fields (`gsPresent`, `gsInputTopology`, `gsOutputTopology`,
// `gsMaxVertices`, `gsInvocations`) whenever the SPIR-V parses,
// regardless of whether the emulator can handle the body — those
// fields back the `glGetProgramiv(GL_GEOMETRY_*)` queries, which
// have to answer correctly even for programs we can't emulate.
bool detectGeometryEmulatable(GLProgramObject& program);

// Sprint 6 Phase 1 sub-task 3 day 3 (CKPT43): texture-sampling support
// for the shared CPU shader interpreter. Each sampler-array element
// holds CPU-readable texel data + metadata. The interpreter reads
// from this map when handling OpImageSampleImplicitLod /
// OpImageSampleExplicitLod against a sampler-array variable.
//
// Layout note: textures with non-default `bytesPerRow` (e.g. Metal-
// padded readback) must set `bytesPerRow != 0`. For tightly-packed
// layouts, leave `bytesPerRow = 0` and the interpreter computes
// stride = width * texel_bytes.
struct SampledTextureSlot {
    std::vector<std::uint8_t> data;
    std::uint32_t width = 0;
    std::uint32_t height = 0;
    // CKPT160 (Sprint 14 Day 7): depth/layers field for OpImageQuerySize
    // on 3D / 2D_ARRAY / CUBE_MAP_ARRAY / 1D_ARRAY storage images. For
    // 2D/RECT/CUBE/BUFFER targets where the third dimension is meaningless,
    // leave at default (0) — the OpImageQuerySize handler distinguishes
    // 2D-class (returns ivec2) vs 3D-class (returns ivec3) per the SPIR-V
    // result type, so the depth field is only consulted when ivec3 result
    // is requested.
    std::uint32_t depth = 0;
    std::uint32_t bytesPerRow = 0;
    // Byte stride between array/cube layer-faces in data. When zero,
    // readers fall back to bytesPerRow * height.
    std::uint32_t bytesPerImage = 0;
    // Optional mip chain metadata for sampled-texture snapshots. When
    // empty, readers treat data as a single level using width/height.
    std::vector<std::uint32_t> mipOffsets;
    std::vector<std::uint32_t> mipWidths;
    std::vector<std::uint32_t> mipHeights;
    std::vector<std::uint32_t> mipBytesPerRow;
    std::vector<std::uint32_t> mipBytesPerImage;
    std::vector<std::uint32_t> mipLayerFaces;
    // Number of addressable storage-image layer-faces. For cube arrays
    // imageSize() reports cube count in depth, while imageLoad/store
    // coordinates address the six faces per cube via coord.z.
    std::uint32_t layerFaces = 0;
    std::uint32_t internalFormat = 0;
    std::uint32_t samplerType = 0;
    // Storage-image maps fill this with the effective GL image unit.
    // Sampled-texture maps leave it at the sentinel.
    std::uint32_t imageUnit = 0xFFFFFFFFu;
};

// Per-sampler-array: vector of slots, one per element. For non-array
// samplers, a 1-element vector. Empty vector means "sampler not
// bound" — interpreter returns 0 for samples.
using SampledTextureArray = std::vector<SampledTextureSlot>;

// Keyed by the SPIR-V variable ID of the sampler-array OpVariable
// (the UniformConstant variable). Caller resolves
// program.<stage>Reflection.sampledTextures + program.uniforms +
// state texture-unit bindings, reads MTLTexture.contents/getBytes,
// and packs the slots in this map.
using SampledTextureMap = std::unordered_map<std::uint32_t, SampledTextureArray>;

// Helper exposed from GeometryShaderEmulator.cpp so platform-specific
// callers (GLContext.mm) can find sampler variables in a SPIR-V
// module without re-parsing it themselves. Returns the SPIR-V
// variable ID, the OpName-decorated identifier (which may have the
// `_appgl_` prefix from CompatShaderRewrite), and the array element
// count (1 for non-array samplers).
struct SamplerVarInfo {
    std::uint32_t varId = 0;
    std::string name;
    std::uint32_t arrayCount = 1;
};
std::vector<SamplerVarInfo> collectSamplerVarsFromSpirv(
    const std::uint32_t* spirv, std::size_t wordCount);

// Sprint 7 Phase 2 #7 (CKPT59): per-output-varying descriptor for the
// public `discoverVsOutputVaryings` helper. Lets non-GS callers
// (drawArrays VS-only TF capture path) discover VS output names + widths
// + locations without re-parsing SPIR-V themselves.
struct VsOutputVaryingInfo {
    std::string name;
    std::uint32_t width = 0;     // flat scalar count
    std::uint32_t location = 0;
    std::uint8_t baseType = 0;   // 0=float, 1=int, 2=uint
    std::uint8_t scalarByteSize = 4;
};
std::vector<VsOutputVaryingInfo> discoverVsOutputVaryings(
    const std::uint32_t* spirv, std::size_t wordCount);

// Sprint 7 Phase 2 #7 (CKPT59): VS-only TF capture entry point.
// Builds an EmulatedDraw whose `expandedVertexData` mirrors the VS's
// per-vertex outputs (gl_Position + named varyings) packed flat. The
// caller then feeds the result to writeGsXfbAndCheckDiscard for actual
// TF buffer writes — same downstream pipeline as the GS-emul and tess-
// emul paths. Required for separable VS-only programs joined to a
// pipeline whose GS is detached (see CTS
// `KHR-GL46.geometry_shader.api.program_pipeline_vs_gs_capture` pass 2)
// AND for any future native-GL VS-only TF test that doesn't go through
// GS or tess emulation.
EmulatedDraw emulateVsOnlyDrawForTf(
    GLProgramObject& program,
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    const GLStateTracker& state,
    GLenum drawMode,
    GLsizei count,
    GLint first,
    GLsizei instanceCount = 1,
    GLuint baseInstance = 0,
    // Sprint 7 #9 (CKPT65) — drawElements call-site passes a
    // pre-resolved uint32 index array (already type-promoted +
    // offset-resolved). When non-null, the i-th vertex reads VBO slot
    // elementIndices[i] instead of (first + i). drawArrays call-site:
    // pass nullptr (default).
    const std::uint32_t* elementIndices = nullptr,
    const SampledTextureMap* sampledTextures = nullptr,
    const SampledTextureMap* storageImages = nullptr);

// Sprint 20 Decision F Option A Step 0: env-gated aggregate timing
// counters for the VS-only transform-feedback CPU path. These are no-ops
// unless APPGL_DF64_VSTF_TIMING is present in the process environment.
bool vsOnlyTfTimingEnabled();
std::uint64_t vsOnlyTfTimingNowNs();
void recordVsOnlyTfWriteDurationNs(std::uint64_t ns);

// Sprint 17 Day 7+ Bank-Group-H Path B Component A1 helper. Walks the
// VS SPIR-V's Output variable / struct-member decorations and returns
// true iff any output is decorated `BuiltInCullDistance`. Used at link
// time on VS+FS-only programs (`!gsPresent && !hasTessellation`) to set
// `GLProgramObject::needsCullDistancePrepass`. Internally reuses the
// existing `scanClipCullWrites` SPIR-V walk (sister-pattern leverage).
bool vsSpirvWritesCullDistance(const std::uint32_t* spirv, std::size_t wordCount);

// Sprint 17 Day 7+ Bank-Group-H Path B Component C — CPU cull pre-pass
// for VS+FS programs writing gl_CullDistance. Implements GL §14.6.3
// per-primitive cull check by running the VS interpreter per vertex,
// capturing cullDistance, grouping vertices into primitives by topology
// (POINTS / LINES / TRIANGLES / LINE_STRIP / LINE_LOOP / TRIANGLE_STRIP
// / TRIANGLE_FAN), and outputting a list of original-vertex-indices for
// non-culled primitives. Caller issues a Metal indexed draw against a
// transient buffer built from `filteredIndicesOut`. Returns true on
// success; false on VS-pre-pass failure or unknown topology.
bool emulateVsCullPrepass(
    GLProgramObject& program,
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    const GLStateTracker& state,
    GLenum drawMode,
    GLsizei count,
    GLint first,
    const std::uint32_t* elementIndices,
    GLsizei instanceCount,
    GLuint baseInstance,
    std::vector<std::uint32_t>& filteredIndicesOut,
    std::string* diagnostic);

// Emulate a single drawArrays/drawElements call for a program that
// has a GS stage. Returns an `EmulatedDraw` whose `.ok` flag tells
// the caller whether the CPU path produced a usable expanded-vertex
// buffer. On `ok == false`, the caller should record the diagnostic
// and fall back to the VS+FS-only path (same behaviour as before this
// emulator existed).
// drawArrays call-site: pass `elementIndices = nullptr`. The emulator
// reads VBO slot `(first + i)` for the i-th vertex.
// drawElements call-site: pass a pre-resolved uint32 index array
// (already indexOffset-resolved and promoted to uint32 — the caller
// handles GL_UNSIGNED_BYTE / _SHORT promotion, which the runtime
// index-expansion cache already does for Metal). The emulator reads
// VBO slot `elementIndices[i]` for the i-th vertex.
EmulatedDraw emulateGeometryDraw(
    GLProgramObject& program,
    const GLVertexArrayObject& vao,
    GLObjectStore& objects,
    const GLStateTracker& state,
    GLenum drawMode,
    GLsizei count,
    GLint first,
    const std::uint32_t* elementIndices,
    GLsizei instanceCount = 1,
    GLuint baseInstance = 0,
    // Sprint 6 Phase 1 sub-task 3 day 3 (CKPT43): caller-supplied
    // sampler-array texture data for VS+GS texture() in CPU emul.
    // Caller (GLContext.mm) walks SPIR-V + reflection + state, reads
    // MTLTexture bytes, and packs the map. Null → CPU emul samples
    // return zeros. With the map, OpImageSample[Implicit|Explicit]Lod
    // ops resolve to actual texel values.
    const SampledTextureMap* vsSampledTextures = nullptr,
    const SampledTextureMap* gsSampledTextures = nullptr,
    // Sprint 7 Phase 1 #4 (CKPT54): caller-supplied storage-image data
    // for VS+GS imageLoad() in CPU emul. Same SampledTextureMap shape
    // (var_id → vector of texel slots) but bound via the image-unit
    // namespace (glBindImageTexture(unit, tex)) rather than the sampler
    // unit namespace. Null → CPU emul imageLoad returns zeros.
    // OpImageRead opcode resolves through this map.
    const SampledTextureMap* vsStorageImages = nullptr,
    const SampledTextureMap* gsStorageImages = nullptr,
    // Sprint 8 #8 β.3 (CKPT97): tess→GS plumbing. When non-null, the GS
    // emulator skips its VS pre-pass and instead consumes the previous
    // stage's per-vertex output (typically the post-tessellation
    // EmulatedDraw produced by `emulateTessellationDraw`). Each vertex
    // of `priorStageOutput->expandedVertexData` becomes one entry in
    // `allVertexInputs`, with `position` taken from the leading 4 floats
    // and named varyings sliced per `priorStageOutput->varyingNames` /
    // `varyingWidths`. The GS Interpreter is also constructed with
    // those varyingNames as its input-side names, so block-member
    // lookups (`gl_in[0].tc_position` etc.) match the TES-emitted
    // names without requiring a VS pre-pass at all. When this is set,
    // `count` is overridden by `priorStageOutput->vertexCount` and
    // `drawMode` is overridden by the GS input topology (the post-
    // tessellation primitive layout is already resolved into discrete
    // sequential vertices).
    const EmulatedDraw* priorStageOutput = nullptr);

// Run a single VS invocation on CPU for the vertex at `vboSlot`.
// Exposed so the tess-CPU emulator can reuse the same interpreter
// to produce per-patch-vertex outputs (position + named varyings)
// before the TES body walk consumes them.
//
//   vsSpirv / vsWordCount: the VS SPIR-V module bytecode.
//   program: source of default-uniform and block-uniform values.
//   vao: vertex-attribute format + enabled-slot config.
//   objects: shared object store (for VBO shadow lookup).
//   vboSlot: the i-th vertex (0..count-1) within this draw.
//   instanceID: gl_InstanceID value to feed the interpreter.
//   outVaryingNames / outVaryingWidths: list of location-decorated
//     Output varyings we want captured, in parallel — consumers get
//     the flat-scalar payload in `out.varyings` in the same order.
//   outVertex: the returned vertex state. gl_Position lands in
//     `position[0..3]`; flat varyings in `varyings`; clip/cull
//     distances in the respective vectors when the VS writes them.
//
// Returns false on interpreter failure (unsupported opcode, missing
// entry point). The tess-emul caller should fall back to the legacy
// translated path in that case.
bool runVsForVertex(
    const std::uint32_t* vsSpirv,
    std::size_t vsWordCount,
    const GLProgramObject& program,
    const GLVertexArrayObject& vao,
    const GLObjectStore& objects,
    std::size_t vboSlot,
    std::int32_t instanceID,
    const std::vector<std::string>& outVaryingNames,
    const std::vector<std::uint32_t>& outVaryingWidths,
    EmulatedVertex& outVertex,
    std::string* diagnostic = nullptr,
    const SampledTextureMap* sampledTextures = nullptr,
    const SampledTextureMap* storageImages = nullptr,
    // Sprint 17 Day 4+ BONUS-2 [gpu_shader5 array-indexing]: caller-
    // supplied per-binding UBO buffer map for runtime UBO array
    // dynamic-indexing. Built once per draw in the caller (e.g.
    // `emulateVsOnlyDrawForTf`) from `state.indexedBufferBinding(
    // GL_UNIFORM_BUFFER, baseBinding+i)` for each `uniform Block { }
    // arr[N]` declared in the VS. Default nullptr preserves
    // backward-compat (programs without UBO arrays don't need it).
    const appgl::interp::UniformBufferMap* uniformBuffers = nullptr,
    std::vector<PendingImageWrite>* pendingImageWrites = nullptr);

// Run a single TES invocation on CPU for the vertex whose tess-space
// barycentric / parametric coord is `tessCoord`. Exposed so the tess-
// CPU emulator can interpret non-passthrough TES bodies (which the
// static matcher in `matchTessEvalPassthrough` rejects) — the common
// CTS `constant_expressions.*_tess_eval` shape, for example, mixes a
// passthrough `gl_Position = vec4(gl_TessCoord.x, 0, 0, 1)` with SSBO
// side-effect writes through `generateExecBufferIo`.
//
//   tesSpirv / tesWordCount: the TES SPIR-V module bytecode.
//   program: source of default-uniform / block-uniform values (same
//     uniform map the VS path builds).
//   tessCoord: the domain coord for this output vertex. For isolines
//     mode only .x is meaningful; for triangles / quads all three
//     components matter.
//   primitiveID: gl_PrimitiveID for the patch the vertex belongs to
//     (== patch-index-in-draw, per GL 4.6 §11.2.3).
//   outVaryingNames / outVaryingWidths: same parallel-array shape as
//     `runVsForVertex`. Consumers get flat-scalar varying payload.
//   outVertex: gl_Position + varyings + clip/cull distances land
//     here, mirroring `runVsForVertex`.
//
// Returns false on any interpreter bail (unsupported opcode, missing
// entry point). Phase 3f-1: scaffolding only — call sites not yet
// wired. Phase 3f-3+ adds SSBO storage-class plumbing so the side
// effects actually reach the bound GL buffer.
// (Sprint 6 Phase 1 sub-task 3 day 3 — CKPT43 — sampler-texture
// types moved earlier in the file to predate runVsForVertex.)

// Phase 3f-3: SSBO region handed to the interpreter. `ptr` is a host-
// visible pointer into a Metal buffer's contents (MTLResourceStorage-
// ModeShared guarantees CPU visibility on Apple Silicon), `size` is
// the byte size available at that pointer (typically buffer.length -
// bufferBinding.offset). Keyed by the SPIR-V binding number on the
// SSBO's variable DecorationBinding.
// (SampledTextureMap declarations moved up earlier in the header
// to predate runVsForVertex's signature.)
struct TesSsboRegion {
    void* ptr = nullptr;
    std::size_t size = 0;
};
using TesSsboMap = std::unordered_map<std::uint32_t, TesSsboRegion>;

// Phase 3f-12: pre-built uniform map shape the tess emulator's
// runners expect. Matches `Interpreter::UniformValues` defined
// internally — kept as a public typedef so the runner signature
// can accept a pointer without leaking the anonymous-namespace
// type. Each entry is a flattened scalar-per-element float
// vector; the runner bit-casts int/uint/bool as needed via the
// type information in the SpirvModule.
using TesUniformMap = std::unordered_map<std::string, std::vector<float>>;

// Phase 3f-12: build a TesUniformMap from a program's current
// uniform values. Intended to be called ONCE per
// emulateTessellationDraw and the result passed to every
// runTes/TcsForVertex call for that draw, avoiding per-invocation
// rebuild cost. Keyed by uniform variable name; top-level uniforms
// get a direct entry; block members are keyed by member name.
TesUniformMap buildTesUniformMap(const GLProgramObject& program);
TesUniformMap buildTesUniformMapForStage(const GLProgramObject& program,
                                         int stageIndex);

// Phase 3f-14: per-patch varying map shared across the TCS
// invocations for a single patch AND the TES vertices generated
// from that same patch. Shape matches `patch out vec<N>` /
// `patch in vec<N>` / scalar-array interfaces.
//
// Sprint 8 #8 β.2 Day 2 (CKPT70): keyed by the variable NAME
// (OpName on the SPIR-V variable, e.g. "tc_patch_data") rather
// than the SPIR-V Location decoration. data_pass_through-class
// shapes declare `patch out vec4 tc_patch_data;` without
// explicit `layout(location=N)`; glslang emits NO Location
// decoration on these. Cross-stage matching is by name (sister
// to CKPT66/CKPT69 SPIR-V two-regime distinction). Located
// variables also get keyed by name (OpName always present);
// unlocated variables keep working identically.
//
// TCS captures into this map after each invocation's body run —
// last-write-wins per GL 4.6 §11.2.2 (only one TCS invocation
// should write any given per-patch output; if multiple write,
// the spec lets implementations pick). TES seeds its Input
// patch-in variables from this map at initVariables time.
using TesPatchVaryingMap = std::unordered_map<std::string, std::vector<float>>;
using TcsSharedOutputStorage = std::unordered_map<std::uint32_t, std::vector<float>>;

bool runTesForVertex(
    const std::uint32_t* tesSpirv,
    std::size_t tesWordCount,
    const GLProgramObject& program,
    const std::array<float, 3>& tessCoord,
    std::int32_t primitiveID,
    const std::vector<std::string>& outVaryingNames,
    const std::vector<std::uint32_t>& outVaryingWidths,
    const TesSsboMap* ssboMap,
    // Phase 3f-5: per-input-patch-vertex data (the VS pre-pass's
    // EmulatedVertex outputs for this patch). Empty vector means
    // "no gl_in[] plumbing" (phase 3f-2 behaviour). Interpreter
    // populates gl_in[k].gl_Position / gl_ClipDistance /
    // gl_CullDistance when the TES body reads them.
    const std::vector<EmulatedVertex>& patchInputs,
    EmulatedVertex& outVertex,
    // Phase 3f-12: pre-built uniform map. When non-null, the
    // runner uses this instead of rebuilding buildUniformMap
    // internally. Caller should build it once per
    // emulateTessellationDraw via `buildTesUniformMap(program)`
    // and keep it alive across all per-vertex calls.
    const TesUniformMap* precomputedUniforms = nullptr,
    // Phase 3f-14: per-patch varyings captured by the TCS pre-
    // pass for this patch. TES bodies declaring
    // `patch in <type> name;` read the values keyed by Location
    // from this map in their init. Nullptr keeps the legacy
    // behaviour of zero-initialising patch-in variables.
    const TesPatchVaryingMap* patchVaryings = nullptr,
    std::string* diagnostic = nullptr,
    // Sprint 8 #8 β.2 (CKPT69): cross-stage input-varying interface.
    // For TES: these are the TCS-output user-block member names (or
    // VS-output member names when no TCS is present). The interpreter
    // reads `gl_in[k].user_block.member` by looking up the member
    // name in this list. Widths are parallel — one per name. Empty
    // (default) keeps the pre-CKPT69 behaviour of leaving user-block
    // gl_in[] reads unresolved (zeroed).
    const std::vector<std::string>* inVaryingNames = nullptr,
    const std::vector<std::uint32_t>* inVaryingWidths = nullptr,
    // Sprint 16 Day 6 (CKPT215) — Tess OpImage gap. When non-null,
    // the per-vertex TES interpreter receives the same sampled-texture
    // and storage-image maps that VS/GS interpreters already accept
    // (mirror of vsSampledTextures/vsStorageImages on
    // `runVsForVertex` style — see GSE.cpp:5486-5491). Without these
    // wires the interpreter's `sampledTextures_` / `storageImages_`
    // are empty, so a TES body executing `texture(sampler, coord)`
    // (lowers to OpImageSampleExplicitLod) hits the empty-map fallback
    // at GSE.cpp:2845-2853 and silently returns zeros.
    const SampledTextureMap* sampledTextures = nullptr,
    const SampledTextureMap* storageImages = nullptr,
    const appgl::interp::UniformBufferMap* uniformBuffers = nullptr,
    std::vector<PendingImageWrite>* pendingImageWrites = nullptr);

// Run a single TCS invocation on CPU. One invocation per
// (patch, invocationID) where invocationID ∈ [0, layout(vertices=N)).
// Body reads are limited to gl_PrimitiveID / gl_InvocationID /
// gl_PatchVerticesIn (phase 3f-4 scope); any SSBO writes route
// through `ssboMap` into the bound GL buffer (same plumbing as
// runTesForVertex). Phase 3f-8 adds optional tess-level capture via
// `outerLevelsOut` / `innerLevelsOut`: when non-null, after the body
// runs the interpreter reads BuiltInTessLevelOuter / Inner stored
// values into those arrays. Slots the TCS didn't write keep their
// pre-seeded contents, so the caller can initialise them to the
// glPatchParameterfv defaults and let the TCS override.
//
// Returns false on interpreter bail. `outVertex` (phase 3f-10)
// receives the captured gl_out[invocationID] — position, clip/cull
// distances — for stitching into the TES stage's gl_in[] array.
// `patchInputs` (phase 3f-10) is the input patch's VS outputs; if
// non-empty, the TCS's gl_in[] is populated from them so bodies
// like `gl_out[gl_InvocationID].gl_Position = gl_in[…].gl_Position`
// produce real values.
bool runTcsForVertex(
    const std::uint32_t* tcsSpirv,
    std::size_t tcsWordCount,
    const GLProgramObject& program,
    std::int32_t primitiveID,
    std::int32_t invocationID,
    std::int32_t patchVertices,
    const TesSsboMap* ssboMap,
    const std::vector<EmulatedVertex>& patchInputs,
    EmulatedVertex& outVertex,
    float* outerLevelsOut = nullptr,
    float* innerLevelsOut = nullptr,
    // Phase 3f-12: same pre-built uniform map as runTesForVertex.
    const TesUniformMap* precomputedUniforms = nullptr,
    // Phase 3f-14: out-parameter for per-patch varyings. When
    // non-null, after the TCS body runs the runner walks Output
    // variables with DecorationPatch + DecorationLocation and
    // writes their flat-scalar-float storage into this map
    // keyed by Location. Subsequent invocations of the same
    // patch (or future draws targeting the same map) overwrite
    // per-Location. Callers that don't consume patch-out pass
    // nullptr.
    TesPatchVaryingMap* patchVaryingsOut = nullptr,
    std::string* diagnostic = nullptr,
    // Sprint 8 #8 β.2 (CKPT69): TCS cross-stage interface. inVarying*
    // are the VS-output user-block member names that map onto TCS
    // gl_in[].user_block.member; outVarying* are the TCS-output user-
    // block member names captured per-invocation into outVertex's
    // varying payload (and downstream consumed by TES gl_in[] reads
    // and by the synthesised pass-through VS as cross-stage varyings).
    const std::vector<std::string>* inVaryingNames = nullptr,
    const std::vector<std::uint32_t>* inVaryingWidths = nullptr,
    const std::vector<std::string>* outVaryingNames = nullptr,
    const std::vector<std::uint32_t>* outVaryingWidths = nullptr,
    // Sprint 16 Day 6 (CKPT215) — Tess OpImage gap; sister to
    // runTesForVertex's new params. Same maps semantics.
    const SampledTextureMap* sampledTextures = nullptr,
    const SampledTextureMap* storageImages = nullptr,
    const appgl::interp::UniformBufferMap* uniformBuffers = nullptr,
    std::vector<PendingImageWrite>* pendingImageWrites = nullptr,
    TcsSharedOutputStorage* sharedOutputStorage = nullptr);

// Synthesise a pass-through vertex-shader MSL source that reads
// the expanded per-vertex payload (one buffer slot with gl_Position
// + all user varyings packed sequentially) and writes gl_Position
// plus `[[user(locn<N>)]]` outputs at the same locations the
// original GS wrote. Called once per draw after
// `emulateGeometryDraw` succeeds; the resulting MSL is fed into
// the normal translated-draw encoder alongside the program's
// unchanged fragment MSL.
// When `layeredFbo` is true and `draw.hasLayer` is true, the synth
// VS emits `[[render_target_array_index]]` as the final output and
// reads `vsin_layer` from the packed buffer. When either is false,
// the attribute slot is still declared (so the vertex descriptor
// and packed-buffer stride match between the MSL and the encoder),
// but `gl_Layer` isn't wired to the render-target array index —
// non-layered attachments route all writes to slice 0 per
// GL 4.6 §9.4.1.
std::string synthesisePassThroughVertexMSL(const EmulatedDraw& draw,
                                           bool layeredFbo = true,
                                           bool viewportArrayBound = false);

// Post-process the fragment shader MSL that SPIRV-Cross produced
// for a GS-emulated program so it reads the GS-supplied
// gl_PrimitiveID override from a flat user varying instead of
// Metal's rasteriser-provided `[[primitive_id]]`.
//
// The SPIRV-Cross output for an FS that reads `gl_PrimitiveID`
// looks like:
//
//   fragment main0_out main0(uint gl_PrimitiveID [[primitive_id]])
//   {
//       main0_out out = {};
//       ...references to gl_PrimitiveID...
//   }
//
// or, with user varyings present:
//
//   struct main0_in { … };
//   fragment main0_out main0(main0_in in [[stage_in]],
//                            uint gl_PrimitiveID [[primitive_id]])
//   { … }
//
// This helper rewrites the parameter list to drop the
// `[[primitive_id]]` parameter and adds a stage_in field (on an
// existing main0_in, or a synthesised GS-prim-id-only struct)
// whose value is bound to a local `uint gl_PrimitiveID =
// uint(<readback>);` at the start of main0(). The local shadows
// what SPIRV-Cross was otherwise receiving from Metal's
// rasteriser, and the rest of the function body references it
// unchanged.
//
// `primitiveIdLocation` must match the output location picked by
// `synthesisePassThroughVertexMSL` (via
// `draw.primitiveIDLocation`) so the FS input and VS output line
// up — Metal's pipeline validator rejects the link otherwise.
//
// Returns the original `fsMsl` unchanged when either
// `!draw.hasPrimitiveID` or the MSL doesn't contain a
// `[[primitive_id]]` reference.
std::string rewriteFragmentMSLForPrimitiveID(const std::string& fsMsl,
                                              const EmulatedDraw& draw);

// Metal rejects fragment `[[stage_in]]` structs that contain nested
// appgl_df64/appgl_df64xN helper structs because every nested scalar has
// the same leaf field name. The GS-emulation pass-through VS transports
// these values as float/floatN user varyings, then this rewrite rebuilds
// appgl_df64 values at each `in.<field>` use site.
std::string rewriteFragmentMSLForFp64StageIn(const std::string& fsMsl);

// Walk a SPIR-V module's entry-point function body for
// OpAccessChain instructions that reach any Uniform-storage
// variable, and return a set of "stage-referenced uniform names"
// covering:
//   - Plain uniforms (default-block members): the member's GLSL
//     name (e.g. "uni_colors_white").
//   - UBO block members: "BlockName.memberName".
//   - SSBO block members: "BlockName.memberName".
// The returned names match what `glGetProgramResource*` would
// return for GL_UNIFORM / GL_BUFFER_VARIABLE queries. Callers
// narrow the `GL_REFERENCED_BY_<stage>_SHADER` bitmask so
// declared-but-unused uniforms don't get the stage's bit. Used
// by `glGetProgramResourceiv` for the GS side — VS/FS stages
// get the equivalent via SPIRV-Cross `get_active_interface_
// variables()`, but the GS is CPU-emulated and we keep all
// uniform-related reflection at block-level (active) granularity
// only for its own translation path; per-member usage here
// closes the gap for CTS
// `program_resource.program_resource`.
//
// Returns an empty set when the SPIR-V doesn't parse or has no
// function body. Safe no-op on programs without a GS stage.
std::unordered_set<std::string> scanStageReferencedUniforms(
    const std::vector<std::uint32_t>& spirv);

}  // namespace appgl

#endif  // APPGL_SHADER_GEOMETRY_SHADER_EMULATOR_H
