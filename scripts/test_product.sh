#!/bin/bash
# Offline product tests. Generated files stay outside the checkout by default.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
scratch="${QUAD_MONITOR_TEST_BUILD_DIR:-}"
owned=0
if [ -z "$scratch" ]; then
  scratch="$(mktemp -d /tmp/quad-product-tests.XXXXXX)"
  owned=1
fi
trap 'if [ "$owned" -eq 1 ]; then rm -rf "$scratch"; fi' EXIT
mkdir -p "$scratch"
cd "$root"
swift test --package-path App --scratch-path "$scratch/swift"
cmake -S windows -B "$scratch/core" -DCMAKE_BUILD_TYPE=Release
cmake --build "$scratch/core"
ctest --test-dir "$scratch/core" --output-on-failure
uv run --no-project --with numpy --with pillow python -B -m unittest discover -s tests -v
