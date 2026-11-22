#!/bin/sh
set -eu
# Absolute source paths make Swift's #filePath independent of the caller's cwd.
tool_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_dir=$(CDPATH= cd -- "$tool_dir/../.." && pwd)
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/palettecheck.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM
swiftc "$repo_dir/Shared/ArtworkPalette.swift" "$tool_dir/main.swift" -o "$build_dir/palettecheck"
"$build_dir/palettecheck"
