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
- The module is registered with ExtensionRegistry and advertises
  `GL_EXT_fragment_shading_rate` without changing the existing extension list.
- Functional behavior remains in Core until the state and Metal render-pass
  hooks move behind the module boundary.

Cross-extension dependency:
- `ShaderTranslator` currently uses a global MSL 2.4 target so the SPIRV-Cross
  fork can emit EXT_fragment_shading_rate builtins (`[[shading_rate]]` and
  `[[primitive_shading_rate]]`).
- Decision H4 keeps that translator policy global for this migration. A
  module-managed translator feature request is a future refinement if another
  extension needs conflicting MSL-version policy.
