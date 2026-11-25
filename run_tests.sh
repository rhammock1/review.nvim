#!/usr/bin/env bash
# Usage: ./run_tests.sh [tests/file_spec.lua]
# Plugins come from $REVIEW_TEST_DEPS, else lazy.nvim's directory.
cd "$(dirname "$0")"
target="${1:-tests/}"
out=$(nvim --headless --noplugin -u tests/minimal_init.lua \
  -c "PlenaryBustedDirectory $target {minimal_init = 'tests/minimal_init.lua', sequential = true}" 2>&1)
code=$?
printf '%s\n' "$out"
# A spec file with a syntax error is reported but doesn't fail the run.
if grep -q "FAILED TO LOAD" <<<"$out"; then
  echo "A spec file failed to load." >&2
  exit 1
fi
exit $code
