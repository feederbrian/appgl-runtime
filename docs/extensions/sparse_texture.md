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

Current ownership:
- Core texture objects no longer store sparse params, sparse level count,
  sparse heap, or committed-region vectors.
- `SparseTextureAlloc` stores that state in a per-context sidecar keyed by
  texture object, releases sparse heaps on texture storage reset/delete/context
  teardown, and implements sparse storage allocation, page commitment, and
  committed-region upload.
- `SparseTextureBind` handles `GL_TEXTURE_SPARSE_ARB`,
  `GL_VIRTUAL_PAGE_SIZE_INDEX_ARB`, `GL_NUM_SPARSE_LEVELS_ARB`, and sparse
  internal-format page-size queries through registry hooks.
- GLContext remains responsible for generic texture validation and immutable
  level population, then routes sparse-specific work to the module.
