#!/usr/bin/env bash
# Run the plugin tests. No Rex server and no wt binary required.
set -eu
cd "$(dirname "$0")/.."

if command -v luajit >/dev/null 2>&1; then
  LUA=luajit
elif command -v lua5.1 >/dev/null 2>&1; then
  LUA=lua5.1
elif command -v lua >/dev/null 2>&1; then
  LUA=lua
else
  echo "need luajit or lua" >&2
  exit 1
fi

echo "using $LUA"
"$LUA" test/session_test.lua
"$LUA" test/pick_test.lua
