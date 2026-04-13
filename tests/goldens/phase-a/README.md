# Phase A Goldens

Phase A goldens are captured from offscreen AppGL contexts with `glReadPixels(GL_RGBA, GL_UNSIGNED_BYTE)` and compared by `appgl-runtime/tests/GoldenCompare.cpp`.

| Scene ID | Golden | Coverage Purpose | Tolerance |
| --- | --- | --- | --- |
| `phase-a.read-pixels` | `phase-a.read-pixels.png` | Deterministic offscreen clear, default framebuffer depth/stencil clear state, capability queries, enable-state mirror, and RGBA8 readback | `1%` deviating channels |
| `phase-a.fbo-depth-stencil-readback` | `phase-a.fbo-depth-stencil-readback.png` | User FBO color attachment readback plus depth/stencil renderbuffer clear/readback validation | `1%` deviating channels |
| `phase-a.vertex-input` | `phase-a.vertex-input.png` | Dedicated VAO/input-state descriptor cache scenario with deterministic readback | `1%` deviating channels |
| `phase-a.texture-sampler-state` | `phase-a.texture-sampler-state.png` | Texture upload, parameter query arity guards, mipmap generation, and sampler object state | `1%` deviating channels |
| `phase-a.index-uint8-expansion` | `phase-a.index-uint8-expansion.png` | Centralized `GL_UNSIGNED_BYTE` element-index expansion policy for future Metal draw submission | `1%` deviating channels |

To refresh goldens intentionally:

```sh
APPGL_WORKSPACE_ROOT="$PWD" APPGL_WRITE_GOLDENS=1 appgl-runtime/build/appgl_gauntlet_cli phase-a
```

Normal gauntlet runs must not set `APPGL_WRITE_GOLDENS`; missing or mismatched PNGs fail the CLI.
