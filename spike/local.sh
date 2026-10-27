#!/bin/bash
# Spike: run the Linux jobs of spike-portable.yml locally, in the same
# containers with the same scripts (Docker or OrbStack; x86_64 targets run
# under emulation on Apple silicon).
#
#   local.sh build <target>        fresh container and /work; full build.sh
#   local.sh finish <target>       redo trim..package in the build's
#                                  container, from the post-server snapshot
#   local.sh smoke <target> [image...]
#   local.sh cli-install <target>  gel server install via a local package root
#   local.sh shell <target>        shell in the build container
#
# State lives in $SPIKE_LOCAL_DIR (default ~/.cache/gel-spike): a pristine
# source checkout per ref, and <target>/out, which holds what the CI build
# job uploads.  The workflow stays the final check: GitHub's runner images
# and the macOS build aren't reproduced here.
set -euo pipefail

SPIKE=$(cd "$(dirname "$0")" && pwd)
STATE=${SPIKE_LOCAL_DIR:-$HOME/.cache/gel-spike}
SOURCE_REPO=${SOURCE_REPO:-gelstable/gel}
SOURCE_REF=${SOURCE_REF:-v7.1}
CLI_URL=https://github.com/gelstable/gel-cli/releases/download/v7.10.2

usage() { sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
[[ $# -ge 2 ]] || usage
cmd=$1
target=$2
shift 2

case "$target" in
    x86_64-*) platform=linux/amd64 ;;
    aarch64-*) platform=linux/arm64 ;;
    *) usage ;;
esac
arch=${target%%-*}
case "$target" in
    *-linux-gnu) image=quay.io/pypa/manylinux_2_28_$arch; smoke_images=(debian:12 rockylinux:9 ubuntu:20.04) ;;
    *-linux-musl) image=quay.io/pypa/musllinux_1_2_$arch; smoke_images=(alpine:3.20) ;;
    *) usage ;;
esac
name=gel-spike-$target
out=$STATE/$target/out
src=$STATE/src/$SOURCE_REF

checkout() {
    [[ -d $src ]] && return
    mkdir -p "$STATE/src"
    git clone -q --branch "$SOURCE_REF" --recurse-submodules \
        "https://github.com/$SOURCE_REPO.git" "$src.tmp"
    mv "$src.tmp" "$src"
}

archive() {
    local f=$out/gel-server-$target.tar.gz
    [[ -f $f ]] || { echo "no $f; run: $0 build $target" >&2; exit 1; }
}

case "$cmd" in
    build)
        checkout
        docker rm -f "$name" >/dev/null 2>&1 || true
        docker volume rm "$name" >/dev/null 2>&1 || true
        rm -rf "$out"
        mkdir -p "$out"
        docker pull -q --platform "$platform" "$image"
        docker inspect --format '{{index .RepoDigests 0}}' "$image" | tee "$out/image-digest.txt"
        docker run -d --name "$name" --platform "$platform" \
            -v "$src:/src-pristine:ro" -v "$SPIKE:/spike:ro" \
            -v "$out:/out" -v "$name:/work" \
            "$image" sleep infinity >/dev/null
        # build.sh writes into /src, so give each build its own copy.
        docker exec "$name" cp -a /src-pristine /src
        start=$(date +%s)
        docker exec -e SPIKE_SNAPSHOT=1 "$name" bash /spike/build.sh "$target"
        echo "total $(( $(date +%s) - start ))" >> "$out/timings.txt"
        cat "$out/identity.txt" "$out/timings.txt" "$out/size.txt"
        ;;
    finish)
        docker exec -e SPIKE_RESUME=1 "$name" bash /spike/finish.sh "$target"
        cat "$out/identity.txt" "$out/size.txt"
        ;;
    smoke)
        archive
        [[ $# -gt 0 ]] || set -- "${smoke_images[@]}"
        for img in "$@"; do
            echo "== smoke $target on $img"
            docker run --rm --platform "$platform" \
                -v "$out:/dist:ro" -v "$SPIKE:/spike:ro" \
                "$img" sh /spike/smoke.sh "/dist/gel-server-$target.tar.gz"
        done
        ;;
    cli-install)
        archive
        cli=$STATE/gel-cli-$arch-unknown-linux-musl
        [[ -f $cli ]] || curl -sSfL -o "$cli" "$CLI_URL/gel-cli-$arch-unknown-linux-musl"
        img=${smoke_images[0]}
        docker run --rm --platform "$platform" \
            -v "$out:/dist:ro" -v "$SPIKE:/spike:ro" -v "$cli:/gel:ro" \
            "$img" sh /spike/cli-install.sh /dist "$target" /gel
        ;;
    shell)
        docker exec -it "$name" bash
        ;;
    *) usage ;;
esac
