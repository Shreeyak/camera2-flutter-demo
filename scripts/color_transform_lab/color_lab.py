#!/usr/bin/env python3
"""
Color Transform Lab — interactive OpenGL-based color adjustment viewer.

The fragment shader implements the exact same math as the production pipeline:
  - Contrast:    pivot around 0.5 on RGB
  - Brightness:  additive shift on RGB
  - Saturation:  luma-mix (BT.709 or BT.601 weights, selectable)
  - Black bal.:  per-channel multiplicative gain (R, G, B)

The left half of the window shows the original image; the right half shows
the processed result. Both are rendered by the GPU using GLSL shaders — only
the uniforms differ (identity values on the left, slider values on the right).

Usage:
  python color_lab.py [image_path]
  python color_lab.py                # opens a file dialog
"""

import sys
import ctypes
import numpy as np
from pathlib import Path

from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QHBoxLayout, QVBoxLayout,
    QLabel, QSlider, QPushButton, QFileDialog, QGroupBox, QComboBox,
)
from PyQt6.QtOpenGLWidgets import QOpenGLWidget
from PyQt6.QtGui import QSurfaceFormat, QImage
from PyQt6.QtCore import Qt, QTimer

from OpenGL.GL import (
    glViewport, glClearColor, glClear, GL_COLOR_BUFFER_BIT,
    glGenTextures, glBindTexture, GL_TEXTURE_2D, glTexParameteri,
    GL_TEXTURE_MIN_FILTER, GL_TEXTURE_MAG_FILTER, GL_LINEAR,
    GL_TEXTURE_WRAP_S, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE,
    glTexImage2D, GL_RGB, GL_UNSIGNED_BYTE,
    glGenVertexArrays, glBindVertexArray,
    glGenBuffers, glBindBuffer, GL_ARRAY_BUFFER,
    glBufferData, GL_STATIC_DRAW,
    glEnableVertexAttribArray, glVertexAttribPointer, GL_FLOAT,
    glCreateProgram, glCreateShader, GL_VERTEX_SHADER, GL_FRAGMENT_SHADER,
    glShaderSource, glCompileShader, glGetShaderiv, GL_COMPILE_STATUS,
    glGetShaderInfoLog, glAttachShader, glLinkProgram,
    glGetProgramiv, GL_LINK_STATUS, glGetProgramInfoLog,
    glUseProgram, glGetUniformLocation,
    glUniform1i, glUniform1f, glUniform3f,
    glActiveTexture, GL_TEXTURE0,
    glDrawArrays, GL_TRIANGLE_STRIP,
    glDeleteShader, glPixelStorei, GL_UNPACK_ALIGNMENT,
)
from PIL import Image

# ---------------------------------------------------------------------------
# Shaders
# ---------------------------------------------------------------------------

VERT_SRC = """
#version 410 core
in vec2 aPos;
in vec2 aTexCoord;
out vec2 vTexCoord;
void main() {
    gl_Position = vec4(aPos, 0.0, 1.0);
    vTexCoord   = aTexCoord;
}
"""

# Identity — left panel (original)
FRAG_IDENTITY = """
#version 410 core
uniform sampler2D uTexture;
in  vec2 vTexCoord;
out vec4 fragColor;
void main() {
    fragColor = texture(uTexture, vTexCoord);
}
"""

# Full processing — right panel (matches production pipeline shader math)
FRAG_PROCESS = """
#version 410 core
uniform sampler2D uTexture;
uniform float uBrightness;    // -1..1,  0   = identity
uniform float uContrast;      // 0.5..2, 1.0 = identity
uniform float uSaturation;    // 0..2,   1.0 = identity
uniform float uGainR;         // 0.5..2, 1.0 = identity
uniform float uGainG;
uniform float uGainB;
uniform vec3  uLumaWeights;   // BT.709 or BT.601

in  vec2 vTexCoord;
out vec4 fragColor;

void main() {
    vec3 c = texture(uTexture, vTexCoord).rgb;

    // Contrast: scale around midpoint
    c = (c - 0.5) * uContrast + 0.5;

    // Brightness: additive
    c += uBrightness;

    // Saturation: luma-mix
    float luma = dot(c, uLumaWeights);
    c = mix(vec3(luma), c, uSaturation);

    // Per-channel gain (black balance)
    c *= vec3(uGainR, uGainG, uGainB);

    fragColor = vec4(clamp(c, 0.0, 1.0), 1.0);
}
"""

BT709 = (0.2126, 0.7152, 0.0722)
BT601 = (0.299,  0.587,  0.114)

# ---------------------------------------------------------------------------
# OpenGL helpers
# ---------------------------------------------------------------------------

