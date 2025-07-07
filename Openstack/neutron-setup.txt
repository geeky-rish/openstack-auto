#!/bin/bash

# Configuration variables (modify these as needed)
NEUTRON_IP="192.168.116.134"              # NAT interface IP (ens33)
MANAGEMENT_IP="100.100.100.3"              # NAT interface IP (ens34)
BRIDGE_IP="100.100.38.12"                  # Bridge interface IP (br-ex)
NEUTRON_HOSTNAME="neutron01"
DOMAIN="moin.com"
CONTROLLER_IP="192.168.116.130"            # Controller node NAT IP
COMPUTE_IP="192.168.116.132"              # Compute node NAT IP
NAT_INTERFACE_1="ens33"                    # First NAT interface name
NAT_INTERFACE_2="ens34"                    # Second NAT interface name
BRIDGE_INTERFACE="br-ex"                   # Bridge interface name
GATEWAY_IP="192.168.116.1"                 # Gateway for NAT interface 1
RABBITMQ_USER="openstack"
RABBITMQ_PASS="rabbit"
NEUTRON_DB_PASS="neutronPass"
SERVICE_PASS="service_pass"
METADATA_SECRET="metadata_secret"

# Exit on any error
set -e

# Function to check if command succeeded
check_error() {
    if [ $? -ne 0 ]; then
        echo "Error: $1"
        exit 1
    fi
}

# Section 1: Update and Upgrade System
echo "Updating and upgrading system..."
apt-get update -y
apt-get dist-upgrade -y
check_error "System update and upgrade failed"

# Section 2: Install Basic Utilities
echo "Installing basic utilities..."
apt-get install -y software-properties-common cpu-checker bridge-utils
check_error "Failed to install basic utilities"

# Section 3: Enable OpenStack Yoga Repository
echo "Enabling OpenStack Yoga repository..."
add-apt-repository cloud-archive:yoga -y
apt-get update -y
check_error "Failed to enable OpenStack Yoga repository"

# Section 4: Check KVM Support
echo "Checking KVM support..."
kvm-ok
check_error "KVM support check failed"

# Section 5: Set Hostname
echo "Setting hostname to $NEUTRON_HOSTNAME..."
echo "$NEUTRON_HOSTNAME" > /etc/hostname
hostname "$NEUTRON_HOSTNAME"
check_error "Failed to set hostname"

# Section 6: Configure /etc/hosts
echo "Configuring /etc/hosts..."
cat << EOF > /etc/hosts
127.0.0.1 localhost
$CONTROLLER_IP controller01.$DOMAIN controller01
$NEUTRON_IP $NEUTRON_HOSTNAME.$DOMAIN $NEUTRON_HOSTNAME
$COMPUTE_IP compute01.$DOMAIN compute01
EOF
check_error "Failed to configure /etc/hosts"

# Section 7: Configure Netplan for 2 NAT and 1 Bridge Interface
echo "Configuring Netplan for NAT ($NAT_INTERFACE_1, $NAT_INTERFACE_2) and Bridge ($BRIDGE_INTERFACE)..."
cat << EOF > /etc/netplan/01-netcfg.yaml
network:
  version: 2
  ethernets:
    $NAT_INTERFACE_1:
      addresses:
        - $NEUTRON_IP/24
      gateway4: $GATEWAY_IP
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
    $NAT_INTERFACE_2:
      addresses:
        - $MANAGEMENT_IP/24
  bridges:
    $BRIDGE_INTERFACE:
      interfaces: []
      addresses:
        - $BRIDGE_IP/24
      parameters:
        stp: false
        forward-delay: 0
EOF
netplan apply
check_error "Failed to configure Netplan"

# Verify network connectivity
echo "Verifying network connectivity..."
ping -c 3 $GATEWAY_IP
check_error "Failed to ping gateway from NAT interface"
ping -c 3 $CONTROLLER_IP
check_error "Failed to ping Controller IP"

# Section 8: Install and Configure NTP
echo "Installing NTP..."
apt-get install -y ntp
check_error "Failed to install NTP"

# Configure NTP to sync with Controller
echo "Configuring NTP..."
cat << EOF > /etc/ntp.conf
server $CONTROLLER_IP iburst
driftfile /var/lib/ntp/ntp.drift
restrict default kod nomodify notrap nopeer noquery
restrict -6 default kod nomodify notrap nopeer noquery
restrict 127.0.0.1
restrict -6 ::1
EOF
service ntp restart
check_error "Failed to restart NTP service"

# Section 9: Configure Kernel Networking Parameters
echo "Configuring kernel networking parameters..."
cat << EOF > /etc/sysctl.conf
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
EOF
sysctl -p
check_error "Failed to apply sysctl settings"

# Section 10: Install and Configure Open vSwitch
echo "Installing Open vSwitch..."
apt-get install -y openvswitch-switch
check_error "Failed to install Open vSwitch"

