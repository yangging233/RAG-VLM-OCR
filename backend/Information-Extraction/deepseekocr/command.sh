#!/bin/bash

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

DEEPSEEK_OCR_BACKGROUND=false ./start_deepseek_ocr.sh
