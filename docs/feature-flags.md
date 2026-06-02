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

## Diagnostic Logging

Batch-A diagnostic logging is resolved once at runtime initialization and is
default-inert.

| Flag | Type | Default | Aliases | Environment |
| --- | --- | --- | --- | --- |
| `logging` | enum: `off`, `error`, `warn`, `info`, `debug`, `trace` | `off` | `log`, `diagnostic-logging` | `APPGL_LOGGING`, `APPGL_DIAGNOSTIC_LOGGING` |
| `logging-file` | path | empty | `log-file`, `logging-output`, `log-output` | `APPGL_LOGGING_FILE`, `APPGL_LOG_FILE` |
| `logging-components` | comma-delimited string | `all` | `log-components`, `logging-component-filter` | `APPGL_LOGGING_COMPONENTS`, `APPGL_LOG_COMPONENTS` |

When `logging` is not `off` and `logging-file` is empty, AppGL uses the
stderr/console diagnostic sink. When `logging-file` is set, AppGL opens that
explicit path once at init and writes diagnostic log lines there. Open failures
are diagnosed and file export is disabled; they do not fail process startup.
Automatic directories and timestamped file names are deferred to a future
`logging-dir` flag.

`logging-components` accepts:

```text
all,runtime,feature_flags,shader_translator,frame_graph,command_submission,
extension_registry,draw,shader,texture,buffer,pipeline
```

Repeated component arguments are not accumulated in Batch-A; use one
comma-delimited value such as:

```bash
--appgl-logging=debug
--appgl-logging-components=shader_translator,frame_graph
--appgl-logging-file=/tmp/appgl.log
```

`AppGLLog.h` remains the compile-time upper bound for hot-path structured
logging. Unless CMake options such as `APPGL_LOG_DRAW`, `APPGL_LOG_SHADER`,
`APPGL_LOG_TEXTURE`, `APPGL_LOG_BUFFER`, or `APPGL_LOG_PIPELINE` are enabled,
those callsites compile to zero-overhead stubs and runtime component filtering
does not touch draw or encode paths. Existing ad hoc `APPGL_TRACE_*`,
`APPGL_*PROFILE`, `APPGL_LOG_LB`, and `APPGL_LOG_LINK` probes are not aliases for
Batch-A logging.

## Metal Validation Reconciliation

`metal-validation-layer` is a request and diagnostic reconciliation flag. It does
not force Metal validation internally and it is not a runtime switch.

| Flag | Type | Default | Aliases | Environment |
| --- | --- | --- | --- | --- |
| `metal-validation-layer` | bool | `false` | `metal-validation`, `metal-debug-layer`, `mtl-debug-layer` | `APPGL_METAL_VALIDATION_LAYER`, `APPGL_METAL_VALIDATION` |

AppGL resolves this flag before the first `MTLCreateSystemDefaultDevice()` call.
Actual Metal validation enablement must be arranged by the porter or launcher
before the process loads Metal. AppGL reconciles against Apple's pre-launch
environment signal `METAL_DEVICE_WRAPPER_TYPE`:

- requested and `METAL_DEVICE_WRAPPER_TYPE` enabled: silent OK
- requested and the pre-launch env is not enabled: one diagnostic with porter
  guidance
- not requested: silent

The diagnostic explicitly states that enablement is porter/launcher/pre-process
work and that AppGL cannot guarantee or force validation internally after Metal
has loaded or after a device exists.
