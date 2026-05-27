# DCR-4 Fantastic Submission-Groups Design

Status: design draft for Clerk/Foreman review.

This document is read-only design for re-applying the FANTASTIC F1-F4
surfaces on top of the DCR-3 submission architecture. It does not authorize
implementation. Any source change in the DCR-4 line needs explicit
Clerk/Foreman approval after this design is reviewed.

## Goals

DCR-4 should make the FANTASTIC paths declare their submission shape instead
of carrying local submission behavior. The target architecture has one
submission contract shared by F1-F4:

- command-buffer creation and pressure stay under the bounded-outstanding
  pressure net.
- GPU producer/consumer correctness flows through the generic producer-pending
  write/read funnel.
- transient invalidation, resize, and abandon cases use commit-before-abandon.
- FANTASTIC paths contribute grouped work descriptions, resource sets,
  transient ownership, and fallback boundaries.

Submission groups are the DCR-4 organizing concept. They are not a new queue,
not a second scheduler, and not a hidden wait layer.

## Non-Goals

- Do not flip F2/F3 default policy as part of the design step.
- Do not add a fourth correctness leg unless review identifies an unmodeled
  requirement that cannot compose with the three DCR-3 legs.
- Do not restore approximate fallback behavior for geometry, tessellation, or
  transform-feedback cases that require exact CPU or honest-NS handling.
- Do not patch individual CTS failures before the owning submission surface and
  resource contract are enumerated.

## F1-F4 Submission Surfaces

### F1: Argument Buffer ABI and Mesh-GS Foundation

F1 carries two submission-facing surfaces.

The argument-buffer ABI surface covers compute dispatch and translated graphics
VS/FS binding layouts. It separates set 0 sampled/storage/SSBO bindings from
set 1 UBO bindings, uses compact sampled ids, synthetic storage image ids at
128+, and synthetic SSBO ids at 192+. Submission code must treat argument-buffer
materialization as part of the draw/dispatch group that consumes the resolved
GL binding table. Binding setup may allocate/update Metal sidecar buffers and
retain Metal objects for the command-buffer lease, but it should not submit or
wait by itself.

The F1 mesh-GS foundation surface establishes VS-as-compute, mesh dispatch, and
layer/high-max-vertices eligibility. Submission code must represent the prepass
and render work as one logical draw group with ordered subgroups, transient
buffer ownership, and exact fallback boundaries.

F1 needs from submission:

- a binding subgroup that records resolved sampled, UBO, SSBO, image, and
  atomic buffer read/write sets.
- lease retention for argument buffers, sidecar buffers, reflected layouts, and
  transient mesh buffers.
- no direct wait for writable SSBO/image/atomic bindings; correctness is owned
  by the producer-pending funnel.
- eligibility/fallback decisions recorded before the group emits Metal work.

### F2: Default-Armed Mesh-GS DrawArrays Promotion

F2 promotes exact drawArrays-family geometry shader programs to the hardware
mesh path when the program and draw shape fit the proven scope: non-indexed,
non-adjacent topologies, point/line-strip/triangle-strip geometry output,
layered shapes where exact, sampler/uniform-only resources, bounded
max_vertices, and bounded primitive count.

The submission surface is a multi-stage draw group:

1. optional VS-as-compute/remap prepass writes a transient VS-output buffer.
2. mesh-GS render subgroup reads that transient buffer and writes framebuffer
   attachments.
3. fallback subgroup selects exact CPU GS or honest NS when native mesh is not
   exact.

F2 needs from submission:

- same-queue ordering between prepass and mesh render without CPU wait.
- transient buffer lifetime tied to the command-buffer/ring completion lease.
- FBO writes marked through the producer funnel after successful group emission.
- indexed GS kept out of the hardware mesh group until an exact index-aware
  prepass exists; repeated indices, basevertex, baseinstance, gl_VertexID, and
  drawID cannot be approximated.
- encoder/PSO failure reported as fallback/NS according to the F2 matrix, never
  as stripped VS+FS rendering.

