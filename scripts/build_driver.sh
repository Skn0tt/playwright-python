#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Build the Playwright driver bundles from upstream source.
#
# Instead of downloading pre-built bundles from cdn.playwright.dev, this script
# clones microsoft/playwright at the tag matching the desired version and runs
# upstream's utils/build/build-playwright-driver.sh. That script cross-builds
# the per-platform bundles (playwright-<version>-<suffix>.zip) that setup.py
# embeds into the platform wheels -- the same artifacts the CDN serves.
#
# A single host builds all platform bundles at once: the upstream script
# downloads the matching Node.js binary for each target, so the host platform
# does not constrain which bundles can be produced.
#
# This is intentionally a shell script (rather than language-specific code) so
# the same build step can be shared across the Playwright language forks.
#
# Usage: scripts/build_driver.sh <version>

set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  echo "usage: scripts/build_driver.sh <version>" >&2
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DRIVER_DIR="$REPO_ROOT/driver"
SOURCE_DIR="$DRIVER_DIR/playwright-src"
PLAYWRIGHT_REPO="https://github.com/microsoft/playwright"

# Bundle suffixes produced by utils/build/build-playwright-driver.sh. Keep in
# sync with the "zip_name" values in setup.py.
SUFFIXES=(mac mac-arm64 linux linux-arm64 win32_x64 win32_arm64)

require_tools() {
  local missing=()
  local tool
  for tool in git node npm bash; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Building the Playwright driver from source requires the following tools," >&2
    echo "which were not found on PATH: ${missing[*]}." >&2
    echo "Install Node.js (with npm), git and bash, then retry. On Windows, run the" >&2
    echo "build from a bash shell (e.g. Git Bash)." >&2
    exit 1
  fi
}

cloned_version() {
  if [[ -f "$SOURCE_DIR/package.json" ]]; then
    (cd "$SOURCE_DIR" && node -p "require('./package.json').version") 2>/dev/null || true
  fi
}

clone_source() {
  # Reuse an existing checkout only if it is at the exact version we want;
  # otherwise wipe it so a stale ref can never leak into the bundles.
  if [[ -d "$SOURCE_DIR" && "$(cloned_version)" != "$VERSION" ]]; then
    rm -rf "$SOURCE_DIR"
  fi
  if [[ ! -d "$SOURCE_DIR" ]]; then
    mkdir -p "$DRIVER_DIR"
    echo "Cloning $PLAYWRIGHT_REPO at v$VERSION"
    git clone --depth 1 --branch "v$VERSION" "$PLAYWRIGHT_REPO" "$SOURCE_DIR"
  fi
  local cloned
  cloned="$(cloned_version)"
  if [[ "$cloned" != "$VERSION" ]]; then
    echo "Cloned Playwright source reports version '$cloned' but '$VERSION' was requested." >&2
    exit 1
  fi
}

build_source() {
  echo "Installing Playwright dependencies (npm ci)"
  (cd "$SOURCE_DIR" && npm ci)
  echo "Building Playwright (npm run build)"
  (cd "$SOURCE_DIR" && npm run build)
  echo "Building driver bundles"
  (cd "$SOURCE_DIR" && bash utils/build/build-playwright-driver.sh)
}

copy_bundles() {
  local output_dir="$SOURCE_DIR/utils/build/output"
  local suffix zip_name built
  for suffix in "${SUFFIXES[@]}"; do
    zip_name="playwright-$VERSION-$suffix.zip"
    built="$output_dir/$zip_name"
    if [[ ! -f "$built" ]]; then
      echo "Expected driver bundle was not produced: $built" >&2
      exit 1
    fi
    cp "$built" "$DRIVER_DIR/$zip_name"
  done
}

require_tools
clone_source
build_source
copy_bundles
