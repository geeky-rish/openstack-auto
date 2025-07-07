#!/bin/bash

# Configuration variables (modify these as needed)
CONTROLLER_IP="192.168.116.130"           # NAT interface IP (ens33)
MANAGEMENT_IP="100.100.100.1"              # Bridge interface IP (br0)
CONTROLLER_HOSTNAME="controller01"
DOMAIN="moin.com"
NEUTRON_IP="192.168.116.134"              # Neutron node NAT IP
COMPUTE_IP="192.168.116.132"              # Compute node NAT IP
NAT_INTERFACE="ens33"                      # NAT interface name
BRIDGE_INTERFACE="br0"                     # Bridge interface name
GATEWAY_IP="192.168.116.1"                 # Gateway for NAT interface
RABBITMQ_USER="openstack"
RABBITMQ_PASS="rabbit"
MYSQL_ROOT_PASS="mysql_root_pass"
KEYSTONE_DB_PASS="keystonePass"
GLANCE_DB_PASS="glancePass"
NOVA_DB_PASS="novaPass"
PLACEMENT_DB_PASS="placementPass"
NEUTRON_DB_PASS="neutronPass"
CINDER_DB_PASS="cinderPass"
CEILOMETER_DB_PASS="ceilometerPass"
ADMIN_PASS="admin_pass"
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
apt-get upgrade -y
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
echo "Setting hostname to $CONTROLLER_HOSTNAME..."
echo "$CONTROLLER_HOSTNAME" > /etc/hostname
hostname "$CONTROLLER_HOSTNAME"
check_error "Failed to set hostname"

# Section 6: Configure /etc/hosts
echo "Configuring /etc/hosts..."
cat << EOF > /etc/hosts
127.0.0.1 localhost
$CONTROLLER_IP $CONTROLLER_HOSTNAME.$DOMAIN $CONTROLLER_HOSTNAME
$NEUTRON_IP neutron01.$DOMAIN neutron01
$COMPUTE_IP compute01.$DOMAIN compute01
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
        - $CONTROLLER_IP/24
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
ping -c 3 $MANAGEMENT_IP
check_error "Failed to ping management IP"

# Section 8: Install and Configure MySQL and RabbitMQ
echo "Installing MySQL and RabbitMQ..."
apt-get install -y mariadb-server python3-pymysql rabbitmq-server memcached python3-pymysql
check_error "Failed to install MySQL and RabbitMQ"

# Configure MySQL
echo "Configuring MySQL..."
cat << EOF > /etc/mysql/mariadb.conf.d/50-server.cnf
[mysqld]
bind-address = 0.0.0.0
default-storage-engine = innodb
innodb_file_per_table = on
max_connections = 4096
collation-server = utf8_general_ci
character-set-server = utf8
EOF
service mysql restart
check_error "Failed to restart MySQL"
mysql_secure_installation --use-default --password=$MYSQL_ROOT_PASS
check_error "Failed to secure MySQL installation"

# Configure RabbitMQ
echo "Configuring RabbitMQ..."
rabbitmqctl add_user $RABBITMQ_USER $RABBITMQ_PASS
rabbitmqctl set_permissions $RABBITMQ_USER ".*" ".*" ".*"
check_error "Failed to configure RabbitMQ"

# Configure Memcached
echo "Configuring Memcached..."
sed -i "s/-l 127.0.0.1/-l 0.0.0.0/" /etc/memcached.conf
service memcached restart
check_error "Failed to restart Memcached"

# Section 9: Install OpenStack Client
echo "Installing OpenStack client..."
apt-get install -y python3-openstackclient
check_error "Failed to install OpenStack client"

# Section 10: Install and Configure Keystone
echo "Installing Keystone..."
apt-get install -y keystone apache2 libapache2-mod-wsgi-py3 python3-oauth2client
check_error "Failed to install Keystone"

# Create Keystone Database
echo "Creating Keystone database..."
mysql -u root -p$MYSQL_ROOT_PASS <<EOF
CREATE DATABASE keystone;
GRANT ALL ON keystone.* TO 'keystoneUser'@'localhost' IDENTIFIED BY '$KEYSTONE_DB_PASS';
GRANT ALL ON keystone.* TO 'keystoneUser'@'%' IDENTIFIED BY '$KEYSTONE_DB_PASS';
FLUSH PRIVILEGES;
EOF
check_error "Failed to create Keystone database"

