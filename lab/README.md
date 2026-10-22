# lab/ - local libvirt lab only

Nothing in this folder is used by AAP / RHDP.

| File | Purpose |
|---|---|
| `setup-controller.sh` | One-time: Python venv with ansible-core, ansible-lint, ansible-rulebook, plus collections |
| `env.sh` | `source lab/env.sh` before running locally: activates the venv, turns on the run log |
| `lab.sh` | Snapshot / revert / start / stop the four lab VMs |
| `eda/selinux_drift_rulebook.yml` | Real-time drift with the `ansible-rulebook` CLI (AAP uses `rulebooks/selinux_drift_aap.yml`) |

How to build the VMs: [../docs/local-lab.md](../docs/local-lab.md).
