#!/bin/sh
# Runs bin/<name>.py with the bundled python3, like metapkg's pyentrypoint:
# resolve symlinks to this script, then exec python3 -I next to it.
set -e
self=$0
while [ -L "$self" ]; do
    link=$(readlink "$self")
    case "$link" in
        /*) self=$link ;;
        *) self=$(dirname "$self")/$link ;;
    esac
done
dir=$(cd "$(dirname "$self")" && pwd -P)
exec "$dir/python3" -I "$dir/$(basename "$self").py" "$@"
