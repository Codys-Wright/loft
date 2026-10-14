#!/usr/bin/env bash
# Rebuilds every shell window (bar, dock, panels) — what Mod+Shift+R does,
# but harder: a full reload instead of reusing the windows.
#
# @raycast.schemaVersion 1
# @raycast.title Restart Shell
# @raycast.mode silent
# @raycast.icon view-refresh
# @raycast.packageName Loft
# @raycast.description Reload the bar, dock and panels
# @keyword reload shell, quickshell
set -euo pipefail

quickshell ipc --any-display ${LOFT_SHELL_PATH:+--path "$LOFT_SHELL_PATH"} call shell hardReload