# Create External and Internal Bridges
echo "Creating external bridge br-ex and internal bridge br-int..."
ovs-vsctl add-br br-ex
ovs-vsctl add-br br-int
check_error "Failed to create OVS bridges"

# Add second NAT interface to br-ex
echo "Adding $NAT_INTERFACE_2 to br-ex..."
ovs-vsctl add-port br-ex $NAT_INTERFACE_2
check_error "Failed to add $NAT_INTERFACE_2 to br-ex"

# Validate OVS Bridges
echo "Validating OVS bridges..."
ovs-vsctl show
check_error "Failed to validate OVS bridges"

# Section 11: Install Neutron Components
echo "Installing Neutron components..."
apt-get install -y neutron-openvswitch-agent neutron-l3-agent neutron-dhcp-agent neutron-metadata-agent python3-neutronclient
check_error "Failed to install Neutron components"

# Section 12: Configure Neutron ML2 Plugin
echo "Configuring Neutron ML2 plugin..."
cat << EOF > /etc/neutron/plugins/ml2/openvswitch_agent.ini
[agent]
tunnel_types = vxlan
l2_population = True
arp_responder = true

[ovs]
local_ip = $MANAGEMENT_IP
bridge_mappings = physnet1:br-ex
datapath_type = system

[securitygroup]
enable_security_group = true
firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver
EOF
check_error "Failed to configure Neutron ML2 plugin"

# Section 13: Configure Neutron L3 Agent
echo "Configuring Neutron L3 agent..."
cat << EOF > /etc/neutron/l3_agent.ini
[DEFAULT]
interface_driver = openvswitch
external_network_bridge = br-ex
router_delete_namespaces = True
verbose = True
EOF
check_error "Failed to configure Neutron L3 agent"

# Section 14: Configure Neutron DHCP Agent
echo "Configuring Neutron DHCP agent..."
cat << EOF > /etc/neutron/dhcp_agent.ini
[DEFAULT]
enable_isolated_metadata = True
interface_driver = openvswitch
dhcp_driver = neutron.agent.linux.dhcp.Dnsmasq
dnsmasq_config_file = /etc/neutron/dnsmasq-neutron.conf
force_metadata = true
dnsmasq_dns_servers = 1.1.1.1,8.8.8.8,8.8.4.4
EOF

cat << EOF > /etc/neutron/dnsmasq-neutron.conf
dhcp-option-force=26,1400
EOF
check_error "Failed to configure Neutron DHCP agent"

# Section 15: Configure Neutron Metadata Agent
echo "Configuring Neutron Metadata agent..."
cat << EOF > /etc/neutron/metadata_agent.ini
[DEFAULT]
nova_metadata_host = $CONTROLLER_IP
nova_metadata_port = 8775
nova_metadata_protocol = http
metadata_proxy_shared_secret = $METADATA_SECRET
memcache_servers = $CONTROLLER_IP:11211
EOF
check_error "Failed to configure Neutron Metadata agent"

# Section 16: Configure Neutron
echo "Configuring Neutron..."
cat << EOF > /etc/neutron/neutron.conf
[DEFAULT]
debug = False
core_plugin = ml2
service_plugins = router
auth_strategy = keystone
state_path = /var/lib/neutron
allow_overlapping_ips = True
transport_url = rabbit://$RABBITMQ_USER:$RABBITMQ_PASS@$CONTROLLER_IP
interface_driver = openvswitch
bind_host = 0.0.0.0
bind_port = 9696
lock_path = /var/lib/neutron/tmp

[keystone_authtoken]
www_authenticate_uri = http://$CONTROLLER_IP:5000
auth_url = http://$CONTROLLER_IP:5000
memcached_servers = $CONTROLLER_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = $SERVICE_PASS
insecure = false

[database]
connection = mysql+pymysql://neutronUser:$NEUTRON_DB_PASS@$CONTROLLER_IP/neutron

[nova]
auth_url = http://$CONTROLLER_IP:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = nova
password = $SERVICE_PASS

[oslo_concurrency]
lock_path = /var/lib/neutron/tmp

[placement]
auth_url = http://$CONTROLLER_IP:5000
os_region_name = RegionOne
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = $SERVICE_PASS
EOF
check_error "Failed to configure neutron.conf"

# Section 17: Restart Neutron Services
echo "Restarting Neutron services..."
service neutron-openvswitch-agent restart
service neutron-l3-agent restart
service neutron-dhcp-agent restart
service neutron-metadata-agent restart
service dnsmasq restart
check_error "Failed to restart Neutron services"

# Section 18: Restart Neutron Server on Controller
echo "Restarting Neutron server on Controller..."
ssh root@$CONTROLLER_IP "service neutron-server restart"
check_error "Failed to restart Neutron server on Controller"

# Section 19: Final Verification
echo "Verifying Neutron agents on Controller..."
source /root/creds
neutron agent-list
check_error "Failed to verify Neutron agents"

echo "Neutron node setup completed successfully!"
echo "Run 'neutron agent-list' on the Controller node to verify all agents are up."