cmake_minimum_required(VERSION 3.22.1)
project(cambrian_camera)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

add_library(cambrian_camera SHARED
    src/CameraBridge.cpp
    src/ImagePipeline.cpp
)

target_include_directories(cambrian_camera PRIVATE include)

target_link_libraries(cambrian_camera
    android   # ANativeWindow, Surface, etc.
    log       # __android_log_print
)