# Configure Keystone
echo "Configuring Keystone..."
cat << EOF > /etc/keystone/keystone.conf
[cache]
memcache_servers = $MANAGEMENT_IP:11211

[database]
connection = mysql+pymysql://keystoneUser:$KEYSTONE_DB_PASS@$MANAGEMENT_IP/keystone

[token]
provider = fernet
EOF
su -s /bin/sh -c "keystone-manage db_sync" keystone
check_error "Failed to sync Keystone database"
keystone-manage fernet_setup --keystone-user keystone --keystone-group keystone
keystone-manage credential_setup --keystone-user keystone --keystone-group keystone
check_error "Failed to initialize Fernet keys"

# Bootstrap Keystone
echo "Bootstrapping Keystone..."
keystone-manage bootstrap --bootstrap-password $ADMIN_PASS \
  --bootstrap-admin-url http://$MANAGEMENT_IP:5000/v3/ \
  --bootstrap-internal-url http://$MANAGEMENT_IP:5000/v3/ \
  --bootstrap-public-url http://$CONTROLLER_IP:5000/v3/ \
  --bootstrap-region-id RegionOne
check_error "Failed to bootstrap Keystone"

# Configure Apache for Keystone
echo "Configuring Apache for Keystone..."
echo "ServerName $CONTROLLER_HOSTNAME" >> /etc/apache2/apache2.conf
service apache2 restart
check_error "Failed to restart Apache for Keystone"

# Create Credential File
echo "Creating credential file..."
cat << EOF > /root/creds
export OS_PROJECT_DOMAIN_NAME=default
export OS_USER_DOMAIN_NAME=default
export OS_PROJECT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$ADMIN_PASS
export OS_AUTH_URL=http://$CONTROLLER_IP:5000/v3
export OS_IDENTITY_API_VERSION=3
EOF
source /root/creds
check_error "Failed to source credentials"

# Create Roles and Projects
echo "Creating roles and projects..."
openstack role create _member_
openstack role add --project admin --user admin admin
openstack project create --domain default --description "Service Project" service
openstack project create --domain default --description "Demo Project" demo
openstack user create --domain default --password $ADMIN_PASS demo
openstack role create user
openstack role add --project demo --user demo user
check_error "Failed to create roles and projects"

# Section 11: Install and Configure Glance
echo "Installing Glance..."
apt-get install -y glance
check_error "Failed to install Glance"

# Create Glance Database
echo "Creating Glance database..."
mysql -u root -p$MYSQL_ROOT_PASS <<EOF
CREATE DATABASE glance;
GRANT ALL ON glance.* TO 'glanceUser'@'localhost' IDENTIFIED BY '$GLANCE_DB_PASS';
GRANT ALL ON glance.* TO 'glanceUser'@'%' IDENTIFIED BY '$GLANCE_DB_PASS';
FLUSH PRIVILEGES;
EOF
check_error "Failed to create Glance database"

# Configure Glance
echo "Configuring Glance..."
cat << EOF > /etc/glance/glance-api.conf
[DEFAULT]
bind_host = 0.0.0.0
transport_url = rabbit://$RABBITMQ_USER:$RABBITMQ_PASS@$MANAGEMENT_IP

[database]
connection = mysql+pymysql://glanceUser:$GLANCE_DB_PASS@$MANAGEMENT_IP/glance

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/

[paste_deploy]
flavor = keystone

[keystone_authtoken]
www_authenticate_uri = http://$MANAGEMENT_IP:5000
auth_url = http://$MANAGEMENT_IP:5000
memcached_servers = $MANAGEMENT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = $SERVICE_PASS
EOF
su -s /bin/sh -c "glance-manage db_sync" glance
service glance-api restart
check_error "Failed to configure and restart Glance"

# Create Glance Service and Endpoints
echo "Creating Glance service and endpoints..."
openstack user create --domain default --password $SERVICE_PASS glance
openstack role add --project service --user glance admin
openstack service create --name glance --description "OpenStack Image service" image
openstack endpoint create --region RegionOne image public http://$CONTROLLER_IP:9292
openstack endpoint create --region RegionOne image internal http://$MANAGEMENT_IP:9292
openstack endpoint create --region RegionOne image admin http://$MANAGEMENT_IP:9292
check_error "Failed to create Glance service and endpoints"

