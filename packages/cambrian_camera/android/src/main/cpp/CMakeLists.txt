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
    c++_shared   # required: OpenCV static libs reference libc++ symbols
)