### F3: Hardware Tessellation Entry

F3 keeps CPU-domain tessellation as the default until hardware tessellation is
both exact and performance-gated. The hardware surface has several GPU stages:
TCS/TES translation, tess-factor generation/clamp, domain evaluation, optional
render work, and limited TF/rasterizer-discard interaction.

The submission surface is a tessellation draw group with ordered subgroups for
control/factor/domain/render work. The group owns patch buffers, tess-factor
buffers, domain-output buffers, and any retained pipeline state. If hardware
eligibility fails, the group must choose CPU-domain exact handling or honest NS.

F3 needs from submission:

- resource read/write declaration for FBO, SSBO, image, atomic, TF, and query
  side effects before work is emitted.
- explicit subgroup boundaries for compute-like tess stages and render stages.
- no hidden commit-and-wait to paper over tess buffer visibility; same-queue
  ordering and producer-pending drains must be enough, except for existing
  explicit sync/readback reasons.
- hardware path parked behind the established performance/default gates until
  a rung authorizes a default policy change.
- subgroup failure classification that preserves exact CPU or honest NS.

### F4: B4 Adjacency, Streams, and Transform Feedback

F4 covers the no-native-Metal B4 shapes: adjacency topologies, geometry shader
streams, transform-feedback-active geometry draws, and stream draw/replay
paths. The proven route is CPU GS emulation plus the TF writer; if exact CPU
handling cannot run, the result is honest NS. Approximate legacy translated
fallback is forbidden.

The submission surface combines CPU and GPU work:

- CPU GS expansion may produce temporary vertex/stream data without a command
  buffer.
- raster subgroup draws expanded vertices when rasterization is active.
- transform-feedback capture subgroup writes TF buffers, counters, and query
  state.
- stream replay consumes previously written TF/stream data.

F4 needs from submission:

- CPU-only expansion represented in the parent submission group even when no
  Metal command buffer is emitted for that subgroup.
- TF buffer/counter/query writes marked as producers, so readback, replay,
  lifecycle, and redefinition drain through the generic funnel.
- exact-only guard metadata carried with the group so encode failure cannot fall
  through to legacy approximate rendering.
- clean distinction between no-raster TF capture, raster+TF, and stream replay
  consumers.

## Submission-Groups Concept

A submission group is a logical description of GL work emitted by one public GL
operation or by a tightly coupled internal operation. It is metadata and
ownership passed into the existing submission machinery, not a new command
buffer factory.

Each group should be able to declare:

- group kind, parent id, and ordered subgroup list.
- command-buffer reason(s) for any Metal work it emits.
- submit policy: attach to current frame, pressure-flush eligible,
  commit-current-before-standalone, explicit commit-and-wait, async frame
  commit, or no GPU work.
- GL resource read set and write set.
- transient Metal resources and CPU temporaries retained until completion.
- fallback/NS boundary and whether legacy approximate fallback is disallowed.
- default-framebuffer/objectless side effects when no GL object owns the
  producer bit.

Representative group kinds:

- `ArgumentBindingGroup`
- `MeshGsDrawGroup`
- `MeshGsPrepassGroup`
- `MeshGsRenderGroup`
- `TessDrawGroup`
- `TessControlGroup`
- `TessFactorGroup`
- `TessDomainGroup`
- `CpuGsExpansionGroup`
- `TransformFeedbackCaptureGroup`
- `StreamReplayGroup`

The parent group records the semantic GL operation. Subgroups record ordered
implementation work. Subgroups do not create new synchronization semantics;
they only make the existing command-buffer ordering, resource ownership, and
producer/consumer declarations auditable.

## Structural Integration and No-Stapling

DCR-4 must build the FANTASTIC surfaces into the validated DCR-3 architecture.
The rule is no stapled side waits, no private pressure control, and no
surface-local command-buffer lifecycle.

### Leg 1: Bounded-Outstanding Pressure Net

