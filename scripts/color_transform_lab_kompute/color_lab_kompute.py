#!/usr/bin/env python3
"""
Color Transform Lab — Kompute/Vulkan edition.

Processes images using a Vulkan compute shader via Kompute.
Qt6 GUI shows the original (left) and processed (right) side by side.
Sliders update push constants — no shader recompilation per frame.

Usage:
    python color_lab_kompute.py [image_path]

Requires:
    pip install kompute numpy Pillow PyQt6
    glslc on PATH (from Vulkan SDK: https://vulkan.lunarg.com/
                   or: brew install shaderc)
"""

import sys
import os
import struct
import subprocess
import tempfile
import numpy as np
from PIL import Image
import kompute as kp

from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QLabel,
    QSlider, QVBoxLayout, QHBoxLayout, QSizePolicy,
)
from PyQt6.QtCore import Qt, QTimer
from PyQt6.QtGui import QImage, QPixmap, QFont

# ---------------------------------------------------------------------------
# GLSL Compute Shader
# ---------------------------------------------------------------------------

SHADER_SOURCE = """
#version 450

layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;

// Flat RGBA float32 buffers. Pixel i lives at [4i .. 4i+3].
layout(set = 0, binding = 0) buffer InputBuf  { float data[]; } inBuf;
layout(set = 0, binding = 1) buffer OutputBuf { float data[]; } outBuf;

layout(push_constant) uniform Params {
    float brightness;  // [-1,   1]   0   = identity
    float contrast;    // [0.5,  2]   1   = identity
    float saturation;  // [0,    2]   1   = identity
    float gainR;       // [0.5, 2.0]  1.0 = identity (WB gain)
    float gainG;
    float gainB;
    uint  numPixels;
} p;

void main() {
    uint idx = gl_GlobalInvocationID.x;
    if (idx >= p.numPixels) return;

    uint base = idx * 4u;
    vec3 c = vec3(inBuf.data[base], inBuf.data[base + 1u], inBuf.data[base + 2u]);

    // Contrast (midpoint pivot, gamma space)
    c = (c - 0.5) * p.contrast + 0.5;

    // Brightness (additive)
    c += p.brightness;

    // Saturation — BT.709 luma-mix (matches production Android shader)
    float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
    c = mix(vec3(luma), c, p.saturation);

    // White balance gains (multiplicative per-channel)
    c *= vec3(p.gainR, p.gainG, p.gainB);

    c = clamp(c, 0.0, 1.0);

    outBuf.data[base]      = c.r;
    outBuf.data[base + 1u] = c.g;
    outBuf.data[base + 2u] = c.b;
    outBuf.data[base + 3u] = inBuf.data[base + 3u];  // alpha passthrough
}
"""


# ---------------------------------------------------------------------------
# Shader compilation (GLSL → SPIR-V)
# ---------------------------------------------------------------------------

def _find_glslc() -> str:
    """Locate glslc binary. Checks PATH, then common Vulkan SDK locations."""
    import shutil
    path = shutil.which("glslc")
    if path:
        return path
    sdk = os.environ.get("VULKAN_SDK", "")
    if sdk:
        candidate = os.path.join(sdk, "bin", "glslc")
        if os.path.isfile(candidate):
            return candidate
    # macOS Homebrew shaderc
    for brew_prefix in ("/opt/homebrew/bin", "/usr/local/bin"):
        candidate = os.path.join(brew_prefix, "glslc")
        if os.path.isfile(candidate):
            return candidate
    raise RuntimeError(
        "glslc not found.\n"
        "Install the LunarG Vulkan SDK (https://vulkan.lunarg.com/) or:\n"
        "  brew install shaderc"
    )


