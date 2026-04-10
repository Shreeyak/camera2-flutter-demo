cmake_minimum_required(VERSION 3.22.1)
project(cambrian_camera)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(cambrian_camera SHARED
    src/CameraBridge.cpp
    src/GpuRenderer.cpp
    src/ImagePipeline.cpp
    src/fpng.cpp
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

# ---------------------------------------------------------------------------
# libjpeg-turbo — build from source so we get a known version with NEON
# enabled by the NDK toolchain. libjpeg-turbo explicitly prohibits
# add_subdirectory/FetchContent, so we use ExternalProject_Add instead and
# expose the resulting static library as an IMPORTED target.
# Only needed for the Android target; the host test build does not encode images.
# ---------------------------------------------------------------------------
if(ANDROID)
    include(ExternalProject)

    set(LIBJPEG_TURBO_INSTALL_DIR ${CMAKE_BINARY_DIR}/libjpeg-turbo-install)
    # Pre-create the include directory so CMake's INTERFACE_INCLUDE_DIRECTORIES
    # validation passes at configure time (the dir is populated at build time).
    file(MAKE_DIRECTORY ${LIBJPEG_TURBO_INSTALL_DIR}/include)

    ExternalProject_Add(libjpeg_turbo_ext
        GIT_REPOSITORY https://github.com/libjpeg-turbo/libjpeg-turbo.git
        GIT_TAG        3.0.3
        GIT_SHALLOW    TRUE
        CMAKE_ARGS
            -DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}
            -DANDROID_ABI=${ANDROID_ABI}
            -DANDROID_NDK=${ANDROID_NDK}
            -DANDROID_PLATFORM=${ANDROID_PLATFORM}
            -DANDROID_STL=${ANDROID_STL}
            -DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
            -DCMAKE_INSTALL_PREFIX=${LIBJPEG_TURBO_INSTALL_DIR}
            # Build the static TurboJPEG library only.
            -DENABLE_SHARED=OFF
            -DENABLE_STATIC=ON
            -DWITH_TURBOJPEG=ON
            -DWITH_JAVA=OFF
            -DWITH_TURBOJPEG_UTILS=OFF
        BUILD_BYPRODUCTS
            ${LIBJPEG_TURBO_INSTALL_DIR}/lib/libturbojpeg.a
    )

    add_library(turbojpeg_static STATIC IMPORTED GLOBAL)
    add_dependencies(turbojpeg_static libjpeg_turbo_ext)
    set_target_properties(turbojpeg_static PROPERTIES
        IMPORTED_LOCATION        ${LIBJPEG_TURBO_INSTALL_DIR}/lib/libturbojpeg.a
        INTERFACE_INCLUDE_DIRECTORIES ${LIBJPEG_TURBO_INSTALL_DIR}/include
    )

    add_dependencies(cambrian_camera libjpeg_turbo_ext)
endif()

target_link_libraries(cambrian_camera
    android
    log
    GLESv3
    EGL
    $<$<BOOL:${ANDROID}>:turbojpeg_static>
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
    )

    target_include_directories(cambrian_camera_tests PRIVATE
        include
        src
        test/stubs   # provides android/log.h and android/native_window.h stubs
    )

    target_link_libraries(cambrian_camera_tests
        GTest::gtest_main
        # Note: android, log, EGL, GLESv3 are Android-only — not linked for host build
    )

    include(GoogleTest)
    gtest_discover_tests(cambrian_camera_tests)
endif()
