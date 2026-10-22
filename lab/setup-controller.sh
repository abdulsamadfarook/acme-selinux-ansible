#!/usr/bin/env bash
# One-time (local lab): Python venv + collections for the control node.
set -euo pipefail
cd "$(dirname "$0")/.."
python3 -m venv .venv
.venv/bin/pip install -q --upgrade pip
.venv/bin/pip install -q -r requirements-venv.txt
.venv/bin/ansible-galaxy collection install -r requirements.yml -p collections
echo "Done. Activate with:  source .venv/bin/activate"