F1-F4 groups may request command buffers only through the existing submission
factory. They may provide command-buffer reasons and pressure eligibility, but
they do not own allocator backpressure, ring slots, or in-flight limits.

Composition:

- F1 argbuf updates attach to the draw/dispatch command buffer unless a
  pre-existing upload/staging reason requires separate work.
- F2 mesh prepass/render subgroups use ordered work on the normal queue and are
  pressure-visible through the existing factory.
- F3 tess compute/render subgroups use existing command-buffer reasons and keep
  default-off/perf gates separate from pressure policy.
- F4 CPU-only subgroups declare no GPU work; raster/TF subgroups use normal
  command-buffer allocation.

### Leg 2: Producer-Pending Funnel

F1-F4 groups must emit resource write/read sets once at the group boundary.
They do not manually wait on command buffers for coherence.

Composition:

- F1 contributes reads for sampled/UBO buffers and read-only SSBO/image uses,
  and writes for writable SSBO/image/atomic uses.
- F2 contributes transient subgroup dependencies internally and GL-visible FBO
  writes externally.
- F3 contributes FBO, SSBO, image, atomic, TF, and query side effects according
  to the selected hardware/CPU route.
- F4 contributes TF buffer/counter/query writes and stream replay reads.

Internal transient buffers are ordered by the command queue and retained by the
lease. GL-visible resources are marked through the producer funnel.

### Leg 3: Commit-Before-Abandon

F1-F4 groups must not abandon a live current command buffer during transient
invalidation, resize, restore, or lifecycle changes. If a group needs a
standalone command buffer or invalidates current frame state, it must first use
the DCR-3 commit-before-abandon path.

Composition:

- F1 sidecar/argbuf resource replacement cannot discard pending encoder work.
- F2 mesh transient recreation cannot abandon a current draw command buffer.
- F3 tess buffer/pipeline fallback cannot invalidate current work without
  committing it first.
- F4 TF/raster replay state changes cannot drop pending writes before replay or
  readback.

## Per-Rung Plan and Gates

DCR-4 should proceed in small sub-commits. Each rung needs a local design note
or close packet, enumerated P->F/P->NonPass changes, and no crown until
SCOUT-W records the gate-of-record.

### DCR4-A: Inventory and Taxonomy

Map all F1-F4 submission sites to proposed group kinds, command-buffer reasons,
resource read/write sets, fallback boundaries, and transient ownership. This is
expected to be behavior-neutral.

Gates:

- build-only or doc-only verification as applicable.
- focused sentinel runs for existing DCR-3 command-buffer counters if any code
  is touched.
- no runtime behavior change accepted in this rung.

### DCR4-B: F1 Argument Buffer Grouping

Introduce the group declaration around argument-buffer binding materialization
and the mesh-GS foundation resource sets. Keep env/default policy unchanged.

Gates:

- CKPT91 argbuf default-off and argbuf-on coverage.
- SSBO, storage image, shader atomic, and program-interface families.
- renderer preflight.
- per-rung broad sweep if binding/resource-set code changes.

### DCR4-C: F2 Mesh-GS DrawArrays Grouping

Move drawArrays hardware mesh promotion onto parent/subgroup declarations:
prepass, remap, mesh render, transient retention, and exact fallback/NS.

Gates:

- geometry_shader full.
- texture_gather GS residuals.
- transform_feedback guard coverage.
- F2 close matrix preservation with P->F and P->NonPass enumeration.
- SCOUT-W gate-of-record before any default-policy crown.

### DCR4-D: F3 Tessellation Grouping

Represent hardware tessellation stages as ordered subgroups while retaining CPU
domain default behavior unless explicitly authorized later.

Gates:

- tessellation full.
- texture_gather tess residuals.
- TF/rasterizer-discard focused tess cases.
- shader ballot remains honest Hard-NS unless a separate design proves support.
- performance gate before any default flip.

### DCR4-E: F4 B4 Exact CPU/TF Grouping

Represent adjacency, streams, active TF, and stream replay as exact-only B4
groups. Preserve the no-legacy-fallback guard.

