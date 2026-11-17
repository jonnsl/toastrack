#!/bin/sh
# Build the daemon with cargo and copy it where meson expects it.
# Usage: cargo-build.sh CARGO MANIFEST_DIR TARGET_DIR PROFILE OUTPUT
set -eu

cargo=$1
manifest_dir=$2
target_dir=$3
profile=$4
output=$5

if [ "$profile" = release ]; then
    "$cargo" build --manifest-path "$manifest_dir/Cargo.toml" --target-dir "$target_dir" --release --locked
else
    "$cargo" build --manifest-path "$manifest_dir/Cargo.toml" --target-dir "$target_dir" --locked
fi
# Renamed into place, since the old binary may be running
cp "$target_dir/$profile/toastrack-daemon" "$output.tmp"
mv -f "$output.tmp" "$output"
