#!/bin/bash
#
# Edge-Controls for Industrial
# Copyright (c) Intel Corporation, 2021
#
# Authors:
#  Jeremy Ouillette <jeremy.ouillette@intel.com>
#


set -e


DIR=$(dirname "$(realpath -s "$0")")
prog=${0##*/}


if [ "$EUID" -ne 0 ]; then
    bold() { echo -e "\e[1m$@\e[0m" ; }
    bold "Please run as root: 'sudo ./${prog}'"
    echo ""
    exit
fi


echo_error()
{
    local RED='\033[1;97;41m'
    local NC='\033[0m' # No Color
    echo -e "${RED}{ERR}:${NC} "${1}
}


get_target_image()
{
    local target=${1}
    local file_extentions=($(echo "${2}" | tr ' ' '\n'))

    # Get image name
    if [[ -f "${DIR}/targets/${target}" ]]; then
        local ecs_image_name=$(source "${DIR}/targets/${target}"; echo ${TARGET_IMAGE_BASENAME})
        # Iterate through all file extentions supplied
        for ext in ${file_extentions[@]}; do
            # Check for symbolic links first, then files
            for t in l f; do
                # Check if image exists
                local image=$(find "${DIR}/build/ecs-${target}/build/tmp/deploy/images" -mindepth 2 ! -type ${t} 2> /dev/null | grep -m 1 "${ecs_image_name}.*\.${ext}$") || :
                if [[ -n "${image}" ]]; then
                    break 2
                fi
            done
        done
    fi

    echo ${image}
}


get_available_targets()
{
    local file_extentions=${1}

    pushd .
    cd "${DIR}/targets"

    find "${DIR}/targets" -maxdepth 1 -type f -name '*' -print0 |
    while IFS= read -r -d '' file; do
        local target=$(basename "${file}")
        if [[ -n "$(get_target_image ${target} ${file_extentions})" ]] ; then
            echo ${target}
        fi
    done
    popd
}


prompt_input()
{
    local __text="input :"
    local __resultvar=${1}
    local __regex=${2}
    local __prompt="${3:-${__text}}"
    local __max_retries="${4:-2}" # Default value is 3
    local __list=("$@"); __list=("${__list[@]:4}")
    local __count=0
    local __input

    while :
    do
        read -p "${__prompt}" __input 

        if [[ ${__input} =~ ${__regex} ]]
        then
            # Check if filtering is enabled
            if [ ! -z ${__list} ]; then
                if [[ ! " ${__list[@]} " =~ " ${__input} " ]]; then
                    echo_error "Entered value not present in list. Please re-enter."
                else    
                    # Entry accepted
                    break
                fi
            else
                # Entry accepted
                break
            fi
        else
            echo_error "Entered value is invalid. Please re-enter."
        fi
    
        if [[ $__count -eq $__max_retries ]]
        then
            echo_error "Exceeded Retries..."
            return 1
        fi
        __count=$__count+1
    done
   
    #Remove trailing spaces and any additional words
    __input=$(echo "${__input}" | awk '{print $1;}') 
    eval $__resultvar="'$__input'"
    return 0
}


resize_device_partition()
{
    local device=${1}

    # Ensure device is unmounted
    umount /dev/${device}1 > /dev/null 2>&1 || :
    umount /dev/${device}2 > /dev/null 2>&1 || :
    umount /dev/${device} > /dev/null 2>&1 || :

    # Fix GPT
    sgdisk -e "/dev/${device}"
    # Resize device partition to hold ECI image
    parted -s "/dev/${device}" resizepart 2 100% 
    sync

    # Fix tree structure
    #e2fsck -p -f "/dev/${device}2"
    local tmp_resize=$(mktemp -d /tmp/eci-XXXX)
    fallocate -l 1000000000 "${tmp_resize}/preallocate"
    sync
    rm "${tmp_resize}/preallocate"
    # Apparently just mounting the partition fixes the tree structure??
    mount "/dev/${device}2" "${tmp_resize}"
    sync

    # Resize filesystem
    resize2fs -p "/dev/${device}2"
    sync
    umount "${tmp_resize}"
    rm -rf "${tmp_resize}"
    sync
}


embed_vm_acrn_image()
{
    local device="${1}"
    local profile="${2}"
    local targets="${3}"

    # Remove any remnants
    umount /tmp/eci-* > /dev/null 2>&1 || :
    rm -rf /tmp/eci-*
   
    # Resize device partition
    resize_device_partition ${device}

    local tmp_mnt=$(mktemp -d /tmp/eci-XXXX)
    local tmp_rootfs=$(mktemp -d /tmp/eci-XXXX)
    local tmp_edit=$(mktemp -d /tmp/eci-XXXX)

    # Mount resized partition
    mount "/dev/${device}2" "${tmp_mnt}"
    sync

    # Copy existing rootfs.img to tmp
    echo "Copying ACRN rootfs to local storage..."
    #dd if="${tmp_mnt}/rootfs.img" of="${tmp_rootfs}/rootfs.img" bs=4M oflag=sync status=progress
    curl --progress-bar -o "${tmp_rootfs}/rootfs.img" "file://${tmp_mnt}/rootfs.img"

    # Resize rootfs to contain larger files
    echo "Resizing rootfs..."
    local tmp_resize=$(mktemp -d /tmp/eci-XXXX)
    # Apparently just mounting the partition fixes the tree structure??
    mount "${tmp_rootfs}/rootfs.img" "${tmp_resize}"
    umount "${tmp_resize}"
    rm -r  "${tmp_resize}"

    local min_size=$(resize2fs -P "${tmp_rootfs}/rootfs.img" | cut -d':' -f2)
    local block_size=$(dumpe2fs -h "${tmp_rootfs}/rootfs.img" | grep -i "Block size" | awk '{print $3}')
    # Add 10G of extra space for additional image
    local min_size=$(($min_size + (10000000000 / $block_size)))
    # Iterate over all images
    local -i addition=0
    for vm in $(echo "${targets}"); do
        # Get target image
        unset image
        local image="$(get_target_image ${vm//\"/} 'wic wic.img')"
        if [[ -n "${image}" ]]; then
            # Get image size
            addition+=$(du --block-size=${block_size} "${image}" | awk '{print $1}')
        fi
    done
    local new_size=$(($min_size + $addition))

    sleep 2; sync
    e2fsck -f "${tmp_rootfs}/rootfs.img"
    resize2fs -p "${tmp_rootfs}/rootfs.img" "${new_size}" || :
    sync

    # Mount copied rootfs.img to tmp to be edited
    mount -o loop "${tmp_rootfs}/rootfs.img" "${tmp_edit}"
    sync

    # Create profile directory
    mkdir -p "${tmp_edit}/var/lib/machines/profiles"

    local -i count=1
    local -i step=2

    if [[ -n "${profile}" ]]; then
        echo "Copying VM profile into rootfs"
        local profile_location="${tmp_edit}/var/lib/machines/profiles/$(basename ${profile})"
        # Copy profile to rootfs.img
        cp "${profile}" "${profile_location}"
        # Create symlink to active profile
        rm -rf "${tmp_edit}/var/lib/machines/vm_profile"
        ln -rs "${profile_location}" "${tmp_edit}/var/lib/machines/vm_profile"
    else
        count=0
    fi

    echo ""
    for vm in $(echo "${targets}"); do
        # Get target image
        unset image
        local image="$(get_target_image ${vm//\"/} 'wic wic.img')"
        local name="vm${count}"
        count+=1

        if [[ -n "${image}" ]]; then
            echo "Copying ${vm} image into rootfs as ${name}.wic"
            mkdir -p "${tmp_edit}/var/lib/machines/images"
            # Copy image to rootfs.img
            #rsync -ah --progress "${image}" "${tmp_edit}/var/lib/machines/images/${name}.wic"
            curl --progress-bar -o "${tmp_edit}/var/lib/machines/images/${name}.wic" "file://${image}"
            sync
        else
            echo "Image for ${vm} not available. Skipping ${name}."

            if [[ "${vm}" =~ "Windows" ]] || [[ "${vm}" =~ "Linux" ]]; then
                local filename="${name}_$(echo ${vm//\"} | awk '{print tolower($0)}').iso"
                EXIT_MSG+="\n  Step ${step}:"
                EXIT_MSG+="\n ------------------------------------------------"
                EXIT_MSG+="\n  Copy the ${vm} image for ${name} into target filesystem at:"
                EXIT_MSG+="\n  /var/lib/machines/images/${filename}\n"
            else
                local filename="${name}.wic"
                EXIT_MSG+="\n  Step ${step}:"
                EXIT_MSG+="\n ------------------------------------------------"
                EXIT_MSG+="\n  Copy the ${vm} image for ${name} into target filesystem at:"
                EXIT_MSG+="\n  /var/lib/machines/images/${filename}\n"
                EXIT_MSG+="\n  NOTE: The ${vm} image is eligible to be copied automatically."
                EXIT_MSG+="\n  To copy the ${vm} image automatically, use the setup.sh script"
                EXIT_MSG+="\n  to build the ${vm} image before running create_bootable_usb.sh.\n"
            fi
    
            step+=1
        fi
    done

    umount "${tmp_edit}"
    sync
    rm -r "${tmp_edit}"

    # Copy edited rootfs.img to device
    local image_size=$(du -h --apparent-size "${tmp_rootfs}/rootfs.img" | awk '{print $1}')
    echo "Copying rootfs to ACRN image... (size: ${image_size})"
    dd if="${tmp_rootfs}/rootfs.img" of="${tmp_mnt}/rootfs.img" bs=4M oflag=sync status=progress
    sync

    echo "Removing temporary directories..."
    # Unmount and cleanup
    rm -r "${tmp_rootfs}"
    umount "${tmp_mnt}"
    rm -r "${tmp_mnt}"
}


embed_vm_acrn()
{
    local target=${1}
    local device=${2}

    # Get list of available targets with images
    IFS=$'\n' targets=($(get_available_targets 'wic wic.img')) # split to array

    # Delete "acrn" elements from array
    local delete=("acrn")
    for value in "${delete[@]}"; do
      for i in "${!targets[@]}"; do
        if [[ ${targets[i]} = *"${value}"* ]]; then
          unset 'targets[i]'
        fi
      done
    done

    # Check if any images exist
    if [ ${#targets[@]} -gt 0 ]; then
        echo ""
        # Clear input buffer
        while read -e -t 1; do : ; done
        # Get input from user
        read -p "Do you want to include an ECI image for ACRN hypervisor use? y/[n] :" answer
        if [[ $answer =~ [Yy] ]]; then

            echo ""
            # Clear input buffer
            while read -e -t 1; do : ; done
            # Get input from user
            read -p "Do you want to use the VM profile tool to select a configuration? y/[n] :" answer

            if [[ $answer =~ [Yy] ]]; then
                local platform=$(grep "^ACRN_BOARD_pn-acrn-hypervisor" "${DIR}/build/ecs-${target}/build/conf/local.conf" | cut -d'"' -f 2)
                selected_profile=$("${DIR}/targets/scripts/vm_config.sh" --platform "${platform}")
                # If the profile was created, only super-user will have priviledge
                chown "$(logname)" "${DIR}/${selected_profile}"
                chgrp "$(id $(logname) -g)" "${DIR}/${selected_profile}"

                if [[ $? -ne 0 ]]; then
                    exit 1
                fi
                
                if [[ -n "${selected_profile}" ]]; then
                    local targets=$(jq ".vm[].image" < "${DIR}/${selected_profile}")
                    embed_vm_acrn_image "${device}" "${DIR}/${selected_profile}" "${targets}" 
                else
                    exit 1
                fi
            else
                local regex=""
                echo ""
                echo ""
                echo "Available target images:"
                echo "---------------------------------------------"
                for t in "${targets[@]}"; do
                    printf "%s\t\t%s \n" "${t}"
                    regex="${regex}|${t}"
                done
                echo "---------------------------------------------"

                local target_vm
                if ! prompt_input target_vm "${regex}" "Please enter target from list :" 3 "${targets[@]}"
                then
                    exit 1
                fi
                echo ""

                embed_vm_acrn_image "${device}" "" "${target_vm}"
            fi
        fi
    fi
}


create_usb()
{
    local target=${1}

    # Prompt user to select image if none provided
    if [[ -z ${target} ]]; then
        # Get list of available targets with images
        IFS=$'\n' targets=($(get_available_targets 'wic wic.img')) # split to array

        # Check if any images exist
        if [ "${#targets[@]}" -eq 0 ]; then
            red "No built images found."
            red "Build target image fisrt using setup.sh script."
            exit 1
        fi

        local regex=""
        echo ""
        echo "Available target images:"
        echo "---------------------------------------------"
        for t in "${targets[@]}"; do
            printf "%s\t\t%s \n" "${t}"
            regex="${regex}|${t}"
        done
        echo "---------------------------------------------"
        bold "Note: If desired target image is not available,"
        bold "use the setup.sh script to build target image."
        echo ""
        local target
        if ! prompt_input target "${regex}" "Please enter target from list :" 3 "${targets[@]}"
        then
            exit 1
        fi
        echo ""
    fi

    # Get target image
    local image=$(get_target_image ${target} 'wic wic.img')

    # Verify image exists
    if [ -z "${image}" ]; then
        if [ "${target}" = "rts-poky" ]; then
            red "Target \"rts-poky\" does not produce an image file."
            red "Refer to ECI documentation for instructions on installing"
            red "rts-poky Debian *.deb files."
        else
            red "No image found for ecs-${target}."
            red "Build ecs-${target} image using setup.sh script."
        fi
        exit 1
    fi

    # Get all storage devices
    local list=$(ls /dev/sd* | grep -E "^/dev/sd[a-z]$")

    # Find all devices with removable storage
    local -a devices
    for line in ${list} ; do
        local device=${line##*dev/}
        if [ $(cat /sys/block/${device}/removable) -eq 1 ]; then
            devices+=( "${device}" )
        fi
    done
    
    # Verify device exists
    if [ -z ${devices} ]; then
        die "No removable mass storage devices found."
        exit 1
    fi

    echo ""
    echo "Available removable mass storage devices:"
    printf "Vendor\t\t\tdevice\n"
    echo "---------------------------------------------"
    for d in "${devices[@]}"; do
        printf "%s\t\t%s \n" $(cat /sys/block/${d}/device/vendor) "${d}"
    done
    echo "---------------------------------------------"

    local device
    if ! prompt_input device "^sd[a-z]$" "Please enter device from list (ex: sda) :" 3 "${devices[@]}"
    then
        exit 1
    fi

    # Get device storage size
    eject -t "/dev/${device}" || :
    local device_storage=$((($(blockdev --getsize64 "/dev/${device}")/1000000000)))
    
    # Verify device meets minimum storage requirements
    if [[ ${device_storage} -lt 12 ]]; then
	    echo ""
        red "Not enough storage on device /dev/${device}."
        echo "Need at least 12GB of storage."
        exit 1
    fi

    echo ""
    # Clear input buffer
    while read -e -t 1; do : ; done
    # Get input from user
    read -p "Warning: All data will be erased on /dev/${device} Proceed? y/[n] :" answer

	if [[ ! $answer =~ [Yy] ]]; then
        exit 1
	fi
    #wipefs -a -f "/dev/${device}"

    umount "/dev/${device}1" > /dev/null 2>&1 || :
    umount "/dev/${device}2" > /dev/null 2>&1 || :
    dd bs=4M if="${image}" of="/dev/${device}" oflag=sync status=progress
    sync
    umount "/dev/${device}1" > /dev/null 2>&1 || :
    umount "/dev/${device}2" > /dev/null 2>&1 || :
    local rc=0
    sleep 2; sync
    e2fsck "/dev/${device}2" || rc=1 
    if [[ $rc -ne 0 ]]; then
        echo "USB write failed. Attempting again..."
        eject "/dev/${device}" || :
        sleep 1
        eject -t "/dev/${device}" || :
        sleep 1
        dd bs=4M if="${image}" of="/dev/${device}" oflag=sync status=progress
        sync
        umount "/dev/${device}1" > /dev/null 2>&1 || :
        umount "/dev/${device}2" > /dev/null 2>&1 || :
        rc=0
        sleep 2; sync
        e2fsck "/dev/${device}2" || rc=1
        if [[ $rc -ne 0 ]]; then
            echo "USB is in unrecoverable state."
            echo "Please run this script again:"
            bold() { echo -e "\e[1m$@\e[0m" ; }
            bold "sudo ./${prog}"
            exit 1
        fi
    fi

    if [[ "$target" == *"acrn"* ]]; then # ACRN target
        embed_vm_acrn ${target} ${device}
    fi

    # Complete
    print_complete_message ${target}
}


print_complete_message()
{
    target=${1}
    
    echo ""
    echo "*************************************************"
    echo " Bootable USB creation complete!"
    echo " Boot from USB to install ecs-${target} image."
    if [[ -n "${EXIT_MSG}" ]]; then
        echo ""
        echo " NOTE: Additional steps are required before"
        echo " selected VM configuration is available."
        echo " Follow the instructions below to enable"
        echo " the selected VM configuration."
        echo ""
        echo "  Step 1:"
        echo " ------------------------------------------------"
        echo "  Install the ACRN image to the target platform"
        echo "  using the USB created by this tool."
        printf "${EXIT_MSG}"
    fi
    echo "*************************************************"
    echo ""
}


usage()
{
    cat << EOF
NAME
    ${prog} - Create bootable USB for build target.

SYNOPSIS
    ${prog} [TARGET]

DESCRIPTION
    A script to create a bootable USB for a build target.

TARGETS
    Note that * denotes an experimental beta option.

EOF

    #subshell so we don't pollute our namespace
    find "${DIR}/targets" -maxdepth 1 -type f -name '*' -print0 |
    while IFS= read -r -d '' file; do
    (
        #source file and run description to print description
        . "${file}"
        description
    )
    done
    echo ""
    exit 0
}


#----------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------

# Console output colors
bold() { echo -e "\e[1m$@\e[0m" ; }
red() { echo -e "\e[31m$@\e[0m" ; }
green() { echo -e "\e[32m$@\e[0m" ; }
yellow() { echo -e "\e[33m$@\e[0m" ; }

die() { red "ERR: $@" >&2 ; exit 2 ; }
silent() { "$@" > /dev/null 2>&1 ; }
output() { echo -e "- $@" ; }
outputn() { echo -en "- $@ ... " ; }
ok() { green "${@:-OK}" ; }

pushd() { command pushd "$@" >/dev/null ; }
popd() { command popd "$@" >/dev/null ; }

EXIT_MSG=""
target="${1:-none}"
[[ "${target}" != "none" ]] && shift

case "${target}" in
    none)
        create_usb
        ;;
    help) #support help [target] form
        #since help has to break scope of its subcommand file it is implemented here
        if [[ "${1:-none}" == "none" ]]; then #no subcommand given
            usage
        elif [[ -f "${DIR}/targets/${1}" ]]; then #valid target
        #subshell to prevent namespace pollution
        (
            . "${DIR}/targets/${1}"
            description
        )
        else #invalid target
            red "'$1' is not a valid target.\n"
            usage
        fi
        ;;
    *)
        if [[ "$1" =~ ^help$ ]]; then #support [command] help form
        #subshell to prevent namespace pollution
        (
            . "${DIR}/targets/${target}"
            description
        )
        else
            if [[ -f "${DIR}/targets/${target}" ]]; then #valid target
                create_usb ${target}
            else
                die "'${target}' is not a valid target.  See '${prog} help' for a list of targets."
            fi
        fi
        ;;
esac

