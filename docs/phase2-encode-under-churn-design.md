# Phase 2 Encode-Under-Churn Design

Status: design note; Slice 1 instrumentation is opt-in; behavior-changing
levers remain gated on Foreman + SCOUT-W review.
Date: 2026-05-31

## Objective

The S23 correctness queue is closed. Phase 2 targets the remaining real-app
performance cliff: realistic state churn serializes AppGL's GL-to-Metal encode
path enough that the real-app-pattern benchmark misses the operator's 120 FPS
floor early in the 500-5000 draw range.

Baseline from the d17e298 stock real-app-pattern run:

| Draws | FPS | Frame Time | Gap to 120 FPS |
| ----- | --- | ---------- | -------------- |
| 100 | 103.4 | 9.7 ms | 1.2x |
| 500 | 23.2 | 43.1 ms | 5.2x |
| 2000 | 5.8 | 172 ms | 20.7x |
| 5000 | 2.5 | 400 ms | 48x |
| 20000 | 0.63 | 1587 ms | 190x |

The 120 FPS budget is 8.33 ms/frame. At 500 draws that is 16.7 us total
per draw. At 5000 draws it is 1.7 us total per draw, which is a stretch goal
unless the workload collapses into a hardware-batched path. Phase 2 should
therefore report both:

- the practical low/mid draw-count floor that can hold 120 FPS after the lever;
- the high-draw-count stretch curve and what additional batching or hardware
  routing would be required to reach it.

## Current Attribution

The useful baseline is harness-free real-app-pattern, not the older
BenchInternal `glFinish`-inflated 358 us number.

Current real-app profile shape:

- full cost is about 80-97 us/draw under realistic churn;
- about half is app-workload setup/state churn outside the AppGL wrapper;
- AppGL GL-wrapper cost is about 43.9 us/draw;
- `framegraph_encode` is the dominant AppGL bucket at about 29.5 us/draw;
- inside `framegraph_encode`, `state_resolve` is about 12.55 us and
  `encoder_setup` is about 8.44 us;
- `sampler_producer_drain` is negligible for this path.

Source shape:

- `GLContext::Impl::encodeTranslatedDrawAndMarkFbo` builds a `TranslatedDrawInfo`
  wrapper, declares the submission group, then calls
  `frameGraph->encodeTranslatedDraw`.
- `MetalFrameGraph::Impl::encodeTranslatedDraw` re-derives the pipeline key,
  shader slot metadata, argument-buffer needs, render-pass/encoder state, and
  resource bindings for each draw.
- The existing VAO layout cache (`cachedVertexArrayLayout`) helps stable VAO
  layouts, but the real-app workload intentionally churns state; a last-state
  cache is not enough.

The target is therefore not a single-threaded micro-shave. The target is to
make the encode path flex Apple Silicon resources: use memory for structural
memoization, cores for parallel draw preparation where GL ordering allows it,
and Metal hardware routing to reduce repeated per-draw binding work.

## Design Constraints

- Preserve GL draw order. Do not reorder overlapping draws, blending,
  depth/stencil side effects, transform feedback, image/SSBO writes, queries,
  or readbacks unless a proof says the sequence is order-independent.
- Preserve CPU-visible synchronization. Phase 2 must not hide stale pixels or
  stale buffer contents from `glReadPixels`, `glGetTexImage`,
  `glGetBufferSubData`, mapped reads, or lifecycle edges.
- Do not build a churn-busted last-draw cache. Cache keys must describe stable
  structural state, not the last draw serial.
- Keep caches bounded and invalidated by explicit generations. Perf credit is
  not worth unbounded memory growth or stale resource bindings.
- Maintain a conformance gate of P-to-F equals zero for the selected SCOUT-W
  baseline before claiming the lever.

## Lever A: Structural Draw-Plan Memoization

First implementation candidate.

Build a reusable `TranslatedDrawPlan` for the parts of
`TranslatedDrawInfo`/`encodeTranslatedDraw` that are structural rather than
per-draw values. The plan is keyed by structural state and fills a per-draw
packet with the current dynamic values.

Candidate key fields:

- program object/generation and translated MSL generation;
- VAO object plus `attribGeneration`, or a content hash for layout-equivalent
  VAOs when safe;
- draw mode/topology class, indexed vs arrays, instanced vs non-instanced;
- fixed-function state fingerprint: blend tuple, depth/stencil tuple,
  rasterizer state, clip origin/depth mode, viewport-array shape,
  sample mask/shading, polygon offset, cull/front-face/fill mode;
- framebuffer attachment signature: color/depth/stencil Metal formats,
  sample counts, array/layer shape, attachmentless FBO shape;
- resource layout shape: which samplers, UBOs, SSBOs, images, atomics, and
  push/default uniform blocks the program uses, plus their Metal slots;
- argument-buffer mode and shader slot metadata.

Candidate cached payload:

