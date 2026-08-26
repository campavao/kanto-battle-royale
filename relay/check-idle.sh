#!/usr/bin/env bash
# Is anyone playing right now?  Run this BEFORE deploying the relay (POK-123).
#
# The relay has no drain on SIGTERM, so a restart kills every match in
# progress.  Until POK-123 lands, a relay deploy waits for an empty box.
# Mod releases no longer restart it -- Railway watchPatterns is "relay/**" --
# so this only gates changes under relay/.
#
# It reads the heartbeat server.js prints every five minutes:
#
#   <ts> rooms 1/40 conns 4/200 | sent 9.1MB in 94377 lines | peak 2 rooms 4 conns
#
#   ./check-idle.sh          # one look
#   ./check-idle.sh --watch  # poll until it goes idle
#
# Exit 0 idle, 1 busy, 2 could not tell -- which is NOT the same as idle.
set -uo pipefail

# Pinned rather than relying on `railway link`: this has to work from any
# checkout, and linking is interactive.
PROJECT="34e1da0b-5125-40be-9954-d90fafa3e156"   # kanto-br-relay
SERVICE="relay"
ENVIRONMENT="production"

# --lines makes it FETCH and exit.  Without it `railway logs` streams, and
# this script would hang forever instead of answering.
read_beat() {
  timeout 60 railway logs -p "$PROJECT" -s "$SERVICE" -e "$ENVIRONMENT" \
      -d --lines 60 2>/dev/null \
    | grep -E "rooms [0-9]+/[0-9]+ conns [0-9]+/" \
    | tail -1
}

check_once() {
  local line rooms conns
  line="$(read_beat)"
  if [ -z "$line" ]; then
    echo "could not read a heartbeat from the relay."
    echo "check 'railway whoami' and that the service is up -- do NOT assume idle."
    return 2
  fi

  rooms="$(sed -E 's/.*rooms ([0-9]+)\/.*/\1/' <<<"$line")"
  conns="$(sed -E 's/.*conns ([0-9]+)\/.*/\1/' <<<"$line")"

  echo "$line"
  if [ "$rooms" = "0" ] && [ "$conns" = "0" ]; then
    echo "IDLE - safe to deploy the relay."
    return 0
  fi
  echo "BUSY - $conns connection(s) in $rooms room(s).  Hold the deploy."
  return 1
}

# The heartbeat is only every five minutes, so a fresh "0 0" can be up to
# five minutes stale and somebody may have joined since.  Worth knowing
# before you push; it is a good-enough gate, not a lock.
if [ "${1:-}" = "--watch" ]; then
  while true; do
    if check_once; then exit 0; fi
    echo "-- waiting 60s (heartbeat is every 5 min, so this lags) --"
    sleep 60
  done
fi

check_once
exit $?
