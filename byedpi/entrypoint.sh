#!/bin/sh
# ciadpi's --hosts file has no comment syntax: it would read a "# ..." line as a
# hostname and log "invalid host". So strip comments, blank lines and trailing
# whitespace from the git-friendly hosts.default into a clean tmpfs list, then
# exec ciadpi with the args from the compose command (which points --hosts at
# the clean list). Fails closed if the list ends up empty.
set -eu

SRC=/etc/byedpi/hosts.default
OUT=/run/byedpi/hosts

if [ ! -w "$(dirname "$OUT")" ]; then
  echo "$(dirname "$OUT") is not writable by uid $(id -u); mount it as tmpfs (see docker-compose.yml)" >&2
  exit 70
fi

grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$SRC" | sed 's/[[:space:]]*$//' > "$OUT"
if [ ! -s "$OUT" ]; then
  echo "hosts.default lists no hostnames" >&2
  exit 64
fi

echo "byedpi: splitting $(wc -l < "$OUT") host(s): $(tr '\n' ' ' < "$OUT")"
exec /usr/local/bin/ciadpi "$@"
