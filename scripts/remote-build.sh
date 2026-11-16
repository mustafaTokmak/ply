#!/bin/sh
# Sync this checkout to a Mac with Xcode and run a command there (default: swift build).
# PLY_MAC is an ssh host (default: the ssh alias "homeserver"); PLY_MAC_DIR the folder there.
# Usage: scripts/remote-build.sh [command...]   e.g. scripts/remote-build.sh swift test
set -e
HOST="${PLY_MAC:-homeserver}"
DIR="${PLY_MAC_DIR:-build/ply}"
cd "$(dirname "$0")/.."
ssh -o BatchMode=yes "$HOST" "mkdir -p $DIR"
rsync -az --delete --exclude .build --exclude build --exclude dist --exclude .git ./ "$HOST:$DIR/"
if [ $# -eq 0 ]; then set -- swift build; fi
ssh -o BatchMode=yes "$HOST" "cd $DIR && $*"
