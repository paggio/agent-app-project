#!/usr/bin/env bash
# PostToolUse hook — formats what was just written. Never blocks.
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || echo .)}" || exit 0
grep -qE '^fmt:' Makefile 2>/dev/null && make -s fmt >/dev/null 2>&1
exit 0
