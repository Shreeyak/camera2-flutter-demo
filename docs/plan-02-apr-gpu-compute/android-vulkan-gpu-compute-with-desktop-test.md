# C++ Vulkan Compute Color Lab (Desktop Prototype → Android)

## Context

Desktop C++ prototype of the color transform pipeline using raw Vulkan compute, GLFW, and Dear ImGui. The Vulkan compute core (`ColorProcessor`) is written to be portable to Android NDK unchanged. Only the GLFW/ImGui/OpenGL display layer is desktop-specific.

**Replaces** the Python + Kompute-Python-bindings approach (blocked by pybind11 incompatibility with Python 3.12+). Uses raw Vulkan instead of Kompute — same synchronization primitives the Android migration guide recommends, and directly mirrors the RenderScript migration sample patterns.

**Source:** `scripts/color_transform_lab_vk/`

### Reference implementations
- [Android RenderScript → Vulkan migration guide](https://developer.android.com/guide/topics/renderscript/migrate/migrate-vulkan)
- [RenderScript migration sample (Android)](https://github.com/android/renderscript-samples/tree/main/RenderScriptMigrationSample/app/src/main)
- [Vulkan spec: Command Buffers](https://docs.vulkan.org/spec/latest/chapters/cmdbuffers.html#commandbuffers)
- [Vulkan spec: Memory Barriers](https://docs.vulkan.org/spec/latest/chapters/synchronization.html#synchronization-memory-barriers)
- [Android Vulkan compute example with depth (reference for VkDevice/queue setup)](https://github.com/tvaranka/vulkan_android_example_depth)
- [Google Samples: Android Vulkan Tutorials (instance/device/pipeline patterns)](https://github.com/googlesamples/android-vulkan-tutorials)

---

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Desktop only (NOT ported to Android)                   │
│  main.cpp: GLFW window + ImGui sliders + stb_image load │
│  DisplayContext: OpenGL texture + ImGui::Image()         │
└──────────────────────┬──────────────────────────────────┘
                       │  RGBA float32 buffer in/out
┌──────────────────────▼──────────────────────────────────┐
│  ColorProcessor  ← PORTABLE TO ANDROID NDK              │
│  Raw Vulkan compute:                                     │
│   VkInstance / VkDevice / VkQueue (compute)             │
│   VkBuffer×2 (input, output) — host-visible/coherent    │
│   VkDescriptorSet (binds the 2 buffers)                 │
│   VkPipeline (compute, SPIR-V color_transform.comp)     │
│   VkCommandBuffer: bind → push_constants → dispatch     │
│                    → pipeline_barrier → submit → fence  │
└──────────────────────────────────────────────────────────┘
```

---

## File Structure

```
scripts/color_transform_lab_vk/
├── CMakeLists.txt
├── run.sh                     # build + launch
├── shaders/
│   └── color_transform.comp   # GLSL source
├── src/
│   ├── VulkanUtils.h/cpp      # instance/device/memory helpers (portable)
│   ├── ColorProcessor.h/cpp   # compute pipeline core (PORTABLE TO ANDROID)
│   └── main.cpp               # GLFW + ImGui desktop app
└── third_party/               # fetched by CMake
    ├── imgui/
    ├── glfw/
    └── stb/
```

---

## Step 1: GLSL Compute Shader (`shaders/color_transform.comp`)

Matches the production Android shader. Operations in order: contrast → brightness → saturation (BT.709 luma-mix) → per-channel gain → clamp.

The `lumaMode` push constant selects BT.709 (default, matches Camera2 OES output) or BT.601 (legacy SD), letting the lab toggle between them.

```glsl
#version 450
layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0) buffer InputBuf  { float data[]; } inBuf;
layout(set = 0, binding = 1) buffer OutputBuf { float data[]; } outBuf;

layout(push_constant) uniform Params {
    float brightness;   // [-1, 1],   0.0 = identity
    float contrast;     // [0.5, 2],  1.0 = identity
    float saturation;   // [0, 2],    1.0 = identity
    float gainR;        // [0.5, 2],  1.0 = identity (WB gain)
    float gainG;
    float gainB;
    uint  numPixels;    // width * height
    uint  lumaMode;     // 0 = BT.709, 1 = BT.601
} p;

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= p.numPixels) return;

    uint base = idx * 4u;
    vec3 c = vec3(inBuf.data[base], inBuf.data[base+1u], inBuf.data[base+2u]);

    c = (c - 0.5) * p.contrast + 0.5;
    c += p.brightness;

    vec3 weights = (p.lumaMode == 0u)
        ? vec3(0.2126, 0.7152, 0.0722)   // BT.709 (default, Camera2 OES)
        : vec3(0.299,  0.587,  0.114);    // BT.601
    float luma = dot(c, weights);
    c = mix(vec3(luma), c, p.saturation);

    c *= vec3(p.gainR, p.gainG, p.gainB);
    c = clamp(c, 0.0, 1.0);

    outBuf.data[base]      = c.r;
    outBuf.data[base+1u]   = c.g;
    outBuf.data[base+2u]   = c.b;
    outBuf.data[base+3u]   = inBuf.data[base+3u];
}
```

Push constants are 32 bytes (6 × float + 2 × uint32). Well within the 128-byte guaranteed minimum.

**Build-time SPIR-V compilation** (desktop and Android — no runtime glslc):
```cmake
find_program(GLSLC glslc HINTS $ENV{VULKAN_SDK}/bin REQUIRED)
add_custom_command(
    OUTPUT  ${CMAKE_BINARY_DIR}/color_transform.spv
    COMMAND ${GLSLC} -fshader-stage=compute
            ${CMAKE_SOURCE_DIR}/shaders/color_transform.comp
            -o ${CMAKE_BINARY_DIR}/color_transform.spv
    DEPENDS ${CMAKE_SOURCE_DIR}/shaders/color_transform.comp
)
add_custom_target(shaders DEPENDS ${CMAKE_BINARY_DIR}/color_transform.spv)
```

Desktop: SPV loaded from `SHADER_SPV_PATH` at startup.
Android: embedded as a `uint32_t[]` C array: `xxd -i color_transform.spv > color_transform_spv.h`.

---

## Step 2: `ColorProcessor` — Portable Vulkan Compute Core

### API (`ColorProcessor.h`)

```cpp
struct ColorParams {
    float    brightness = 0.f;
    float    contrast   = 1.f;
    float    saturation = 1.f;
    float    gainR = 1.f, gainG = 1.f, gainB = 1.f;
    uint32_t numPixels  = 0;
    uint32_t lumaMode   = 0;  // 0 = BT.709, 1 = BT.601
};
static_assert(sizeof(ColorParams) == 32);

class ColorProcessor {
public:
    // spirv: SPIR-V words from .spv file (caller provides — no file I/O here)
    bool init(uint32_t width, uint32_t height,
              const std::vector<uint32_t>& spirv);

    // Upload input image (RGBA float32). Call once unless image changes.
    void uploadInput(const float* rgba);

    // Re-record and submit command buffer with new push constants.
    void process(const ColorParams& params);

    // Map output for CPU read. Waits on fence. Valid until unmapOutput().
    const float* mapOutput();
    void unmapOutput();

    void destroy();

private:
    VkInstance       instance_   = VK_NULL_HANDLE;
    VkPhysicalDevice physDevice_ = VK_NULL_HANDLE;
    VkDevice         device_     = VK_NULL_HANDLE;
    VkQueue          queue_      = VK_NULL_HANDLE;
    uint32_t         queueFamily_ = 0;

    VkCommandPool    cmdPool_    = VK_NULL_HANDLE;
    VkCommandBuffer  cmdBuf_     = VK_NULL_HANDLE;
    VkFence          fence_      = VK_NULL_HANDLE;

    VkDescriptorSetLayout descLayout_ = VK_NULL_HANDLE;
    VkDescriptorPool      descPool_   = VK_NULL_HANDLE;
    VkDescriptorSet       descSet_    = VK_NULL_HANDLE;
    VkPipelineLayout      pipeLayout_ = VK_NULL_HANDLE;
    VkPipeline            pipeline_   = VK_NULL_HANDLE;

    VkBuffer       inputBuf_  = VK_NULL_HANDLE;
    VkDeviceMemory inputMem_  = VK_NULL_HANDLE;
    VkBuffer       outputBuf_ = VK_NULL_HANDLE;
    VkDeviceMemory outputMem_ = VK_NULL_HANDLE;

    VkDeviceSize bufferSize_ = 0;
    uint32_t     width_ = 0, height_ = 0;
};
```

### Key implementation details

**Buffer allocation — host-visible + host-coherent:**

Using `HOST_COHERENT` avoids explicit `vkFlushMappedMemoryRanges` / `vkInvalidateMappedMemoryRanges`. On unified-memory Android SoCs this is equivalent to device-local (no performance cost). For dedicated VRAM GPUs, upgrade to device-local + staging buffers later.

```cpp
VkBufferCreateInfo bufInfo{VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO};
bufInfo.size  = bufferSize_;
bufInfo.usage = VK_BUFFER_USAGE_STORAGE_BUFFER_BIT;
vkCreateBuffer(device_, &bufInfo, nullptr, &inputBuf_);

uint32_t memTypeIdx = findMemoryType(physDevice_,
    memReqs.memoryTypeBits,
    VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
VkMemoryAllocateInfo allocInfo{VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO};
allocInfo.allocationSize  = memReqs.size;
allocInfo.memoryTypeIndex = memTypeIdx;
vkAllocateMemory(device_, &allocInfo, nullptr, &inputMem_);
vkBindBufferMemory(device_, inputBuf_, inputMem_, 0);
// (identical pattern for outputBuf_ / outputMem_)
```

**Descriptor layout — two storage buffers at binding 0 and 1:**

```cpp
VkDescriptorSetLayoutBinding bindings[2] = {};
bindings[0] = {0, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr};
bindings[1] = {1, VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, 1, VK_SHADER_STAGE_COMPUTE_BIT, nullptr};

VkDescriptorSetLayoutCreateInfo layoutInfo{VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO};
layoutInfo.bindingCount = 2;
layoutInfo.pBindings    = bindings;
vkCreateDescriptorSetLayout(device_, &layoutInfo, nullptr, &descLayout_);
```

**Pipeline layout with push constant range:**

```cpp
VkPushConstantRange pcRange{};
pcRange.stageFlags = VK_SHADER_STAGE_COMPUTE_BIT;
pcRange.offset     = 0;
pcRange.size       = sizeof(ColorParams);  // 32 bytes

VkPipelineLayoutCreateInfo plInfo{VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO};
plInfo.setLayoutCount         = 1;
plInfo.pSetLayouts            = &descLayout_;
plInfo.pushConstantRangeCount = 1;
plInfo.pPushConstantRanges    = &pcRange;
vkCreatePipelineLayout(device_, &plInfo, nullptr, &pipeLayout_);
```

**`process()` — command buffer recording with correct synchronization:**

Per [Vulkan spec §7.6 Pipeline Barriers](https://docs.vulkan.org/spec/latest/chapters/synchronization.html#synchronization-memory-barriers):

```cpp
void ColorProcessor::process(const ColorParams& params) {
    // Ensure previous dispatch is complete before re-recording
    vkWaitForFences(device_, 1, &fence_, VK_TRUE, UINT64_MAX);
    vkResetFences(device_, 1, &fence_);

    vkResetCommandBuffer(cmdBuf_, 0);
    VkCommandBufferBeginInfo beginInfo{VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};
    beginInfo.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cmdBuf_, &beginInfo);

    // HOST → COMPUTE barrier: host wrote input buffer, shader will read it
    VkBufferMemoryBarrier inBarrier{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
    inBarrier.srcAccessMask       = VK_ACCESS_HOST_WRITE_BIT;
    inBarrier.dstAccessMask       = VK_ACCESS_SHADER_READ_BIT;
    inBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    inBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    inBarrier.buffer              = inputBuf_;
    inBarrier.size                = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmdBuf_,
        VK_PIPELINE_STAGE_HOST_BIT,           // srcStageMask
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, // dstStageMask
        0, 0, nullptr, 1, &inBarrier, 0, nullptr);

    vkCmdBindPipeline(cmdBuf_, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline_);
    vkCmdBindDescriptorSets(cmdBuf_, VK_PIPELINE_BIND_POINT_COMPUTE,
        pipeLayout_, 0, 1, &descSet_, 0, nullptr);
    vkCmdPushConstants(cmdBuf_, pipeLayout_,
        VK_SHADER_STAGE_COMPUTE_BIT, 0, sizeof(ColorParams), &params);

    uint32_t groupCount = (params.numPixels + 255u) / 256u;
    vkCmdDispatch(cmdBuf_, groupCount, 1, 1);

    // COMPUTE → HOST barrier: shader wrote output buffer, host will read it
    VkBufferMemoryBarrier outBarrier{VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER};
    outBarrier.srcAccessMask       = VK_ACCESS_SHADER_WRITE_BIT;
    outBarrier.dstAccessMask       = VK_ACCESS_HOST_READ_BIT;
    outBarrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    outBarrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    outBarrier.buffer              = outputBuf_;
    outBarrier.size                = VK_WHOLE_SIZE;
    vkCmdPipelineBarrier(cmdBuf_,
        VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, // srcStageMask
        VK_PIPELINE_STAGE_HOST_BIT,           // dstStageMask
        0, 0, nullptr, 1, &outBarrier, 0, nullptr);

    vkEndCommandBuffer(cmdBuf_);

    VkSubmitInfo submit{VK_STRUCTURE_TYPE_SUBMIT_INFO};
    submit.commandBufferCount = 1;
    submit.pCommandBuffers    = &cmdBuf_;
    vkQueueSubmit(queue_, 1, &submit, fence_);
    // Fence is waited at the top of the next process() call,
    // or explicitly in mapOutput() via vkWaitForFences.
}

const float* ColorProcessor::mapOutput() {
    vkWaitForFences(device_, 1, &fence_, VK_TRUE, UINT64_MAX);
    void* ptr = nullptr;
    vkMapMemory(device_, outputMem_, 0, bufferSize_, 0, &ptr);
    return static_cast<const float*>(ptr);
}

void ColorProcessor::unmapOutput() {
    vkUnmapMemory(device_, outputMem_);
}
```

---

## Step 3: `VulkanUtils` — Portable Helpers

```cpp
// Pick first physical device that has a compute queue
VkPhysicalDevice pickPhysicalDevice(VkInstance instance);

// Return queue family index with VK_QUEUE_COMPUTE_BIT
uint32_t findComputeQueueFamily(VkPhysicalDevice physDevice);

// Select memory type from typeBits satisfying required properties
uint32_t findMemoryType(VkPhysicalDevice physDevice,
                        uint32_t typeBits,
                        VkMemoryPropertyFlags props);

// Load a .spv file → std::vector<uint32_t> (desktop only; called by main.cpp)
std::vector<uint32_t> loadSpirv(const std::string& path);

// Create VkShaderModule from SPIR-V words
VkShaderModule createShaderModule(VkDevice device,
                                  const std::vector<uint32_t>& spirv);
```

VkInstance creation enables `VK_EXT_debug_utils` + `VK_LAYER_KHRONOS_validation` in debug builds (`#ifndef NDEBUG`). On Android, validation layers are loaded from `libVkLayer_khronos_validation.so` shipped with NDK debug builds — same `#ifndef NDEBUG` guard.

---

## Step 4: `CMakeLists.txt`

```cmake
cmake_minimum_required(VERSION 3.22)
project(color_lab_vk CXX)
set(CMAKE_CXX_STANDARD 17)

find_package(Vulkan REQUIRED)
find_package(OpenGL REQUIRED)

include(FetchContent)
FetchContent_Declare(glfw  GIT_REPOSITORY https://github.com/glfw/glfw.git   GIT_TAG 3.4)
FetchContent_Declare(imgui GIT_REPOSITORY https://github.com/ocornut/imgui.git GIT_TAG v1.91.1)
FetchContent_Declare(stb   GIT_REPOSITORY https://github.com/nothings/stb.git  GIT_TAG master)
FetchContent_MakeAvailable(glfw imgui stb)

# Compile shader at build time
find_program(GLSLC glslc HINTS $ENV{VULKAN_SDK}/bin REQUIRED)
add_custom_command(
    OUTPUT  ${CMAKE_BINARY_DIR}/color_transform.spv
    COMMAND ${GLSLC} -fshader-stage=compute
            ${CMAKE_SOURCE_DIR}/shaders/color_transform.comp
            -o ${CMAKE_BINARY_DIR}/color_transform.spv
    DEPENDS ${CMAKE_SOURCE_DIR}/shaders/color_transform.comp
)
add_custom_target(shaders DEPENDS ${CMAKE_BINARY_DIR}/color_transform.spv)

set(IMGUI_SOURCES
    ${imgui_SOURCE_DIR}/imgui.cpp
    ${imgui_SOURCE_DIR}/imgui_draw.cpp
    ${imgui_SOURCE_DIR}/imgui_tables.cpp
    ${imgui_SOURCE_DIR}/imgui_widgets.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_glfw.cpp
    ${imgui_SOURCE_DIR}/backends/imgui_impl_opengl3.cpp
)

add_executable(color_lab_vk
    src/VulkanUtils.cpp
    src/ColorProcessor.cpp
    src/main.cpp
    ${IMGUI_SOURCES}
)
add_dependencies(color_lab_vk shaders)

target_include_directories(color_lab_vk PRIVATE
    src/
    ${imgui_SOURCE_DIR}
    ${imgui_SOURCE_DIR}/backends
    ${stb_SOURCE_DIR}
)
target_compile_definitions(color_lab_vk PRIVATE
    SHADER_SPV_PATH="${CMAKE_BINARY_DIR}/color_transform.spv"
)
target_link_libraries(color_lab_vk PRIVATE
    Vulkan::Vulkan
    glfw
    OpenGL::GL
)
```

**Android note:** On Android, remove glfw/imgui/OpenGL deps entirely. `ColorProcessor.cpp` + `VulkanUtils.cpp` compile unchanged. `main.cpp` is replaced by Android NativeActivity + JNI. Add `target_link_libraries(... vulkan android log)`.

---

## Step 5: `main.cpp` — Desktop GUI

```
1. Parse argv[1] for image path (or generate test gradient)
2. stb_image → uint8 RGBA → float32 RGBA [0,1]
3. glfwInit() → glfwCreateWindow (1400×720, "Color Lab Vulkan")
4. glfwMakeContextCurrent() (OpenGL 3.3 core for ImGui display)
5. ImGui::CreateContext() + ImGui_ImplGlfw_Init + ImGui_ImplOpenGL3_Init
6. Load SPIR-V: loadSpirv(SHADER_SPV_PATH)
7. processor.init(width, height, spirv)
8. processor.uploadInput(rgbaFloat.data())
9. Create two GL textures (orig, processed) via glTexImage2D
10. Upload orig texture once (never changes)

Main loop:
  glfwPollEvents()
  ImGui_ImplOpenGL3_NewFrame() / ImGui_ImplGlfw_NewFrame() / ImGui::NewFrame()

  ImGui::Begin("Controls")
    ImGui::RadioButton("BT.709", &lumaMode, 0)  ImGui::SameLine()
    ImGui::RadioButton("BT.601", &lumaMode, 1)
    dirty |= ImGui::SliderFloat("Brightness", &p.brightness, -1.f, 1.f)
    dirty |= ImGui::SliderFloat("Contrast",   &p.contrast,    0.5f, 2.f)
    dirty |= ImGui::SliderFloat("Saturation", &p.saturation,  0.f,  2.f)
    dirty |= ImGui::SliderFloat("Gain R",     &p.gainR,       0.5f, 2.f)
    dirty |= ImGui::SliderFloat("Gain G",     &p.gainG,       0.5f, 2.f)
    dirty |= ImGui::SliderFloat("Gain B",     &p.gainB,       0.5f, 2.f)
    if (ImGui::Button("Reset")) { p = {}; p.numPixels = w*h; dirty = true; }
  ImGui::End()

  if (dirty) {
    p.lumaMode = lumaMode;
    processor.process(p);
    const float* out = processor.mapOutput();
    // convert float32 → uint8, upload to processed GL texture
    glBindTexture(GL_TEXTURE_2D, procTex);
    glTexSubImage2D(..., GL_RGBA, GL_UNSIGNED_BYTE, uint8Out.data());
    processor.unmapOutput();
    dirty = false;
  }

  ImGui::Begin("Original");   ImGui::Image((ImTextureID)origTex, panelSize); ImGui::End()
  ImGui::Begin("Processed");  ImGui::Image((ImTextureID)procTex, panelSize); ImGui::End()

  ImGui::Render()
  ImGui_ImplOpenGL3_RenderDrawData(ImGui::GetDrawData())
  glfwSwapBuffers(window)
```

---

## Step 6: Image Loading (`stb_image`)

```cpp
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

int w, h, ch;
uint8_t* raw = stbi_load(path, &w, &h, &ch, 4);  // force RGBA
std::vector<float> rgbaFloat(w * h * 4);
for (int i = 0; i < w * h * 4; ++i)
    rgbaFloat[i] = raw[i] / 255.f;
stbi_image_free(raw);
```

---

## Alignment with Referenced Vulkan Docs

| Pattern from docs | Implementation |
|---|---|
| `VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT` | ✓ `beginInfo.flags` in `process()` |
| `vkResetCommandBuffer` before re-recording | ✓ Called at top of `process()` |
| HOST→COMPUTE barrier before dispatch | ✓ `inBarrier`: `HOST_WRITE`→`SHADER_READ`, `HOST_BIT`→`COMPUTE_SHADER_BIT` |
| COMPUTE→HOST barrier after dispatch | ✓ `outBarrier`: `SHADER_WRITE`→`HOST_READ`, `COMPUTE_SHADER_BIT`→`HOST_BIT` |
| `VK_QUEUE_FAMILY_IGNORED` on single-queue barriers | ✓ Both barriers |
| Push constants via `vkCmdPushConstants` | ✓ 32-byte `ColorParams` before `vkCmdDispatch` |
| Fence for host synchronization | ✓ `vkWaitForFences` in `mapOutput()` and top of `process()` |
| Compute queue with `VK_QUEUE_COMPUTE_BIT` | ✓ `findComputeQueueFamily()` |

---

## Android Portability Rules for `ColorProcessor`

1. **No file I/O** — SPIR-V passed as `std::vector<uint32_t>` from caller. Desktop: file read. Android: `#include "color_transform_spv.h"` (generated by `xxd -i`).
2. **No `printf`/`std::cout`** — wrap logging in `VK_LOG(msg)` macro. Desktop: `fprintf(stderr, ...)`. Android: `__android_log_print(ANDROID_LOG_DEBUG, "ColorProcessor", ...)`.
3. **No Vulkan surface/swapchain extensions** in `ColorProcessor` — headless compute instance only. Surface extensions belong in the display layer.
4. **Validation layers** — `#ifndef NDEBUG` guard. Android NDK ships `libVkLayer_khronos_validation.so` in debug builds.
5. **Memory strategy** — `HOST_VISIBLE | HOST_COHERENT` works everywhere for the lab. Android production: camera input arrives as `AHardwareBuffer`; import via `VK_ANDROID_external_memory_android_hardware_buffer` to avoid the CPU copy.

---

## Verification

1. **Build:** `cmake -B build -DCMAKE_BUILD_TYPE=Debug && cmake --build build` — shader compiles to `color_transform.spv`, executable links without errors
2. **Vulkan device:** Startup log shows selected GPU name — not SwiftShader
3. **Validation clean:** No synchronization warnings or errors from `VK_LAYER_KHRONOS_validation` in debug output
4. **Display:** Window shows original (left) and processed (right) side-by-side with correct image content
5. **Identity check:** All sliders at default → processed = original (pixel-for-pixel)
6. **Brightness slider:** Drag to +0.5 → right panel brightens uniformly; left unchanged
7. **BT.709/BT.601 toggle:** Desaturate image, switch standard → saturation response changes slightly
8. **Reset button:** Returns all sliders to identity; processed matches original again
9. **Performance:** `std::chrono` around `process()` at 4K → < 10ms dispatch+readback
10. **Android compile:** `ColorProcessor.cpp` + `VulkanUtils.cpp` compile with Android NDK toolchain (`aarch64-linux-android`) without modification