# Download and Create Cirros Image
echo "Downloading and creating Cirros image..."
wget -q http://download.cirros-cloud.net/0.4.0/cirros-0.4.0-x86_64-disk.img
glance image-create --name "cirros" \
  --file cirros-0.4.0-x86_64-disk.img \
  --disk-format qcow2 --container-format bare \
  --visibility=public
check_error "Failed to create Cirros image"

# Section 12: Install and Configure Nova
echo "Installing Nova..."
apt-get install -y nova-api nova-conductor nova-scheduler nova-novncproxy placement-api python3-novaclient
check_error "Failed to install Nova"

# Create Nova and Placement Databases
echo "Creating Nova and Placement databases..."
mysql -u root -p$MYSQL_ROOT_PASS <<EOF
CREATE DATABASE nova;
GRANT ALL ON nova.* TO 'novaUser'@'localhost' IDENTIFIED BY '$NOVA_DB_PASS';
GRANT ALL ON nova.* TO 'novaUser'@'%' IDENTIFIED BY '$NOVA_DB_PASS';
CREATE DATABASE nova_api;
GRANT ALL ON nova_api.* TO 'novaUser'@'localhost' IDENTIFIED BY '$NOVA_DB_PASS';
GRANT ALL ON nova_api.* TO 'novaUser'@'%' IDENTIFIED BY '$NOVA_DB_PASS';
CREATE DATABASE placement;
GRANT ALL ON placement.* TO 'placementUser'@'localhost' IDENTIFIED BY '$PLACEMENT_DB_PASS';
GRANT ALL ON placement.* TO 'placementUser'@'%' IDENTIFIED BY '$PLACEMENT_DB_PASS';
CREATE DATABASE nova_cell0;
GRANT ALL ON nova_cell0.* TO 'novaUser'@'localhost' IDENTIFIED BY '$NOVA_DB_PASS';
GRANT ALL ON nova_cell0.* TO 'novaUser'@'%' IDENTIFIED BY '$NOVA_DB_PASS';
FLUSH PRIVILEGES;
EOF
check_error "Failed to create Nova and Placement databases"

# Configure Nova
echo "Configuring Nova..."
cat << EOF > /etc/nova/nova.conf
[DEFAULT]
osapi_compute_listen = $CONTROLLER_IP
osapi_compute_listen_port = 8774
metadata_listen = $MANAGEMENT_IP
metadata_listen_port = 8775
enabled_apis = osapi_compute,metadata
my_ip = $MANAGEMENT_IP
use_neutron = True
firewall_driver = nova.virt.firewall.NoopFirewallDriver
transport_url = rabbit://$RABBITMQ_USER:$RABBITMQ_PASS@$MANAGEMENT_IP

[api]
auth_strategy = keystone

[vnc]
enabled = true
server_listen = 0.0.0.0
server_proxyclient_address = $MANAGEMENT_IP

[api_database]
connection = mysql+pymysql://novaUser:$NOVA_DB_PASS@$MANAGEMENT_IP/nova_api

[database]
connection = mysql+pymysql://novaUser:$NOVA_DB_PASS@$MANAGEMENT_IP/nova

[cinder]
os_region_name = RegionOne

[keystone_authtoken]
www_authenticate_uri = http://$MANAGEMENT_IP:5000
auth_url = http://$MANAGEMENT_IP:5000
memcached_servers = $MANAGEMENT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = nova
password = $SERVICE_PASS

[glance]
api_servers = http://$MANAGEMENT_IP:9292

[oslo_concurrency]
lock_path = /var/lib/nova/tmp

[neutron]
auth_url = http://$MANAGEMENT_IP:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = neutron
password = $SERVICE_PASS
service_metadata_proxy = true
metadata_proxy_shared_secret = $METADATA_SECRET
insecure = false

[placement]
auth_url = http://$MANAGEMENT_IP:5000
os_region_name = RegionOne
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = $SERVICE_PASS

[wsgi]
api_paste_config = /etc/nova/api-paste.ini
EOF

# Configure Placement
echo "Configuring Placement..."
cat << EOF > /etc/placement/placement.conf
[DEFAULT]
debug = false

[api]
auth_strategy = keystone