- pipeline cache key and translated shader slot metadata;
- vertex descriptor / vertex layout binding plan;
- fixed-function binding plan for depth/stencil, cull, winding, fill,
  sample mask, viewport/scissor mode, and polygon offset;
- resource binding plan mapping program reflection entries to GL texture units
  and buffer binding points;
- submission-group read/write classification that does not depend on the
  current object names;
- flags that decide whether the draw can use argument-buffer or future ICB
  paths.

Dynamic values that must remain per draw:

- vertex/index buffer object names, Metal pointers, offsets, counts;
- current uniform bytes and ring offsets;
- actual texture/sampler objects and buffer binding objects;
- viewport/scissor rectangles;
- FBO attachment object pointers;
- producer-token state and pending read/write hazards;
- query/TF/feedback side effects.

Invalidation:

- program relink invalidates all plans for that program;
- VAO attribute mutation invalidates plans keyed by that VAO generation;
- framebuffer attachment mutation invalidates plans keyed by that FBO
  generation;
- texture sampler parameter changes invalidate sampler-state payload only, not
  the whole program reflection plan;
- global fixed-function state changes select a different structural key rather
  than mutating the prior plan.

Expected movement:

- `framegraph_encode` drops first;
- `state_resolve` should drop sharply on recurring churn patterns;
- `encoder_setup` drops only where the plan avoids repeated per-draw encoder
  decisions or allows more redundant state calls to be suppressed.

Review decision: key by VAO identity first for safety, then add optional
layout-content keys after a dedicated equivalence gate. The ADV-3 lesson is
that stable-layout caching is real, but layout-content equivalence needs
instrumentation and proof.

## Lever B: Encoder Binding Plan + Argument Buffers

Second implementation candidate, after Lever A gives a safe structural plan.

The real-app path repeatedly binds per-stage textures, samplers, UBOs, SSBOs,
image bindings, atomics, and default uniform buffers. The code already has
argument-buffer plumbing behind `APPGL_ENABLE_ARGUMENT_BUFFERS`, but it is not
the default safe path.

Use the `TranslatedDrawPlan` to decide when a draw's resource shape is stable
enough to route through a persistent Metal binding layout:

- precompute per-stage argument encoder layouts from the structural plan;
- allocate/update small argument-buffer records for current dynamic resources;
- bind one or two argument buffers instead of many `set*` calls;
- keep direct binding as the fallback for unsupported stages or high-risk
  resource shapes.

Correctness guard:

- argument buffers may replace binding calls only when every shader-visible
  resource in the plan is represented;
- missing resource slots, sampler defaulting, texture view aliases, image
  bindings, SSBO size buffers, and default uniform blocks must have focused
  gates before default-on;
- CPU/GPU hazard tracking remains outside the argument buffer and must still
  decide whether a producer needs ordering or a CPU wait.

Expected movement:

- `encoder_setup` and `binding` buckets drop;
- Metal encoder call count per draw drops;
- Apple Silicon memory bandwidth is used for compact argument records instead
  of CPU-side Objective-C binding churn.

## Lever C: Parallel Draw Preparation

Third implementation candidate. It is useful only after the draw packet shape
is explicit.

Metal render encoders are not a general thread-parallel escape hatch for GL:
GL draw order is observable. The safe first target is CPU-side preparation,
not parallel command emission.

Safe shape:

1. On the GL thread, record an ordered draw packet containing the current GL
   state snapshot, object generations, dynamic resource handles, and side-effect
   flags.
2. In worker tasks, resolve structural plan lookups, uniform packing, resource
   binding records, and validation for packets that do not need immediate GL
   feedback.
3. On the owning GL/Metal encode thread, replay packets to the Metal encoder in
   original order.

Hard stops that keep preparation serial:

- CPU readbacks or queries that require immediate results;
- buffer/texture mapping with CPU-visible effects;
- transform feedback side effects;
- commands that mutate object storage used by already-recorded packets;
- any path without enough generation tracking to prove the packet snapshot is
  still valid.

Future-only shape:

- `MTLParallelRenderCommandEncoder`, multiple command buffers, or ICBs can be
  considered only for provably order-independent draw runs, such as no blend,
  no feedback writes, no image/SSBO writes, compatible depth semantics, and no
  order-dependent queries. General GL cannot assume that.

Expected movement:

- wall-clock frame time drops more than single-draw `framegraph_encode` if the
  workload has enough independent packets;
- per-draw profile buckets may not drop proportionally because work moves to
  worker threads. Reports must include total frame time and CPU utilization,
  not just bucket percentages.

## Lever D: Hardware Batching Routes

Fourth implementation candidate and the likely requirement for the high end of
the 5000-draw range.

When the structural plan detects a long run of compatible draws, AppGL can use
Metal hardware routing instead of issuing one fully-bound draw at a time:

- merge compatible draws into `glMultiDraw*`/MDI-style internal batches when
  GL input already provides independent draw records;
