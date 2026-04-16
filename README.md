# Ubuntu 24.04 vCenter Template Preparation

A script to prepare an Ubuntu 24.04 VM for use as a vCenter template.

> ⚠️ **Not fully tested yet. Use at your own discretion.**

---

## What it does

* Updates the system and installs required packages
* Configures timezone (Europe/Amsterdam), locale and time sync (Chrony)
* Dynamically sets the NTP server to the default gateway on each boot via a systemd service
* Installs Chrony Exporter for Prometheus monitoring (port `:9200`)
* Hardens SSH and enables it on boot
* Installs Node Exporter for Prometheus monitoring
* Disables swap (required for Kubernetes/Rancher)
* Disables unattended upgrades
* Configures cloud-init (NoCloud only)
* Writes a base Netplan config (DHCP on any ethernet interface)
* Cleans up logs, temp files, SSH host keys, machine-id and shell history
* Shuts down automatically when done

---

## Usage

```bash
curl -sSfL https://raw.githubusercontent.com/rrvicompany/ubuntu-vcenter-template/main/template-prep.sh | sudo bash
```

Or manually:

```bash
chmod +x template-prep.sh
sudo ./template-prep.sh
```

---

## Prometheus Exporters

| Exporter | Port | Description |
|---|---|---|
| Node Exporter | `:9100` | System metrics (CPU, memory, disk, network) |
| Chrony Exporter | `:9200` | NTP sync status and metrics |

---

## Workflow

1. Deploy a VM from the existing template
2. Make any additional changes
3. Run the script
4. Convert to template in vCenter → **Right-click VM → Convert to Template**

> ⚠️ This is a one-way operation. Do not run on a VM you are still using.
