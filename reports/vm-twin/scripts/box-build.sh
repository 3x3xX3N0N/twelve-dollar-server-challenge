#!/usr/bin/env bash
# box-build.sh <entry>... (root, server VM): what the scorer does, per entry: install.sh as root, build.sh as the
# normal user `bench` (wall time, CPU time and memory peak from systemd), then test/run.sh as `bench` (42 checks).
# The seed is made once, as `bench`, by seed/make-seed.sh. Logs: /root/build-logs/.
set -uo pipefail
R=/home/bench/repo; L=/root/build-logs; mkdir -p $L
if [ ! -d $R ]; then tar -xzf /root/repo.tgz -C /home/bench; chown -R bench: $R; fi
if [ ! -f $R/seed/feed.db ]; then
  t=$(date +%s); su - bench -c "cd $R && bash seed/make-seed.sh" > $L/seed.log 2>&1; echo "seed rc=$? $(( $(date +%s) - t )) s: $(tail -1 $L/seed.log)"
fi
for e in "$@"; do
  E=$R/submissions/$e
  t=$(date +%s); bash $E/install.sh > $L/$e-install.log 2>&1; echo "$e install rc=$? $(( $(date +%s) - t )) s"
  t=$(date +%s)
  systemd-run --wait --pipe --collect -p User=bench -p Group=bench -p WorkingDirectory=$E -E HOME=/home/bench \
    /bin/bash $E/build.sh > $L/$e-build.log 2>&1; rc=$?
  echo "$e build rc=$rc $(( $(date +%s) - t )) s; $(grep -E 'Memory peak|CPU time' $L/$e-build.log | tr '\n' ' ')"
  grep -E 'PGO|profile|training' $L/$e-build.log | tail -3
  t=$(date +%s)
  su - bench -c "cd $R && bash test/run.sh submissions/$e" > $L/$e-test.log 2>&1; echo "$e test rc=$? $(( $(date +%s) - t )) s: $(grep -E '[0-9]+/[0-9]+|passed|failed' $L/$e-test.log | tail -2 | tr '\n' ' ')"
done
echo BUILD-DONE
