# AppGL

An OpenGL 4.6 → Metal translation layer for macOS, shipping as `libAppGL.dylib`.

---

## ⚠ Pre-release — not ready for use

**This repository is published for transparency, not for consumption.** It is not packaged, not
supported, and not ready to build against. There are no installation instructions yet, and issues and
pull requests are not being accepted.

A substantial internal rework is planned before this becomes usable. Until that lands, treat anything
here as subject to change without notice.

---

## Where it stands

Conformance measured 2026-08-12 against the current pin:

| suite | standing |
|---|---|
| **Khronos CTS** (`KHR-GL46`, 19,716 cases) | 19,402 pass · 4 fail · 310 not-supported |
| **Piglit** (7,858 rows) | 4,316 pass · 587 fail · 2,421 skip |

Both figures are at default settings. AppGL is a single binary whose behaviour is selected at runtime
via environment flags — there is no separate "feature build."

---

## License

See [`LICENSE`](LICENSE).

Third-party components retain their own licenses. AppGL vendors
[SPIRV-Cross](https://github.com/KhronosGroup/SPIRV-Cross) and
[glslang](https://github.com/KhronosGroup/glslang), both Apache-2.0; see [`NOTICE`](NOTICE).

## Security

Please do not open public issues for security findings. See [`SECURITY.md`](SECURITY.md).
