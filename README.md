# ACME Financial: SELinux from Permissive to Enforcing with Ansible

Ansible content for moving a RHEL 9 estate from SELinux **Permissive** to **Enforcing**
without application downtime, with automatic rollback, audit evidence and continuous
drift enforcement. Built for the ACME Financial scenario (1,200 nodes, PCI-DSS / SOC 2)
and tested two ways:

- **In Ansible Automation Platform 2.5** on Red Hat Demo Platform (two RHEL 9 nodes):
  job templates, a workflow with an approval step, a schedule, and Event-Driven Ansible.
- **Locally** from the command line against four libvirt VMs, including a host that
  starts with SELinux disabled.

The same playbooks and roles serve both.

## The approach

| Step | Playbook | What it does |
|---|---|---|
| 1. Discover | `playbooks/selinux_audit.yml` | Reads the audit log on every host while it is still Permissive and groups the would-be denials into root causes (port, label or policy). One verdict per host: YES, NO, REVIEW (a service runs unconfined) or NOT ASSESSABLE (SELinux disabled). |
| 2. Fix | `playbooks/selinux_policy.yml` | Applies the declared policy: custom modules, file contexts (`sefcontext` + `restorecon`), port types (`seport`), booleans (`seboolean`). Does not change the mode. Supports `--check --diff`. |
| 3. Enforce | `playbooks/selinux_enforce.yml` | Per host: a gate (zero denials since the policy was applied), `setenforce 1` without reboot or restart, a soak that checks the application and new denials every second, automatic rollback on any failure. Canary first, then waves; the first failure stops the rollout. |
| 4. Keep | `playbooks/selinux_drift.yml` | Re-applies everything declared and holds migrated hosts at Enforcing. Reports who changed what (`auid` from auditd). Runs on a schedule and, through EDA, within seconds of a `setenforce 0` or a boolean change. |

Supporting playbooks:

| Playbook | Purpose |
|---|---|
| `selinux_rollback.yml` | Break-glass: back to Permissive (never Disabled). Requires a change or incident reference. |
| `selinux_from_disabled.yml` | `SELINUX=disabled` hosts: remove `selinux=0`, set permissive, full relabel, reboot, verify. |
| `eda_forwarder.yml` | Installs a small service on each node that sends SELinux state changes to EDA. |
| `acme_deploy.yml`, `smoke_test.yml` | The demo application (see below) and an end-to-end check. |
| `chaos.yml` | Injects realistic SELinux failures (mislabelled file, new port, moved log directory, ...). |
| `lab_reset.yml` | Puts a test environment back to the permissive baseline. |

## Design decisions

- **Policy is data.** What each tier needs (ports, paths, booleans, modules) lives in
  `inventory/group_vars/<tier>/selinux.yml`; the roles are generic. App roles contain no
  SELinux tasks: app teams state what they need, the platform turns it into policy.
- **Least privilege.** The web tier uses `httpd_can_network_relay` (proxy-type ports only)
  plus one labelled backend port, not `httpd_can_network_connect` (any port). acme-api,
  which has no stock policy, gets a custom module (`policy/acme_api`) instead of running
  unconfined. `audit2allow` output is shown for review, never applied.
- **The gate is evidence-based.** Each host must show zero denials since the current policy
  was applied, measured on that host's own clock. A changed policy restarts the
  observation window automatically; re-applying an unchanged policy does not
  (`selinux_policy_reset_window: true` does it explicitly after a manual fix).
- **A marker decides what automation may do.** Enforce writes
  `/var/lib/acme-selinux/enforced` after the soak; break-glass rollback removes it. Drift
  only holds marked hosts at Enforcing, so it reverts an unapproved `setenforce 0` but
  never undoes an approved rollback.
- **Root causes, not rows.** One mislabelled data directory produces hundreds of AVC
  records. The audit groups them into the change a person would make, which is what a
  change board needs.
