#!/bin/bash
# Spike: transient user service lifetime vs detached children; stdout cleanliness; env propagation.
set -u
UNIT="fleet-spike-$(cat /proc/sys/kernel/random/uuid)"
export FLEET_SPIKE_VAR="hello-from-client"
export FLEET_SECRET="should-not-appear-in-argv"
OUT=$(mktemp)
echo "unit=$UNIT"
# Service: prints env + pids to stdout, spawns detached child that escapes via setsid+nohup, then blocks reading stdin.
systemd-run --user --quiet --pipe --wait --collect --service-type=exec \
  --unit="$UNIT" -p KillMode=control-group -p TimeoutStopSec=5 -p Restart=no \
  --setenv=FLEET_SPIKE_VAR --setenv=FLEET_SECRET \
  --working-directory=/tmp \
  /bin/sh -c 'echo "svc-pid=$$ var=$FLEET_SPIKE_VAR cwd=$(pwd)"; setsid nohup sleep 600 >/dev/null 2>&1 & echo "detached=$!"; (sleep 600 &) ; echo "shell-child-spawned"; cat' \
  > "$OUT" 2>/tmp/fleet-probe/spike-stderr.log < <(sleep 30) &
RUNNER=$!
sleep 1.5
echo "--- stdout from service (must be only service output):"; cat "$OUT"
echo "--- show:"
systemctl --user show "$UNIT" -p LoadState,ActiveState,SubState,MainPID,ControlGroup,InvocationID,Job,Result
CG=$(systemctl --user show "$UNIT" -p ControlGroup --value)
echo "--- cgroup procs before stop:"; cat "/sys/fs/cgroup$CG/cgroup.procs" | tr '\n' ' '; echo; cat "/sys/fs/cgroup$CG/cgroup.events"
echo "--- killing only the Emacs-side wrapper (systemd-run pid $RUNNER):"
kill -9 $RUNNER; sleep 1
systemctl --user show "$UNIT" -p ActiveState,SubState,MainPID --value | tr '\n' ' '; echo
echo "--- cgroup procs after wrapper kill:"; cat "/sys/fs/cgroup$CG/cgroup.procs" 2>/dev/null | tr '\n' ' '; echo
echo "--- systemctl --user stop:"
time systemctl --user stop "$UNIT"
echo "--- show after stop:"
systemctl --user show "$UNIT" -p LoadState,ActiveState,SubState,MainPID,ControlGroup,Result
echo "--- cgroup dir exists?"; ls -d "/sys/fs/cgroup$CG" 2>&1
echo "--- leftover sleeps from spike (should be none):"; pgrep -af 'sleep 600' || echo none
echo "--- boot id: $(cat /proc/sys/kernel/random/boot_id)"
