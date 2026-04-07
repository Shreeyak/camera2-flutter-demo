#!/bin/bash
# Run the color transform lab using the local venv.
# Usage: ./run.sh [image_path]
set -e
cd "$(dirname "$0")"
.venv/bin/python color_lab.py "$@"
