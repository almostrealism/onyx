#!/bin/bash
# Build and run Onyx
set -e
swift build
.build/debug/Onyx
