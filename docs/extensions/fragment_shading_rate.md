# EXT_fragment_shading_rate

Sprint 19 Decision H4 / Item 55 moves EXT_fragment_shading_rate out of Core
into `src/extensions/fragment_shading_rate/`.

Module split:
- `FragmentShadingRateModule` owns capability probing, lifecycle, extension
  string registration, current draw-rate state, combiner validation, and the
  per-context module state record.
- `RasterizationRateMap` owns Metal shading-rate quality mapping,
  `MTLRasterizationRateMap` cache ownership, and render-pass attachment helpers.
- `FragmentShadingRateExtension` owns GL entry-point implementation and routing
  for the base EXT_fragment_shading_rate API.

Current migration checkpoint:
- The module is registered with ExtensionRegistry and preserves the existing
  `GL_EXT_fragment_shading_rate` extension list position.
- Per-context FSR state, typed FSR queries, base EXT entry-point behavior, and
  Metal rasterization-rate-map cache ownership live in this module.
- Core keeps thin runtime/GLContext/MetalFrameGraph routing points so existing
  dispatch, coverage marking, draw snapshots, and render-pass setup can call
  the module hooks without owning extension behavior.

Cross-extension dependency:
- `ShaderTranslator` currently uses a global MSL 2.4 target so the SPIRV-Cross
  fork can emit EXT_fragment_shading_rate builtins (`[[shading_rate]]` and
  `[[primitive_shading_rate]]`).
- Decision H4 keeps that translator policy global for this migration. A
  module-managed translator feature request is a future refinement if another
  extension needs conflicting MSL-version policy.
