cmake_minimum_required(VERSION 3.22.1)
project(cambrian_camera)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# OpenCV: for Android, use the symlinked SDK; for host tests, rely on system install.
# See CLAUDE.md for setup instructions.
if(ANDROID)
    set(OpenCV_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../opencv/sdk/native/jni")
endif()
find_package(OpenCV REQUIRED core imgproc)

add_library(cambrian_camera SHARED
    src/CameraBridge.cpp
    src/GpuRenderer.cpp
    src/ImagePipeline.cpp
    src/InputRing.cpp
)

# Pixel-processing code needs optimization even in Debug — without it, our
# per-pixel loops run ~20x slower than OpenCV's pre-compiled (always -O2) functions.
# -O2 baseline for all configs; -O3 + -ffast-math for Release.
# -ffast-math enables NEON FMA; safe for uint8 [0,255] pixel math.
target_compile_options(cambrian_camera PRIVATE
    -O2 -ftree-vectorize
    $<$<CONFIG:Release>:-O3 -ffast-math>
    $<$<CONFIG:RelWithDebInfo>:-ffast-math>
)

target_include_directories(cambrian_camera PRIVATE include)

target_link_libraries(cambrian_camera
    opencv_core
    opencv_imgproc
    android
    log
    GLESv3
    EGL
    c++_shared   # required: OpenCV static libs reference libc++ symbols
)

if(NOT ANDROID)
    include(FetchContent)
    FetchContent_Declare(
        googletest
        GIT_REPOSITORY https://github.com/google/googletest.git
        GIT_TAG        v1.14.0
    )
    FetchContent_MakeAvailable(googletest)

    add_executable(cambrian_camera_tests
        test/TrackerDimTest.cpp
        test/SinkRoutingTest.cpp
        src/ImagePipeline.cpp
        src/InputRing.cpp
    )

    target_include_directories(cambrian_camera_tests PRIVATE
        include
        src
        test/stubs   # provides android/log.h and android/native_window.h stubs
    )

    target_link_libraries(cambrian_camera_tests
        GTest::gtest_main
        opencv_core
        opencv_imgproc
        # Note: android, log, EGL, GLESv3 are Android-only — not linked for host build
    )

    include(GoogleTest)
    gtest_discover_tests(cambrian_camera_tests)
endif()
