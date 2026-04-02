#!/bin/bash
# Run the Kompute/Vulkan color transform lab using the local venv.
# Usage: ./run.sh [image_path]
#
# First-time setup:
#   python3 -m venv .venv
#   .venv/bin/pip install -r requirements.txt
#
# Also requires glslc on PATH for shader compilation:
#   brew install shaderc          # macOS
#   # or install the LunarG Vulkan SDK from https://vulkan.lunarg.com/
set -e
cd "$(dirname "$0")"
.venv/bin/python color_lab_kompute.py "$@"
