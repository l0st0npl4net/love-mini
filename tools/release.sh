#!/bin/sh
# The files of a love-mini release on GitHub (tag v<version>), which Port Store installs
# (its recipes/ports/love-mini.json): builds the package and says what to upload.
#   tools/release.sh
# out/love-mini-<version>.zip and out/openal-soft-1.21.1-source.tar.gz (OpenAL Soft is
# LGPL: its source goes with every release).
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
version=$(cat "$here/VERSION")
"$here/build/mini2d.sh" >/dev/null
"$here/build/package.sh" >/dev/null
"$here/tools/neoncheck.sh"
echo "release v$version:"
echo "  $here/out/love-mini-$version.zip"
echo "  $here/out/openal-soft-1.21.1-source.tar.gz"
echo "with GitHub's CLI:"
echo "  gh release create v$version out/love-mini-$version.zip out/openal-soft-1.21.1-source.tar.gz --title \"love-mini $version\" --notes-file docs/releases/v$version.md"
