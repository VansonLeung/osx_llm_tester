#!/bin/zsh
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVELOPER_DIR_PATH="$(xcode-select -p)"
cd "$PROJECT_ROOT"

# The command-line tools ship Swift Testing outside the default search paths.
if [[ "$DEVELOPER_DIR_PATH" == "/Library/Developer/CommandLineTools" ]]; then
    swift test --disable-xctest \
        -Xswiftc -F -Xswiftc "$DEVELOPER_DIR_PATH/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_PATH/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$DEVELOPER_DIR_PATH/Library/Developer/usr/lib"
else
    swift test --disable-xctest
fi
