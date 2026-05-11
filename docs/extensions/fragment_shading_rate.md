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
- `caa2699` initially advertised base FSR support with a global MSL 2.4
  translator target so the SPIRV-Cross fork could emit
  `[[shading_rate]]` and `[[primitive_shading_rate]]` for
  ShadingRateKHR / PrimitiveShadingRateKHR builtins.
- `fc07399` contained the 422 Cluster B fallout by keeping non-FSR
  geometry-shader replay paths at `GL_SHADING_RATE_1X1_PIXELS_EXT`.
- `f024cc0` finished the current gating model: `ShaderReflection` records
  whether a translated stage uses FSR builtins, `ShaderTranslator` selects
  MSL 2.4 only for SPIR-V resources that expose those builtins, and all other
  shaders remain on the long-held MSL 2.3 target.
- GL draw setup now passes non-1x1 FSR state only when the linked program's
  reflection uses FSR builtins. `MetalFrameGraph` treats
  `GL_SHADING_RATE_1X1_PIXELS_EXT` as a hard no-op, so non-FSR draws do not
  receive rate-map attachment.
- Pattern lesson: cross-extension dependency declarations need empirical
  validation at the affected-stage boundary, not just at the affected
  extension's API surface.
