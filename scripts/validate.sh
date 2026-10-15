#!/bin/sh
# Read-only validation of the proxy from the Docker host (run it on the NAS).
# It never changes configuration and never downloads torrents.
#
# Usage: sh scripts/validate.sh [proxy-url]
#   PROXY_URL   default http://127.0.0.1:8888
#   SITES       space-separated https URLs to test (default below)
#
# Each line reports: HTTP status, certificate verification result (0 = valid),
# and a classification:
#   OK        2xx/3xx with a valid certificate
#   CF        Cloudflare challenge (cf-mitigated: challenge) - reachable, but the
#             site blocks non-browser clients
#   DENIED    the proxy refused the request (403 from tinyproxy)
#   HTTP-4xx  the site itself answered 4xx
#   CONN-FAIL no HTTP response (blocked, reset, refused or timed out)
#   TLS-FAIL  certificate verification failed (curl exit 60/51)
# The direct baseline is split into IPv4 and IPv6: a site that fails only over
# IPv6 is an IPv6 routing problem, not SNI filtering, and must not be added to
# hosts.default. The proxy path is IPv4-only (Docker bridge networks).
set -u

PROXY_URL="${1:-${PROXY_URL:-http://127.0.0.1:8888}}"
SITES="${SITES:-https://discord.com/ https://gateway.discord.gg/ https://cdn.discordapp.com/}"
HDR=$(mktemp)
ERR=$(mktemp)
trap 'rm -f "$HDR" "$ERR"' EXIT

probe() { # $1 = label, $2 = url, $3.. = extra curl args
  label=$1; url=$2; shift 2
  : > "$HDR"
  out=$(curl -sS -o /dev/null -D "$HDR" -m 15 "$@" \
        -w '%{http_code} %{ssl_verify_result} %{http_connect}' "$url" 2>"$ERR")
  rc=$?
  set -- $out; code=${1:-000}; verify=${2:--}; connect=${3:-000}
  if grep -qi '^cf-mitigated: challenge' "$HDR" 2>/dev/null; then class=CF
  elif [ "$connect" = 403 ]; then class=DENIED; code=403        # proxy refused the CONNECT
  elif [ "$code" = 403 ] && grep -qi '^Server: tinyproxy' "$HDR" 2>/dev/null; then class=DENIED
  elif [ "$rc" = 60 ] || [ "$rc" = 51 ]; then class=TLS-FAIL      # certificate problem
  elif [ "$rc" != 0 ] || [ "$code" = 000 ]; then class=CONN-FAIL   # reset, timeout, refused
  elif echo "$code" | grep -qE '^[23][0-9][0-9]$'; then class=OK
  else class=HTTP-$code
  fi
  printf '%-7s %-10s code=%-3s verify=%-2s rc=%-2s %s\n' "$label" "$class" "$code" "$verify" "$rc" "$url"
}

echo "proxy: $PROXY_URL"
echo "== 1. direct (no proxy) baseline, IPv4 and IPv6 separately"
for u in $SITES; do probe direct4 "$u" --noproxy '*' -4; done
for u in $SITES; do probe direct6 "$u" --noproxy '*' -6; done

echo "== 2. through the proxy (certificate validation ON)"
for u in $SITES; do probe proxy "$u" -x "$PROXY_URL"; done

echo "== 3. redirect chain stays on the proxy"
curl -sS -L -o /dev/null -m 20 -x "$PROXY_URL" \
  -w 'final=%{url_effective} code=%{http_code} hops=%{num_redirects}\n' http://thepiratebay.org/ 2>&1 | tail -1

echo "== 4. must be refused by the proxy (expect DENIED)"
for u in http://127.0.0.1/ http://localhost/ http://192.168.1.1/ https://192.168.1.1/ \
         http://10.0.0.1/ http://100.100.100.100/ http://example.com:8080/ \
         https://example.com:8443/ http://router.lan/ http://[::1]/; do
  probe proxy "$u" -x "$PROXY_URL"
done
