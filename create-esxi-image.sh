#!/bin/bash
set -eE

# Defaults
DEFAULT_QEMU_MEMORY=16G
DEFAULT_QEMU_SMP=4
DEFAULT_QEMU_CPU=host
DEFAULT_QEMU_BIOS=/usr/share/ovmf/OVMF.fd
DEFAULT_ROOT_PASSWORD='P@ssw0rd'

if [ $EUID -ne 0 ]; then
    echo "This script must be run as root" 1>&2
    exit 1
fi

run() {
    local CMD=$1
    shift

    if [[ $DRY_RUN ]]; then
        echo Executing: $CMD "$@" 1>&2
        [[ $CMD =~ dd|mkdir|mkfs|mount|rm|umount ]] || return 0
    fi
    command $CMD "$@"
}

CMDS=(cp dd mkdir mkfs mkisofs mount mv rm qemu-img qemu-system-x86_64 truncate umount)
for CMD in ${CMDS[*]}; do eval 'function '$CMD' { run '$CMD' "$@"; }'; done

CMD=$(basename $0)
BASEDIR=$(dirname $0)

usage() {
    local IFS='|'
    cat <<EOD
Usage: $CMD [OPTIONS] [ISO]

ISO                Optional VMware ESXi or VMvisor installer ISO

OPTIONS:
-i|--iso           VMware ISO image with Kickstart file (default ISO label)
-k|--kickstart     Kickstart file (default ks.cfg)
-o|--overwrite     Overwrite already existing VMware ISO image with Kickstart
-s|--size SIZE     Disk image size expressed in GiB (default 32)
-z|--compress      Compress qcow2 output image with zlib algorithm
-N|--name NAME     VMware disk image name without extension (default ISO label)
   --vnc [OPTS]    Enable VNC to interact with VM for image creation (OPT default to ":0,to=100")
   --dry-run       Print actions instead of executing them
-h|--help          Display this help

ENVIRONMENT:
QEMU_MEMORY        Default $DEFAULT_QEMU_MEMORY
QEMU_SMP           Default $DEFAULT_QEMU_SMP
QEMU_CPU           Default $DEFAULT_QEMU_CPU
QEMU_BIOS          Default $DEFAULT_QEMU_BIOS
EOD
}

if ! OPTS=$(getopt -o 'i:k:os:zN:h' -l 'iso:,kickstart:,overwrite,size:,compress,name:,vnc::,dry-run,help' -n $CMD -- "$@"); then
    usage 1>&2
    exit 1
fi
eval set -- "$OPTS"
unset OPTS

KS_CFG='ks.cfg'
OVERWRITE=False
DISPLAY='-display none'
VNC_OPT=':0,to=100'
while true; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -i|--iso)
            VMWARE_ISO="$2"
            shift
            ;;
        -k|--kickstart)
            KS_CFG="$2"
            shift
            ;;
        -o|--overwrite)
            OVERWRITE=True
            ;;
        -s|--size)
            SIZE=$2
            shift
            ;;
        -z|--compress)
            COMPRESS='-c'
            ;;
        -N|--name)
            DISK_NAME=$2
            shift
            ;;
        --vnc)
            DISPLAY="${DISPLAY} -vnc ${2:-$VNC_OPT}"
            shift
            ;;
        --dry-run)
            DRY_RUN=True
            ;;
        --)
            shift
            break
            ;;
        *)
            echo "Internal error while parsing parameters." 1>&2
            exit 1
            ;;
    esac
    shift
done

