#!/usr/bin/env bash
# Build SM8750 kernel inside a Fedora 43 container with GCC 15
exec "$(dirname "${BASH_SOURCE[0]}")/../kernel-common/build-gcc15.sh" sm8750 "$@"