def compile_glsl_to_spirv(source: str) -> bytes:
    """Compile a GLSL compute shader to SPIR-V bytes via glslc."""
    glslc = _find_glslc()
    with tempfile.TemporaryDirectory() as tmp:
        src_path = os.path.join(tmp, "shader.comp")
        spv_path = os.path.join(tmp, "shader.spv")
        with open(src_path, "w") as f:
            f.write(source)
        result = subprocess.run(
            [glslc, "-fshader-stage=compute", src_path, "-o", spv_path],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise RuntimeError(f"glslc failed:\n{result.stderr}")
        with open(spv_path, "rb") as f:
            return f.read()


# ---------------------------------------------------------------------------
# Kompute processor
# ---------------------------------------------------------------------------

class KomputeColorProcessor:
    """
    Wraps a Kompute Manager + compute pipeline for the color transform shader.
    Tensors are allocated once on init(); process() just updates push constants
    and re-dispatches — no GPU allocations per frame.
    """

    def __init__(self, img_rgba_float: np.ndarray):
        """
        img_rgba_float: float32 array, shape (H, W, 4), values in [0, 1].
        """
        assert img_rgba_float.dtype == np.float32
        assert img_rgba_float.ndim == 3 and img_rgba_float.shape[2] == 4

        self._h, self._w = img_rgba_float.shape[:2]
        self._num_pixels = self._w * self._h

        flat = img_rgba_float.ravel()  # shape (H*W*4,)

        print("Compiling compute shader…", flush=True)
        spirv_bytes = compile_glsl_to_spirv(SHADER_SOURCE)
        # Kompute expects a list of uint32 words
        num_words = len(spirv_bytes) // 4
        spirv_words = list(struct.unpack(f"{num_words}I", spirv_bytes[:num_words * 4]))

        print("Initialising Kompute (Vulkan)…", flush=True)
        self._mgr = kp.Manager()

        self._tensor_in  = self._mgr.tensor(flat.tolist())
        self._tensor_out = self._mgr.tensor([0.0] * len(flat))

        params = [self._tensor_in, self._tensor_out]

        workgroup = (int(np.ceil(self._num_pixels / 256)), 1, 1)
        # Default push constants (identity)
        default_push = [0.0, 1.0, 1.0, 1.0, 1.0, 1.0, float(self._num_pixels)]

        self._algo = self._mgr.algorithm(params, spirv_words, workgroup, [], default_push)

        # Upload input once; it doesn't change between frames in this lab.
        (self._mgr.sequence()
             .record(kp.OpTensorSyncDevice([self._tensor_in]))
             .eval())

        print("Kompute ready.", flush=True)

    def process(self,
                brightness: float,
                contrast: float,
                saturation: float,
                gain_r: float,
                gain_g: float,
                gain_b: float) -> np.ndarray:
        """
        Dispatch the shader with new push constants.
        Returns float32 RGBA array (H, W, 4).
        """
        push = [
            float(brightness),
            float(contrast),
            float(saturation),
            float(gain_r),
            float(gain_g),
            float(gain_b),
            float(self._num_pixels),
        ]

        (self._mgr.sequence()
             .record(kp.OpAlgoDispatch(self._algo, push))
             .eval()
             .record(kp.OpTensorSyncLocal([self._tensor_out]))
             .eval())

        flat = np.array(self._tensor_out.data(), dtype=np.float32)
        return flat.reshape(self._h, self._w, 4)


# ---------------------------------------------------------------------------
# Qt helpers
# ---------------------------------------------------------------------------

def rgba_float_to_qpixmap(arr: np.ndarray) -> QPixmap:
    """Convert float32 RGBA (H, W, 4) → QPixmap."""
    uint8 = np.clip(arr * 255.0, 0, 255).astype(np.uint8)
    h, w = uint8.shape[:2]
    # Qt wants RGBA big-endian (RGBA8888)
    img = QImage(uint8.tobytes(), w, h, w * 4, QImage.Format.Format_RGBA8888)
    return QPixmap.fromImage(img)


def labeled_slider(label: str, lo: float, hi: float, default: float,
                   decimals: int = 2) -> tuple["QSlider", "QLabel", QWidget]:
    """Return (slider, value_label, container_widget) for a float-valued slider."""
    SCALE = 10 ** decimals

    container = QWidget()
    row = QHBoxLayout(container)
    row.setContentsMargins(0, 0, 0, 0)

    lbl = QLabel(f"{label}:")
    lbl.setFixedWidth(100)
    row.addWidget(lbl)

    slider = QSlider(Qt.Orientation.Horizontal)
    slider.setRange(int(lo * SCALE), int(hi * SCALE))
    slider.setValue(int(default * SCALE))
    row.addWidget(slider)

    val_lbl = QLabel(f"{default:.{decimals}f}")
    val_lbl.setFixedWidth(50)
    row.addWidget(val_lbl)

    slider._scale = SCALE
    slider._decimals = decimals
    slider._val_lbl = val_lbl

    def on_change(v):
        val_lbl.setText(f"{v / SCALE:.{decimals}f}")

    slider.valueChanged.connect(on_change)

    return slider, val_lbl, container


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

class ColorLabWindow(QMainWindow):
    def __init__(self, img_path: str | None):
        super().__init__()
        self.setWindowTitle("Color Transform Lab — Kompute/Vulkan")

        # Load image
        img_path = img_path or self._default_image()
        pil_img = Image.open(img_path).convert("RGBA")
        self._orig_float = np.array(pil_img, dtype=np.float32) / 255.0

        # Kompute processor
        self._proc = KomputeColorProcessor(self._orig_float)

        # Build UI
        central = QWidget()
        self.setCentralWidget(central)
        root = QVBoxLayout(central)

        # Image display row
        img_row = QHBoxLayout()
        root.addLayout(img_row)

        self._orig_label = QLabel()
        self._orig_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._orig_label.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        img_row.addWidget(self._orig_label)

        self._proc_label = QLabel()
        self._proc_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._proc_label.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Expanding)
        img_row.addWidget(self._proc_label)

        # Captions
        cap_row = QHBoxLayout()
        root.addLayout(cap_row)
        for text in ("Original", "Processed  [Vulkan compute]"):
            cap = QLabel(text)
            cap.setAlignment(Qt.AlignmentFlag.AlignCenter)
            f = QFont()
            f.setBold(True)
            cap.setFont(f)
            cap_row.addWidget(cap)

        # Sliders
        self._sliders: dict[str, QSlider] = {}
        slider_defs = [
            # (key,         label,        lo,    hi,   default, decimals)
            ("brightness", "Brightness", -1.0,   1.0,  0.0,    2),
            ("contrast",   "Contrast",    0.5,   2.0,  1.0,    2),
            ("saturation", "Saturation",  0.0,   2.0,  1.0,    2),
            ("gain_r",     "Gain R",      0.5,   2.0,  1.0,    2),
            ("gain_g",     "Gain G",      0.5,   2.0,  1.0,    2),
            ("gain_b",     "Gain B",      0.5,   2.0,  1.0,    2),
        ]
        for key, label, lo, hi, default, dec in slider_defs:
            s, _, widget = labeled_slider(label, lo, hi, default, dec)
            self._sliders[key] = s
            s.valueChanged.connect(self._schedule_update)
            root.addWidget(widget)

        # Debounce timer: coalesce rapid slider drags into one GPU dispatch
        self._dirty = False
        self._timer = QTimer()
        self._timer.setSingleShot(True)
        self._timer.setInterval(30)  # ms
        self._timer.timeout.connect(self._refresh)

        # Initial render
        self._update_orig_display()
        self._schedule_update()

        self.resize(1400, 700)

    # ------------------------------------------------------------------

    def _default_image(self) -> str:
        """Return a small test image path, creating one if needed."""
        path = "/tmp/color_lab_test.png"
        if not os.path.exists(path):
            arr = np.zeros((256, 256, 3), dtype=np.uint8)
            for y in range(256):
                for x in range(256):
                    arr[y, x] = [x, y, (x + y) % 256]
            Image.fromarray(arr).save(path)
            print(f"Created test image: {path}")
        return path

    def _schedule_update(self):
        self._dirty = True
        if not self._timer.isActive():
            self._timer.start()

    def _float_val(self, key: str) -> float:
        s = self._sliders[key]
        return s.value() / s._scale

    def _refresh(self):
        if not self._dirty:
            return
        self._dirty = False

        result = self._proc.process(
            brightness=self._float_val("brightness"),
            contrast=self._float_val("contrast"),
            saturation=self._float_val("saturation"),
            gain_r=self._float_val("gain_r"),
            gain_g=self._float_val("gain_g"),
            gain_b=self._float_val("gain_b"),
        )
        pix = rgba_float_to_qpixmap(result)
        self._proc_label.setPixmap(
            pix.scaled(self._proc_label.size(),
                       Qt.AspectRatioMode.KeepAspectRatio,
                       Qt.TransformationMode.SmoothTransformation)
        )

    def _update_orig_display(self):
        pix = rgba_float_to_qpixmap(self._orig_float)
        self._orig_label.setPixmap(
            pix.scaled(self._orig_label.size(),
                       Qt.AspectRatioMode.KeepAspectRatio,
                       Qt.TransformationMode.SmoothTransformation)
        )

    def resizeEvent(self, event):
        super().resizeEvent(event)
        self._update_orig_display()
        self._schedule_update()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    img_path = sys.argv[1] if len(sys.argv) > 1 else None

    app = QApplication(sys.argv)
    app.setApplicationName("Color Lab Kompute")

    win = ColorLabWindow(img_path)
    win.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
