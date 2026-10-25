#!/bin/sh
# Spike: install a portable archive with the released gel CLI, the way
# `gel server install` installs v7.1, through a local package root
# (GEL_PKG_ROOT) instead of packages.geldata.com.  Run as root in a clean
# container, or as the runner user on macOS:
#   cli-install.sh <dist-dir> <target> <cli-binary>
# <dist-dir> holds gel-server-<target>.tar.zst and .tar.gz.
set -eu
dist=$1
target=$2
cli=$3

if [ "$(uname)" = Darwin ]; then
    mkdir -p "$HOME/.local/bin"
    install -m 0755 "$cli" "$HOME/.local/bin/gel"
    export PATH="$HOME/.local/bin:$PATH"
else
    if command -v apt-get >/dev/null; then
        apt-get update -qq && apt-get install -y -qq procps tar gzip >/dev/null
    elif command -v apk >/dev/null; then
        apk add --no-cache procps >/dev/null
    fi
    (useradd -m smoke 2>/dev/null || adduser -D smoke)
    install -m 0755 "$cli" /usr/local/bin/gel
fi

# The archive's own Python hashes the files and serves the package root.
mkdir -p /tmp/py
tar -xzf "$dist/gel-server-$target.tar.gz" -C /tmp/py
python=$(echo /tmp/py/gel-server-*/bin/python3)
identity=$(basename /tmp/py/gel-server-*)
identity=${identity#gel-server-}

root=/tmp/pkgroot
mkdir -p "$root/archive/.jsonindexes" "$root/archive/$target"
cp "$dist/gel-server-$target.tar.zst" "$root/archive/$target/gel-server-$identity.tar.zst"
"$python" -I - "$root" "$target" "$identity" <<'EOF'
import hashlib, json, pathlib, sys
root, target, identity = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
major = identity.split(".")[0]
ref = f"/archive/{target}/gel-server-{identity}.tar.zst"
data = (root / ref.lstrip("/")).read_bytes()
pkg = {
    "basename": "gel-server",
    "name": f"gel-server-{major}",
    "slot": major,
    "version": identity,
    "tags": {},
    "installrefs": [{
        "ref": ref,
        "type": "application/x-tar",
        "encoding": "zstd",
        "verification": {
            "size": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "blake2b": hashlib.blake2b(data).hexdigest(),
        },
    }],
}
index = root / "archive/.jsonindexes" / f"{target}.json"
index.write_text(json.dumps({"packages": [pkg]}, indent=1))
print(index.read_text())
for suffix in (".testing", ".nightly"):
    (index.parent / f"{target}{suffix}.json").write_text('{"packages": []}')
EOF
"$python" -I -m http.server --bind 127.0.0.1 --directory "$root" 8000 \
    > /tmp/http.log 2>&1 &
i=0
until "$python" -I -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/archive/.jsonindexes/$target.json')" 2>/dev/null; do
    i=$((i + 1))
    if [ $i -gt 30 ]; then cat /tmp/http.log; exit 1; fi
    sleep 1
done

cat > /tmp/cli-user.sh <<EOF
set -eu
export GEL_PKG_ROOT=http://127.0.0.1:8000
gel --version
gel server list-versions
gel server install --version 7.1
gel server list-versions --installed-only
server=\$(gel server info --version 7.1 --bin-path)
echo "installed server: \$server"
"\$server" --version
"\$server" --data-dir /tmp/cli-data --runstate-dir /tmp \\
    --tls-cert-mode generate_self_signed --port 5656 --bind-address 127.0.0.1 \\
    --bootstrap-command "ALTER ROLE admin { SET password := 'spike' }" \\
    > /tmp/server.log 2>&1 &
pid=\$!
i=0
until echo spike | gel query --host 127.0.0.1 --port 5656 --user admin \\
        --password-from-stdin --tls-security insecure --branch main \\
        'select 1 + 1' 2>/dev/null; do
    i=\$((i + 1))
    if [ \$i -gt 120 ] || ! kill -0 \$pid 2>/dev/null; then
        tail -50 /tmp/server.log
        exit 1
    fi
    sleep 5
done
kill \$pid
wait \$pid || true
EOF
if [ "$(uname)" = Darwin ]; then
    sh /tmp/cli-user.sh
else
    su -s /bin/sh smoke -c "sh /tmp/cli-user.sh"
fi