[keystone_authtoken]
www_authenticate_uri = http://$MANAGEMENT_IP:5000
auth_url = http://$MANAGEMENT_IP:5000
memcached_servers = $MANAGEMENT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = $SERVICE_PASS
insecure = false

[placement_database]
connection = mysql+pymysql://placementUser:$PLACEMENT_DB_PASS@$MANAGEMENT_IP/placement
EOF

# Synchronize Nova and Placement Databases
echo "Synchronizing Nova and Placement databases..."
su -s /bin/sh -c "placement-manage db sync" placement
su -s /bin/sh -c "nova-manage api_db sync" nova
su -s /bin/sh -c "nova-manage cell_v2 map_cell0" nova
su -s /bin/sh -c "nova-manage cell_v2 create_cell --name=cell1 --verbose" nova
su -s /bin/sh -c "nova-manage db sync" nova
check_error "Failed to synchronize Nova and Placement databases"

# Create Nova and Placement Service and Endpoints
echo "Creating Nova and Placement service and endpoints..."
openstack user create --domain default --password $SERVICE_PASS nova
openstack role add --project service --user nova admin
openstack service create --name nova --description "OpenStack Compute" compute
openstack endpoint create --region RegionOne compute public http://$CONTROLLER_IP:8774/v2.1/%\(tenant_id\)s
openstack endpoint create --region RegionOne compute internal http://$MANAGEMENT_IP:8774/v2.1/%\(tenant_id\)s
openstack endpoint create --region RegionOne compute admin http://$MANAGEMENT_IP:8774/v2.1/%\(tenant_id\)s
openstack user create --domain default --password $SERVICE_PASS placement
openstack role add --project service --user placement admin
openstack service create --name placement --description "Placement API" placement
openstack endpoint create --region RegionOne placement public http://$CONTROLLER_IP:8778
openstack endpoint create --region RegionOne placement internal http://$MANAGEMENT_IP:8778
openstack endpoint create --region RegionOne placement admin http://$MANAGEMENT_IP:8778
check_error "Failed to create Nova and Placement service and endpoints"

# Restart Nova Services
echo "Restarting Nova services..."
service nova-api restart
service nova-conductor restart
service nova-scheduler restart
service nova-novncproxy restart
check_error "Failed to restart Nova services"

# Section 13: Install and Configure Neutron
echo "Installing Neutron..."
apt-get install -y neutron-server python3-neutronclient
check_error "Failed to install Neutron"

# Create Neutron Database
echo "Creating Neutron database..."
mysql -u root -p$MYSQL_ROOT_PASS <<EOF
CREATE DATABASE neutron;
GRANT ALL ON neutron.* TO 'neutronUser'@'localhost' IDENTIFIED BY '$NEUTRON_DB_PASS';
GRANT ALL ON neutron.* TO 'neutronUser'@'%' IDENTIFIED BY '$NEUTRON_DB_PASS';
FLUSH PRIVILEGES;
EOF
check_error "Failed to create Neutron database"

# Configure Neutron
echo "Configuring Neutron..."
cat << EOF > /etc/neutron/neutron.conf
[DEFAULT]
debug = False
bind_host = 0.0.0.0
bind_port = 9696
core_plugin = ml2
service_plugins = router
auth_strategy = keystone
state_path = /var/lib/neutron
dhcp_agent_notification = True
allow_overlapping_ips = True
notify_nova_on_port_status_changes = True
notify_nova_on_port_data_changes = True
transport_url = rabbit://$RABBITMQ_USER:$RABBITMQ_PASS@$MANAGEMENT_IP
interface_driver = openvswitch
lock_path = /var/lib/neutron/tmp

[agent]
root_helper = sudo /usr/bin/neutron-rootwrap /etc/neutron/rootwrap.conf

[keystone_authtoken]
www_authenticate_uri = http://$MANAGEMENT_IP:5000
auth_url = http://$MANAGEMENT_IP:5000
memcached_servers = $MANAGEMENT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = neutron
password = $SERVICE_PASS
insecure = false

[database]
connection = mysql+pymysql://neutronUser:$NEUTRON_DB_PASS@$MANAGEMENT_IP/neutron

[nova]
auth_url = http://$MANAGEMENT_IP:5000
auth_type = password
project_domain_name = default
user_domain_name = default
region_name = RegionOne
project_name = service
username = nova
password = $SERVICE_PASS
insecure = false