def compile_shader(src: str, kind: int) -> int:
    shader = glCreateShader(kind)
    glShaderSource(shader, src)
    glCompileShader(shader)
    if not glGetShaderiv(shader, GL_COMPILE_STATUS):
        raise RuntimeError(glGetShaderInfoLog(shader).decode())
    return shader

def link_program(vert_src: str, frag_src: str) -> int:
    vs = compile_shader(vert_src, GL_VERTEX_SHADER)
    fs = compile_shader(frag_src, GL_FRAGMENT_SHADER)
    prog = glCreateProgram()
    glAttachShader(prog, vs)
    glAttachShader(prog, fs)
    glLinkProgram(prog)
    glDeleteShader(vs)
    glDeleteShader(fs)
    if not glGetProgramiv(prog, GL_LINK_STATUS):
        raise RuntimeError(glGetProgramInfoLog(prog).decode())
    return prog

# ---------------------------------------------------------------------------
# OpenGL widget
# ---------------------------------------------------------------------------

# Fullscreen quad: two triangles as a strip.
# aPos: NDC xy.  aTexCoord: [0,1]^2 with V flipped (GL origin is bottom-left).
#
#   (-1, 1) ──── (1, 1)      (0,0) ──── (1,0)
#      │      ╲     │           │     ╲    │
#   (-1,-1) ──── (1,-1)      (0,1) ──── (1,1)
#
_QUAD = np.array([
    # x      y     u     v
    -1.0,  1.0,  0.0, 0.0,
    -1.0, -1.0,  0.0, 1.0,
     1.0,  1.0,  1.0, 0.0,
     1.0, -1.0,  1.0, 1.0,
], dtype=np.float32)


class ImageGLWidget(QOpenGLWidget):
    def __init__(self, parent=None):
        super().__init__(parent)
        self._image_rgb: np.ndarray | None = None   # H×W×3 uint8
        self._texture = 0
        self._prog_identity = 0
        self._prog_process = 0
        self._vao = 0
        self._vbo = 0

        # Processing params (updated by sliders)
        self.brightness = 0.0
        self.contrast   = 1.0
        self.saturation = 1.0
        self.gain_r     = 1.0
        self.gain_g     = 1.0
        self.gain_b     = 1.0
        self.luma       = BT709

        # Cached uniform locations for processing program
        self._uloc: dict[str, int] = {}

    # -- Public API ----------------------------------------------------------

    def load_image(self, rgb_u8: np.ndarray):
        """Upload a new H×W×3 uint8 RGB image. Must be called from GL thread."""
        self._image_rgb = rgb_u8
        if self._texture:
            self.makeCurrent()
            self._upload_texture()
            self.update()

    def set_params(self, brightness, contrast, saturation,
                   gain_r, gain_g, gain_b, luma):
        self.brightness = brightness
        self.contrast   = contrast
        self.saturation = saturation
        self.gain_r     = gain_r
        self.gain_g     = gain_g
        self.gain_b     = gain_b
        self.luma       = luma
        self.update()

    # -- GL lifecycle --------------------------------------------------------

    def initializeGL(self):
        # Clear any stale GL errors left by context creation before making
        # any calls — PyOpenGL_accelerate will raise on the first call otherwise.
        from OpenGL.GL import glGetError
        while glGetError() != 0:
            pass

        glClearColor(0.12, 0.12, 0.12, 1.0)

        # Compile shaders
        self._prog_identity = link_program(VERT_SRC, FRAG_IDENTITY)
        self._prog_process  = link_program(VERT_SRC, FRAG_PROCESS)

        # Cache uniform locations for processing program
        for name in ("uTexture", "uBrightness", "uContrast", "uSaturation",
                     "uGainR", "uGainG", "uGainB", "uLumaWeights"):
            self._uloc[name] = glGetUniformLocation(self._prog_process, name)

        # VAO + VBO
        self._vao = glGenVertexArrays(1)
        self._vbo = glGenBuffers(1)
        glBindVertexArray(self._vao)
        glBindBuffer(GL_ARRAY_BUFFER, self._vbo)
        glBufferData(GL_ARRAY_BUFFER, _QUAD.nbytes, _QUAD, GL_STATIC_DRAW)

        stride = 4 * _QUAD.itemsize  # 4 floats per vertex

        for prog in (self._prog_identity, self._prog_process):
            glUseProgram(prog)
            pos_loc = 0   # layout location 0 would be nice but we use name
            glVertexAttribPointer(0, 2, GL_FLOAT, False, stride, ctypes.c_void_p(0))
            glEnableVertexAttribArray(0)
            glVertexAttribPointer(1, 2, GL_FLOAT, False, stride,
                                  ctypes.c_void_p(2 * _QUAD.itemsize))
            glEnableVertexAttribArray(1)

        glBindVertexArray(0)

        # Texture
        self._texture = glGenTextures(1)
        glBindTexture(GL_TEXTURE_2D, self._texture)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)

        if self._image_rgb is not None:
            self._upload_texture()

    def resizeGL(self, w, h):
        pass  # viewport set in paintGL per-panel

    def paintGL(self):
        w, h = self.width(), self.height()
        glClear(GL_COLOR_BUFFER_BIT)

        if not self._texture or self._image_rgb is None:
            return

        glActiveTexture(GL_TEXTURE0)
        glBindTexture(GL_TEXTURE_2D, self._texture)
        glBindVertexArray(self._vao)

        half = w // 2

        # Left panel: original (identity shader)
        glViewport(0, 0, half, h)
        glUseProgram(self._prog_identity)
        glUniform1i(glGetUniformLocation(self._prog_identity, "uTexture"), 0)
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)

        # Right panel: processed
        glViewport(half, 0, w - half, h)
        glUseProgram(self._prog_process)
        glUniform1i(self._uloc["uTexture"],    0)
        glUniform1f(self._uloc["uBrightness"], self.brightness)
        glUniform1f(self._uloc["uContrast"],   self.contrast)
        glUniform1f(self._uloc["uSaturation"], self.saturation)
        glUniform1f(self._uloc["uGainR"],      self.gain_r)
        glUniform1f(self._uloc["uGainG"],      self.gain_g)
        glUniform1f(self._uloc["uGainB"],      self.gain_b)
        glUniform3f(self._uloc["uLumaWeights"], *self.luma)
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4)

        glBindVertexArray(0)

    def _upload_texture(self):
        img = self._image_rgb
        h, w = img.shape[:2]
        glPixelStorei(GL_UNPACK_ALIGNMENT, 1)
        glBindTexture(GL_TEXTURE_2D, self._texture)
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGB, w, h, 0,
                     GL_RGB, GL_UNSIGNED_BYTE, img.tobytes())


