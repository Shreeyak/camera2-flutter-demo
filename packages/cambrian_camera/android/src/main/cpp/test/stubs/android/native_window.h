#pragma once
// Host-only stub for <android/native_window.h> — used by the GTest host build.
#include <cstdint>
#define WINDOW_FORMAT_RGBA_8888 1
typedef struct ANativeWindow ANativeWindow;
inline void ANativeWindow_acquire(ANativeWindow*) {}
inline void ANativeWindow_release(ANativeWindow*) {}
struct ANativeWindow_Buffer {
    int32_t width; int32_t height; int32_t stride; int32_t format;
    void* bits; uint8_t reserved[6*sizeof(int32_t)];
};
inline int ANativeWindow_lock(ANativeWindow*, ANativeWindow_Buffer*, void*) { return -1; }
inline void ANativeWindow_unlockAndPost(ANativeWindow*) {}
inline int ANativeWindow_setBuffersGeometry(ANativeWindow*, int32_t, int32_t, int32_t) { return -1; }