[placement]
auth_url = http://$MANAGEMENT_IP:5000
os_region_name = RegionOne
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = placement
password = $SERVICE_PASS

[oslo_concurrency]
lock_path = /var/lib/neutron/tmp
EOF

cat << EOF > /etc/neutron/plugins/ml2/ml2_conf.ini
[ml2]
type_drivers = flat,vlan,vxlan,gre
tenant_network_types = vxlan
mechanism_drivers = openvswitch,l2population
extension_drivers = port_security

[ml2_type_flat]
flat_networks = physnet1

[ml2_type_vxlan]
vni_ranges = 1:1000

[ml2_type_gre]
tunnel_id_ranges = 1:1000

[securitygroup]
enable_ipset = true
enable_security_group = True
firewall_driver = neutron.agent.linux.iptables_firewall.IptablesFirewallDriver
EOF

# Synchronize Neutron Database
echo "Synchronizing Neutron database..."
su -s /bin/sh -c "neutron-db-manage --config-file /etc/neutron/neutron.conf --config-file /etc/neutron/plugins/ml2/ml2_conf.ini upgrade head" neutron
check_error "Failed to synchronize Neutron database"

# Create Neutron Service and Endpoints
echo "Creating Neutron service and endpoints..."
openstack user create --domain default --password $SERVICE_PASS neutron
openstack role add --project service --user neutron admin
openstack service create --name neutron --description "OpenStack Networking" network
openstack endpoint create --region RegionOne network public http://$CONTROLLER_IP:9696
openstack endpoint create --region RegionOne network internal http://$MANAGEMENT_IP:9696
openstack endpoint create --region RegionOne network admin http://$MANAGEMENT_IP:9696
check_error "Failed to create Neutron service and endpoints"

# Restart Neutron Service
echo "Restarting Neutron service..."
service neutron-server restart
check_error "Failed to restart Neutron service"

# Section 14: Install and Configure Cinder
echo "Installing Cinder..."
apt-get install -y cinder-api cinder-scheduler cinder-volume qemu lvm2 python3-cinderclient
check_error "Failed to install Cinder"

# Create Cinder Database
echo "Creating Cinder database..."
mysql -u root -p$MYSQL_ROOT_PASS <<EOF
CREATE DATABASE cinder;
GRANT ALL ON cinder.* TO 'cinderUser'@'%' IDENTIFIED BY '$CINDER_DB_PASS';
FLUSH PRIVILEGES;
EOF
check_error "Failed to create Cinder database"

# Configure Cinder
echo "Configuring Cinder..."
cat << EOF > /etc/cinder/cinder.conf
[DEFAULT]
rpc_backend = rabbit
my_ip = $CONTROLLER_IP
auth_strategy = keystone
enabled_backends = lvm
glance_api_servers = http://$CONTROLLER_IP:9292

[oslo_messaging_rabbit]
rabbit_host = $CONTROLLER_IP
rabbit_userid = $RABBITMQ_USER
rabbit_password = $RABBITMQ_PASS

[database]
connection = mysql://cinderUser:$CINDER_DB_PASS@$CONTROLLER_IP/cinder

[keystone_authtoken]
auth_uri = http://$CONTROLLER_IP:5000
auth_url = http://$CONTROLLER_IP:35357
memcached_servers = $CONTROLLER_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = cinder
password = $SERVICE_PASS

[oslo_concurrency]
lock_path = /var/lock/cinder

[lvm]
volume_driver = cinder.volume.drivers.lvm.LVMVolumeDriver
volume_group = cinder-volumes
iscsi_protocol = iscsi
iscsi_helper = tgtadm
EOF

# Synchronize Cinder Database
echo "Synchronizing Cinder database..."
su -s /bin/sh -c "cinder-manage db sync" cinder
check_error "Failed to synchronize Cinder database"

