# Local lab only: source this from the repository root before running playbooks locally.
#   source lab/env.sh
# Keeps a local run history (the stand-in for AAP's job history). Not in ansible.cfg,
# because AAP's execution environment cannot write that file and warns on every job.
_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$_root/logs"
export ANSIBLE_LOG_PATH="$_root/logs/ansible.log"
[ -f "$_root/.venv/bin/activate" ] && . "$_root/.venv/bin/activate"
unset _root
