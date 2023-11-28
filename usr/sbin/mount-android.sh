#!/bin/bash

# On systems with A/B partition layout, current slot is provided via cmdline parameter.
if [ -e /proc/bootconfig ]; then
    ab_slot_suffix=$(grep -o 'androidboot\.slot_suffix = ".."' /proc/bootconfig | cut -d '"' -f2)
fi

if [ -z "$ab_slot_suffix" ]; then
    ab_slot_suffix=$(grep -o 'androidboot\.slot_suffix=..' /proc/cmdline |  cut -d "=" -f2)
fi

[ ! -z "$ab_slot_suffix" ] && echo "A/B slot system detected! Slot suffix is $ab_slot_suffix"

find_partition_path() {
    label=$1
    path="/dev/$label"
    # In case fstab provides /dev/mmcblk0p* lines
    for dir in by-partlabel by-name by-label by-path by-uuid by-partuuid by-id; do
        # On A/B systems not all of the partitions are duplicated, so we have to check with and without suffix
        if [ -e "/dev/disk/$dir/$label$ab_slot_suffix" ]; then
            path="/dev/disk/$dir/$label$ab_slot_suffix"
            break
        elif [ -e "/dev/disk/$dir/$label" ]; then
            path="/dev/disk/$dir/$label"
            break
        fi
    done
    echo $path
}

parse_mount_flags() {
    org_options="$1"
    options=""
    for i in $(echo $org_options | tr "," "\n"); do
        [[ "$i" =~ "context" ]] && continue
        options+=$i","
    done
    options=${options%?}
    echo $options
}

if [ -n "${BIND_MOUNT_PATH}" ] && ! mountpoint -q -- "${BIND_MOUNT_PATH}"; then
    android_images="/userdata/android-rootfs.img /var/lib/lxc/android/android-rootfs.img"
    for image in ${android_images}; do
        if [ -f "${image}" ]; then
            mount "${image}" "${BIND_MOUNT_PATH}"
            break
        fi
    done
fi

if [ -e "/dev/disk/by-partlabel/super" ]; then
    echo "mapping super partition"
    dmsetup create --concise "$(parse-android-dynparts /dev/disk/by-partlabel/super)"
fi

echo "checking for vendor mount point"

vendor_images="/userdata/vendor.img /var/lib/lxc/android/vendor.img /dev/mapper/dynpart-vendor /dev/mapper/dynpart-vendor${ab_slot_suffix}"
for image in $vendor_images; do
    if [ -e $image ]; then
        echo "mounting vendor from $image"
        mount $image /vendor -o ro
    fi
done

sys_vendor="/sys/firmware/devicetree/base/firmware/android/fstab/vendor"
if [ -e $sys_vendor ] && ! mountpoint -q -- /vendor; then
    label=$(cat $sys_vendor/dev | awk -F/ '{print $NF}')
    path=$(find_partition_path $label)
    [ ! -e "$path" ] && echo "Error vendor not found" && exit
    type=$(cat $sys_vendor/type)
    options=$(parse_mount_flags $(cat $sys_vendor/mnt_flags))
    echo "mounting $path as /vendor"
    mount $path /vendor -t $type -o $options
fi

# Bind-mount /vendor if we should. Legacy devices do not have /vendor
# on a separate partition and we should handle that.
if [ -n "${BIND_MOUNT_PATH}" ] && mountpoint -q -- /vendor; then
    # Mountpoint, bind-mount. We don't use rbind as we're going
    # to go through the fstab anyways.
    mount -o bind /vendor "${BIND_MOUNT_PATH}/vendor"
fi

sys_persist="/sys/firmware/devicetree/base/firmware/android/fstab/persist"
if [ -e $sys_persist ]; then
    label=$(cat $sys_persist/dev | awk -F/ '{print $NF}')
    path=$(find_partition_path $label)
    # [ ! -e "$path" ] && echo "Error persist not found" && exit
    type=$(cat $sys_persist/type)
    options=$(parse_mount_flags $(cat $sys_persist/mnt_flags))
    echo "mounting $path as /mnt/vendor/persist"
    mount $path /mnt/vendor/persist -t $type -o $options
fi

echo "checking if system overlay exists"
if [ -d "/usr/lib/droid-system-overlay" ]; then
    echo "mounting android's system overlay"
    if [ $(uname -r | cut -d "." -f 1) -ge "4" ]; then
        mount -t overlay overlay -o lowerdir=/usr/lib/droid-system-overlay:/var/lib/lxc/android/rootfs/system /var/lib/lxc/android/rootfs/system
    else
        mount -t overlay overlay -o lowerdir=/var/lib/lxc/android/rootfs/system,upperdir=/usr/lib/droid-system-overlay,workdir=/var/lib/lxc/android/ /var/lib/lxc/android/rootfs/system
    fi
fi
echo "checking if vendor overlay exists"
if [ -d "/usr/lib/droid-vendor-overlay" ]; then
    echo "mounting android's vendor overlay"
    if [ $(uname -r | cut -d "." -f 1) -ge "4" ]; then
        mount -t overlay overlay -o lowerdir=/usr/lib/droid-vendor-overlay:/var/lib/lxc/android/rootfs/vendor /var/lib/lxc/android/rootfs/vendor
    else
        mount -t overlay overlay -o lowerdir=/var/lib/lxc/android/rootfs/vendor,upperdir=/usr/lib/droid-vendor-overlay,workdir=/var/lib/lxc/android/ /var/lib/lxc/android/rootfs/vendor
    fi
fi

# Assume there's only one fstab in vendor
fstab=$(ls /vendor/etc/fstab*)
[ -z "$fstab" ] && echo "fstab not found" && exit

echo "checking fstab $fstab for additional mount points"

cat ${fstab} ${EXTRA_FSTAB} | while read line; do
    set -- $line

    # stop processing if we hit the "#endhalium" comment in the file
    echo $1 | egrep -q "^#endhalium" && break

    # Skip any unwanted entry
    echo $1 | egrep -q "^#" && continue
    ([ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]) && continue
    ([ "$2" = "/system" ] || [ "$2" = "/data" ] || [ "$2" = "/" ] \
    || [ "$2" = "auto" ] || [ "$2" = "/vendor" ] || [ "$2" = "none" ] \
    || [ "$2" = "/misc" ] || [ "$2" = "/system_ext" ] || [ "$2" = "/product" ]) && continue
    ([ "$3" = "emmc" ] || [ "$3" = "swap" ] || [ "$3" = "mtd" ]) && continue

    label=$(echo $1 | awk -F/ '{print $NF}')
    [ -z "$label" ] && continue

    echo "checking mount label $label"

    path=$(find_partition_path $label)

    [ ! -e "$path" ] && continue

    mkdir -p $2
    echo "mounting $path as $2"
    mount $path $2 -t $3 -o $(parse_mount_flags $4)

    # Bind mount on rootfs if we should
    if [ -n "${BIND_MOUNT_PATH}" ] && [[ ${2} != /mnt/* ]]; then
        # /mnt is recursively binded via the LXC configuration
        mount -o bind ${2} "${BIND_MOUNT_PATH}/${2}"
    fi
done
