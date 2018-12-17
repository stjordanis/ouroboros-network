#!/usr/bin/env bash

# Turbohack to clean up the resources.
trap ctrl_c INT

function ctrl_c() {
  echo "Cleaning up named pipes..."
  sh -c "./demo-playground/cleanup-demo.sh"
}

now=`date "+%Y-%m-%d 00:00:00"`

cabal new-run demo-playground -- \
    node -t demo-playground/simple-topology.json -n $1 \
    --system-start "$now" --slot-duration 2
