#ifndef APPGL_LOG_H
#define APPGL_LOG_H
/*
 * AppGL Structured Logging Channels
 *
 * Compile-time gates for hot-path diagnostic output.  Each channel
 * is controlled by a preprocessor macro:
 *
 *   -DAPPGL_LOG_DRAW      Per-draw-call traces (drawArrays, drawElements, …)
 *   -DAPPGL_LOG_SHADER    Shader compile/link lifecycle
 *   -DAPPGL_LOG_TEXTURE   Texture upload, sampler binding
 *   -DAPPGL_LOG_BUFFER    Buffer upload, map/unmap, shadow sync
 *   -DAPPGL_LOG_PIPELINE  Metal pipeline build events
 *   -DAPPGL_LOG_ALL       Enable every channel
 *
 * Usage in .mm / .cpp files:
 *
 *   #include "AppGLLog.h"
 *   APPGL_LOG(DRAW, @"drawArrays: mode=0x%X count=%d", mode, count);
 *
 * In release builds, none of these macros are defined by default,
 * so every APPGL_LOG() compiles to nothing — zero overhead on the
 * draw hot path.  Enable selectively via CMake:
 *
 *   cmake … -DAPPGL_LOG_DRAW=1
 *
 * Rationale: replaces the ungated `NSLog` calls that were costing
 * 50–500 µs per invocation in the draw path (ADV-1).  Diagnostic
 * NSLogs gated behind once-flags (linkProgram, texSubImage first-call)
 * are left as-is — they fire at most once per object and are not
 * hot-path.
 */

#ifdef __OBJC__
#  import <Foundation/Foundation.h>
#endif

/* If APPGL_LOG_ALL is set, enable every channel. */
#ifdef APPGL_LOG_ALL
#  ifndef APPGL_LOG_DRAW
#    define APPGL_LOG_DRAW 1
#  endif
#  ifndef APPGL_LOG_SHADER
#    define APPGL_LOG_SHADER 1
#  endif
#  ifndef APPGL_LOG_TEXTURE
#    define APPGL_LOG_TEXTURE 1
#  endif
#  ifndef APPGL_LOG_BUFFER
#    define APPGL_LOG_BUFFER 1
#  endif
#  ifndef APPGL_LOG_PIPELINE
#    define APPGL_LOG_PIPELINE 1
#  endif
#endif

/*
 * APPGL_LOG(CHANNEL, format, ...)
 *
 * Expands to NSLog when the channel is enabled, otherwise nothing.
 * The channel tag is prepended so grep/Console.app filtering works:
 *   [GL:draw] drawArrays: mode=0x0004 count=36 program=1 …
 */
#ifdef __OBJC__

#  ifdef APPGL_LOG_DRAW
#    define APPGL_LOG_DRAW_FMT(fmt, ...) NSLog(@"[GL:draw] " fmt, ##__VA_ARGS__)
#  else
#    define APPGL_LOG_DRAW_FMT(fmt, ...) ((void)0)
#  endif

#  ifdef APPGL_LOG_SHADER
#    define APPGL_LOG_SHADER_FMT(fmt, ...) NSLog(@"[GL:shader] " fmt, ##__VA_ARGS__)
#  else
#    define APPGL_LOG_SHADER_FMT(fmt, ...) ((void)0)
#  endif

#  ifdef APPGL_LOG_TEXTURE
#    define APPGL_LOG_TEXTURE_FMT(fmt, ...) NSLog(@"[GL:texture] " fmt, ##__VA_ARGS__)
#  else
#    define APPGL_LOG_TEXTURE_FMT(fmt, ...) ((void)0)
#  endif

#  ifdef APPGL_LOG_BUFFER
#    define APPGL_LOG_BUFFER_FMT(fmt, ...) NSLog(@"[GL:buffer] " fmt, ##__VA_ARGS__)
#  else
#    define APPGL_LOG_BUFFER_FMT(fmt, ...) ((void)0)
#  endif

#  ifdef APPGL_LOG_PIPELINE
#    define APPGL_LOG_PIPELINE_FMT(fmt, ...) NSLog(@"[GL:pipeline] " fmt, ##__VA_ARGS__)
#  else
#    define APPGL_LOG_PIPELINE_FMT(fmt, ...) ((void)0)
#  endif

/*
 * Convenience: APPGL_LOG(DRAW, ...) expands to APPGL_LOG_DRAW_FMT(...)
 * This uses token-pasting so the channel name is a compile-time constant.
 */
#  define APPGL_LOG(channel, ...) APPGL_LOG_##channel##_FMT(__VA_ARGS__)

#else
/* Pure C++ — no NSLog available. Stub everything. */
#  define APPGL_LOG(channel, ...) ((void)0)
#endif

#endif /* APPGL_LOG_H */
