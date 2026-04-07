# Fix: Update test call sites for nativeInit/nativeGpuInit signatures

**PR comments:** #17 threads 3042286915, 3042286927

## Problem

`nativeInit` and `nativeGpuInit` gained a `debugLevel` parameter, but instrumentation tests (`GpuSinkConsistencyTest.kt`, `GpuRendererTest.kt`) still call the old signatures. This breaks compilation of test targets.

## Changes

**Option A (overload):** Add a zero-arg `nativeInit()` overload and a 6-arg `nativeGpuInit()` overload that default `debugLevel=0`. Tests continue to compile without changes.

**Option B (update tests):** Add `debugLevel = 0` to all test call sites.

Prefer Option A — it's backward-compatible and prevents future breakage.

**Files:**
- `CameraController.kt` companion object — add overload
- `GpuPipeline.kt` companion object — add overload
- Verify tests compile: `./gradlew :cambrian_camera:compileDebugAndroidTestKotlin`

## Acceptance criteria

- Instrumentation tests compile and pass
- No signature mismatch at test call sites
