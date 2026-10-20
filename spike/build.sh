#!/bin/bash
# Spike: build a portable gel-server tree for one Linux target, without
# gel-pkg or metapkg. Runs as root inside a pypa manylinux_2_28 or
# musllinux_1_2 container.
#
#   /src    gel source at the tag being built, with submodules (read-write)
#   /spike  this directory
#   /out    archives and reports
#
# Usage: build.sh <target-triple>
set -euo pipefail

TARGET=$1
SRC=/src
OUT=/out
WORK=/work
DEPS=$WORK/deps
STAGE=$WORK/install
PREFIX=$STAGE/gel-server
JOBS=$(nproc)

PBS_TAG=20261013
PY_VERSION=3.12.15
OPENSSL_VERSION=3.3.7
ICU_VERSION=74.2
PROTOBUF_C_VERSION=1.5.2
PGVECTOR_VERSION=v0.7.4

mkdir -p "$OUT" "$WORK/src" "$DEPS" "$STAGE"
T0=$(date +%s)
LAST=$T0
stage() {
    local now
    now=$(date +%s)
    echo "$1 $((now - LAST))" >> "$OUT/timings.txt"
    echo "::notice::stage $1 took $((now - LAST))s (total $((now - T0))s)"
    LAST=$now
}

case "$TARGET" in
    *-linux-gnu) LIBC=gnu ;;
    *-linux-musl) LIBC=musl ;;
    *) echo "unsupported target $TARGET" >&2; exit 1 ;;
esac

# ---------------------------------------------------------------- system
if [[ $LIBC == gnu ]]; then
    dnf install -y -q libuuid-devel zlib-devel perl-IPC-Cmd perl-Time-Piece \
        bison flex git zstd file util-linux pkgconf-pkg-config
    dnf module install -y -q nodejs:20
else
    apk add --no-cache util-linux-dev zlib-dev perl linux-headers bison flex \
        git zstd file setpriv nodejs npm pkgconf
fi
npm install -g --silent yarn
git config --global --add safe.directory '*'
stage system-packages

# ---------------------------------------------------------------- rust
RUST_VERSION=$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$SRC/rust-toolchain.toml")
curl -sSf https://sh.rustup.rs | sh -s -- -y -q --profile minimal \
    --default-toolchain "$RUST_VERSION"
export PATH=$HOME/.cargo/bin:$PATH
if [[ $LIBC == musl ]]; then
    # Python extension modules are cdylibs; musl targets default to a
    # static CRT, which can't produce them.
    export RUSTFLAGS="-C target-feature=-crt-static"
fi
stage rust

# ---------------------------------------------------------------- sources
fetch() {
    curl -sSfL -o "$WORK/src/$2" "$1"
    sha256sum "$WORK/src/$2" | tee -a "$OUT/sources.sha256"
}
fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/cpython-$PY_VERSION%2B$PBS_TAG-$TARGET-install_only.tar.gz" python.tar.gz
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" openssl.tar.gz
fetch "https://github.com/unicode-org/icu/releases/download/release-${ICU_VERSION/./-}/icu4c-${ICU_VERSION/./_}-src.tgz" icu.tgz
fetch "https://github.com/protobuf-c/protobuf-c/releases/download/v$PROTOBUF_C_VERSION/protobuf-c-$PROTOBUF_C_VERSION.tar.gz" protobuf-c.tar.gz
stage fetch

# ---------------------------------------------------------------- python
mkdir -p "$PREFIX"
tar -xzf "$WORK/src/python.tar.gz" -C "$WORK"
cp -a "$WORK/python/." "$PREFIX/"
rm -rf "$WORK/python"
PY=$PREFIX/bin/python3
"$PY" -VV
stage python

# ---------------------------------------------------------------- native deps
cd "$WORK/src"
tar -xzf openssl.tar.gz
(
    cd "openssl-$OPENSSL_VERSION"
    ./Configure --prefix="$DEPS" --libdir=lib shared no-tests no-docs \
        > "$OUT/openssl-configure.log"
    make -s -j"$JOBS" > /dev/null
    make -s install_sw > /dev/null
)
stage openssl

tar -xzf icu.tgz
(
    cd icu/source
    ./runConfigureICU Linux --prefix="$DEPS" --disable-samples \
        --disable-tests --disable-extras > "$OUT/icu-configure.log"
    make -s -j"$JOBS" > /dev/null
    make -s install > /dev/null
)
stage icu

tar -xzf protobuf-c.tar.gz
(
    cd "protobuf-c-$PROTOBUF_C_VERSION"
    CFLAGS="-O2 -fPIC" ./configure --prefix="$DEPS" --disable-protoc \
        --enable-static --disable-shared > "$OUT/protobuf-c-configure.log"
    make -s -j"$JOBS" > /dev/null
    make -s install > /dev/null
)
stage protobuf-c

export PKG_CONFIG_PATH=$DEPS/lib/pkgconfig
export LD_LIBRARY_PATH=$DEPS/lib:$PREFIX/lib
export CPPFLAGS="-I$DEPS/include"
export LDFLAGS="-L$DEPS/lib"

# ---------------------------------------------------------------- postgres
mkdir -p "$WORK/pg-build"
(
    cd "$WORK/pg-build"
    "$SRC/postgres/configure" --prefix="$PREFIX" --with-icu --with-openssl \
        --with-uuid=e2fs --without-readline --without-pam \
        > "$OUT/postgres-configure.log"
    make -s -j"$JOBS" MAKELEVEL=0 > /dev/null
    make -s MAKELEVEL=0 install > /dev/null
    make -s -C contrib -j"$JOBS" MAKELEVEL=0 > /dev/null
    make -s -C contrib MAKELEVEL=0 install > /dev/null
)
PG_CONFIG=$PREFIX/bin/pg_config
stage postgres

