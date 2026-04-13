# AppGL Third-Party Sources

These source drops are vendored under `appgl-runtime/third_party/` so the runtime build remains app-bundled and user-space only. They are not shipping artifacts by themselves.

| Dependency | Upstream | Pinned commit | License |
| --- | --- | --- | --- |
| `glslang` | `https://github.com/KhronosGroup/glslang` | `dcf1aaa6fd7dc2081f17aa0a4f1590a76473d961` | BSD-style Khronos license, see `glslang/LICENSE.txt` |
| `SPIRV-Cross` | `https://github.com/KhronosGroup/SPIRV-Cross` | `4d4b79bd7b69b07fabdeb06f849334ba79ea7cee` | Apache-2.0 or MIT, see `SPIRV-Cross/LICENSE` and `SPIRV-Cross/LICENSES/` |
| `stb_image` / `stb_image_write` | `https://github.com/nothings/stb` | `28d546d5eb77d4585506a20480f4de2e706dff4c` | MIT or public domain, see license footer in each header |

`APPGL_VENDOR_THIRD_PARTY=ON` adds `glslang` and `SPIRV-Cross` to the CMake graph for shader pipeline development. The default configure path keeps that option off so the bootstrap runtime and gauntlet stay quick while the translator integration is still being wired.

## Vendoring model

`stb_image*` is committed directly into this directory as plain headers — it is a single-file library and adds negligible footprint.

`glslang` and `SPIRV-Cross` are **optional** source drops. They are NOT tracked in the runtime git repository so the shippable dylib and public history stay compact. Contributors who need them run:

```
scripts/fetch_third_party.sh
```

from the repository root, which clones each upstream at the pinned commit above. The script is idempotent — re-running it will `git fetch` + `git checkout` the pinned commit on an existing clone. Converting these to formal git submodules is revisited in Phase B when the translator path is wired into the Xcode framework target.

