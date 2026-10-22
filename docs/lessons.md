# Lessons learned

Every item below happened while building and testing this project, in the local lab or
in AAP on RHDP. Each one is fixed in the code or the procedure.

## SELinux

**1. `ausearch` returned nothing when run from Ansible.**
Without a terminal, `ausearch` reads standard input instead of the audit logs, so the first
audit reported zero denials everywhere. Every `ausearch` call now uses `--input-logs`.

**2. Stock policy already labels some "custom" paths.**
`/srv/*/www` is `httpd_sys_content_t` and `/srv/.*` is `var_t`, so a docroot under `/srv`
tested nothing. The demo uses `/data/...`, and fixes are checked with `matchpathcon` first.

**3. `/run` and `/var/run` are the same in file context rules.**
A rule for `/run/...` is rejected. Rules and module `.fc` files use `/var/run/...`.

**4. A stock install already has a permissive domain.**
`rhcd_t` (Red Hat connector) ships permissive. The policy role only removes permissive
domains it added itself, and drift reports the rest.

**5. A log file in an unlabelled directory became `httpd_cache_t`.**
A named type transition labelled it. The fix is a rule for the directory, then a relabel.

**6. RHEL policy interfaces differ from upstream reference policy.**
`files_search_opt` does not exist on RHEL, so the first module failed to compile. Check
interface names in `/usr/share/selinux/devel/include` before using them.

**7. Not every failure is SELinux.**
A 20-second acme-api start was a DNS timeout in Python's `getfqdn()`, identical in an
unconfined shell. Reproduce outside the domain before changing policy.

**8. A confined service restarted before its port was labelled.**
Restarting straight after `semodule -i` produced a bind denial. The policy role now
restarts confined services after ports and booleans are in place.

**9. Permissive logs each unique denial once.**
Until the AVC cache is flushed, five failing requests produce one record. Raw counts
understate frequency; root causes are the right measure.

**10. `seboolean` with `persistent: true` ignores a runtime-only change.**
A `setsebool` without `-P` stayed broken. The policy role sets booleans twice: persistent,
then runtime.

**11. `audit2why` and `audit2allow` suggest dangerous fixes.**
For a port denial they suggest `nis_enabled` (bind any port); for a mislabel, broad allow
rules. The audit shows them as hints next to the real root cause and never applies them.

**12. Start-up-only denials disappear from calendar windows.**
A port bind is logged once, when the service starts. A `this-week` window drops it every
Sunday. The audit uses a rolling 30-day window, or the time of the last policy change or
reset, whichever applies.

**13. `dontaudit` hides denials.**
A host can report zero denials and still fail. Every report says so; `semodule -DB` shows
hidden denials while reproducing, `semodule -B` restores the rules.

**14. Components outside ACME's control produce denials.**
On RHDP the hypervisor's guest agent searches container directories constantly, and
`systemctl daemon-reload` triggers a denial between systemd and a monitoring container.
The guest agent noise is suppressed with a `dontaudit`-only module that grants nothing;
the rest is reported to its owner rather than hidden.

## Ansible

**15. `ansible-rulebook` runs playbooks from a temporary copy.**
Paths built from `inventory_dir` or `playbook_dir` pointed into the copy, so reports and
module sources were not found. Paths are built from `ansible_config_file | dirname`;
`ANSIBLE_CONFIG` and the inventory directory must be passed to `ansible-rulebook`.

**16. `set -o pipefail` with `grep -q` inverts results.**
`grep -q` exits early, the upstream command gets SIGPIPE and the pipeline fails. It left
`selinux=0` in place on the disabled host; the verify step caught it.

**17. Strict conditionals reject string booleans.**
`-e flag=true` and survey answers arrive as strings, which ansible-core 2.19 refuses in a
condition. Every boolean variable is used with `| bool`.

**18. Test with the ansible-core your platform runs.**
AAP 2.5's execution environment has ansible-core 2.16, where `set_fact` turns the string
`NO` into `False`. The audit verdict is computed inside a dictionary, and a second
virtualenv with 2.16 is used for testing. Collections are pinned to versions 2.16 supports.

**19. Check mode skips work that later tasks depend on.**
Reports were not written in check mode, and a module compile with `chdir` failed because
check mode had not created the folder. Report tasks run with `check_mode: false`; compile
and load print "would compile" instead. Test `--check` on a clean host.

**20. Lists from two groups are not merged.**
On RHDP one host is both `app` and `db`. Ansible kept only the later group's
`selinux_ports`, silently dropping the API port. That host has `host_vars` with the
combined lists.

**21. An apostrophe in a comment broke a `shell:` task.**
Ansible's argument splitting saw unbalanced quotes. Keep quotes out of free-form shell
comments.

**22. A deploy playbook that sets Permissive is dangerous.**
Re-running it to undo a change would have silently de-enforced the fleet. Setting the
baseline is now opt-in (`acme_lab_baseline=true`).

## AAP and EDA

**23. Files written on the controller disappear with the job.**
In AAP the playbook runs in a short-lived container, and `reports/` is not in Git. The
roles create the folder, and the Markdown report is printed into the job output, which AAP
keeps.

**24. `log_path` in `ansible.cfg` warns on every AAP job.**
The container cannot write the file. The local run log is enabled by `lab/env.sh` instead.

**25. The Event Stream URL in the UI used an internal hostname.**
The nodes could not resolve it. The forwarder uses the same path on the platform's public
route.

**26. The default decision environment could not be pulled.**
It needs a registry credential for registry.redhat.io. Either attach one or use a decision
environment the platform can pull.

**27. Survey passwords with quotes broke the forwarder's credentials.**
Shell and curl quoting truncated them. The forwarder sends a ready-made Basic header
(base64 has no quotes), stored in a root-only file.

**28. Ad-hoc commands in AAP reject `{{ }}` in arguments.**
Use a job template for anything templated.

## Process

**29. Clock skew made the gate blind.**
After snapshot reverts the guests were hours behind the controller, so every time window
was in the guests' future and counted nothing. All comparisons use the target host's own
clock, a marker in the future is refused, and lab reverts step the clocks.

**30. Drift undid an approved rollback.**
Drift switched every Permissive host to Enforcing, including one rolled back during an
incident, and skipped the gate for hosts never migrated. Enforce now writes a "migrated"
marker; rollback removes it; drift only enforces marked hosts.

**31. Denials after the policy block a later gate, by design.**
A chaos test created real denials. Fixing the label made the app work, but the gate still
refused to re-enforce a rolled-back host, because the policy itself had not changed. After a
real fix, `selinux_policy_reset_window: true` restarts the observation window. In a demo,
inject failures after the last enforce.

**32. A forgotten EDA listener re-enforced hosts during a test.**
A rulebook left running from the day before reacted to a test. Check rulebook activations
before testing anything that changes the SELinux mode.

**33. The first automatic rollback took 30 seconds.**
The soak slept before checking, and 125 requests failed. It now checks every second and
aborts on the first failure: about 0.5 seconds of failed requests.

**34. The first audit report was misleading.**
It counted every permission on every file ("17 unique denials" for one directory), said
"ready" for an unconfined service, ignored SELINUX_ERR records and was not tied to the fix.
It now reports root causes, the REVIEW and NOT ASSESSABLE verdicts and SELINUX_ERR, uses
the policy time as its window, and is evaluated against ground truth
(`tests/test_audit_report.yml`).