git clone -q --depth 1 --branch "$PGVECTOR_VERSION" \
    https://github.com/pgvector/pgvector.git "$WORK/pgvector"
make -s -C "$WORK/pgvector" PG_CONFIG="$PG_CONFIG" OPT_FLAGS= > /dev/null
make -s -C "$WORK/pgvector" PG_CONFIG="$PG_CONFIG" OPT_FLAGS= install > /dev/null
make -s -C "$SRC/edb_stat_statements" PG_CONFIG="$PG_CONFIG" > /dev/null
make -s -C "$SRC/edb_stat_statements" PG_CONFIG="$PG_CONFIG" install > /dev/null
stage pg-extensions

# ---------------------------------------------------------------- server
mkdir -p "$PREFIX/share/data"
export EDGEDB_BUILD_OFFICIAL=yes
export EDGEDB_BUILD_IS_RELEASE=1
export EDGEDB_BUILD_DATE=${EDGEDB_BUILD_DATE:-$(date -u +%Y%m%d%H%M)}
EDGEDB_BUILD_TARGET=$("$PY" -c "import base64, sys; print(base64.b32encode(sys.argv[1].encode()).decode().rstrip('=').lower())" "$TARGET")
export EDGEDB_BUILD_TARGET
export EDGEDB_BUILD_PACKAGE=1
export EDGEDB_BUILD_PG_CONFIG=../../../../bin/pg_config
export EDGEDB_BUILD_SHARED_DIR=../../../../share/data
export EDGEDB_BUILD_RUNSTATEDIR=
export _EDGEDB_BUILDMETA_SHARED_DATA_DIR=$PREFIX/share/data
export _EDGEDB_BUILDMETA_PG_CONFIG_PATH=$PG_CONFIG
export EDGEDB_BUILD_OPENSSL_CFLAGS="-I$DEPS/include"
export EDGEDB_BUILD_OPENSSL_LDFLAGS="-L$DEPS/lib -lssl -lcrypto"
export EDGEDB_BUILD_PROTOBUFC_CFLAGS="-I$DEPS/include"
export EDGEDB_BUILD_PROTOBUFC_LDFLAGS="-L$DEPS/lib -lprotobuf-c"
export LDFLAGS="$LDFLAGS -L$DEPS/lib -lprotobuf-c"
export OPENSSL_DIR=$DEPS
export CI=
"$PY" -m pip install --no-cache-dir --no-warn-script-location "$SRC" \
    > "$OUT/pip-install.log" 2>&1 || { tail -200 "$OUT/pip-install.log"; exit 1; }
"$PY" -m pip freeze > "$OUT/pip-freeze.txt"
"$PY" -m pip list --format=json > "$OUT/pip-list.json"
grep -E 'Building wheel for|Created wheel for' "$OUT/pip-install.log" \
    > "$OUT/built-from-source.txt" || true
stage server

# ---------------------------------------------------------------- trim
# pip writes console scripts with absolute shebangs; keep only what the
# portable tree ships and replace the entry points with launchers.
cd "$PREFIX/bin"
for f in *; do
    case "$f" in
        python3|python3.12|postgres|initdb|pg_*|psql|ecpg|createdb|createuser|dropdb|dropuser|clusterdb|reindexdb|vacuumdb|vacuumlo|oid2name|pgbench) ;;
        *) rm -f "$f" ;;
    esac
done
for name in gel-server edgedb-server gel-load-ext edgedb-load-ext; do
    module=edb.server.main
    [[ $name == *load-ext ]] && module=edb.load_ext.main
    cat > "$name.py" <<EOF
# -*- coding: utf-8 -*-
import re
import sys
from $module import main
if __name__ == '__main__':
    sys.argv[0] = re.sub(r'(-script\.pyw|\.exe)?\$', '', sys.argv[0])
    sys.exit(main())
EOF
    install -m 0755 /spike/launcher.sh "$name"
done
rm -rf "$PREFIX/include" "$PREFIX/lib/pkgconfig" "$PREFIX/share/man" \
    "$PREFIX/share/doc"
find "$PREFIX/lib" -maxdepth 1 -name '*.a' -delete
stage trim

# ---------------------------------------------------------------- relocate
"$PY" /spike/relocate.py --prefix "$PREFIX" --libc "$LIBC" \
    --search "$DEPS/lib" --report "$OUT/linkage.txt"
stage relocate

# ---------------------------------------------------------------- bootstrap cache
unset LD_LIBRARY_PATH
useradd -m builder 2>/dev/null || adduser -D builder
CACHE=$WORK/datacache
RUNDIR=$(mktemp -d)
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
IDENTITY=$("$PY" -I - "$PREFIX" <<'PY'
import importlib.util, pathlib, sys
prefix = pathlib.Path(sys.argv[1])
path = next(prefix.glob("lib/python3.*/site-packages/edb/_buildmeta.py"))
spec = importlib.util.spec_from_file_location("_buildmeta", path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
major, minor, stage, stage_no, local = mod.VERSION
build_hash = next(p[1:] for p in local if p.startswith("s"))
names = {0: "dev", 10: "alpha", 20: "beta", 30: "rc"}
suffix = "" if stage == 40 else f"-{names[stage]}.{stage_no}"
print(f"{major}.{minor}{suffix}+{build_hash}")
PY
)
echo "identity $IDENTITY" | tee "$OUT/identity.txt"
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
