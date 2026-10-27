# Spike: settings shared by build.sh and finish.sh.  Source with the
# target triple as the argument.
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

