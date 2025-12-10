#!/bin/bash

set -x -e

RASPIOS_URL="$1"
RASPIOS_SHA256="$2"
IMAGE_SUFFIX="$3"

# *sigh*, some docker containers don't seem to have sbin in their PATH
export PATH=$PATH:/usr/sbin

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
BUILD_DIR="${SCRIPT_DIR}/work/root/"
LOOP_DEVICE=""

# Cleanup function for error handling
cleanup() {
    echo "Cleaning up..."
    sudo umount -fl "${BUILD_DIR}/boot/firmware" 2>/dev/null || true
    sudo umount -fl "${BUILD_DIR}/proc" 2>/dev/null || true
    sudo umount -fl "${BUILD_DIR}/sys" 2>/dev/null || true
    sudo umount -fl "${BUILD_DIR}/dev" 2>/dev/null || true
    sudo umount -fl "${BUILD_DIR}" 2>/dev/null || true
    if [ -n "${LOOP_DEVICE}" ]; then
        sudo losetup -d "${LOOP_DEVICE}" 2>/dev/null || true
    fi
}
trap cleanup EXIT ERR

# cleanup any previous build attempts
umount -fl "${BUILD_DIR}/boot/firmware" 2>/dev/null || true
umount -fl "${BUILD_DIR}/proc" 2>/dev/null || true
umount -fl "${BUILD_DIR}/sys" 2>/dev/null || true
umount -fl "${BUILD_DIR}/dev" 2>/dev/null || true
umount -fl "${BUILD_DIR}" 2>/dev/null || true
# Cleanup any existing loop devices
sudo losetup -D 2>/dev/null || true
rm -rf "${BUILD_DIR}" || true
mkdir -p "${BUILD_DIR}"

# download a modern RaspiOS build (use cache if available)
if [ ! -f raspios.img.xz ]
then
	echo "Downloading Raspberry Pi OS image..."
	wget -nv -O raspios.img.xz "${RASPIOS_URL}"
	echo "${RASPIOS_SHA256} raspios.img.xz" | sha256sum --check --status
	if [ $? -ne 0 ]
	then
	    echo "downloaded raspios does not match checksum";
	    return -1;
	fi
else
	echo "Using cached Raspberry Pi OS image..."
	# Verify cached image checksum
	echo "${RASPIOS_SHA256} raspios.img.xz" | sha256sum --check --status
	if [ $? -ne 0 ]
	then
	    echo "Cached image checksum mismatch, re-downloading..."
	    rm raspios.img.xz
	    wget -nv -O raspios.img.xz "${RASPIOS_URL}"
	    echo "${RASPIOS_SHA256} raspios.img.xz" | sha256sum --check --status
	    if [ $? -ne 0 ]
	    then
	        echo "downloaded raspios does not match checksum";
	        return -1;
	    fi
	fi
fi

rm -f raspios.img
xz -kd raspios.img.xz

# Repartition image
mv raspios.img raspikiosk.img
truncate -s +3G raspikiosk.img
echo ", +" | sfdisk -N2 ./raspikiosk.img

# Setup loop device for Raspberry Pi image (with partition scanning)
# Use automatic loop device detection for WSL compatibility
LOOP_DEVICE=$(sudo losetup --show -f -P raspikiosk.img)
echo "Using loop device: ${LOOP_DEVICE}"

# Resize partition
sudo resize2fs "${LOOP_DEVICE}p2"

# Manually set PARTUUID to 0x23421312
sudo fdisk "${LOOP_DEVICE}" <<EOF > /dev/null
p
x
i
0x23421312
r
p
w
EOF

# Mount partitions
sudo mount "${LOOP_DEVICE}p2" "${BUILD_DIR}"
sudo mount "${LOOP_DEVICE}p1" "${BUILD_DIR}/boot/firmware"

# Copy the (raspberry pi-specific) skeleton files
# Note: --no-owner --no-group for FAT32 boot partition compatibility
sudo rsync -a --no-owner --no-group "${SCRIPT_DIR}/raspberry_pi_skeleton/." "${BUILD_DIR}" || true
sudo rsync -a "${SCRIPT_DIR}/kiosk_skeleton/." "${BUILD_DIR}/kiosk_skeleton" || true

# Copy custom files to bootfs (kioskbrowser.ini, www-public, etc.)
# FAT32 doesn't support Unix permissions, so skip owner/group
if [ -d "${SCRIPT_DIR}/custom" ]; then
    echo "Copying custom files to bootfs..."
    sudo rsync -av --no-owner --no-group "${SCRIPT_DIR}/custom/." "${BUILD_DIR}/boot/firmware/" || true
fi

# Use correct architecture specific (arm64/armhf) config.txt
sudo rm "${BUILD_DIR}/boot/firmware/config.txt"
sudo mv "${BUILD_DIR}/boot/firmware/config-${IMAGE_SUFFIX}.txt" "${BUILD_DIR}/boot/firmware/config.txt"

# Include git repo version info
echo -n "AnotterKiosk Raspberry Pi version: " > "${BUILD_DIR}/version-info"
git describe --abbrev=4 --dirty --always --tags >> "${BUILD_DIR}/version-info"

# Mount system partitions (from the build host)
sudo mount proc -t proc -o nosuid,noexec,nodev "${BUILD_DIR}/proc/"
sudo mount sys -t sysfs -o nosuid,noexec,nodev,ro "${BUILD_DIR}/sys/"
sudo mount devpts -t devtmpfs -o mode=0755,nosuid "${BUILD_DIR}/dev/"

# and then actually install everything.
sudo chroot "${BUILD_DIR}" /kiosk_skeleton/build.sh

sudo rm -r "${BUILD_DIR}/kiosk_skeleton"

cp "${BUILD_DIR}/version-info" version-info

# trim all filesystems
sudo fstrim -a

# fill unused space on /boot with 0x00 
# (FAT32, so zerofree doesn't work, we'll do it manually)
sudo dd if=/dev/zero of="${BUILD_DIR}/boot/firmware/zerofree" bs=1M || true
sudo rm "${BUILD_DIR}/boot/firmware/zerofree" || true

sudo umount -fl "${BUILD_DIR}/proc" || true
sudo umount -fl "${BUILD_DIR}/sys" || true
sudo umount -fl "${BUILD_DIR}/dev" || true

sudo umount "${BUILD_DIR}/proc" || true
sudo umount "${BUILD_DIR}/sys" || true
sudo umount "${BUILD_DIR}/dev" || true

sudo umount "${BUILD_DIR}/boot/firmware" || true
sudo umount "${BUILD_DIR}" || true

# set all empty blocks on ext4 to 0x00 (for better compression)
sudo zerofree "${LOOP_DEVICE}p2"

# Cleanup loop device
sudo losetup -d "${LOOP_DEVICE}" || true

tag=$(git describe --abbrev=4 --dirty --always --tags)
mv raspikiosk.img anotterkiosk-${tag}-${IMAGE_SUFFIX}.img
xz -T0 anotterkiosk-${tag}-${IMAGE_SUFFIX}.img
