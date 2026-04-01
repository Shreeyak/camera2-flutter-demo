cmake_minimum_required(VERSION 3.22.1)
project(cambrian_camera)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# OpenCV: symlinked at packages/cambrian_camera/android/opencv
# See CLAUDE.md for setup instructions.
set(OpenCV_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../opencv/sdk/native/jni")
find_package(OpenCV REQUIRED core imgproc)

add_library(cambrian_camera SHARED
    src/CameraBridge.cpp
    src/ImagePipeline.cpp
    src/InputRing.cpp
)

# Aggressive optimization for pixel-processing hot loops (NEON auto-vectorization,
# fused multiply-add).  -ffast-math is safe here: all values are uint8 [0,255]
# or float intermediates — no NaN/denormal edge cases.
target_compile_options(cambrian_camera PRIVATE
    $<$<CONFIG:Release>:-O3 -ffast-math -ftree-vectorize>
    $<$<CONFIG:RelWithDebInfo>:-O2 -ffast-math -ftree-vectorize>
)

target_include_directories(cambrian_camera PRIVATE include)

target_link_libraries(cambrian_camera
    opencv_core
    opencv_imgproc
    android
    log
    c++_shared   # required: OpenCV static libs reference libc++ symbols
)
