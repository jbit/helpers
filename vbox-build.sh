#!/bin/bash

HELP=(
    "This is a simple script that:"
    "  - Creates a headless VirtualBox virtual machine"
    "  - Sets up a netboot ubuntu xenial install environment"
    "  - Netboots the virtual machine"
    "  - Proceeds with automated ubuntu installation"
    ""
    "So after running this script you'll have a new VM with ubuntu installed :)"
    ""
    "Takes one argument which is the name of the virtual machine"
    "Edit the script to configure the VM"
)

case "$1" in
--help | -h)
    printf '%s\n' "${HELP[@]}"
    exit 1
    ;;

esac

set -o nounset

VM_NAME="${1:-VM-$(date +%Y%m%d-%H%M%S)}"
VM_ROOT="/Volumes/VM"
VM_PATH="${VM_ROOT}/${VM_NAME}"
VM_TFTP_PATH="${VM_PATH}/TFTP"
VM_SSH_KEY="$(cat $HOME/.ssh/id_rsa.pub)"
VM_TIMEZONE="Australia/Victoria"
VM_MEMORY=4096 # MBytes
VM_DISK=8192 # MBytes
VM_CPUS=4 # Number of cores
VM_USER="$USER"
VM_OS="Ubuntu_64"
VM_PACKAGES=(
    openssh-server # Allow SSH access
    avahi-daemon # Make this system available by <name>.local
    virtualbox-guest-dkms
    virtualbox-guest-utils
    build-essential # Allow building things :)
    net-tools # Oldskool network tools (ifconfig, etc)
)

echo $VM_NAME

MIRROR_PROTOCOL="http"
MIRROR_HOSTNAME="ftp.iinet.net.au"
MIRROR_DIRECTORY="/pub/ubuntu"
MIRROR_URL="${MIRROR_PROTOCOL}://${MIRROR_HOSTNAME}/${MIRROR_DIRECTORY}"
INSTALLER_FILE="netboot.tar.gz"
INSTALLER_MIRROR_PATH="netboot/${INSTALLER_FILE}"
INSTALLER_BASE_URL="${MIRROR_URL}/dists/bionic/main/installer-amd64/current/images"
INSTALLER_URL="${INSTALLER_BASE_URL}/${INSTALLER_MIRROR_PATH}"
INSTALLER_SHA256SUMS="${INSTALLER_BASE_URL}/SHA256SUMS"
INSTALLER_KERNEL="ubuntu-installer/amd64/linux"
INSTALLER_INITRD_GZ="ubuntu-installer/amd64/initrd.gz"
INSTALLER_INITRD_GZ_CUSTOM="${INSTALLER_INITRD_GZ}.custom"

VM_SETUP=(
    --memory ${VM_MEMORY}
    --cpus ${VM_CPUS}

    # Virtualization settings
    --paravirtprovider kvm
    --hwvirtex on
    --nestedpaging on
    --largepages on
    --rtcuseutc on
    --draganddrop disabled
    --clipboard disabled

    # UART
    --uart1 0x3F8 4
    --uartmode1 server "${VM_PATH}/UART"

    # Hardware
    --chipset ich9
    --audio none
    --usb off
    --usbehci off
    --usbxhci off

    # Disable graphics output
    --defaultfrontend headless
    --graphicscontroller none
    --accelerate3d off
    --accelerate2dvideo off

    # Network Interface for internet and PXE network booting
    # (Intel E1000 NIC required for PXE booting)
    --nic1 nat
    --nictype1 82545EM
    --cableconnected1 on
    --nattftpprefix1 "${VM_TFTP_PATH}"
    --nattftpfile1 pxelinux.0
    --nicbootprio1 1

    # Network Interface for ssh/etc
    --nic2 hostonly
    --nictype2 virtio
    --cableconnected2 on
    --hostonlyadapter2 vboxnet0

    # BIOS splash screen
    --bioslogofadein off
    --bioslogofadeout off
    --bioslogodisplaytime 0

    # BIOS boot order
    --boot1 disk
    --boot2 net
    --boot3 none
    --boot4 none

    # Auto start on boot up (if machine is setup for this)
    # https://www.virtualbox.org/manual/ch09.html#autostart
    --autostart-enabled on
)

gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys "630239CC130E1A7FD81A27B140976EAF437D05B5" "790BC7277767219C42C86F933B4FE6ACC0B21F32"

##### There shouldn't be any tweakables below this line #####

# Make sure we have vboxnet0 (Hostonly network)
VBoxManage list hostonlyifs | grep '^Name:\s*vboxnet0$'
if [ $? -ne 0 ]; then
    echo "Creating new hostonlyif"
    VBoxManage hostonlyif create
fi

# Bail on any errors
set -o errexit
# Print all the lines as they're ran
set -o xtrace

# Download installer image and verification materials
wget --no-verbose --continue "${INSTALLER_URL}" "${INSTALLER_SHA256SUMS}" "${INSTALLER_SHA256SUMS}.gpg"

# Verify the checksum file is signed properly
gpg --verify SHA256SUMS.gpg SHA256SUMS

# Verify the netboot.tar.gz file is what it seems
sed -n "s_\./${INSTALLER_MIRROR_PATH}_${INSTALLER_FILE}_p" SHA256SUMS | gsha256sum -c

# Virtual machine creation
VBoxManage createvm --name "${VM_NAME}" --ostype "${VM_OS}" --basefolder "${VM_ROOT}"
VBoxManage registervm "${VM_PATH}/${VM_NAME}.vbox"
VBoxManage modifyvm "${VM_NAME}" ${VM_SETUP[@]}

