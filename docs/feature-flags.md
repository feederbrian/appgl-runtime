# AppGL Feature Flags

AppGL resolves launch-time feature flags with one shared typed resolver.
The resolver owns per-flag metadata:

- canonical name and aliases
- porter environment-variable aliases
- type: bool, int, float, enum, string, or path
- default value
- scope: porter, app, runtime, or both
- validator and invalid-value policy
- optional NORM#1 label for runtime-touching flags

The S23 precedence rule is deterministic:

1. Command-line arguments on the host process.
2. Porter environment variables.
3. User JSON config.
4. Built-in default.

Invalid values are diagnosed and ignored; resolution falls through to the next
lower valid source or the built-in default. Runtime-dangerous flags can mark
their invalid policy as default-safe, which forces the default after a bad
explicit value.

Missing default-discovery JSON files are silent. Malformed or unreadable
explicit JSON paths selected by `--appgl-config`, `APPGL_OPTIONS_JSON`, or
`APPGL_CONFIG_JSON` are recorded in the feature-flag diagnostics surface.

## Command Line

Boolean flags accept either generic or per-flag forms:

```bash
--appgl-enable=f64-emulation
--appgl-disable=f64-emulation
--appgl-f64-emulation=1
--appgl-f64-emulation=false
--appgl-no-f64-emulation
```

If the same flag appears more than once on the command line, the last matching
argument wins within the command-line source.

Typed flags use per-flag assignment:

```bash
--appgl-some-float-flag=1.0
--appgl-some-enum-flag=off
--appgl-some-path-flag=/tmp/appgl
```

`--appgl-config=/path/to/appgl-options.json` selects a JSON config file. Values
from that file still have JSON precedence; they do not outrank command-line
feature values or porter environment variables.

## Environment

Each feature owns its compatibility environment-variable aliases. Environment
variables use AppGL's existing boolean convention: presence means enabled unless
the value is an explicit false token.

Accepted true tokens: `1`, `true`, `yes`, `on`, `enable`, `enabled`.
Accepted false tokens: `0`, `false`, `no`, `off`, `disable`, `disabled`.

## JSON Config

Search order:

1. `--appgl-config=/path/to/appgl-options.json` if set.
2. `APPGL_OPTIONS_JSON` or `APPGL_CONFIG_JSON` if set.
3. `appgl-options.json` in the current working directory.
4. `appgl-options.json` next to the process executable.
5. `appgl-options.json` in the app bundle resources.

Flag keys may be top-level or nested under `appgl` or `features`.
Values may be raw JSON scalars or objects with an `enabled`, `force`, or `value`
member. Boolean values may be booleans, boolean strings, or numbers. Numeric,
enum, string, and path flags are parsed according to their registry type and
validator.

```json
{
  "appgl": {
    "features": {
      "f64-emulation": true
    }
  }
}
```

## Initial Consumer

`f64-emulation` is the first shared-infrastructure consumer. It keeps the older
aliases `fp64-emulation`, `gpu-shader-fp64`, and `vertex-attrib-64bit`, plus the
existing environment variables:

```bash
APPGL_ENABLE_FP64_EMULATION=1
APPGL_ENABLE_GPU_SHADER_FP64=1
APPGL_ENABLE_VERTEX_ATTRIB_64BIT=1
```
