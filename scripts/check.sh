#!/bin/bash
# Checks Cumulus://ID Russia from wherever it runs. Exit 1 on any failure.
set -uo pipefail
BASE=${BASE:-https://ru-id.cumuluscloud.app}
fail=0
check() { # name expected-code url
  local got
  got=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "$3")
  if [ "$got" = "$2" ]; then echo "ok   $1 ($got)"; else echo "FAIL $1: got $got, want $2"; fail=1; fi
}
check "home page" 200 "$BASE/"
check "OIDC discovery" 200 "$BASE/.well-known/openid-configuration"
check "HTTP redirects to HTTPS" 301 "${BASE/https:/http:}/"
issuer=$(curl -s --max-time 20 "$BASE/.well-known/openid-configuration" | sed -n 's/.*"issuer" *: *"\([^"]*\)".*/\1/p')
if [ "$issuer" = "$BASE" ]; then echo "ok   issuer is $issuer"; else echo "FAIL issuer: '$issuer'"; fail=1; fi
cookie=$(curl -s -D - -o /dev/null --max-time 20 "$BASE/" | grep -i '^set-cookie' | grep -io 'domain=[^;]*' | head -1)
case "$cookie" in
  ""|*ru-id.cumuluscloud.app*) echo "ok   cookie scope ${cookie:-host-only}" ;;
  *) echo "FAIL cookie scope $cookie (must stay on ru-id)"; fail=1 ;;
esac
exit $fail