# Only one optional parameter allowed
if [[ $# -gt 1 ]]; then
    usage 1>&2
    exit 1
elif [[ $# -eq 1 ]]; then
    if [[ ! -f "$1" ]]; then
        echo "VMware ISO file not found: $1" 1>&2
        usage 1>&2
        exit 1
    fi
    ISO="$1"
fi

# Check ISO files
if [[ -z "$VMWARE_ISO" || ! -f "$VMWARE_ISO" ]]; then
    OVERWRITE=True
elif [[ -n "$VMWARE_ISO" && ! -f "$VMWARE_ISO" ]]; then
    OVERWRITE=True
fi
if [[ $OVERWRITE == True && -z "$ISO" ]]; then
    echo "No VMware ISO provided" 1>&2
    usage 1>&2
    exit 1
elif [[ $OVERWRITE == False && ! -f "$VMWARE_ISO" ]]; then
    echo "No VMware ISO provided" 1>&2
    usage 1>&2
    exit 1
fi

# Check Kickstart file
if [[ $OVERWRITE == True && ! -f "$KS_CFG" ]]; then
    echo "Kickstart file not found: $KS_CFG" 1>&2
    usage 1>&2
    exit 1
fi

# Check disk size
: ${SIZE:=32}
if [[ $SIZE -lt 32 ]]; then
    echo "Insufficient disk size: $SIZE (>= 32GiB)"
    exit 1
fi

cleanup() {
    umount "$TMP_MOUNT_PATH/overlay" "$TMP_MOUNT_PATH/iso" || :
    rm -rf "$TMP_DISK_IMAGE" "$TMP_MOUNT_PATH" ks.img || :
} &>/dev/null
trap cleanup INT ERR EXIT

if [[ $OVERWRITE == True ]]; then
    echo "Create custom ISO image..."
    TMP_DISK_IMAGE=$(/bin/mktemp)
    TMP_MOUNT_PATH=$(/bin/mktemp -d)
    mkdir $TMP_MOUNT_PATH/{iso,upper,workdir,overlay}
    # Mount VMware ISO image
    mount -o loop -r "$ISO" "$TMP_MOUNT_PATH/iso"

    eval `blkid -o export $(awk '$2~mount{ print $1 }' mount="$TMP_MOUNT_PATH/iso" /proc/mounts)`

    mount -t overlay \
          -o lowerdir="$TMP_MOUNT_PATH/iso",upperdir="$TMP_MOUNT_PATH/upper",workdir="$TMP_MOUNT_PATH/workdir" \
          none "$TMP_MOUNT_PATH/overlay"

    sed -e 's|\( *APPEND.*\)|\1 ks=usb:/KS.CFG|' -i "$TMP_MOUNT_PATH/overlay/isolinux.cfg"
    sed -e 's|^kernelopt=.*|kernelopt=runweasel ks=usb:/KS.CFG|' -i "$TMP_MOUNT_PATH/overlay/efi/boot/boot.cfg"

    # Burn the new ISO
    mkisofs -quiet \
            -r -iso-level 3 \
            -volid "$LABEL" \
            -allow-limited-size \
            -eltorito-boot isolinux.bin \
            -eltorito-catalog boot.cat \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            -eltorito-alt-boot \
            -e efiboot.img \
            -no-emul-boot \
            -o "$TMP_DISK_IMAGE" \
            "$TMP_MOUNT_PATH/overlay"
    umount "$TMP_MOUNT_PATH/overlay"

    : ${VMWARE_ISO:="${DISK_NAME:-$LABEL}.iso"}
    mv "$TMP_DISK_IMAGE" "$VMWARE_ISO"

    # Clean up ISO tasks
    umount "$TMP_MOUNT_PATH/iso"
    rm -rf "$TMP_DISK_IMAGE" "$TMP_MOUNT_PATH"
else
    eval `blkid -o export "$VMWARE_ISO"`
fi
echo "VMware ISO image: $VMWARE_ISO"

echo "Create Kickstart USB image..."
TMP_DISK_IMAGE=$(/bin/mktemp)
TMP_MOUNT_PATH=$(/bin/mktemp -d)

truncate --size=16M "$TMP_DISK_IMAGE"
parted -s "$TMP_DISK_IMAGE" mklabel msdos
parted -s "$TMP_DISK_IMAGE" mkpart primary fat16 1 100%
mkfs.fat -F 16 --offset 2048 "$TMP_DISK_IMAGE"
mount -o loop,offset=$[2048*512] "$TMP_DISK_IMAGE" "$TMP_MOUNT_PATH"

IFS='-' read -r OS VERSION BUILD TYPE <<<"$LABEL"
IFS='.' read -r MAJOR MINOR <<<"$VERSION"

: ${ROOT_PASSWORD:=$DEFAULT_ROOT_PASSWORD}
INSTALL_OPTIONS="--overwritevmfs --ignoreprereqwarnings --ignoreprereqerrors"
[[ $MAJOR -le 7 ]] || INSTALL_OPTIONS="$INSTALL_OPTIONS --forceunsupportedinstall"

export INSTALL_OPTIONS ROOT_PASSWORD
envsubst <"$KS_CFG" >"$TMP_MOUNT_PATH/ks.cfg"

umount "$TMP_MOUNT_PATH"
mv "$TMP_DISK_IMAGE" ks.img


echo "Create QCow2 disk image..."
QCOW_DISK="${DISK_NAME:-$LABEL}.qcow2"

TMP_DISK_IMAGE=$(/bin/mktemp)
truncate --size=${SIZE}G "$TMP_DISK_IMAGE"

qemu_system() {
    local ACCEL='kvm'
    [[ -c /dev/kvm ]] || ACCEL='tcg'

    qemu-system-x86_64 \
        -accel $ACCEL \
        -cpu ${QEMU_CPU:-$DEFAULT_QEMU_CPU} \
        -smp ${QEMU_SMP:-$DEFAULT_QEMU_SMP} \
        -m ${QEMU_MEMORY:-$DEFAULT_QEMU_MEMORY} \
        -bios "${QEMU_BIOS:-$DEFAULT_QEMU_BIOS}" \
        -usb \
        -device ahci,id=ahci \
        -drive file="$TMP_DISK_IMAGE",if=none,id=disk0,media=disk,format=raw \
        -device ide-hd,bus=ahci.0,drive=disk0 \
        -drive file="$VMWARE_ISO",if=none,id=cd0,media=cdrom,format=raw \
        -device ide-cd,bus=ahci.1,drive=cd0 \
        -drive file="ks.img",if=none,id=stick,format=raw \
        -device usb-storage,bus=usb-bus.0,drive=stick,removable=off \
        -nic user,model=e1000e \
        $DISPLAY \
        "$@"
}

echo "Install VMware from ISO..."
# cdrom only needed on first boot
qemu_system -no-reboot

echo "Convert${COMPRESS+ and compress} VMware disk image ($QCOW_DISK)..."
qemu-img convert $COMPRESS -p -O qcow2 "$TMP_DISK_IMAGE" "$QCOW_DISK"
