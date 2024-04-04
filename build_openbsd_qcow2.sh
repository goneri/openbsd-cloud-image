#!/usr/bin/env bash
################################################################################
# Description : see the print_help function or launch 'build_openbsd_qcow2 --help'
#
# Based on Stefan Kreutz work:
# * https://www.skreutz.com/posts/autoinstall-openbsd-on-qemu/
# * https://git.skreutz.com/autoinstall-openbsd-on-qemu.git/tree
#
# Copyright (c) 2023 Hyacinthe Cartiaux <hyacinthe.cartiaux@gmail.com>
# Copyright (c) 2020 Stefan Kreutz <mail@skreutz.com>
#
# Permission to use, copy, modify, and distribute this software for any purpose
# with or without fee is hereby granted, provided that the above copyright
# notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
# REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY
# AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
# INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
# LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
# OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
# PERFORMANCE OF THIS SOFTWARE.#
#
################################################################################
#set -x

# Defaults
TOP_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PATH_MIRROR="${TOP_DIR}/mirror"
PATH_IMAGES="${TOP_DIR}/images"
PATH_TFTP="${TOP_DIR}/tftp"

OPENBSD_VERSION="7.4"
v=${OPENBSD_VERSION//./}
OPENBSD_ARCH=amd64

OPENBSD_TRUSTED_MIRROR="https://ftp.openbsd.org/pub/OpenBSD/${OPENBSD_VERSION}"
OPENBSD_MIRROR="https://cdn.openbsd.org/pub/OpenBSD/${OPENBSD_VERSION}"

IMAGE_SIZE=50G
IMAGE_NAME="${PATH_IMAGES}/openbsd${v}_$(date +%Y-%m-%d).qcow2"

### Functions

function warning    { echo "[WARNING] $1"; }
function fail       { echo "[FAIL] $*" 1>&2 && exit 1; }
function report     { echo "[INFO] $*"; }
function exec_cmd   {
    if [ "$DRY_RUN" == "DEBUG" ] ; then
        if [[ $1 == "bg" ]]; then
            shift
            echo "[DRY-RUN] $* &"
        else
            echo "[DRY-RUN] $*"
        fi
    else
        echo "[CMD] $*"
        if [[ $1 == "bg" ]]; then
            shift
            $* &
        else
            $*
        fi
        return $?
    fi
}

function check_program {
    program="$1"
    exec_cmd command -v "${program}" || \
        fail "You need ${program} installed and in the path"
}

function check_for_programs {
    check_program ssh
    check_program sudo
    check_program signify
    check_program qemu-img
    check_program qemu-system-x86_64
    check_program python3
    check_program curl
}

function build_mirror {
    files="base${v}.tgz bsd bsd.mp bsd.rd comp${v}.tgz game${v}.tgz man${v}.tgz pxeboot xbase${v}.tgz xfont${v}.tgz xserv${v}.tgz xshare${v}.tgz"

    exec_cmd curl -C - -O --create-dirs --output-dir "${PATH_MIRROR}/pub/OpenBSD/${OPENBSD_VERSION}" "${OPENBSD_TRUSTED_MIRROR}/openbsd-${v}-base.pub"

    for i in $files SHA256.sig
    do
        exec_cmd curl -C - -O --create-dirs --output-dir "${PATH_MIRROR}/pub/OpenBSD/${OPENBSD_VERSION}/${OPENBSD_ARCH}" "${OPENBSD_MIRROR}/${OPENBSD_ARCH}/$i"
    done

    exec_cmd cd "${TOP_DIR}/custom"
    exec_cmd tar -czf "${PATH_MIRROR}/pub/OpenBSD/${OPENBSD_VERSION}/amd64/site${v}.tgz" install.site

    exec_cmd cd "${PATH_MIRROR}/pub/OpenBSD/${OPENBSD_VERSION}/${OPENBSD_ARCH}"
    exec_cmd ls -l | tail -n +2 | exec_cmd tee index.txt
    exec_cmd signify -C -p "../openbsd-${v}-base.pub" -x SHA256.sig -- $files

    exec_cmd cd "${TOP_DIR}"
    exec_cmd ln -sf ../custom/install.conf "${PATH_MIRROR}"
    exec_cmd ln -sf ../custom/disklabel    "${PATH_MIRROR}"
}

function start_mirror {
    exec_cmd bg sudo python3 -m http.server --directory mirror --bind 127.0.0.1 80
    trap "report Stop the HTTP mirror server ; exec_cmd kill $(jobs -p)" EXIT
    report Waiting for the HTTP mirror server to be available
    while [ ! "$(exec_cmd curl --silent 'http://127.0.0.1/install.conf')" ]
    do
        exec_cmd sleep 1
    done
    report HTTP mirror server reachable
}

function build_tftp {
    exec_cmd cd "${TOP_DIR}"
    exec_cmd mkdir -p "${PATH_TFTP}/etc"
    exec_cmd ln -sf "../mirror/pub/OpenBSD/${OPENBSD_VERSION}/amd64/pxeboot" tftp/auto_install
    exec_cmd ln -sf "../mirror/pub/OpenBSD/${OPENBSD_VERSION}/amd64/bsd.rd" tftp/bsd.rd
    exec_cmd ln -sf ../../custom/boot.conf tftp/etc/
}

function create_image {
    exec_cmd mkdir -p "${PATH_IMAGES}"
    exec_cmd qemu-img create -f qcow2 "${IMAGE_NAME}" "${IMAGE_SIZE}"
}

function launch_install {
    # Skip lines to preserve the output
    exec_cmd seq $(( $(tput lines) +3  )) | exec_cmd tr -dc '\n'
    # Start qemu
    exec_cmd qemu-system-x86_64 -action reboot=shutdown -boot once=n -enable-kvm -smp cpus=1 -m 512m   \
                                -drive file="${IMAGE_NAME}",media=disk,if=virtio                       \
                                -device virtio-net-pci,netdev=n1 -nographic                            \
                                -netdev user,id=n1,hostname=openbsd-vm,tftp=tftp,bootfile=auto_install,hostfwd=tcp::2222-:22
}

####
# print help
##
print_help() {
    less <<EOF
NAME
  $COMMAND

SYNOPSIS
  $COMMAND [-h|--help]


DESCRIPTION
  $COMMAND build a cloud image of OpenBSD

OPTIONS
  -h --help
    Display a help screen and quit.

  -d --debug
    Display extra debug output

  -b
    Build !

AUTHOR
  Hyacinthe Cartiaux <Hyacinthe.Cartiaux@gmail.com>

COPYRIGHT
  This is free software; see the source for copying conditions.
EOF
}


### Let's go

# Check for options
while [ $# -ge 1 ]; do
    case $1 in
        -h | --help)     print_help; exit 0 ;;
        -n | --dry-run)  DRY_RUN="DEBUG";   ;;
        -b | --build)    RUN=1;             ;;
    esac
    shift
done

if [[ -z "$RUN" ]]; then
    print_help
    exit 0
else
    check_for_programs
    build_mirror
    build_tftp
    start_mirror
    create_image
    launch_install
    # ssh -o "StrictHostKeyChecking no" -o "UserKnownHostsFile /dev/null" -o "Port 2222" root@127.0.0.1
fi

