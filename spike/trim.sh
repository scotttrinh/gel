#!/bin/bash
# Reduce an installed tree to what the v7.1 portable archives ship
# (gel-pkg's edgedb, python and postgresql install/no_install lists), and
# add the launchers, tests and CA bundle.
#
# Usage: trim.sh <prefix> <gel-src> <spike-dir>
set -euo pipefail
PREFIX=$1
SRC=$2
SPIKE=$3

# bin: v7.1's PostgreSQL subset, the bundled python3, and launchers.
cd "$PREFIX/bin"
for f in *; do
    case "$f" in
        python3|python3.12|postgres|initdb|pg_basebackup|pg_combinebackup|pg_config|pg_ctl|pg_dump|pg_restore|pg_rewind|pg_verifybackup|pg_waldump|psql) ;;
        *) rm -rf "$f" ;;
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
    install -m 0755 "$SPIKE/launcher.sh" "$name"
done

# lib: drop development files, ECPG, and python-build-standalone's Tcl/Tk.
cd "$PREFIX/lib"
rm -rf pkgconfig tcl* tk* itcl* thread* libtcl* libtk* \
    libecpg* libpgtypes* postgresql/pgxs
find . -maxdepth 1 \( -name '*.a' -o -name '*.la' \) -delete
# Unversioned development symlinks (libpq.so etc.).
find . -maxdepth 1 -type l -name '*.so' -delete
find . -maxdepth 1 -type l -name '*.dylib' ! -name '*.*.dylib' -delete

# Python standard library, per gel-pkg's python no_install.list.
PYLIB=$(echo "$PREFIX"/lib/python3.*)
rm -rf "$PYLIB"/{test,dbm,distutils,ensurepip,idlelib,lib2to3,pydoc_data,sqlite3,tkinter,turtledemo,venv,wsgiref,xmlrpc} \
    "$PYLIB"/turtle.py "$PYLIB"/unittest/test "$PYLIB"/config-*/libpython*.a
rm -f "$PYLIB"/lib-dynload/*_test* "$PYLIB"/lib-dynload/_tkinter.* \
    "$PYLIB"/lib-dynload/_dbm.* "$PYLIB"/lib-dynload/_gdbm.* \
    "$PYLIB"/lib-dynload/_crypt.* "$PYLIB"/lib-dynload/_sqlite3.* \
    "$PYLIB"/lib-dynload/xxlimited* "$PYLIB"/lib-dynload/xxsubtype*

rm -rf "$PREFIX/include" "$PREFIX/share/man" "$PREFIX/share/doc" \
    "$PREFIX/share/terminfo"

# share/tests: gel-pkg copies the source tree's tests/.
cp -a "$SRC/tests" "$PREFIX/share/tests"
find "$PREFIX/share/tests" -name __pycache__ -prune -exec rm -rf {} +

# etc/ssl/cert.pem: gel-pkg ships certifi's bundle there.
mkdir -p "$PREFIX/etc/ssl"
cp "$PYLIB/site-packages/certifi/cacert.pem" "$PREFIX/etc/ssl/cert.pem"

# On Linux, python-build-standalone's python3.12 is statically linked; its
# libpython is only for embedding, and nothing here embeds Python.
if [[ $(file -b "$PREFIX/bin/python3.12") == ELF* ]]; then
    rm -f "$PREFIX"/lib/libpython3*.so*
fi

# Strip debug info (gel-pkg stripped everything).  Leave
# python-build-standalone's own binaries alone: they are already stripped,
# and BOLT-optimized, which older strip versions corrupt.
{
    find "$PREFIX/bin" -maxdepth 1 -type f ! -name 'python*' ! -name '*.py' ! -name '*-server' ! -name '*-load-ext'
    find "$PREFIX/lib" -maxdepth 1 -type f \( -name 'lib*.so*' -o -name 'lib*.dylib' \) ! -name 'libpython*'
    find "$PREFIX/lib/postgresql" -type f \( -name '*.so' -o -name '*.dylib' \)
    find "$PYLIB/site-packages" -type f \( -name '*.so' -o -name '*.dylib' \)
} | while IFS= read -r f; do
    case "$(file -b "$f")" in
        ELF*) strip --strip-debug "$f" ;;
        Mach-O*) strip -S "$f" 2>/dev/null || true ;;
    esac
done
