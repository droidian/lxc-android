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
        [[ "$i" =~ context|trusted ]] && continue
        options+=$i","
    done
    options=${options%?}
    echo $options
}

get_apex_payload_offset() {
    apex_file="$1"
    python3 -c "
import zipfile

def calculate_offset(apex_path):
    with zipfile.ZipFile(apex_path, 'r') as zf:
        try:
            with zf.open('apex_payload.img') as f:
                return f._orig_compress_start
        except KeyError:
            pass
    return 0 # apex_payload.img not found

print(calculate_offset('$apex_file'))
" 2>/dev/null || echo 0
}

mount_apex() {
    source_path="$1"
    target_path="$2"

    if [ -d "$source_path" ]; then
        # Directory-based APEX
        mkdir -p "$target_path"
        echo "Mounting flattened APEX $source_path to $target_path"
        mount -o bind "$source_path" "$target_path"
    elif [ -f "$source_path" ] && [[ "$source_path" == *.apex ]]; then
        # File-based APEX
        mkdir -p "$target_path"
        offset=$(get_apex_payload_offset "$source_path")
        if [ "$offset" -eq 0 ]; then
            log "Unable to determine offset for APEX file $source_path, skipping"
            return
        fi
        echo "Mounting APEX file $source_path to $target_path with offset $offset"
        mount -o loop,offset=${offset},ro "$source_path" "$target_path"
    fi
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

if [ ! -e "/vendor/build.prop" ]; then
    echo "checking for vendor mount point"
    vendor_images="/userdata/vendor.img /var/lib/lxc/android/vendor.img /dev/disk/by-partlabel/vendor${ab_slot_suffix} /dev/disk/by-partlabel/vendor_a /dev/disk/by-partlabel/vendor_b /dev/mapper/dynpart-vendor /dev/mapper/dynpart-vendor${ab_slot_suffix} /dev/mapper/dynpart-vendor_a /dev/mapper/dynpart-vendor_b"
    for image in $vendor_images; do
        if [ -e $image ]; then
            echo "mounting vendor from $image"
            mount $image /vendor -o ro

            if [ -e "/vendor/build.prop" ]; then
                echo "found valid vendor partition: $image"
                break
            else
                echo "$image is not a valid vendor partition"
                umount /vendor
            fi
        fi
    done
fi

if [ ! -e "/vendor_dlkm/etc/build.prop" ]; then
    echo "checking for vendor_dlkm mount point"
    vendor_dlkm_images="/dev/mapper/dynpart-vendor_dlkm /dev/mapper/dynpart-vendor_dlkm${ab_slot_suffix} /dev/mapper/dynpart-vendor_dlkm_a /dev/mapper/dynpart-vendor_dlkm_b"
    for image in $vendor_dlkm_images; do
        if [ -e $image ]; then
            echo "mounting vendor_dlkm from $image"
            mount $image /vendor_dlkm -o ro

            if [ -e "/vendor_dlkm/etc/build.prop" ]; then
                echo "found valid vendor_dlkm partition: $image"
                break
            else
                echo "$image is not a valid vendor_dlkm partition"
                umount /vendor_dlkm
            fi
        fi
    done
fi

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
        echo "overlayed on /var/lib/lxc/android/rootfs/system"
        if [ -d "/android/system" ]; then
            mount -t overlay overlay -o lowerdir=/usr/lib/droid-system-overlay:/android/system /android/system
            echo "overlayed on /android/system"
        fi
    else
        mount -t overlay overlay -o lowerdir=/var/lib/lxc/android/rootfs/system,upperdir=/usr/lib/droid-system-overlay,workdir=/var/lib/lxc/android/ /var/lib/lxc/android/rootfs/system
        echo "overlayed on /var/lib/lxc/android/rootfs/system"
        if [ -d "/android/system" ]; then
            mount -t overlay overlay -o lowerdir=/android/system,upperdir=/usr/lib/droid-system-overlay,workdir=/android/ /android/system
            echo "overlayed on /android/system"
        fi
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
set -- /vendor/etc/fstab*
[ ! -e "$1" ] && echo "fstab not found" && exit 1
fstab=$1

echo "checking fstab $fstab for additional mount points"

cat ${fstab} ${EXTRA_FSTAB} | while read line; do
    set -- $line

    case $1 in
        \#endhalium*) break ;; # stop processing if we hit the "#endhalium" comment in the file
        \#*|"") continue ;; # Skip any unwanted entry
    esac

    ([ -z "$1" ] || [ -z "$2" ] || [ -z "$3" ] || [ -z "$4" ]) && continue

    case $2 in
        /system|/data|/|auto|/vendor|none|/misc|/system_ext|/product) continue ;;
    esac

    case $3 in
        emmc|swap|mtd) continue ;;
    esac

    label=${1##*/}
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

if [ -d /android/apex ]; then
    echo "Handling /android/apex mounts"

    mount -t tmpfs android_apex /android/apex

    for apex_dir in "/android/system/apex" "/android/system_ext/apex"; do
        [ -d "$apex_dir" ] || continue

        for apex_entry in "$apex_dir"/*; do
            # Extract APEX name (remove directory suffixes and .apex extension)
            apex_name=$(basename "$apex_entry" | sed 's/\.\(release\|debug\|apex\)$//')
            target_path="/android/apex/${apex_name}"

            case "$apex_name" in
                com.android.runtime|com.android.art|com.android.i18n|com.android.vndk.*)
                    mount_apex "$apex_entry" "$target_path"
                    ;;
            esac
        done
    done
fi

