#!/usr/bin/env bash
# Usage: ./run_tests.sh [tests/file_spec.lua]
cd "$(dirname "$0")"
target="${1:-tests/}"
nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory $target {minimal_init = 'tests/minimal_init.lua', sequential = true}" 2>&1
