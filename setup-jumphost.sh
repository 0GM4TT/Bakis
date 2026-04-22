#!/bin/bash
# setup-jumphost.sh
# Run this once on the CentOS jumphost to prepare the Ansible environment
# Usage: bash setup-jumphost.sh

set -e  # exit on any error

# Ensure script is not run as root
if [ "$EUID" -eq 0 ]; then
    echo "ERROR: Do not run this script as root. Run as a regular user."
    exit 1
fi

echo "==> Updating system packages..."
sudo dnf update -y

echo "==> Installing dependencies..."
sudo dnf install -y python3 python3-pip sshpass git

echo "==> Installing EPEL repository..."
sudo dnf install -y epel-release

echo "==> Installing mDNS support (avahi + nss-mdns)..."
sudo dnf install -y nss-mdns avahi

echo "==> Configuring nsswitch.conf for mDNS resolution..."
if ! grep -q 'mdns4_minimal' /etc/nsswitch.conf; then
    sudo sed -i 's/^hosts:.*/hosts:      files mdns4_minimal [NOTFOUND=return] dns myhostname/' /etc/nsswitch.conf
    echo "==> nsswitch.conf updated"
else
    echo "==> nsswitch.conf already configured, skipping..."
fi

echo "==> Enabling and starting avahi-daemon..."
sudo systemctl enable --now avahi-daemon

echo "==> Opening firewall for mDNS..."
sudo firewall-cmd --add-service=mdns --permanent
sudo firewall-cmd --reload

echo "==> Adding Pi nodes to /etc/hosts..."
if ! grep -q 'k3s-master' /etc/hosts; then
    echo "192.168.50.200 k3s-master
192.168.50.201 k3s-worker1
192.168.50.202 k3s-worker2" | sudo tee -a /etc/hosts
    echo "==> /etc/hosts updated"
else
    echo "==> /etc/hosts already configured, skipping..."
fi

echo "==> Installing ansible-core..."
pip3 install --user ansible-core

echo "==> Adding ~/.local/bin to PATH if not already there..."
if ! grep -q '.local/bin' ~/.bashrc; then
    echo 'export PATH=$PATH:~/.local/bin' >> ~/.bashrc
fi
export PATH=$PATH:~/.local/bin

echo "==> Verifying ansible installation..."
ansible --version

echo "==> Installing required Ansible collections..."
ansible-galaxy collection install community.general
ansible-galaxy collection install kubernetes.core
ansible-galaxy collection install ansible.posix

echo "==> Generating SSH keypair for Ansible if not exists..."
if [ ! -f ~/.ssh/ansible_id ]; then
    ssh-keygen -t rsa -b 4096 -f ~/.ssh/ansible_id -C "ansible-jumphost" -N ""
    echo "==> SSH keypair created at ~/.ssh/ansible_id"
else
    echo "==> SSH keypair already exists, skipping..."
fi

echo "==> Your Ansible public key (copy this somewhere safe):"
cat ~/.ssh/ansible_id.pub

echo "==> Installing kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
kubectl version --client

echo "==> Creating .kube directory..."
mkdir -p ~/.kube

echo "==> Adding /usr/local/bin to PATH for root..."
if ! grep -q '/usr/local/bin' ~/.bashrc; then
    echo 'export PATH=$PATH:/usr/local/bin' >> ~/.bashrc
fi
export PATH=$PATH:/usr/local/bin

echo "==> Installing virtctl..."
KUBEVIRT_VERSION="v1.8.0"
curl -L -o virtctl "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-amd64"
chmod +x virtctl
sudo mv virtctl /usr/local/bin/

echo "==> Testing mDNS resolution..."
ping -c 1 k3s-master.local 2>/dev/null && echo "mDNS working!" || echo "WARNING: mDNS not resolving yet — try restarting avahi-daemon after reboot"

echo ""
echo "================================================"
echo " Jumphost setup complete."
echo " Next step: run the bootstrap playbook:"
echo " ansible-playbook playbooks/00_bootstrap.yml --ask-pass"
echo "================================================"