# ---------------------------------------------------------------------------
# Slider widget
# ---------------------------------------------------------------------------

class SliderRow(QWidget):
    def __init__(self, label, lo, hi, default, scale, fmt="{:.2f}", parent=None):
        super().__init__(parent)
        self._scale = scale
        self._fmt = fmt
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lbl = QLabel(label)
        lbl.setFixedWidth(110)
        self.slider = QSlider(Qt.Orientation.Horizontal)
        self.slider.setRange(lo, hi)
        self.slider.setValue(default)
        self.val_lbl = QLabel(fmt.format(default * scale))
        self.val_lbl.setFixedWidth(50)
        self.slider.valueChanged.connect(
            lambda v: self.val_lbl.setText(fmt.format(v * scale)))
        lay.addWidget(lbl)
        lay.addWidget(self.slider)
        lay.addWidget(self.val_lbl)

    def value(self) -> float:
        return self.slider.value() * self._scale

    def reset(self, v: int):
        self.slider.setValue(v)


# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

class MainWindow(QMainWindow):
    def __init__(self, image_path: str | None = None):
        super().__init__()
        self.setWindowTitle("Color Transform Lab — GPU")
        self._pending = False
        self._build_ui()
        self.resize(1400, 720)
        if image_path:
            QTimer.singleShot(100, lambda: self._load(image_path))
        else:
            QTimer.singleShot(100, self._open_file)

    def _build_ui(self):
        central = QWidget()
        self.setCentralWidget(central)
        root = QHBoxLayout(central)

        # ── Controls ────────────────────────────────────────────────────────
        ctrl = QWidget()
        ctrl.setFixedWidth(370)
        cv = QVBoxLayout(ctrl)
        cv.setAlignment(Qt.AlignmentFlag.AlignTop)

        btn = QPushButton("Open Image…")
        btn.clicked.connect(self._open_file)
        cv.addWidget(btn)

        # Luma standard
        gb = QGroupBox("Luma weights")
        gl = QHBoxLayout(gb)
        self.luma_combo = QComboBox()
        self.luma_combo.addItems(["BT.709 (HD / default)", "BT.601 (SD)"])
        self.luma_combo.currentIndexChanged.connect(self._push)
        gl.addWidget(self.luma_combo)
        cv.addWidget(gb)

        # Tone
        gb2 = QGroupBox("Tone  (RGB, applied in shader order: contrast → brightness)")
        gl2 = QVBoxLayout(gb2)
        self.sl_brightness = SliderRow("Brightness", -100, 100, 0,    0.01)
        self.sl_contrast   = SliderRow("Contrast",    50, 200, 100, 0.01)
        for s in (self.sl_brightness, self.sl_contrast):
            s.slider.valueChanged.connect(self._schedule)
            gl2.addWidget(s)
        cv.addWidget(gb2)

        # Saturation
        gb3 = QGroupBox("Saturation  (luma-mix)")
        gl3 = QVBoxLayout(gb3)
        self.sl_sat = SliderRow("Saturation", 0, 200, 100, 0.01)
        self.sl_sat.slider.valueChanged.connect(self._schedule)
        gl3.addWidget(self.sl_sat)
        cv.addWidget(gb3)

        # Black balance
        gb4 = QGroupBox("Black Balance  (per-channel gain)")
        gl4 = QVBoxLayout(gb4)
        self.sl_gr = SliderRow("Gain R", 50, 200, 100, 0.01)
        self.sl_gg = SliderRow("Gain G", 50, 200, 100, 0.01)
        self.sl_gb = SliderRow("Gain B", 50, 200, 100, 0.01)
        for s in (self.sl_gr, self.sl_gg, self.sl_gb):
            s.slider.valueChanged.connect(self._schedule)
            gl4.addWidget(s)
        cv.addWidget(gb4)

        rst = QPushButton("Reset All")
        rst.clicked.connect(self._reset)
        cv.addWidget(rst)

        self.status = QLabel("No image loaded")
        self.status.setWordWrap(True)
        cv.addWidget(self.status)
        cv.addStretch()

        # ── GL canvas ───────────────────────────────────────────────────────
        canvas_wrap = QWidget()
        canvas_lay = QVBoxLayout(canvas_wrap)
        canvas_lay.setContentsMargins(0, 0, 0, 0)

        header = QWidget()
        hl = QHBoxLayout(header)
        hl.setContentsMargins(0, 0, 0, 4)
        lbl_orig = QLabel("Original")
        lbl_orig.setAlignment(Qt.AlignmentFlag.AlignCenter)
        lbl_proc = QLabel("Processed")
        lbl_proc.setAlignment(Qt.AlignmentFlag.AlignCenter)
        hl.addWidget(lbl_orig, 1)
        hl.addWidget(lbl_proc, 1)
        canvas_lay.addWidget(header)

        self.gl_widget = ImageGLWidget()
        canvas_lay.addWidget(self.gl_widget, stretch=1)

        root.addWidget(ctrl)
        root.addWidget(canvas_wrap, stretch=1)

    # ── File loading ────────────────────────────────────────────────────────

    def _open_file(self):
        path, _ = QFileDialog.getOpenFileName(
            self, "Open Image", str(Path.home()),
            "Images (*.png *.jpg *.jpeg *.tiff *.bmp *.webp)")
        if path:
            self._load(path)

    def _load(self, path: str):
        img = Image.open(path).convert("RGB")
        arr = np.array(img, dtype=np.uint8)
        self.gl_widget.makeCurrent()
        self.gl_widget.load_image(arr)
        self.gl_widget.doneCurrent()
        self.setWindowTitle(f"Color Transform Lab — GPU — {Path(path).name}")
        self.status.setText(f"{Path(path).name}\n{arr.shape[1]}×{arr.shape[0]} px")
        self._push()

    # ── Slider → GL ─────────────────────────────────────────────────────────

    def _schedule(self):
        if not self._pending:
            self._pending = True
            QTimer.singleShot(16, self._do_push)

    def _do_push(self):
        self._pending = False
        self._push()

    def _push(self):
        luma = BT709 if self.luma_combo.currentIndex() == 0 else BT601
        self.gl_widget.set_params(
            brightness=self.sl_brightness.value(),
            contrast=self.sl_contrast.value(),
            saturation=self.sl_sat.value(),
            gain_r=self.sl_gr.value(),
            gain_g=self.sl_gg.value(),
            gain_b=self.sl_gb.value(),
            luma=luma,
        )

    def _reset(self):
        defaults = [
            (self.sl_brightness, 0),
            (self.sl_contrast,   100),
            (self.sl_sat,        100),
            (self.sl_gr,         100),
            (self.sl_gg,         100),
            (self.sl_gb,         100),
        ]
        for sl, d in defaults:
            sl.reset(d)


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    # QSurfaceFormat MUST be set before QApplication is created.
    # macOS supports up to OpenGL 4.1 core; 4.1 core is the safest request.
    fmt = QSurfaceFormat()
    fmt.setVersion(4, 1)
    fmt.setProfile(QSurfaceFormat.OpenGLContextProfile.CoreProfile)
    QSurfaceFormat.setDefaultFormat(fmt)

    app = QApplication(sys.argv)
    path = sys.argv[1] if len(sys.argv) > 1 else None
    win = MainWindow(path)
    win.show()
    sys.exit(app.exec())
