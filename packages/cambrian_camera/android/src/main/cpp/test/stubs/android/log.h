#pragma once
// Host-only stub for <android/log.h> — used by the GTest host build.
#include <cstdarg>
#define ANDROID_LOG_DEBUG 3
#define ANDROID_LOG_WARN  5
#define ANDROID_LOG_ERROR 6
inline int __android_log_print(int, const char*, const char* fmt, ...) { return 0; }
