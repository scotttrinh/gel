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

source /spike/env.sh "$1"

# ---------------------------------------------------------------- system
if [[ $LIBC == gnu ]]; then
    dnf install -y -q libuuid-devel zlib-devel perl-IPC-Cmd perl-Time-Piece \
        bison flex git zstd file util-linux pkgconf-pkg-config
    dnf module install -y -q nodejs:20
else
    apk add --no-cache util-linux-dev zlib-dev perl linux-headers bison flex \
        git zstd file setpriv nodejs npm pkgconf cmake
fi
npm install -g --silent yarn
# The build exports LD_LIBRARY_PATH for our own OpenSSL, which the distro's
# node can't run against; give node a clean environment.
NODE=$(command -v node)
printf '#!/bin/sh\nexec env -u LD_LIBRARY_PATH %s "$@"\n' "$NODE" > /usr/local/bin/node
chmod +x /usr/local/bin/node
hash -r
# Old sdists (e.g. sentencepiece) declare cmake_minimum_required < 3.5,
# which CMake 4 rejects.
export CMAKE_POLICY_VERSION_MINIMUM=3.5
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
    curl -sSfL --retry 5 --retry-all-errors -o "$WORK/src/$2" "$1"
    sha256sum "$WORK/src/$2" | tee -a "$OUT/sources.sha256"
}
fetch "https://github.com/astral-sh/python-build-standalone/releases/download/$PBS_TAG/cpython-$PY_VERSION%2B$PBS_TAG-$TARGET-install_only_stripped.tar.gz" python.tar.gz
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
"$PY" -I /spike/patch_sysconfig.py "$PREFIX"
"$PY" -I -c 'import sysconfig; print(sysconfig.get_config_var("CC"), "|", sysconfig.get_config_var("LDSHARED"))'
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

if [[ -n ${SPIKE_SNAPSHOT:-} ]]; then
    rm -rf "$WORK/snapshot"
    cp -a "$PREFIX" "$WORK/snapshot"
fi
bash /spike/finish.sh "$TARGET"
