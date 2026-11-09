#!/usr/bin/env bash
# Logs Docker in to a registry with NEXUS_USERNAME and NEXUS_PASSWORD.
#
#   scripts/login.sh <registry>
#
# After a few failed logins, Nexus refuses every login for a while with "Too
# many authentication attempts" (HTTP 429). This waits that out, but gives up
# at once on any other refusal: retrying a wrong password only extends the
# lockout.
set -euo pipefail

registry=$1
: "${NEXUS_USERNAME:?}" "${NEXUS_PASSWORD:?}"

for attempt in 1 2 3 4 5; do
  if out=$(printf '%s' "$NEXUS_PASSWORD" | docker login "$registry" -u "$NEXUS_USERNAME" --password-stdin 2>&1); then
    echo "$out"
    exit 0
  fi
  # The 429 arrives as an HTML page; its first line says enough.
  echo "$out" | head -n 1 | sed 's/<!DOCTYPE.*//'
  case "$out" in
    *toomanyrequests*)
      wait=$((attempt * 60))
      echo "$registry is refusing logins for now; trying again in ${wait}s"
      sleep "$wait"
      ;;
    *)
      echo "::error::$registry refused the login"
      exit 1
      ;;
  esac
done
echo "::error::$registry was still refusing logins after 5 attempts"
exit 1
