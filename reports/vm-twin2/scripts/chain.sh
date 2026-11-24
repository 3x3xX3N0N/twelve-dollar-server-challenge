#!/usr/bin/env bash
# chain.sh: JVM calibration at 96k with the calibrated NIC (4 queues), then the interleaved step search from 160k.
set -uo pipefail
S="$(cd "$(dirname "$0")" && pwd)"; export W="${W:?}"
bash $S/nicq.sh 4; bash $S/one.sh calib-nio-q4 kotlin-nio-3x3xX3N0N 96000 | cut -c1-400
bash $S/search.sh 160000 16000 320000
echo CHAIN-DONE
