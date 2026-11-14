#!/usr/bin/env bash
# Point git at the versioned hooks in .githooks/ (pre-push: gitleaks over the
# pushed commits + scripts/run_tests.sh). Run once per checkout, worktrees too.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
chmod +x .githooks/*
git config core.hooksPath .githooks
echo "hooks installed: $(ls .githooks | tr '\n' ' ')"
