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
#   CONN-FAIL no HTTP response (blocked, reset or timed out)
#   TLS-FAIL  certificate verification failed
set -u

PROXY_URL="${1:-${PROXY_URL:-http://127.0.0.1:8888}}"
SITES="${SITES:-https://rarbg.to/ https://nyaa.si/ https://thepiratebay.org/}"
HDR=$(mktemp)
trap 'rm -f "$HDR"' EXIT

probe() { # $1 = label, $2 = url, $3.. = extra curl args
  label=$1; url=$2; shift 2
  : > "$HDR"
  out=$(curl -sS -o /dev/null -D "$HDR" -m 15 "$@" \
        -w '%{http_code} %{ssl_verify_result}' "$url" 2>&1 | tail -1)
  code=${out%% *}; verify=${out##* }
  case "$out" in *"CONNECT tunnel failed, response 403"*) code=403; verify=-;; esac
  class=CONN-FAIL
  if grep -qi '^cf-mitigated: challenge' "$HDR" 2>/dev/null; then class=CF
  elif [ "$code" = 403 ] && grep -qi '^Server: tinyproxy' "$HDR" 2>/dev/null; then class=DENIED
  elif [ "$code" = 403 ] && [ "$verify" = - ]; then class=DENIED
  elif [ "$verify" != 0 ] && [ "$verify" != - ] && [ "$code" = 000 ] && echo "$url" | grep -q '^https'; then class=TLS-FAIL
  elif echo "$code" | grep -qE '^[23][0-9][0-9]$'; then class=OK
  elif echo "$code" | grep -qE '^4[0-9][0-9]$'; then class=HTTP-$code
  fi
  printf '%-7s %-10s code=%-3s verify=%-2s %s\n' "$label" "$class" "$code" "$verify" "$url"
}

echo "proxy: $PROXY_URL"
echo "== 1. direct (no proxy) baseline"
for u in $SITES; do probe direct "$u" --noproxy '*'; done

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
