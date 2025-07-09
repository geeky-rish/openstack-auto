#!/bin/bash

# OpenStack DevStack Single Node Setup Script
# This script sets up a single-node OpenStack environment using DevStack

set -e  # Exit on any error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging function
log() {
    echo -e "${BLUE}[$(date '+%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}"
    exit 1
}

success() {
    echo -e "${GREEN}[SUCCESS] $1${NC}"
}

warning() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

# Check if running as root
if [[ $EUID -eq 0 ]]; then
    error "This script should not be run as root initially. It will handle sudo operations internally."
fi

# Check OS compatibility
check_os() {
    log "Checking OS compatibility..."
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$NAME
        VERSION=$VERSION_ID
        log "Detected OS: $OS $VERSION"
        
        case $ID in
            ubuntu|debian)
                PACKAGE_MANAGER="apt"
                ;;
            centos|rhel|fedora)
                PACKAGE_MANAGER="yum"
                ;;
            *)
                error "Unsupported OS: $OS"
                ;;
        esac
    else
        error "Cannot detect OS version"
    fi
}

# Update system packages
update_system() {
    log "Updating system packages..."
    
    if [[ $PACKAGE_MANAGER == "apt" ]]; then
        sudo apt update
        sudo apt -y upgrade
        sudo apt-get install -y sudo git vim curl wget
    elif [[ $PACKAGE_MANAGER == "yum" ]]; then
        sudo yum update -y
        sudo yum install -y sudo git vim curl wget
    fi
    
    success "System packages updated successfully"
}

# Create stack user
create_stack_user() {
    log "Creating stack user..."
    
    # Check if stack user already exists
    if id "stack" &>/dev/null; then
        warning "Stack user already exists, skipping creation"
        return 0
    fi
    
    # Create stack user
    sudo useradd -s /bin/bash -d /opt/stack -m stack
    sudo chmod +x /opt/stack
    
    # Add stack user to sudoers
    echo "stack ALL=(ALL) NOPASSWD: ALL" | sudo tee /etc/sudoers.d/stack
    
    success "Stack user created successfully"
}

# Clone DevStack repository
clone_devstack() {
    log "Cloning DevStack repository..."
    
    # Switch to stack user for the rest of the operations
    sudo -u stack bash << 'EOF'
cd /opt/stack

# Remove existing devstack directory if it exists
if [[ -d "devstack" ]]; then
    echo "Removing existing devstack directory..."
    rm -rf devstack
fi

# Clone devstack
git clone https://opendev.org/openstack/devstack
cd devstack

echo "DevStack cloned successfully"
EOF
    
    success "DevStack repository cloned"
}

# Create local.conf file
create_local_conf() {
    log "Creating local.conf file..."
    
    # Get host IP address
    HOST_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
    
    sudo -u stack bash << EOF
cd /opt/stack/devstack

# Create local.conf with basic configuration
cat > local.conf << 'LOCALCONF'
[[local|localrc]]

# Credentials - all passwords set to 'secret' for ease of use
ADMIN_PASSWORD=secret
DATABASE_PASSWORD=secret
RABBIT_PASSWORD=secret
SERVICE_PASSWORD=secret

# Network Configuration
HOST_IP=${HOST_IP}
FLOATING_RANGE=192.168.1.224/27
FIXED_RANGE=10.11.12.0/24
FIXED_NETWORK_SIZE=256
FLAT_INTERFACE=eth0

# Services Configuration
# Enable essential services
ENABLED_SERVICES=rabbit,mysql,key

# Enable Nova services
ENABLED_SERVICES+=,n-api,n-crt,n-obj,n-cpu,n-cond,n-sch,n-novnc,n-cauth

# Enable Glance services
ENABLED_SERVICES+=,g-api,g-reg

# Enable Neutron services
ENABLED_SERVICES+=,q-svc,q-agt,q-dhcp,q-l3,q-meta

# Enable Cinder services
ENABLED_SERVICES+=,c-api,c-vol,c-sch,c-bak

# Enable Horizon
ENABLED_SERVICES+=,horizon

# Enable Heat (optional)
ENABLED_SERVICES+=,heat,h-api,h-api-cfn,h-api-cw,h-eng

# Logging
LOGFILE=/opt/stack/logs/stack.sh.log
VERBOSE=True
LOG_COLOR=True
SCREEN_LOGDIR=/opt/stack/logs

# Swift (optional - comment out if not needed)
# ENABLED_SERVICES+=,s-proxy,s-object,s-container,s-account
# SWIFT_HASH=66a3d6b56c1f479c8b4e70ab5c2000f5

# Disable unnecessary services to save resources
disable_service tempest
disable_service c-bak

# Image URLs (optional - uncomment if you want to pre-download images)
# IMAGE_URLS+=",http://download.cirros-cloud.net/0.3.4/cirros-0.3.4-x86_64-disk.img"

LOCALCONF

echo "local.conf created successfully"
EOF
    
    success "local.conf file created"
}

# Display local.conf content
show_config() {
    log "Displaying local.conf configuration..."
    echo "----------------------------------------"
    sudo -u stack cat /opt/stack/devstack/local.conf
    echo "----------------------------------------"
}

# Run stack.sh
run_stack() {
    log "Starting OpenStack installation..."
    warning "This process will take 15-45 minutes depending on your system and internet speed"
    
    sudo -u stack bash << 'EOF'
cd /opt/stack/devstack

# Set environment variables
export FORCE=yes

# Run the stack script
./stack.sh

echo "OpenStack installation completed"
EOF
    
    success "OpenStack installation completed successfully"
}

# Display final information
display_info() {
    log "Installation completed successfully!"
    echo ""
    echo "=========================================="
    echo "OpenStack Dashboard (Horizon) Access:"
    echo "=========================================="
    echo "URL: http://$(ip route get 8.8.8.8 | awk '{print $7; exit}')/dashboard"
    echo "Username: admin"
    echo "Password: secret"
    echo ""
    echo "=========================================="
    echo "Useful Commands:"
    echo "=========================================="
    echo "Switch to stack user: sudo su stack"
    echo "DevStack directory: /opt/stack/devstack"
    echo "OpenStack CLI: source /opt/stack/devstack/openrc admin admin"
    echo "Restart services: sudo su stack && cd /opt/stack/devstack && ./rejoin-stack.sh"
    echo "Stop services: sudo su stack && cd /opt/stack/devstack && ./unstack.sh"
    echo "View logs: ls -la /opt/stack/logs/"
    echo ""
    echo "=========================================="
    echo "Next Steps:"
    echo "=========================================="
    echo "1. Access the dashboard using the URL above"
    echo "2. Create a project, network, and launch instances"
    echo "3. Use 'openstack --help' for CLI commands"
    echo "4. Check /opt/stack/logs/ for any issues"
    echo ""
}

# Main execution
main() {
    echo "=========================================="
    echo "OpenStack DevStack Single Node Setup"
    echo "=========================================="
    echo ""
    
    check_os
    update_system
    create_stack_user
    clone_devstack
    create_local_conf
    
    # Ask user if they want to review the configuration
    echo ""
    read -p "Do you want to review the local.conf configuration? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        show_config
        echo ""
        read -p "Do you want to proceed with the installation? (y/N): " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            warning "Installation cancelled by user"
            exit 0
        fi
    fi
    
    run_stack
    display_info
}

# Cleanup function for graceful exit
cleanup() {
    warning "Script interrupted. Cleaning up..."
    exit 1
}

# Set trap for cleanup
trap cleanup SIGINT SIGTERM

# Run main function
main "$@"
