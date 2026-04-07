# Fix: Wrap nativeInit allocation in try/catch

**PR comments:** #21 thread 3042403922

## Problem

`nativeInit()` in `CameraBridge.cpp` calls `new cam::ImagePipeline()` without exception handling. If allocation or thread creation throws (`std::bad_alloc`, `std::system_error`), the JNI call crashes instead of returning 0 as documented.

## Changes

**`CameraBridge.cpp` — `nativeInit()`:**

```cpp
try {
    auto* pipeline = new cam::ImagePipeline();
    LOGD("nativeInit: pipeline=%p", pipeline);
    return static_cast<jlong>(reinterpret_cast<uintptr_t>(pipeline));
} catch (...) {
    LOGE("nativeInit: failed to create ImagePipeline");
    return 0;
}
```

## Acceptance criteria

- `nativeInit()` returns 0 on allocation failure instead of crashing
- Kotlin side handles 0 return (already does via existing null-check logic)
