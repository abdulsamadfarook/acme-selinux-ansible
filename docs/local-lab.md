# Local lab

Four RHEL 9.8 VMs on libvirt, driven from the host with the Ansible CLI. Not used by AAP.

```
        control node (the KVM host)   .venv in this repository
        192.168.122.1 = also the local EDA webhook (port 5000)
                        |  libvirt "default" NAT network, DHCP reservations
  +---------------+-----+----------+----------------+
web01 .11       app01 .12        db01 .13         legacy01 .14
httpd :8090 --> acme-api :8282 --> PostgreSQL :5433  starts SELinux-disabled
```

Why four nodes: a multi-tier app where each tier needs different policy, a rolling
rollout that only means something with several hosts, and a disabled host for the
relabel procedure. 2 vCPU / 2 GB each is enough.

## Build

The VM build tooling (a kickstart file and a `virt-install` wrapper) lives outside this
repository. In short:

1. Install KVM tooling:
   `sudo apt install -y qemu-kvm libvirt-daemon-system virtinst genisoimage python3-venv virt-viewer`,
   add yourself to the `libvirt` and `kvm` groups.
2. Download the RHEL 9.8 **DVD** ISO from developers.redhat.com (it contains every package,
   so installs need no subscription).
3. Reserve fixed addresses on the `default` network, for example:
   ```bash
   virsh -c qemu:///system net-update default add-last ip-dhcp-host \
     "<host mac='52:54:00:ac:00:11' name='web01' ip='192.168.122.11'/>" --live --config
   ```
   (.12 app01, .13 db01, .14 legacy01).
4. Kickstart-install the four VMs: minimal RHEL 9.8 plus httpd, postgresql-server,
   python3-psycopg2, policycoreutils-python-utils, setroubleshoot-server,
   selinux-policy-devel; user `abdul` with sudo and your SSH key; SELinux enforcing.
5. Eject the install media and take a first snapshot: `lab/lab.sh snap fresh-install`.

## Control node

```bash
lab/setup-controller.sh        # venv with ansible-core, ansible-lint, ansible-rulebook + collections
source lab/env.sh              # activates the venv, enables logs/ansible.log
ansible all -m ping
```

The lab's SSH user is set in `inventory/hosts.yml` (`ansible_user`), not in `ansible.cfg`,
so AAP is not affected by it.

## Baseline and snapshots

```bash
ansible-playbook playbooks/acme_deploy.yml -e acme_lab_baseline=true   # app + permissive
lab/lab.sh snap acme-permissive

NODES=legacy01 lab/lab.sh revert fresh-install
ansible-playbook playbooks/lab_legacy_disable.yml                      # legacy01: SELinux disabled
NODES=legacy01 lab/lab.sh snap legacy-disabled
```

`lab/lab.sh` takes and reverts snapshots on all nodes at once (`snap`, `revert`, `list`,
`delete`, `start`, `stop`, `console`). A revert also steps the guest clocks
(`playbooks/lab_timesync.yml`): a snapshot restores the clock to the moment it was taken,
and every time-window check (audit, gate) would otherwise be wrong.

## Checks

```bash
ansible-playbook tests/test_audit_report.yml -e case=baseline   # audit report vs ground truth
ansible-playbook playbooks/smoke_test.yml                       # /, /api/health, /api/accounts -> 200
tests/run_chaos.sh                                              # every chaos scenario end to end
```

## Real-time drift without AAP

```bash
ansible-playbook playbooks/eda_forwarder.yml      # forwarder posts to 192.168.122.1:5000 by default
ANSIBLE_CONFIG=$PWD/ansible.cfg ansible-rulebook -r lab/eda/selinux_drift_rulebook.yml -i $PWD/inventory --verbose
# another terminal: ssh abdul@192.168.122.11 sudo setenforce 0   -> Enforcing again in about 20 s
```

`ANSIBLE_CONFIG` and the inventory **directory** are both required: `ansible-rulebook`
runs the playbook from a temporary copy ([lessons.md](lessons.md), item 15).

## Disabled host

```bash
NODES=legacy01 lab/lab.sh revert legacy-disabled
ansible-playbook playbooks/selinux_from_disabled.yml      # targets the legacy group, one host at a time
```
