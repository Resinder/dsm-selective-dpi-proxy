#!/bin/sh
# Healthy when ciadpi completes a SOCKS5 greeting (version 5, "no auth" accepted).
set -eu
reply=$(printf '\005\001\000' | nc -w 3 127.0.0.1 "${1:-1080}" | od -An -tx1 | tr -d ' \n')
[ "$reply" = "0500" ]
