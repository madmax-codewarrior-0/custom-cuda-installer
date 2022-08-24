#!/bin/bash

# Must be running as root to do pretty much all of this
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root"
    exit
fi

if [[ $# -lt 1 ]]; then
    echo "Please provide one arguement: part1 | part2"
    exit
fi

# Reboot at the end of part2
need_reboot="false"

# Simple write
if [[ "$2" = "-v" ]] || [[ "$2" = "--verbose" ]]; then
    write_steps="true"
fi

function Write-Out() {

    local _CYAN=
    _CYAN=$(tput setaf 2)
    local _RESET=
    _RESET=$(tput sgr0)

    echo -e "\n${_CYAN}# # #\n  $1\n# # #${_RESET}\n"
}

function Write-CritErr() {

    local _CYAN=
    _CYAN=$(tput setaf 1)
    local _RESET=
    _RESET=$(tput sgr0)

    echo -e "\n${_CYAN}! ! !\n  $1\n! ! !${_RESET}\n"
    exit
}

# At this time, the latest CUDA Run file
cuda_run_url=https://developer.download.nvidia.com/compute/cuda/11.7.1/local_installers/cuda_11.7.1_515.65.01_linux_ppc64le.run

# Locations matter
cuda_install_dir=/root/cuda
run_file_output=$cuda_install_dir/cuda_11.7.1_515.65.01_linux_ppc64le.run

# handy tmpfs additions (if necessary)
tmp_fs_comment="# Added for performance, security, and reliability"
tmp_fs_addition="tmpfs /tmp tmpfs rw,nosuid,nodev"

# Nouveau blacklist filename
nouv_bl_filename="/etc/modprobe.d/provisioner-nouveau-blacklist.conf"

# Notes that are modified from the original installer output (when not run with --silent)
root_cuda_notes="===========
= Summary =
===========

Nvidia Driver:  Installed (515.65.01)
CUDA:           Installed (11.7.1)
Toolkit:        Installed in /usr/local/cuda-11.7/

Please make sure that
 -   PATH includes /usr/local/cuda-11.7/bin
 -   LD_LIBRARY_PATH includes /usr/local/cuda-11.7/lib64, or, add /usr/local/cuda-11.7/lib64 to /etc/ld.so.conf and run ldconfig as root

To uninstall the CUDA Toolkit, run cuda-uninstaller in /usr/local/cuda-11.7/bin
To uninstall the NVIDIA Driver, run nvidia-uninstall
Logfile is /var/log/cuda-installer.log
"
# Strip away the bit about ldconfig, uninstallers, and logs
user_cuda_notes="$(echo "$root_cuda_notes" | head -n -5)"

os_id="$(grep -e '^ID=' /etc/os-release | cut -d '=' -f 2)"

[[ $write_steps = "true" ]] && Write-Out "OS ID: $os_id"

# OS specific lists of packages
case $os_id in 
    "centos")
        case "$(grep 'VERSION_ID' /etc/os-release | cut -d '=' -f 2 | cut -d '"' -f 2)" in 
            "7")
                pkg_mngr="yum"
            ;;
            "8" | "9")
                pkg_mngr="dnf"
            ;;
            *)
                Write-CritErr "Unsupported version of CentOS!"
            ;;
        esac
        pkg_list="tar gzip gcc gcc-c++ make kernel-devel-$(uname -r) kernel-headers-$(uname -r)"
        initramfs_update="dracut --force"
    ;;
    "almalinux" | "rocky")
        pkg_mngr="dnf"
        pkg_list="gcc gcc-c++ make kernel-devel-$(uname -r) kernel-headers-$(uname -r)"
        initramfs_update="dracut --force"
    ;;
    "debian" | "ubuntu")
        pkg_mngr="apt"
        pkg_list="make gcc cpp g++ build-essentials"
        initramfs_update="update-initramfs -u -k all"
    ;;
    *)
        Write-CritErr "Unsupported OS!"
    ;;
esac

if [[ "$1" = "part1" ]]; then
    # Upgrade all packages
    [[ $write_steps = "true" ]] && Write-Out "Upgrading system packages..."
    if [[ $os_id = "debian" ]] || [[ $os_id = "ubuntu" ]]; then
        $pkg_mngr update
    fi
    eval $pkg_mngr upgrade -y

    # Install prerequisites
    [[ $write_steps = "true" ]] && Write-Out "Installing prerequisite packages..."
    eval $pkg_mngr install -y "$pkg_list"

    mkdir $cuda_install_dir

    # Pull the CUDA run-file installer
    [[ $write_steps = "true" ]] && Write-Out "Downloading CUDA installer file..."
    curl -s $cuda_run_url --output $run_file_output

    # Set permissions on the script
    chmod 750 $run_file_output

    # Add a simple performance and security component, if not present already
    if ! grep -q '/tmp' /etc/fstab; then
        [[ $write_steps = "true" ]] && Write-Out "Adding tmpfs additions..."
        echo -e "$tmp_fs_comment\n$tmp_fs_addition" | tee -a /etc/fstab
    else
        [[ $write_steps = "true" ]] && Write-Out "/tmp already mounted"
    fi
    
    # Blacklist the nouveau driver, if not already
    if grep -r -q 'blacklist nouveau' /etc/modprobe.d/*; then
        [[ $write_steps = "true" ]] && Write-Out "Looks like someone already blacklisted the nouveau driver. Continuing..."
    else
        [[ $write_steps = "true" ]] && Write-Out "Blacklisting the nouveau driver..."
        echo -e "# generated prior to Nvidia installer" | tee -a $nouv_bl_filename
        echo -e "blacklist nouveau\noptions nouveau modeset=0" | tee -a $nouv_bl_filename

        [[ $write_steps = "true" ]] && Write-Out "Regenerating initramfs..."
        eval $initramfs_update
    fi

    # Disable the nouveau 
    if lsmod | grep -q 'nouveau'; then
        [[ $write_steps = "true" ]] && Write-Out "Found active nouveau driver. Disabling..."
        rmmod nouveau
    else
        [[ $write_steps = "true" ]] && Write-Out "And it's not running currently. Neat, continuing..."
    fi

    Write-Out "Alright, part2 should be ready! Go for it!"

    exit

elif [ "$1" = "part2" ]; then
    # See if CUDA was already installed to the default location
    search=$(find /usr -type d -name "cuda")

    if [ -n "$search" ]; then
        [[ $write_steps = "true" ]] && Write-Out "CUDA already installed?\n$search"
        exit
    else
        # Run the installer in silent mode installing the nvidia driver and CUDA
        [[ $write_steps = "true" ]] && Write-Out "Beginning cuda silent installer..."
        sh $run_file_output --silent --driver --toolkit --tmpdir=/tmp

        [[ $write_steps = "true" ]] && Write-Out "Done! Distributing notes..."
        echo "$root_cuda_notes" > /root/cuda-notes.txt

        for dir in /home/*
        do 
            echo "$user_cuda_notes" > "$dir/cuda-notes.txt"
        done
        
        [[ $write_steps = "true" ]] && Write-Out "Copying installer logs to $cuda_install_dir!"
        cp /var/log/cuda-installer.log $cuda_install_dir
        cp /var/log/nvidia-installer.log $cuda_install_dir

        [[ $write_steps = "true" ]] && Write-Out "Remove old provisioning nouveau blacklist file..."
        rm -f "$nouv_bl_filename"

        Write-Out "Installation complete!"
    fi

    if [ $need_reboot = "true" ]; then
        reboot now
    fi
else
    echo "Please provide one of these arguments: part1 | part2"
    exit
fi