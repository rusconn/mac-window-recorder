#!/bin/bash
# Copyright (C) 2026 rusconn
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <https://www.gnu.org/licenses/>.

set -euo pipefail

FFMPEG_PREFIX=$(brew --prefix ffmpeg)
VENDOR_LIB="vendor/ffmpeg/lib"
VISITED=$(mktemp)

cleanup() { rm -f "$VISITED"; }
trap cleanup EXIT

realpath_mac() {
    cd "$(dirname "$1")" && echo "$(pwd)/$(basename "$1")"
}

echo "==> Discovering dependencies..."

# Seed with the 4 target libraries (resolve to real files)
for lib in libavcodec libavformat libavutil libswscale; do
    real=$(realpath_mac "$FFMPEG_PREFIX/lib/$lib.dylib")
    echo "$real" >> "$VISITED"
done

# Iteratively discover transitive deps
changed=1
while [ "$changed" -eq 1 ]; do
    changed=0
    while IFS= read -r dylib; do
        [ -z "$dylib" ] || [ ! -f "$dylib" ] && continue
        otool -L "$dylib" 2>/dev/null | awk '/\/opt\/homebrew\// {print $1}' | while IFS= read -r ref; do
            ref_real=$(realpath_mac "$ref" 2>/dev/null || true)
            [ -z "$ref_real" ] || [ ! -f "$ref_real" ] && continue
            if ! grep -qF "$ref_real" "$VISITED" 2>/dev/null; then
                echo "$ref_real" >> "$VISITED"
                echo "  + $(basename "$ref_real")"
            fi
        done
    done < "$VISITED"
    # Check if new entries were added by comparing line counts
    new_count=$(wc -l < "$VISITED")
    # Re-count unique
    unique_count=$(sort -u "$VISITED" | wc -l)
    if [ "$new_count" -ne "$unique_count" ]; then
        sort -u "$VISITED" -o "$VISITED"
        changed=1
    fi
done

sort -u "$VISITED" -o "$VISITED"
DEP_COUNT=$(wc -l < "$VISITED")
echo "Found $DEP_COUNT dylibs"

echo "==> Creating vendor directories..."
rm -rf "$VENDOR_LIB"
mkdir -p "$VENDOR_LIB"

# Step 1: Copy real files
echo "==> Copying dylibs..."
while IFS= read -r dep; do
    [ -z "$dep" ] || [ ! -f "$dep" ] && continue
    cp -f "$dep" "$VENDOR_LIB/"
    chmod 644 "$VENDOR_LIB/$(basename "$dep")"
    echo "  $(basename "$dep")"
done < "$VISITED"

# Step 2: Recreate symlinks
echo "==> Creating symlinks..."
while IFS= read -r dep; do
    [ -z "$dep" ] || [ ! -f "$dep" ] && continue
    real_name=$(basename "$dep")
    dep_dir=$(dirname "$dep")
    
    for link in "$dep_dir"/*.dylib; do
        [ -L "$link" ] || continue
        link_name=$(basename "$link")
        [ "$link_name" = "$real_name" ] && continue
        
        target=$(readlink "$link")
        if [ "$target" = "$real_name" ]; then
            ln -sf "$real_name" "$VENDOR_LIB/$link_name"
        fi
    done
done < "$VISITED"

# Step 3: Fix install names
echo "==> Fixing dylib paths..."
for file in "$VENDOR_LIB"/*.dylib; do
    [ -L "$file" ] || [ ! -f "$file" ] && continue
    filename=$(basename "$file")
    
    chmod 644 "$file"
    install_name_tool -id "@rpath/$filename" "$file" 2>/dev/null || true
    
    refs=$(otool -L "$file" 2>/dev/null | awk '/\/opt\/homebrew\// {print $1}' || true)
    for ref in $refs; do
        ref_base=$(basename "$ref")
        [ "$ref_base" = "$filename" ] && continue
        if [ -f "$VENDOR_LIB/$ref_base" ]; then
            install_name_tool -change "$ref" "@rpath/$ref_base" "$file" 2>/dev/null || true
        fi
    done
done

# Step 4: Re-sign all dylibs (install_name_tool invalidates signatures)
echo "==> Re-signing dylibs..."
for file in "$VENDOR_LIB"/*.dylib; do
    [ -L "$file" ] || [ ! -f "$file" ] && continue
    codesign --force --sign - "$file" 2>/dev/null || true
done

echo ""
echo "==> Verifying..."
bad=""
for f in "$VENDOR_LIB"/*.dylib; do
    [ -L "$f" ] || [ ! -f "$f" ] && continue
    found=$(otool -L "$f" 2>/dev/null | grep '/opt/homebrew/' || true)
    bad="$bad$found"
done

if [ -n "$bad" ]; then
    echo "WARNING: remaining Homebrew refs:"
    echo "$bad"
else
    echo "OK: All Homebrew references replaced."
fi

echo ""
echo "==> Result:"
ls "$VENDOR_LIB/"
echo ""
du -sh "$VENDOR_LIB/"
