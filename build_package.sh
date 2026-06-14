#!/usr/bin/env bash
# Canonical location is scripts/build_package.sh — this wrapper delegates there.
exec "$(dirname "${BASH_SOURCE[0]}")/scripts/build_package.sh" "$@"
