#!/bin/bash

# Configuration variables (modify these as needed)
COMPUTE_IP="192.168.116.132"              # NAT interface IP (ens33)
MANAGEMENT_IP="100.100.100.2"              # Bridge interface IP (br0)
COMPUTE_HOSTNAME="compute01"
DOMAIN="moin.com"
CONTROLLER_IP="192.168.116.130"            # Controller node NAT IP
NEUTRON_IP="192.168.116.134"              # Neutron node NAT IP
NAT_INTERFACE="ens33"                      # NAT interface name
BRIDGE_INTERFACE="br0"                     # Bridge interface name
GATEWAY_IP="192.168.116.1"                 # Gateway for NAT interface
RABBITMQ_USER="openstack"
RABBITMQ_PASS="rabbit"
NOVA_DB_PASS="novaPass"
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
echo "Setting hostname to $COMPUTE_HOSTNAME..."
echo "$COMPUTE_HOSTNAME" > /etc/hostname
hostname "$COMPUTE_HOSTNAME"
check_error "Failed to set hostname"

# Section 6: Configure /etc/hosts
echo "Configuring /etc/hosts..."
cat << EOF > /etc/hosts
127.0.0წ

System: .0.1 localhost
$CONTROLLER_IP $CONTROLLER_HOSTNAME.$DOMAIN $CONTROLLER_HOSTNAME
$NEUTRON_IP neutron01.$DOMAIN neutron01
$COMPUTE_IP $COMPUTE_HOSTNAME.$DOMAIN $COMPUTE_HOSTNAME
EOF
check_error "Failed to configure /etc/hosts"

# Section 7: Configure Netplan for 1 NAT and 1 Bridge Interface
echo "Configuring Netplan for NAT ($NAT_INTERFACE) and Bridge ($BRIDGE_INTERFACE)..."
cat << EOF > /etc/netplan/01-netcfg.yaml
network:
  version: 2
  ethernets:
    $NAT_INTERFACE:
      addresses:
        - $COMPUTE_IP/24
      gateway4: $GATEWAY_IP
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
  bridges:
    $BRIDGE_INTERFACE:
      interfaces: []
      addresses:
        - $MANAGEMENT_IP/24
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

# Configure NTP (default config should sync with controller)
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

# Create Internal Bridge
echo "Creating internal bridge br-int..."
ovs-vsctl add-br br-int
check_error "Failed to create br-int"

# Validate OVS Bridges
echo "Validating OVS bridges..."
ovs-vsctl show
check_error "Failed to validate OVS bridges"

# Section 11: Install and Configure KVM
echo "Installing KVM and libvirt..."
apt-get install -y qemu-kvm libvirt-daemon-system libvirt-daemon virtinst
check_error "Failed to install KVM and libvirt"

# Configure qemu.conf
echo "Configuring qemu.conf..."
cat << EOF > /etc/libvirt/qemu.conf
cgroup_device_acl = [
"/dev/null", "/dev/full", "/dev/zero",
"/dev/random", "/dev/urandom",
"/dev/ptmx", "/dev/kvm", "/dev/kqemu",
"/dev/rtc", "/dev/hpet", "/dev/net/tun"
]
EOF
check_error "Failed to configure qemu.conf"

# Delete default virtual bridge
echo "Deleting default virtual bridge..."
virsh net-destroy default || true
virsh net-undefine default || true
check_error "Failed to delete default virtual bridge"

# Enable live migration
echo "Enabling live migration..."
cat << EOF > /etc/libvirt/libvirtd.conf
listen_tls = 0
listen_tcp = 1
auth_tcp = "none"
EOF
check_error "Failed to configure libvirtd.conf"

# Restart libvirt service
echo "Restarting libvirt service..."
service libvirtd restart
check_error "Failed to restart libvirt service"

# Section 12: Install and Configure Nova Compute
echo "Installing Nova compute components..."
apt-get install -y nova-compute nova-compute-kvm qemu-system-data
check_error "Failed to install Nova compute components"

# Configure nova.conf
echo "Configuring nova.conf..."
cat << EOF > /etc/nova/nova.conf
[DEFAULT]
enabled_apis = osapi_compute,metadata
rpc_backend = rabbit
auth_strategy = keystone
my_ip = $MANAGEMENT_IP
use_neutron = True
firewall_driver = nova.virt.firewall.NoopFirewallDriver
transport_url = rabbit://$RABBITMQ_USER:$RABBITMQ_PASS@$CONTROLLER_IP

