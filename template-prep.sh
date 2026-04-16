#!/bin/bash

# =============================================================================
# Ubuntu 24.04 vCenter Template Preparation Script
# =============================================================================

set -euo pipefail

# --- Colors for output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- Must run as root ---
[[ $EUID -ne 0 ]] && error "This script must be run as root."

# =============================================================================
# 1. SYSTEM CONFIGURATION
# =============================================================================

log "Setting timezone to Europe/Amsterdam..."
timedatectl set-timezone Europe/Amsterdam

log "Setting locale..."
localectl set-locale LANG=en_US.UTF-8

log "Suppressing daemon restart prompts..."
sed -i "/#\$nrconf{restart} = 'i';/s/.*/\$nrconf{restart} = 'a';/" \
    /etc/needrestart/needrestart.conf

# =============================================================================
# 2. SYSTEM UPDATE & PACKAGES
# =============================================================================

log "Updating system..."
export DEBIAN_FRONTEND=noninteractive

apt update -y
apt upgrade -y
apt autoremove -y
apt clean -y

log "Installing required packages..."
apt install -y \
    curl wget git unzip \
    net-tools ca-certificates \
    cloud-init cloud-guest-utils \
    cloud-image-utils cloud-initramfs-growroot \
    open-iscsi openssh-server \
    open-vm-tools \
    apparmor \
    chrony

# =============================================================================
# 3. TIME SYNC (CHRONY) — Dynamic NTP via gateway
# =============================================================================

log "Enabling Chrony time sync..."
systemctl enable --now chrony

log "Installing NTP gateway script..."
cat > /usr/local/bin/set-ntp-gateway.sh << 'EOF'
#!/bin/bash

# Wait for network to be up
sleep 5

# Get the default gateway IP
GATEWAY=$(ip route show default | awk '/default/ {print $3}' | head -n1)

if [ -z "$GATEWAY" ]; then
    echo "No gateway found, skipping NTP configuration."
    exit 1
fi

echo "Setting NTP server to gateway: $GATEWAY"

CHRONY_CONF="/etc/chrony/chrony.conf"

# Remove any previous block we added (in case of reboot/re-run)
sed -i '/# BEGIN NTP GATEWAY CONFIG/,/# END NTP GATEWAY CONFIG/d' $CHRONY_CONF

# Comment out any existing pool/server lines
sed -i '/^pool /s/^/#/' $CHRONY_CONF
sed -i '/^server /s/^/#/' $CHRONY_CONF

# Append the gateway NTP block at the end
cat >> $CHRONY_CONF <<EOFINNER

# BEGIN NTP GATEWAY CONFIG
server $GATEWAY iburst prefer
# END NTP GATEWAY CONFIG
EOFINNER

# Restart chrony to apply
systemctl restart chrony

echo "Done. NTP server set to $GATEWAY"
EOF

chmod +x /usr/local/bin/set-ntp-gateway.sh

log "Creating ntp-gateway systemd service..."
cat > /etc/systemd/system/ntp-gateway.service << 'EOF'
[Unit]
Description=Set NTP server to network gateway
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/set-ntp-gateway.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable ntp-gateway.service

# =============================================================================
# 4. SSH HARDENING
# =============================================================================

log "Hardening SSH..."
sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl enable ssh

# =============================================================================
# 5. NODE EXPORTER
# =============================================================================

log "Installing Node Exporter..."
curl -sSfL https://raw.githubusercontent.com/carlocorradini/node_exporter_installer/main/install.sh | sh -

# =============================================================================
# 6. CHRONY EXPORTER
# =============================================================================

log "Installing Chrony Exporter..."
CHRONY_EXPORTER_VERSION="0.13.3"
CHRONY_EXPORTER_ARCHIVE="chrony_exporter-${CHRONY_EXPORTER_VERSION}.linux-amd64.tar.gz"

wget "https://github.com/SuperQ/chrony_exporter/releases/download/v${CHRONY_EXPORTER_VERSION}/${CHRONY_EXPORTER_ARCHIVE}"
tar xvf "${CHRONY_EXPORTER_ARCHIVE}"
systemctl stop chrony_exporter 2>/dev/null || true
cp "chrony_exporter-${CHRONY_EXPORTER_VERSION}.linux-amd64/chrony_exporter" /usr/local/bin/
chmod +x /usr/local/bin/chrony_exporter
rm -rf "${CHRONY_EXPORTER_ARCHIVE}" "chrony_exporter-${CHRONY_EXPORTER_VERSION}.linux-amd64"

cat > /etc/systemd/system/chrony_exporter.service << 'EOF'
[Unit]
Description=Prometheus Chrony Exporter
After=network-online.target chrony.service
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/chrony_exporter --web.listen-address=:9200
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable chrony_exporter

# =============================================================================
# 7. DISABLE SWAP
# =============================================================================

log "Disabling swap..."
swapoff -a
sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# =============================================================================
# 8. DISABLE UNATTENDED UPGRADES
# =============================================================================

log "Disabling unattended upgrades..."
systemctl disable unattended-upgrades
apt remove -y unattended-upgrades

# =============================================================================
# 9. CLOUD-INIT CONFIGURATION
# =============================================================================

log "Configuring cloud-init datasources (NoCloud only)..."
cat > /etc/cloud/cloud.cfg.d/90-dpkg.cfg << 'EOF'
datasource_list: [ NoCloud, None ]
EOF

log "Disabling cloud-init network management..."
cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg << 'EOF'
network: {config: disabled}
EOF

# =============================================================================
# 10. NETPLAN — BASE NETWORK CONFIG
# =============================================================================

log "Writing base Netplan config..."
cat > /etc/netplan/00-base.yaml << 'EOF'
network:
  version: 2
  renderer: NetworkManager
  ethernets:
    id0:
      match:
        name: "e*"
      dhcp4: true
EOF

chmod 600 /etc/netplan/00-base.yaml

# =============================================================================
# 11. TEMPLATE CLEANUP
# =============================================================================

log "Cleaning logs..."
[ -f /var/log/audit/audit.log ] && cat /dev/null > /var/log/audit/audit.log
[ -f /var/log/wtmp ]            && cat /dev/null > /var/log/wtmp
[ -f /var/log/lastlog ]         && cat /dev/null > /var/log/lastlog
journalctl --rotate
journalctl --vacuum-time=1s

log "Removing udev persistent net rules..."
rm -f /etc/udev/rules.d/70-persistent-net.rules

log "Cleaning temp directories..."
rm -rf /tmp/* /var/tmp/*

log "Removing SSH host keys (regenerated on first boot)..."
rm -f /etc/ssh/ssh_host_*

log "Resetting machine-id..."
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -s /etc/machine-id /var/lib/dbus/machine-id

log "Truncating hostname, hosts, resolv.conf..."
truncate -s 0 /etc/hostname /etc/hosts /etc/resolv.conf
hostnamectl set-hostname localhost

log "Resetting cloud-init state..."
rm -f /etc/cloud/cloud.cfg.d/*.cfg

# Re-apply configs after cleanup
cat > /etc/cloud/cloud.cfg.d/90-dpkg.cfg << 'EOF'
datasource_list: [ NoCloud, None ]
EOF

cat > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg << 'EOF'
network: {config: disabled}
EOF

cloud-init clean -s -l

log "Cleaning shell history..."
unset HISTFILE
history -cw
cat /dev/null > ~/.bash_history
rm -f /root/.bash_history

# =============================================================================
# DONE
# =============================================================================

log "Template preparation complete. Shutting down..."
shutdown -h now