# Create Cinder Service and Endpoints
echo "Creating Cinder service and endpoints..."
openstack user create --domain default --password $SERVICE_PASS cinder
openstack role add --project service --user cinder admin
openstack service create --name cinder --description "OpenStack Block Storage" volume
openstack endpoint create --region RegionOne volume public http://$CONTROLLER_IP:8776/v2/%\(tenant_id\)s
openstack endpoint create --region RegionOne volume internal http://$CONTROLLER_IP:8776/v2/%\(tenant_id\)s
openstack endpoint create --region RegionOne volume admin http://$CONTROLLER_IP:8776/v2/%\(tenant_id\)s
openstack service create --name cinderv2 --description "OpenStack Block Storage" volumev2
openstack endpoint create --region RegionOne volumev2 public http://$CONTROLLER_IP:8776/v2/%\(tenant_id\)s
openstack endpoint create --region RegionOne volumev2 internal http://$CONTROLLER_IP:8776/v2/%\(tenant_id\)s
openstack endpoint create --region RegionOne volumev2 admin http://$CONTROLLER_IP:8776/v2/%\(tenant_id\)s
check_error "Failed to create Cinder service and endpoints"

# Configure Cinder Storage (Assuming /dev/xvdf is available)
echo "Configuring Cinder storage..."
pvcreate /dev/xvdf1 || true
vgcreate cinder-volumes /dev/xvdf1 || true
check_error "Failed to configure Cinder storage"

# Restart Cinder Services
echo "Restarting Cinder services..."
service tgt restart
service cinder-volume restart
service cinder-scheduler restart
service cinder-api restart
check_error "Failed to restart Cinder services"

# Section 15: Install and Configure Horizon
echo "Installing Horizon..."
apt-get install -y openstack-dashboard
check_error "Failed to install Horizon"

# Configure Horizon
echo "Configuring Horizon..."
cat << EOF > /etc/openstack-dashboard/local_settings.py
OPENSTACK_HOST = "$CONTROLLER_IP"
OPENSTACK_KEYSTONE_URL = "http://%s:5000/v3" % OPENSTACK_HOST
OPENSTACK_KEYSTONE_DEFAULT_ROLE = "user"
OPENSTACK_KEYSTONE_MULTIDOMAIN_SUPPORT = True
SESSION_ENGINE = 'django.contrib.sessions.backends.cache'

CACHES = {
    'default': {
         'BACKEND': 'django.core.cache.backends.memcached.MemcachedCache',
         'LOCATION': '$MANAGEMENT_IP:11211',
    }
}

OPENSTACK_API_VERSIONS = {
    "identity": 3,
}

OPENSTACK_KEYSTONE_DEFAULT_DOMAIN = 'default'
TIME_ZONE = "Asia/Kolkata"
EOF

cat << EOF > /etc/apache2/conf-available/openstack-dashboard.conf
WSGIApplicationGroup %{GLOBAL}
EOF

# Restart Apache for Horizon
echo "Restarting Apache for Horizon..."
service apache2 reload
check_error "Failed to restart Apache for Horizon"

# Section 16: Install and Configure Ceilometer
echo "Installing Ceilometer..."
apt-get install -y mongodb-server mongodb-clients python3-pymongo ceilometer-api ceilometer-collector ceilometer-agent-central ceilometer-agent-notification python3-ceilometerclient
check_error "Failed to install Ceilometer"

# Configure MongoDB
echo "Configuring MongoDB..."
cat << EOF > /etc/mongodb.conf
bind_ip = 0.0.0.0
smallfiles = true
EOF
service mongodb stop
rm -f /var/lib/mongodb/journal/prealloc.*
service mongodb start
check_error "Failed to configure MongoDB"

# Create Ceilometer Database in MongoDB
echo "Creating Ceilometer MongoDB database..."
mongo --host $CONTROLLER_HOSTNAME --eval "
  db = db.getSiblingDB('ceilometer');
  db.addUser({user: 'ceilometer', pwd: '$CEILOMETER_DB_PASS', roles: [ 'readWrite', 'dbAdmin' ]})"
check_error "Failed to create Ceilometer MongoDB database"

# Configure Ceilometer
echo "Configuring Ceilometer..."
cat << EOF > /etc/ceilometer/ceilometer.conf
[database]
connection = mongodb://ceilometer:$CEILOMETER_DB_PASS@$MANAGEMENT_IP:27017/ceilometer

[DEFAULT]
auth_strategy = keystone
rpc_backend = rabbit

[api]
port = 8777
host = 0.0.0.0

[keystone_authtoken]
auth_uri = http://$MANAGEMENT_IP:5000
auth_url = http://$MANAGEMENT_IP:35357
memcached_servers = $MANAGEMENT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = ceilometer
password = $SERVICE_PASS

[oslo_messaging_rabbit]
rabbit_host = $MANAGEMENT_IP
rabbit_userid = $RABBITMQ_USER
rabbit_password = $RABBITMQ_PASS

