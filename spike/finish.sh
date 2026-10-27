#!/bin/bash
# Spike: trim, relocate, bootstrap and package the tree build.sh built.
# build.sh runs this after the server stage.  With SPIKE_RESUME=1 it first
# restores the tree from the snapshot local.sh has build.sh take, so these
# stages can be redone without rebuilding everything before them.
#
# Usage: finish.sh <target-triple>
set -euo pipefail
source /spike/env.sh "$1"
PY=$PREFIX/bin/python3

if [[ -n ${SPIKE_RESUME:-} ]]; then
    rm -rf "$STAGE" "$OUT"/gel-server-*
    mkdir -p "$STAGE"
    cp -a "$WORK/snapshot" "$PREFIX"
fi

# ---------------------------------------------------------------- trim
# pip writes console scripts with absolute shebangs; keep only what the
# portable tree ships and replace the entry points with launchers.
bash /spike/trim.sh "$PREFIX" "$SRC" /spike
stage trim

# ---------------------------------------------------------------- relocate
"$PY" /spike/relocate.py --prefix "$PREFIX" --libc "$LIBC" \
    --search "$DEPS/lib" --report "$OUT/linkage.txt"
stage relocate

# ---------------------------------------------------------------- bootstrap cache
unset LD_LIBRARY_PATH
id builder >/dev/null 2>&1 || useradd -m builder 2>/dev/null || adduser -D builder
CACHE=$WORK/datacache
RUNDIR=$(mktemp -d)
rm -rf "$CACHE"
mkdir -p "$CACHE"
chown builder "$CACHE" "$RUNDIR"
setpriv --reuid=builder --regid="$(id -g builder)" --init-groups \
    env HOME=/tmp PG_DISABLE_PS_DISPLAY=1 _EDGEDB_WRITE_DATA_CACHE_TO="$CACHE" \
    "$PREFIX/bin/gel-server" --data-dir="$RUNDIR/data" --runstate-dir="$RUNDIR" \
    --bootstrap-only > "$OUT/bootstrap.log" 2>&1 \
    || { tail -100 "$OUT/bootstrap.log"; exit 1; }
cp "$CACHE"/* "$PREFIX/share/data/"
rm -rf "$RUNDIR"
stage bootstrap-cache

# ---------------------------------------------------------------- package
IDENTITY=$("$PY" -I /spike/identity.py "$PREFIX")
echo "identity $IDENTITY" | tee "$OUT/identity.txt"
# Installed files must be readable by whoever runs the server.
chmod -R u+rwX,go+rX,go-w "$PREFIX"
# gel CLI releases up to at least 7.10.2 resolve hard-link targets without
# stripping the archive's top directory, so ship copies instead (PostgreSQL
# installs its timezone aliases as hard links).
find "$PREFIX" -type f -links +1 -exec sh -c \
    'for f; do cp -p "$f" "$f.tmp" && mv "$f.tmp" "$f"; done' sh {} +
mv "$PREFIX" "$STAGE/gel-server-$IDENTITY"
cd "$STAGE"
tar -cf - "gel-server-$IDENTITY" | zstd -q -19 -T0 -o "$OUT/gel-server-$TARGET.tar.zst"
tar -czf "$OUT/gel-server-$TARGET.tar.gz" "gel-server-$IDENTITY"
tar -tf "$OUT/gel-server-$TARGET.tar.gz" | sed "s|^gel-server-$IDENTITY/||" | sort > "$OUT/files.txt"
du -sh "gel-server-$IDENTITY" > "$OUT/size.txt"
ls -l "$OUT"/gel-server-* >> "$OUT/size.txt"
du -sh "$WORK" >> "$OUT/size.txt"
df -h / >> "$OUT/size.txt"
stage package
