#!/bin/sh
# Spike smoke test, run as root in a clean container:
#   smoke.sh <archive.tar.gz>
# Unpacks the archive at a path unlike the build path, then as an
# unprivileged user checks --version, bootstraps an instance, and runs a
# query with the bundled Python client.
set -eu
archive=$1

if command -v apt-get >/dev/null; then
    apt-get update -qq && apt-get install -y -qq procps tar gzip >/dev/null
elif command -v dnf >/dev/null; then
    dnf install -y -q procps-ng shadow-utils tar gzip util-linux >/dev/null
elif command -v apk >/dev/null; then
    apk add --no-cache procps >/dev/null
fi
(useradd -m smoke 2>/dev/null || adduser -D smoke)

dest=/home/smoke/some/other/place
mkdir -p "$dest"
tar -xzf "$archive" -C "$dest"
chown -R smoke "$dest"
server=$(echo "$dest"/gel-server-*/bin/gel-server)
python=$(dirname "$server")/python3

cat > /tmp/smoke-user.sh <<EOF
set -eu
"$server" --version
"$server" --data-dir /tmp/smoke-data --runstate-dir /tmp \\
    --tls-cert-mode generate_self_signed --port 5656 --bind-address 127.0.0.1 \\
    --bootstrap-command "ALTER ROLE admin { SET password := 'spike' }" \\
    > /tmp/server.log 2>&1 &
pid=\$!
i=0
until "$python" -I -c "
import gel
c = gel.create_client(host='127.0.0.1', port=5656, user='admin',
                      password='spike', tls_security='insecure', database='main')
print('query result:', c.query_single('select 1 + 1'))
" 2>/dev/null; do
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
su -s /bin/sh smoke -c "sh /tmp/smoke-user.sh"
