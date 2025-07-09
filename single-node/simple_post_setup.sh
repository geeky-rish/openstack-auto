#!/bin/bash

# Simple OpenStack Post-Setup Script
# Run this as stack user after DevStack installation

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date '+%H:%M:%S')] $1${NC}"
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

# Source OpenStack credentials
log "Setting up OpenStack environment..."
source /opt/stack/devstack/openrc admin admin

# Create demo project and user
log "Creating demo project and user..."
openstack project create --domain default --description "Demo Project" demo || true
openstack user create --domain default --password demo demo || true
openstack role add --project demo --user demo member || true

# Create flavors
log "Creating flavors..."
openstack flavor create --id 1 --vcpus 1 --ram 512 --disk 1 m1.tiny || true
openstack flavor create --id 2 --vcpus 1 --ram 2048 --disk 20 m1.small || true
openstack flavor create --id 3 --vcpus 2 --ram 4096 --disk 40 m1.medium || true

# Create networks
log "Creating networks..."
openstack network create --external --provider-physical-network public --provider-network-type flat public || true
openstack subnet create --network public --allocation-pool start=192.168.1.225,end=192.168.1.250 --dns-nameserver 8.8.8.8 --gateway 192.168.1.1 --subnet-range 192.168.1.0/24 public-subnet || true

openstack network create private || true
openstack subnet create --network private --dns-nameserver 8.8.8.8 --gateway 10.11.12.1 --subnet-range 10.11.12.0/24 private-subnet || true

# Create router
log "Creating router..."
openstack router create demo-router || true
openstack router set --external-gateway public demo-router || true
openstack router add subnet demo-router private-subnet || true

# Create security group
log "Creating security group..."
openstack security group create demo-sg --description "Demo Security Group" || true
openstack security group rule create --protocol tcp --dst-port 22 demo-sg || true
openstack security group rule create --protocol tcp --dst-port 80 demo-sg || true
openstack security group rule create --protocol icmp demo-sg || true

# Create keypair
log "Creating keypair..."
if [[ ! -f ~/.ssh/id_rsa ]]; then
    ssh-keygen -t rsa -N "" -f ~/.ssh/id_rsa -q
fi
openstack keypair create --public-key ~/.ssh/id_rsa.pub demo-keypair || true

# Create a sample instance
log "Creating sample instance..."
openstack server create --flavor m1.small --image cirros-0.3.4-x86_64-uec --key-name demo-keypair --security-group demo-sg --network private demo-instance || true

# Display final info
echo ""
echo "============================================="
echo "🎉 OPENSTACK IS READY!"
echo "============================================="
echo "🌐 Dashboard: http://$(ip route get 8.8.8.8 | awk '{print $7; exit}')/dashboard"
echo "👤 Admin Login: admin / secret"
echo "👤 Demo Login: demo / demo"
echo ""
echo "✅ Resources Created:"
echo "  - Networks: public, private"
echo "  - Flavors: m1.tiny, m1.small, m1.medium"
echo "  - Security Group: demo-sg"
echo "  - Keypair: demo-keypair"
echo "  - Sample Instance: demo-instance"
echo ""
echo "🚀 GO TO HORIZON NOW AND START CREATING INSTANCES!"
echo "============================================="

success "Setup complete! Access Horizon dashboard now!"