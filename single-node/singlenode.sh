#!/bin/bash

# Update and upgrade system
sudo apt update
sudo apt -y upgrade

# Create stack user
sudo useradd -s /bin/bash -d /opt/stack -m stack
sudo chmod +x /opt/stack

# Install sudo
sudo apt-get install sudo -y || sudo yum install -y sudo

# Grant sudo privileges to stack user
sudo echo "stack ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/stack

# Switch to stack user and set up DevStack
sudo -u stack bash << EOF
cd ~

# Install git
sudo apt-get install git -y || sudo yum install -y git

# Clone DevStack repository
git clone https://github.com/openstack/devstack.git
cd devstack

# Copy and modify local.conf
cp samples/local.conf .
cat <<EOT >> local.conf
ADMIN_PASSWORD=secret
DATABASE_PASSWORD=secret
RABBIT_PASSWORD=secret
SERVICE_PASSWORD=secret
EOT

# Run stack.sh to install OpenStack
./stack.sh FORCE=yes
EOF
