#!/usr/bin/env bash
# LOCAL LAB ONLY (libvirt VMs, IPs 192.168.122.x, SSH user abdul) - not used by AAP.
# Runs every chaos scenario end to end against the "enforced" snapshot:
#   revert -> inject -> verify the audit report diagnoses it -> fix via Ansible -> verify the app
# Usage: tests/run_chaos.sh [scenario ...]
set -uo pipefail
cd "$(dirname "$0")/.."
export PATH=$PWD/.venv/bin:$PATH
WEB=http://192.168.122.11
ap() { ansible-playbook "$@" </dev/null 2>&1; }
check() { # name expected-code url
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$3"); [ "$code" = "$2" ] && r=ok || r=FAIL
  echo "    [$r] $1: $3 -> $code (want $2)"; [ "$r" = ok ]; }
# capture first: with pipefail, "ansible | grep -q && ..." takes ansible's exit code
# and printed "ok" for a failed evaluation (found while testing this script)
evaluate() { out=$(ap tests/test_audit_report.yml -e case="$1")
  if grep -q 'passed for' <<<"$out" && ! grep -qE 'failed=[1-9]|ERROR' <<<"$out"; then
    echo "    [ok] audit report diagnosed $1: $(grep -oE "root causes found: .*" <<<"$out" | head -1 | cut -c1-120)"
  else echo "    [FAIL] audit report evaluation $1:"; grep -E 'missing:|records:|FAILED' <<<"$out" | head -3 | sed 's/^/        /'; fi; }
# poll instead of a fixed sleep: services come back on their own restart cadence
waitfor() { for i in $(seq 20); do [ "$(curl -s -m 3 -o /dev/null -w '%{http_code}' "$2")" = 200 ] && break; sleep 1; done; check "$1" 200 "$2"; }

WEB_PORTS='[{"ports":"8090","proto":"tcp","setype":"http_port_t"},{"ports":"8282","proto":"tcp","setype":"http_port_t"},{"ports":"8091","proto":"tcp","setype":"http_port_t"}]'
APP_FC='[{"target":"/srv/acme/applogs(/.*)?","setype":"acme_api_log_t","path":"/srv/acme/applogs"}]'

for s in ${@:-mislabel new_port app_logdir db_datadir}; do
  echo "=== $s"
  NODES="web01 app01 db01" lab/lab.sh revert enforced >/dev/null
  ap playbooks/chaos.yml -e scenario=$s | grep -qE 'failed=[1-9]' && echo "    [FAIL] inject" || echo "    injected"
  case $s in
    mislabel)
      check "symptom" 403 $WEB:8090/statement.html
      evaluate chaos_mislabel
      ap playbooks/selinux_policy.yml -l web01 | grep -E 'failed=' | sed 's/^/    fix: /'
      check "fixed" 200 $WEB:8090/statement.html ;;
    new_port)
      check "symptom" 000 $WEB:8091/
      evaluate chaos_new_port
      # the fix = the Git change "add 8091 to selinux_ports in group_vars/web", simulated with -e
      ap playbooks/selinux_policy.yml -l web01 -e "{\"selinux_ports\": $WEB_PORTS}" | grep -E 'failed=' | sed 's/^/    fix: /'
      ssh abdul@192.168.122.11 'sudo systemctl restart httpd' 2>/dev/null
      check "fixed" 200 $WEB:8091/ ;;
    app_logdir)
      sleep 3; check "symptom" 503 $WEB:8090/api/health
      evaluate chaos_app_logdir
      ap playbooks/selinux_policy.yml -l app01 -e "{\"selinux_fcontexts\": $APP_FC}" | grep -E 'failed=' | sed 's/^/    fix: /'
      waitfor "fixed (acme-api restarts itself once it can write its log)" $WEB:8090/api/health ;;
    db_datadir)
      check "symptom" 503 $WEB:8090/api/health
      evaluate chaos_db_datadir
      ap playbooks/selinux_policy.yml -l db01 | grep -E 'failed=' | sed 's/^/    fix: /'
      ssh abdul@192.168.122.13 'sudo systemctl start postgresql' 2>/dev/null
      waitfor "fixed" $WEB:8090/api/health ;;
  esac
done
