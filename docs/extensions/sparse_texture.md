# ARB_sparse_texture

Sprint 19 Decision H4 / Item 55 moves ARB_sparse_texture out of Core into
`src/extensions/sparse_texture/`.

Module split:
- `SparseTextureModule` owns capability probing, lifecycle, and registry
  advertising for `GL_ARB_sparse_texture`.
- `SparseTextureBind` owns sparse texture parameter and internal-format query
  hooks.
- `SparseTextureAlloc` owns sparse allocation, page commitment, upload,
  readback, and sidecar state.
- `SparseTextureExtension` owns sparse-specific entry-point routing.

The first migration checkpoint wires the module and keeps behavior in Core.
Later checkpoints move state and implementation behind registry hooks while
preserving the existing CTS pass profile.