- use indirect argument buffers or ICBs for repeated static draw streams;
- keep per-draw fallback for dynamic state changes, feedback, queries, and
  order-dependent blending/depth cases.

This is not the first patch because it has the largest semantic surface. It is
the path that can plausibly move 5000 draws toward the 120 FPS stretch target.

## Instrumentation Needed

Before the behavior-changing lever lands:

- keep `APPGL_GL_DRAW_PROFILE=1` and `APPGL_DRAW_PROFILE=1` reports comparable
  to the d17e298 baseline;
- add plan-cache counters: lookup, hit, miss, invalidated-by-program,
  invalidated-by-VAO, invalidated-by-FBO, rejected-by-side-effect;
- add resource-route counters: direct binding vs argument-buffer binding,
  set-call counts, argument-buffer bytes updated;
- keep the existing `vaoLayoutCacheHit` field and add explicit plan-cache hit
  status so ADV-3 and Phase 2 are not conflated;
- report worker-thread preparation time separately if Lever C lands.

Do not claim a Phase-2 win from aggregate FPS alone. The component shift must
show which stall moved.

## Implementation Slices

1. Instrumentation-only patch: plan-key prototype and counters, no behavior
   change. Run real-app-pattern to size the hit surface under churn.
2. Structural draw-plan memoization for validation-free payloads only:
   pipeline key, shader slots, vertex layout plan, resource reflection plan.
   Existing direct binding path stays active.
3. Extend memoization to fixed-function encoder decisions and FBO attachment
   signatures. Keep per-draw dynamic resources and hazards live.
4. Argument-buffer route for the subset whose plan proves complete shader
   resource coverage. Default off until focused gates pass, then default-on for
   the proven subset.
5. Parallel draw preparation for snapshot-safe packets. Serial replay remains
   the GL-order-preserving path.
6. Hardware batching for compatible draw runs after real-app evidence shows the
   remaining high-draw-count gap.

Each slice should carry its own before/after profile, not wait for the whole
stack to land.

Slice 1 instrumentation flag:

- `APPGL_PHASE2_PLAN_PROFILE=1` enables candidate plan-key lookup accounting
  in the translated-draw wrapper after submission-group classification.
- `APPGL_PHASE2_PLAN_KEY_PROFILE=1` is accepted as an alias.
- The report prefix is `[APPGL_PHASE2_PLAN_PROFILE]` and emits total draws,
  lookups, hits, misses, rejects, unique key count, hit-rate percentage, and
  per-reject reason counts.
- The hook is measurement-only: every draw still executes the existing direct
  `frameGraph->encodeTranslatedDraw` path.

## Validation Gates

Performance axis:

- GLTest real-app-pattern re-measure against the d17e298 baseline at
  100/500/2000/5000/20000 draws.
- Required report: FPS, frame time, total per-draw cost, AppGL wrapper cost,
  `framegraph_encode`, `state_resolve`, `encoder_setup`, binding cost,
  plan-cache hit rate, and argument-buffer route rate if applicable.
- Report where 120 FPS holds after the lever. If it does not hold at 500 draws,
  the lever is not Phase-2 sufficient.
- For 5000 draws, report the remaining gap and whether it is runtime encode,
  app workload setup, GPU time, or order-dependent draw emission.

Conformance axis:

- SCOUT-W gate of record with P-to-F equals zero for the selected baseline.
- Focused churn cases:
  - VAO layout mutation and VAO rebind with identical layouts;
  - blend/depth/stencil/raster toggles across recurring state patterns;
  - texture/sampler rebinding and sampler parameter mutation;
  - UBO/SSBO/image binding mutation;
  - FBO attachment swaps, MRT, MSAA, layered targets;
  - transform feedback, queries, rasterizer discard, and image/SSBO writes;
  - CPU readback after GPU writes.
- Negative controls where the optimization must not apply:
  - order-dependent blending;
  - depth/stencil side-effect tests;
  - texture or buffer storage redefinition between packet record and replay;
  - resource aliases with pending writes.

## Review Checklist

- Does every cache key name the GL state and object generations that make the
  cached payload valid?
- Is every dynamic value intentionally excluded from the cached payload?
- Can a stale plan survive program relink, VAO mutation, FBO attachment change,
  texture sampler mutation, or buffer storage replacement?
- Does the slice preserve GL draw order and CPU-visible synchronization?
- Does the validation report show component movement, not just FPS movement?
- Is the claimed win resource-flexing Apple Silicon, or merely moving a few
  microseconds inside a serial path?

## Recommended First Patch

Land the instrumentation-only plan-key prototype first. It should compute the
candidate key and record hit/miss/reject counts, but still execute the existing
path. That answers the load-bearing question before behavior changes:

> Under real-app churn, is the state stream structurally repetitive enough for
> draw-plan memoization to pay?

If yes, implement Lever A. If no, go directly to Lever B/D hardware routing,
because the workload is genuinely too unique for memoization to unlock the
120 FPS floor.