[service_credentials]
auth_url = http://$MANAGEMENT_IP:5000/v3
project_domain_name = default
user_domain_name = default
project_name = service
username = ceilometer
password = $SERVICE_PASS
interface = internalURL
region_name = RegionOne
EOF

# Configure Apache for Ceilometer
echo "Configuring Apache for Ceilometer..."
cat << EOF > /etc/apache2/sites-available/ceilometer.conf
Listen 8777

<VirtualHost *:8777>
    WSGIDaemonProcess ceilometer-api processes=2 threads=10 user=ceilometer group=ceilometer display-name=%{GROUP}
    WSGIProcessGroup ceilometer-api
    WSGIScriptAlias / "/var/www/cgi-bin/ceilometer/app"
    WSGIApplicationGroup %{GLOBAL}
    ErrorLog /var/log/apache2/ceilometer_error.log
    CustomLog /var/log/apache2/ceilometer_access.log combined
</VirtualHost>

WSGISocketPrefix /var/run/apache2
EOF
mkdir -p /var/www/cgi-bin/ceilometer
cp /usr/lib/python3/dist-packages/ceilometer/api/app.wsgi /var/www/cgi-bin/ceilometer/app
a2ensite ceilometer
systemctl stop ceilometer-api
systemctl disable ceilometer-api
service apache2 reload
check_error "Failed to configure Apache for Ceilometer"

# Create Ceilometer Service and Endpoints
echo "Creating Ceilometer service and endpoints..."
openstack user create --domain default --password $SERVICE_PASS ceilometer
openstack role add --project service --user ceilometer admin
openstack service create --name ceilometer --description "Telemetry" metering
openstack endpoint create --region RegionOne metering public http://$CONTROLLER_IP:8777
openstack endpoint create --region RegionOne metering internal http://$MANAGEMENT_IP:8777
openstack endpoint create --region RegionOne metering admin http://$MANAGEMENT_IP:8777
check_error "Failed to create Ceilometer service and endpoints"

# Restart Ceilometer Services
echo "Restarting Ceilometer services..."
service ceilometer-agent-central restart
service ceilometer-agent-notification restart
service ceilometer-collector restart
check_error "Failed to restart Ceilometer services"

# Section 17: Enable Image Service Meters for Ceilometer
echo "Configuring Glance for Ceilometer..."
cat << EOF > /etc/glance/glance-api.conf
[DEFAULT]
rpc_backend = rabbit
transport_url = rabbit://$RABBITMQ_USER:$RABBITMQ_PASS@$MANAGEMENT_IP

[oslo_messaging_notifications]
driver = messagingv2

[oslo_messaging_rabbit]
rabbit_host = $MANAGEMENT_IP
rabbit_userid = $RABBITMQ_USER
rabbit_password = $RABBITMQ_PASS

[database]
connection = mysql+pymysql://glanceUser:$GLANCE_DB_PASS@$MANAGEMENT_IP/glance

[glance_store]
stores = file,http
default_store = file
filesystem_store_datadir = /var/lib/glance/images/

[paste_deploy]
flavor = keystone

[keystone_authtoken]
www_authenticate_uri = http://$MANAGEMENT_IP:5000
auth_url = http://$MANAGEMENT_IP:5000
memcached_servers = $MANAGEMENT_IP:11211
auth_type = password
project_domain_name = default
user_domain_name = default
project_name = service
username = glance
password = $SERVICE_PASS
EOF

cat << EOF > /etc/glance/glance-registry.conf
[DEFAULT]
rpc_backend = rabbit

[oslo_messaging_notifications]
driver = messagingv2

[oslo_messaging_rabbit]
rabbit_host = $MANAGEMENT_IP
rabbit_userid = $RABBITMQ_USER
rabbit_password = $RABBITMQ_PASS
EOF

# Restart Glance Services
echo "Restarting Glance services for Ceilometer..."
service glance-registry restart
service glance-api restart
check_error "Failed to restart Glance services"

# Section 18: Final Verification
echo "Verifying OpenStack services..."
openstack compute service list
openstack image list
check_error "Failed to verify OpenStack services"

echo "Controller node setup completed successfully!"
echo "You can access Horizon at http://$CONTROLLER_IP/horizon with User: admin, Password: $ADMIN_PASS"