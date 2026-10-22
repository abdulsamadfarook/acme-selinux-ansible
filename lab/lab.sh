#!/usr/bin/env bash
# Lab helper: snapshot / revert / list all lab nodes in one go.
#   lab/lab.sh snap <name>      take snapshot <name> on every node (VMs are paused briefly)
#   lab/lab.sh revert <name>    revert every node to <name> and start it
#   lab/lab.sh list             show snapshots
#   lab/lab.sh console <node>   open the graphical console (GRUB drills)
#   lab/lab.sh start | stop     boot / gracefully shut down every node
set -euo pipefail
C="virsh -c qemu:///system"
NODES=${NODES:-"web01 app01 db01 legacy01"}
case "${1:-}" in
  snap)   for n in $NODES; do $C snapshot-create-as "$n" "${2:?name}" --atomic >/dev/null && echo "$n: $2"; done ;;
  revert) for n in $NODES; do $C snapshot-revert "$n" "${2:?name}" --running && echo "$n -> $2"; done
          # a revert puts the guest clock back to snapshot time: step it, or every
          # time-window comparison (audit, gate) is wrong
          cd "$(dirname "$0")/.." && .venv/bin/ansible-playbook playbooks/lab_timesync.yml \
            -e target="$(echo $NODES | tr ' ' ,)" </dev/null >/dev/null 2>&1 && echo "clocks stepped" || echo "WARNING: clock step failed - run playbooks/lab_timesync.yml" ;;
  list)   for n in $NODES; do echo "== $n"; $C snapshot-list "$n" --name; done ;;
  delete) for n in $NODES; do $C snapshot-delete "$n" "${2:?name}"; done ;;
  start)  for n in $NODES; do $C start "$n" 2>/dev/null && echo "started $n" || echo "$n already running"; done ;;
  stop)   for n in $NODES; do $C shutdown "$n" 2>/dev/null && echo "stopping $n"; done ;;
  console) virt-viewer -c qemu:///system "${2:?node}" & ;;
  *) sed -n '2,8p' "$0"; exit 1 ;;
esac