Gates:

- geometry_shader adjacency/stream coverage.
- transform_feedback full.
- stream replay and query/counter readback probes.
- explicit encode-failure/no-slip sentinels if the guard is touched.

### DCR4-F: Cross-Surface Composition Audit

Exercise combinations that cross F1-F4 boundaries and DCR-3 legs:
argbuf+mesh, argbuf+tess, TF+replay, lifecycle/delete/redefine after producers,
resize/restore invalidation, and pressure under multi-pass paths.

Gates:

- full conformance sweep by SCOUT-W as gate-of-record.
- DCR-3 sentinel preservation.
- BAR-B style pressure/perf check if command-buffer behavior changes.
- enumerate-don't-patch review for all P->F/P->NonPass deltas.

### DCR4-G: Cleanup Rung

Only after F1-F4 group integration is validated, clean up scaffolding. Convert
env-gated sentinel stubs to compile gates where appropriate and remove any dead
helpers discovered by the DCR-4 work.

Gates:

- build and focused sentinel coverage for removed paths.
- source audit proving removed helpers are unreachable.
- final SCOUT-W close packet.

## Fourth-Leg Check

Initial assessment: F1-F4 do not require a new correctness leg beyond the
DCR-3 architecture. Submission groups are the missing structure for declaring
how multi-stage FANTASTIC work composes with the three existing legs.

The review checklist for every DCR-4 implementation rung is:

- If the need is command-buffer creation, submit cadence, or backpressure, it
  belongs to the bounded-outstanding pressure net.
- If the need is resource visibility, readback, redefinition, lifecycle, or
  replay-after-write, it belongs to the producer-pending funnel.
- If the need is resize, restore, transient invalidation, or abandoning current
  encoder state, it belongs to commit-before-abandon.
- If a need cannot be stated in those terms, stop the rung and open a
  Clerk/Foreman fourth-leg review before implementation continues.

Known watch items that may look like a fourth leg but are not currently one:

- objectless/default-framebuffer producer records need explicit group entries,
  but should still mark/drain through the existing resource or framebuffer
  producer path.
- CPU-only F4 expansion has no command buffer, but its GL-visible outputs are
  TF buffers, query/counter state, or later raster inputs, all of which can be
  represented by group write/read sets.
- synthetic high-in-flight or 48-cap pressure issues remain S23-tracked
  performance/pressure watch items, not DCR-4 correctness blockers.
- env-gated sentinel stubs and dead-helper cleanup belong to the final cleanup
  rung, not the design leg count.

## References

- `docs/dcr3-a/README.md`
- `docs/dcr3-c/generic-producer-pending-flag-design.md`
- `docs/dcr4/dcr4-e-design-note.md`
- `tests/reports/s22-fantastic/FIXED-F1-7129315/FIXED-F1-7129315.meta`
- `tests/reports/s22-fantastic/b1-argbuf-abi/status/summary.txt`
- `tests/reports/s22-fantastic/b2-mesh-gs/status/summary.txt`
- `tests/reports/s22-fantastic/b3-mesh-layered/status/close-meta-166a8e3.txt`
- `tests/reports/s22-fantastic/f2-exit-packet-7129315/F2-EXIT-CLOSE-SHAPE-PACKET.md`
- `tests/reports/s22-fantastic/f2-mesh-gs-drawelements-fallback-map-7129315/F2-MESH-GS-DRAWELEMENTS-FALLBACK-MAP.md`
- `tests/reports/s22-fantastic/f3-hardware-tess-entry-99abb41c/F3-HARDWARE-TESS-PROMOTION-ENTRY-CHECKPOINT.md`
- `tests/reports/s22-fantastic/f4-b4-entry-99abb41c/F4-B4-ENTRY-CHECKPOINT-RQDIR.md`
- `tests/reports/s22-fantastic/f4-b4-close-b4guard/F4-B4-CLOSE-SHAPE-NO-SLIP-RQDIR.md`
