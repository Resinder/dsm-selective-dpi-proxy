#!/bin/sh
# Render tinyproxy.conf from environment variables into a tmpfs and start
# tinyproxy in the foreground. Fails closed on invalid input.
set -eu

CONF_DIR=/run/tinyproxy
CONF="$CONF_DIR/tinyproxy.conf"
FILTER="$CONF_DIR/filter"

: "${PROXY_ALLOW:?PROXY_ALLOW must list the client addresses/CIDRs allowed to use the proxy}"
UPSTREAM_SOCKS="${UPSTREAM_SOCKS:-byedpi:1080}"
CONNECT_PORTS="${CONNECT_PORTS:-443}"
MAX_CLIENTS="${MAX_CLIENTS:-32}"
TIMEOUT="${TIMEOUT:-120}"
LOG_LEVEL="${LOG_LEVEL:-Connect}"
EXTRA_DENY_PATTERNS="${EXTRA_DENY_PATTERNS:-}"

case "$LOG_LEVEL" in
  Critical|Error|Warning|Notice|Connect|Info) ;;
  *) echo "invalid LOG_LEVEL: $LOG_LEVEL" >&2; exit 64 ;;
esac
for n in "$MAX_CLIENTS" "$TIMEOUT"; do
  case "$n" in ''|*[!0-9]*) echo "MAX_CLIENTS/TIMEOUT must be integers" >&2; exit 64 ;; esac
done
case "$UPSTREAM_SOCKS" in
  *[!A-Za-z0-9.:_-]*|'') echo "invalid UPSTREAM_SOCKS: $UPSTREAM_SOCKS" >&2; exit 64 ;;
esac

if [ ! -w "$CONF_DIR" ]; then
  echo "$CONF_DIR is not writable by uid $(id -u); mount it as tmpfs with uid/gid (see docker-compose.yml)" >&2
  exit 70
fi
{
  echo "Port 8888"
  echo "Listen 0.0.0.0"
  echo "Timeout $TIMEOUT"
  echo "MaxClients $MAX_CLIENTS"
  echo "LogLevel $LOG_LEVEL"
  echo "DisableViaHeader Yes"
  echo "XTinyproxy No"
  # Health checks request this pseudo-host through the proxy itself.
  echo 'StatHost "tinyproxy.stats"'
  # Container-local health checks.
  echo "Allow 127.0.0.1"
  for a in $(echo "$PROXY_ALLOW" | tr ',' ' '); do
    case "$a" in
      *[!0-9a-fA-F.:/]*) echo "invalid PROXY_ALLOW entry: $a" >&2; exit 64 ;;
    esac
    echo "Allow $a"
  done
  for p in $(echo "$CONNECT_PORTS" | tr ',' ' '); do
    case "$p" in ''|*[!0-9]*) echo "invalid CONNECT_PORTS entry: $p" >&2; exit 64 ;; esac
    echo "ConnectPort $p"
  done
  # Every request leaves through ByeDPI; ByeDPI alters only the listed hosts.
  echo "Upstream socks5 $UPSTREAM_SOCKS"
  echo "Filter \"$FILTER\""
  echo "FilterURLs On"
  echo "FilterExtended On"
  echo "FilterCaseSensitive Off"
  echo "FilterDefaultDeny No"
} > "$CONF"

cp /usr/local/share/tinyproxy/filter.default "$FILTER"
if [ -n "$EXTRA_DENY_PATTERNS" ]; then
  printf '%s\n' "$EXTRA_DENY_PATTERNS" | tr ';' '\n' >> "$FILTER"
fi

echo "tinyproxy: allow=[$PROXY_ALLOW] connect_ports=[$CONNECT_PORTS] upstream=socks5://$UPSTREAM_SOCKS log=$LOG_LEVEL"
exec tinyproxy -d -c "$CONF"