- **Platform findings are reported, not hidden.** Denials from components ACME does not
  own (the hypervisor's guest agent, a monitoring container) are listed in the audit.
  Only the qemu guest agent noise is suppressed, with a `dontaudit`-only module
  (`policy/qemu_ga_noise`) that grants nothing.

## The demo application

A three-tier app built from things that commonly break under SELinux:

| Tier | Non-standard configuration | Fix |
|---|---|---|
| web (httpd) | Port 8090; docroot and logs under `/data/acme`; reverse proxy to the API on 8282 | `seport` 8090 and 8282 as `http_port_t`; `sefcontext` `httpd_sys_content_t` / `httpd_log_t`; `httpd_can_network_relay` |
| app (acme-api, Python) | No SELinux policy; runtime socket name changes every start (`/run/acme/admin-<pid>.sock`) | Custom module `acme_api`: own domain, file types and port type; a directory rule so new sockets inherit the right type |
| db (PostgreSQL) | `PGDATA=/data/pgsql`, port 5433, socket directory `/run/acme-pgsql` | `sefcontext` `postgresql_db_t` / `postgresql_var_run_t`; `seport` 5433 as `postgresql_port_t` |

## Run it in Ansible Automation Platform

Tested on AAP 2.5 (Controller 4.6, EDA 1.1) with `inventory_rhdp/`: `rhel-1` runs the web
tier, `rhel-2` runs app and db. The AAP objects were created in the UI:

| Object | Settings |
|---|---|
| Project | This repository. Collections install from `collections/requirements.yml` on sync. |
| Inventory | Sourced from the project: `inventory_rhdp/hosts.yml`. |
| Job templates | One per playbook. **Policy**: prompt for Job type (Check/Run), Show changes, Limit and Variables. **Enforce** and **Rollback**: prompt for Limit. **Drift**: prompt for Limit and Job type (EDA passes both). |
| Surveys | Rollback: `change_ref` (required). EDA forwarder: `selinux_eda_url`, `selinux_eda_user`, `selinux_eda_password` (password type). Lab reset: `confirm_reset`. |
| Workflow | Audit → Policy (Check + diff) → **approval** → Policy (Run) → Enforce; Rollback on failure. |
| Schedule | Drift every 15 minutes. |
| EDA | Project = this repository. Event Stream with a Basic credential. Rulebook activation running `rulebooks/selinux_drift_aap.yml`, which launches the Drift job template for the host that sent the event. |

The forwarder must use the Event Stream URL on the platform's public route; the URL the
UI shows may use an internal hostname the nodes cannot resolve.

## Run it locally

```bash
lab/setup-controller.sh                   # once: venv with ansible-core, ansible-lint, ansible-rulebook + collections
source lab/env.sh                         # venv + local run log (logs/ansible.log)
ansible-playbook playbooks/acme_deploy.yml -e acme_lab_baseline=true   # app, all hosts permissive
ansible-playbook playbooks/selinux_audit.yml
ansible-playbook playbooks/selinux_policy.yml --check --diff
ansible-playbook playbooks/selinux_policy.yml
ansible-playbook playbooks/selinux_enforce.yml
ansible-playbook playbooks/selinux_drift.yml
```

Everything in `lab/` is local only: VM helpers, the environment file, and the
`ansible-rulebook` version of the EDA rulebook. Building the VMs: [docs/local-lab.md](docs/local-lab.md).

## Repository layout

```
ansible.cfg                shared settings (local runs and AAP)
requirements.yml           collections (collections/requirements.yml links here for AAP)
inventory/                 local lab inventory; its group_vars hold the declared policy per tier
inventory_rhdp/            RHDP inventory; reuses those group_vars, plus host_vars for rhel-2
playbooks/                 entry points (see the tables above)
roles/
  acme_web, acme_api, acme_db    the demo application (no SELinux tasks)
  selinux_audit                  ausearch -> root causes (files/avc_summary.py) -> report + verdict
  selinux_policy                 modules -> sefcontext -> restorecon -> seport -> seboolean
  selinux_enforce                gate, switch, soak, persist, rollback
  selinux_drift                  detection, attribution, remediation
  selinux_from_disabled          kernel arguments, permissive, relabel, verify
  selinux_eda_forwarder          auditd -> EDA forwarder service
policy/                    custom SELinux modules (.te / .fc / .if)
rulebooks/                 EDA rulebook for AAP
tests/                     audit report evaluation against ground truth; chaos runner (local)
lab/                       local lab only
docs/                      local lab build, lessons learned
```

## Results

Local lab (four VMs):

- **Zero downtime:** 543 requests through web, app and db during the rolling switch to Enforcing, 0 errors.
- **Gate:** a host with a deliberately broken boolean was refused and never switched; the others enforced.
- **Automatic rollback:** a broken canary was detected after 1 s and rolled back; about 0.5 s of failed requests.
- **Audit accuracy:** 12 of 12 host-level checks pass across 8 ground-truth cases (`tests/test_audit_report.yml`), with counts matching an independent raw count.
- **Chaos:** mislabelled file, new port, moved log directory and restored database directory: each diagnosed by the audit and fixed through Ansible.
- **Disabled host:** `selinux=0` + `SELINUX=disabled` to permissive with a full relabel in 93 s, then to Enforcing through the normal gate.
- **EDA (ansible-rulebook):** `setenforce 0` reverted automatically in 21 to 23 s.

AAP on RHDP (two nodes):

- **Baseline audit:** 66 AVC records grouped into 9 root causes (7 for the application, 2 platform findings), plus acme-api running unconfined. After the policy: YES on both hosts.
- **Rolling enforce** with live traffic: all requests answered 200.
- **Workflow** with approval, **break-glass** rollback with a required ticket, and drift leaving the rolled-back host alone until it was re-enforced through the gate.
- **EDA:** `setenforce 0` on a node launched the Drift job for that node through the Event Stream, and the node returned to Enforcing.
- **Chaos:** a mislabelled page went from 403 to 200 with one Policy run (`restorecon`).

## Known limitations

- **The audit job succeeds when its verdict is NO.** The workflow continues to the approval
  step, where a person should reject it, and the gate re-checks every host. Failing the job
  on NO would stop the workflow earlier but also blocks on an already-fixed finding.
- **Report files are written inside the AAP job's container** and are not kept. The Markdown
  report is printed into the job output, which AAP retains; in production the JSON report and
  the job events would go to a SIEM or artifact store.
- **Platform denials count against the gate.** On RHDP, `systemctl daemon-reload` (for example
  when the forwarder is installed) triggers a denial between systemd and a monitoring
  container. Running a gate after that requires restarting the observation window. A
  reviewed list of accepted findings that the gate skips (and the audit still reports)
  would remove this.
- **The forwarder is a shell script that tails the audit log**, and it runs unconfined (the
  audit reports it as REVIEW). Production should use a supported log pipeline.
- **The audit only sees code paths that ran during its window** (month-end jobs) and cannot
  see denials hidden by `dontaudit` rules. Both are stated in every report.
- **Two mislabelled directories with the same type are one root cause**; the report lists both paths.
- **Undeclared booleans are reported, not reverted**, because they may belong to another team.
- **`acme_db_password` is a lab-only value in Git.** Use Ansible Vault or an AAP credential otherwise.

Lessons learned while building and testing: [docs/lessons.md](docs/lessons.md).
