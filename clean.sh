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


warn_and_exit () {
    echo -e $1
    echo "Press any key to exit."
    # Clear input buffer
    while read -e -t 1; do : ; done
    # Get input from user
    read -n 1
    exit 1
}


test_dependencies()
{
    # List of packages that we need to check if installed on host machine
    # Works only for Ubuntu
    dependencies="parallel"

    distro=$(cat /etc/*-release | sed -e "1q;d" | cut -d"=" -f2)

    if [ $distro == "Ubuntu" ]; then
        missing_deps=$(dpkg -l $dependencies 2>&1 | awk '{if (/^D|^\||^\+/) {next} else if(/^dpkg-query:/) { print $6} else if(!/^[hi]i/) {print $2}}')

        # Show a list of missing packages
        echo $missing_deps

        if [[ ! -z "$missing_deps" ]]; then
            warn_and_exit "Please install the missing dependencies listed above before continuing this setup."
        fi
    else
        echo "This setup requires the following dependencies installed on this host system:"
        echo $dependencies
        bold "Please ensure these dependencies are installed."
        bold "Do you want to continue (y/n)"
        if [[ $answer =~ [Yy] ]]; then
            return
        else
            exit 1
        fi
    fi
}


remove_directory()
{
    directory=${1} 
    find $directory -type d 2>/dev/null | parallel --will-cite -j`nproc` --progress rm -rf {} > /dev/null 2>&1
}


clean_target()
{
    target=${1}

    if [ -d "${DIR}/build/ecs-${target}" ]; then
        cd "${DIR}/build/ecs-${target}"
        (
            echo "Removing tmp, sstate-cache, and cache from target: ${target}..."

            if [[ -f kas-container ]]; then
                sudo ./kas-container clean
            else
                rm -rf "${DIR}/build/ecs-${target}/build/bitbake.lock"
                rm -rf "${DIR}/build/ecs-${target}/build/bitbake.sock"
                rm -rf "${DIR}/build/ecs-${target}/build/hashserve.sock"
                rm -rf "${DIR}/build/ecs-${target}/build/build-*"
                rm -rf "${DIR}/build/ecs-${target}/build/sstate-cache"
                rm -rf "${DIR}/build/ecs-${target}/build/cache"
                rm -rf "${DIR}/build/ecs-${target}/build/tmp"
            fi
        )    
        echo ""
        echo "Clean complete!"
        echo ""
    else
        echo ""
        echo "Build target ${target} has not been built yet."
        echo "Nothing to clean. Exiting..."
        echo ""
    fi
}


usage()
{
    cat << EOF
NAME
    ${prog} - Clean specific build target.

SYNOPSIS
    ${prog} [TARGET]

DESCRIPTION
    A script to clean a specific build target.

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


target="${1:-none}"
[[ "${target}" != "none" ]] && shift

case "${target}" in
    none)
        usage
        ;;
    help) #support help [target] form
        #since help has to break scope of its subcommand file it is implemented here
        if [[ "${1:-none}" == "none" ]]; then #no subcommand given
            usage
        elif [[ -f "${DIR}/targets/${1}" ]]; then #valid target
        #subshell to prevent namespace pollution
        (
            . "${DIR}/targets/${1}"
            usage
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
            usage
        )
        else
            if [[ -f "${DIR}/targets/${target}" ]]; then #valid target
                # Prompt user to install dependencies if needed
                #test_dependencies
                # Clean target
                clean_target ${target}
            else
                die "'${target}' is not a valid target.  See '${prog} help' for a list of targets."
            fi
        fi
        ;;
esac