[api]
auth_strategy = keystone

[vnc]
enabled = true
server_listen = 0.0.0.0
server_proxyclient_address = $MANAGEMENT_IP
novncproxy_base_url = http://$CONTROLLER_IP:6080/vnc_auto.html

[api_database]
connection = mysql+pymysql://novaUser:$NOVA_DB_PASS@$CONTROLLER_IP/nova_api

[database]
connection = mysql+pymysql://novaUser:$NOVA_DB_PASS@$CONTROLLER_IP/nova

[cinder]
os_region_name = RegionOne

[keystone_authtoken]
www_authenticate_uri = http://$CONTROLLER_IP:5000
auth_url = http://$CONTROLLER_IP:5000
memcached_servers = $CONTROLLER_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = $SERVICE_PASS
insecure = false

[glance]
api_servers = http://$CONTROLLER_IP:9292

[oslo_concurrency]
lock_path = /var/lib/nova/tmp

[neutron]
service_metadata_proxy = True
metadata_proxy_shared_secret = $METADATA_SECRET
auth_url = http://$CONTROLLER_IP:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = $SERVICE_PASS
insecure = false

[placement]
os_region_name = RegionOne
project_domain_name = Default
project_name = service
auth_type = password
user_domain_name = Default
auth_url = http://$CONTROLLER_IP:5000
username = placement
password = $SERVICE_PASS

[wsgi]
api_paste_config = /etc/nova/api-paste.ini
EOF
check_error "Failed to configure nova.conf"

# Configure nova-compute.conf
echo "Configuring nova-compute.conf..."
cat << EOF > /etc/nova/nova-compute.conf
[libvirt]
virt_type = kvm
EOF
check_error "Failed to configure nova-compute.conf"

# Restart Nova compute service
echo "Restarting Nova compute service..."
service nova-compute restart
check_error "Failed to restart Nova compute service"

# Section 13: Install and Configure Neutron Open vSwitch Agent
echo "Installing Neutron Open vSwitch agent..."
apt-get install -y neutron-openvswitch-agent
check_error "Failed to install Neutron Open vSwitch agent"

# Configure Neutron ML2 plugin
echo "Configuring Neutron ML2 plugin..."
cat << EOF > /etc/neutron/plugins/ml2/ml2_conf.ini
[agent]
tunnel_types = vxlan
l2_population = True
arp_responder = true

[ovs]
local_ip = $MANAGEMENT_IP

[securitygroup]
enable_security_group = true
firewall_driver = neutron.agent.linux.iptables_firewall.OVSHybridIptablesFirewallDriver
EOF
check_error "Failed to configure Neutron ML2 plugin"

# Configure Neutron
echo "Configuring Neutron..."
cat << EOF > /etc/neutron/neutron.conf
[DEFAULT]
debug = False
core_plugin = ml2
service_plugins = router
allow_overlapping_ips = True
verbose = True
auth_strategy = keystone
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
transport_url = rabbit://$RABBITMQ_USER:$RABBITMQ_PASS@$CONTROLLER_IP
bind_host = 0.0.0.0
bind_port = 9696
interface_driver = openvswitch
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

[agent]
root_helper = sudo /usr/bin/neutron-rootwrap /etc/neutron/rootwrap.conf

[database]
connection = mysql+pymysql://neutronUser:$NEUTRON_DB_PASS@$CONTROLLER_IP/neutron

[nova]
auth_url = http://$CONTROLLER_IP:5000
auth_type = password
product_domain_name = default
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

# Restart Neutron Open vSwitch Agent
echo "Restarting Neutron Open vSwitch agent..."
service neutron-openvswitch-agent restart
check_error "Failed to restart Neutron Open vSwitch agent"

# Section 14: Register Compute Node with Controller
echo "Registering compute node with controller..."
source /root/creds
su -s /bin/sh -c "nova-manage cell_v2 discover_hosts --verbose" nova
check_error "Failed to register compute node"

# Section 15: Final Verification
echo "Verifying OpenStack compute services..."
openstack hypervisor list
check_error "Failed to verify hypervisor list"

echo "Compute node setup completed successfully!"
echo "Run 'openstack compute service list' on the Controller node to verify the Compute node is registered."