# Virtual disk creation
VBoxManage createmedium disk --filename "${VM_PATH}/OS.vdi" --size ${VM_DISK} --format VDI
VBoxManage storagectl "${VM_NAME}" --name default --add sata --controller IntelAHCI --portcount 1 --bootable on
VBoxManage storageattach "${VM_NAME}" --storagectl default --port 0 --device 0 --type hdd --medium "${VM_PATH}/OS.vdi" --nonrotational on --discard on

# Setup TFTP environment
mkdir -p "${VM_TFTP_PATH}"
tar -C "${VM_TFTP_PATH}" -xzf "${INSTALLER_FILE}"

# Create pxelinux boot file for 10.x.x.x nodes
cat > "${VM_TFTP_PATH}/pxelinux.cfg/0A" << EOF
DEFAULT autoinstall
SAY AUTO NETWORK INSTALL
TIMEOUT 50
SERIAL 0 115200 0
LABEL autoinstall
	LINUX ${INSTALLER_KERNEL}
    INITRD ${INSTALLER_INITRD_GZ_CUSTOM}
    APPEND root=/dev/ram0 console=ttyS0,115200n8 loglevel=2 DEBIAN_FRONTEND=text auto=true preseed/file=/preseed.cfg
EOF

# Create debian installer preseed file
cat > "${VM_TFTP_PATH}/preseed.cfg" << EOF
# Setup region
d-i debian-installer/language string en
d-i debian-installer/country string US
d-i debian-installer/locale string en_US.UTF-8
d-i time/zone string ${VM_TIMEZONE}

# Setup ubuntu mirror
d-i mirror/country string manual
d-i mirror/protocol string ${MIRROR_PROTOCOL}
d-i mirror/http/hostname string ${MIRROR_HOSTNAME}
d-i mirror/http/directory string ${MIRROR_DIRECTORY}
d-i mirror/http/proxy string

# Setup network
d-i netcfg/choose_interface select auto
d-i netcfg/get_hostname string ${VM_NAME}

# Setup default user (with empty password!)
d-i passwd/user-fullname string user
d-i passwd/username string ${VM_USER}
d-i passwd/user-password-crypted string \$5\$BHQqKyQu6YG\$sP2RR.G77zF3oGr.UEPDbCRw/xo7rwmRgpM3hJDZ8l/
#d-i passwd/user-password string insecure
#d-i passwd/user-password-again string insecure
d-i user-setup/allow-password-weak boolean true
d-i user-setup/encrypt-home boolean false

# Setup partitions, use entire disk, no swap
d-i partman-auto/method string regular
d-i partman-auto/expert_recipe string full :: 500 500 -1 ext4 \$primary{ } \$bootable{ } method{ format } format{ } use_filesystem{ } filesystem{ ext4 } mountpoint{ / } .
d-i partman-partitioning/confirm_write_new_label boolean true
d-i partman/choose_partition select finish
d-i partman/confirm boolean true
d-i partman/confirm_nooverwrite boolean true
d-i partman-basicfilesystems/no_swap boolean false

# Setup clock
d-i clock-setup/ntp boolean false
d-i clock-setup/utc boolean true

# Setup packages
tasksel tasksel/first multiselect manual
d-i base-installer/install-recommends boolean false
d-i pkgsel/upgrade select full-upgrade
d-i pkgsel/update-policy select unattended-upgrades
d-i pkgsel/include string ${VM_PACKAGES[@]}
d-i apt-setup/services-select multiselect security, updates
d-i apt-setup/security-updates boolean true
d-i apt-setup/enable-source-repositories boolean true
d-i apt-setup/non-free boolean true
d-i apt-setup/restricted boolean true
d-i apt-setup/universe boolean true

# Setup bootloader
d-i grub-installer/only_debian boolean true
d-i debian-installer/add-kernel-opts string console=tty0 console=ttyS0,115200n8

# Bring up enp0s8 (the host-only adapter)
# Make sure user changes their password
# Install the users ssh key
d-i preseed/late_command string \
    in-target /bin/sh -c "echo '    enp0s8:' >> /etc/netplan/01-netcfg.yaml" && \
    in-target /bin/sh -c "echo '      dhcp4: yes' >> /etc/netplan/01-netcfg.yaml" && \
    in-target passwd -e ${VM_USER} && \
    in-target mkdir -p /home/${VM_USER}/.ssh && \
    in-target /bin/sh -c "echo ${VM_SSH_KEY} >> /home/${VM_USER}/.ssh/authorized_keys" && \
    in-target chown -R ${VM_USER} /home/${VM_USER}

# Finish
d-i finish-install/reboot_in_progress note
EOF



# Ideally we'd just load the preseed file over tftp, but that doesn't work for some reason
# So let's just append it to the initrd
cp "${VM_TFTP_PATH}/${INSTALLER_INITRD_GZ}" "${VM_TFTP_PATH}/${INSTALLER_INITRD_GZ_CUSTOM}"
pax -s '/.*/preseed.cfg/' -z -x sv4cpio -w "${VM_TFTP_PATH}/preseed.cfg" >> "${VM_TFTP_PATH}/${INSTALLER_INITRD_GZ_CUSTOM}"

# Start the VM
VBoxManage startvm "${VM_NAME}"

# Make a helper script to connect to the uart and call it
cat > "${VM_PATH}/connect.sh" << EOF
#!/bin/bash
socat "unix-client:${VM_PATH}/UART" stdio
EOF
chmod +x "${VM_PATH}/connect.sh"

# connect to UART to show installer progress :)
"${VM_PATH}/connect.sh"
