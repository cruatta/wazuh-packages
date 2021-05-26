#!/bin/sh

# Program to build the Wazuh Virtual Machine
# Wazuh package generator
# Copyright (C) 2015-2020, Wazuh Inc.
#
# This program is a free software; you can redistribute it
# and/or modify it under the terms of the GNU General Public
# License (version 2) as published by the FSF - Free Software
# Foundation.

set -e
# Dependencies: vagrant, virtualbox

# CONFIGURATION VARIABLES

scriptpath=$(
    cd $(dirname $0)
    pwd -P
)

OUTPUT_DIR="${scriptpath}/output"
CHECKSUM_DIR=""
HAVE_VERSION=false
HAVE_OPENDISTRO_VERSION=false
HAVE_ELK_VERSION=false

# Get the currents production branches
BRANCHDOC=$(curl -s https://documentation.wazuh.com/current/index.html | grep -o "m/[0-9\.]\+/i" | head -n1)
BRANCHDOC="${BRANCHDOC:2:3}"
BRANCH=${BRANCHDOC}
export BRANCHDOC
export BRANCH

WAZUH_VERSION=""
OPENDISTRO_VERSION=""
ELK_VERSION=""
PACKAGES_REPOSITORY="prod"
CHECKSUM="no"
UI_REVISION="1"

help () {

    echo
    echo "General usage: $0 [OPTIONS]"
    echo "  -w,    --wazuh            [Required] Version of wazuh to install on VM."
    echo "  -o,    --opendistro       [Required] Version of Open Distro for Elasticsearch."
    echo "  -e,    --elk              [Required] Versions of Elasticsearch, Logstash and Kibana."
    echo "  -r,    --repository       [Optional] Select the software repository [dev/prod]. By default: prod"
    echo "  -b,    --branch           [Optional] Branch/tag of the Wazuh development repository. By default: ${BRANCH}"
    echo "  -d,    --doc              [Optional] Branch/tag of the Wazuh documentation development repository. By default: ${BRANCHDOC}"
    echo "  -s,    --store <path>     [Optional] Set the destination absolute path where the ova file will be stored."
    echo "  -c,    --checksum <path>  [Optional] Generate checksum. By default: no"
    echo "  -u,    --ui-revision      [Optional] Revision of the UI package. By default, 1"
    echo "  -h,    --help             [  Util  ] Show this help."
    echo
    echo "Use example: ./generate_ova.sh -w 4.1.5 -o 1.12.0 -f 7.10.0"
    echo "Use example: ./generate_ova.sh -w 4.2.0 -o 1.12.0 -f 7.10.0 -b 4.2 -d 4.2-rc -r dev"
    exit $1
}

clean() {
    exit_code=$1

    cd ${scriptpath}
    vagrant destroy -f
    OVA_VMDK="wazuh-${OVA_VERSION}-disk001.vmdk"
    rm -f ${OVA_VM} ${OVF_VM} ${OVA_VMDK} ${OVA_FIXED}
    
    exit ${exit_code}
}

build_ova() {

    OVA_VM="wazuh-${OVA_VERSION}.ova"
    OVF_VM="wazuh-${OVA_VERSION}.ovf"
    OVA_FIXED="wazuh-${OVA_VERSION}-fixed.ova"
    export PACKAGES_REPOSITORY

    if [ -e "${OUTPUT_DIR}/${OVA_VM}" ] || [ -e "${OUTPUT_DIR}/${OVF_VM}" ]; then
        rm -f ${OUTPUT_DIR}/${OVA_VM} ${OUTPUT_DIR}/${OVF_VM}
    fi

    # Vagrant will provision the VM with all the software. (See vagrantfile)
    vagrant destroy -f
    vagrant up || clean 1
    vagrant suspend

    echo "Exporting ova"

    # Get machine name
    VM_EXPORT=$(vboxmanage list vms | grep -i vm_wazuh | cut -d "\"" -f2)
    
    # Create OVA with machine
    vboxmanage export ${VM_EXPORT} -o ${OVA_VM} \
    --vsys 0 \
    --product "Wazuh v${WAZUH_VERSION} OVA" \
    --producturl "https://packages.wazuh.com/vm/wazuh-${OVA_VERSION}.ova" \
    --vendor "Wazuh, inc <info@wazuh.com>" --vendorurl "https://wazuh.com" \
    --version "$OVA_VERSION" --description "Wazuh helps you to gain security visibility into your infrastructure by monitoring hosts at an operating system and application level. It provides the following capabilities: log analysis, file integrity monitoring, intrusions detection and policy and compliance monitoring." \
    || clean 1

    vagrant destroy -f

    tar -xvf ${OVA_VM}

    echo "Setting up ova for VMware ESXi"

    # Configure OVA for import to VMWare ESXi
    python Ova2Ovf.py -s ${OVA_VM} -d ${OVA_FIXED}

    # Make output dir of OVA file
    mkdir -p ${OUTPUT_DIR}
    mv ${OVA_FIXED} ${OUTPUT_DIR}/${OVA_VM}

    if [ "${CHECKSUM}" = "yes" ]; then
        mkdir -p ${CHECKSUM_DIR}
        cd ${OUTPUT_DIR} && sha512sum "${OVA_VM}" > "${CHECKSUM_DIR}/${OVA_VM}.sha512"
    fi

}

check_version() {
    WAZUH_MAJOR="$(echo ${WAZUH_VERSION} | head -c 1)"
    if [ "${WAZUH_MAJOR}" = "4" ]; then
        if [ "${PACKAGES_REPOSITORY}" = "prod" ]; then
            curl -Isf https://packages.wazuh.com/${WAZUH_MAJOR}.x/ui/kibana/wazuh_kibana-${WAZUH_VERSION}_${ELK_VERSION}-${UI_REVISION}.zip > /dev/null || ( echo "Error version ${WAZUH_VERSION}-${ELK_VERSION}-${UI_REVISION} not supported." && exit 1 )
        elif [ "${PACKAGES_REPOSITORY}" = "dev" ]; then
            curl -Isf https://packages-dev.wazuh.com/pre-release/ui/kibana/wazuh_kibana-${WAZUH_VERSION}_${ELK_VERSION}-${UI_REVISION}.zip > /dev/null || ( echo "Error version ${WAZUH_VERSION}-${ELK_VERSION} not supported." && exit 1 )
        else
            echo "Error, repository value must take 'prod' (production) or 'dev' (development) value."
            exit
        fi
    else 
        echo "Error, only 4.x versions are supported"
        exit
    fi
}

main() {

    while [ -n "$1" ]; do
        case $1 in
            "-h" | "--help")
            help 0
        ;;

        "-w" | "--wazuh")
            if [ -n "$2" ]; then
                export WAZUH_VERSION="$2"
                HAVE_VERSION=true
            else
                echo "ERROR Need wazuh version."
                help 1
            fi
            shift 2
        ;;

        "-o" | "--opendistro")
            if [ -n "$2" ]; then
                export OPENDISTRO_VERSION="$2"
                HAVE_OPENDISTRO_VERSION=true
            else
                echo "ERROR Need opendistro version."
                help 1
            fi
            shift 2
        ;;

        "-e" | "--elk")
            if [ -n "$2" ]; then
                export ELK_VERSION="$2"
                HAVE_ELK_VERSION=true
            else
                echo "ERROR: Need filebeat version."
                help 1
            fi
            shift 2
        ;;

        "-r" | "--repository")
            if [ -n "$2" ]; then
                PACKAGES_REPOSITORY="$2"
                shift 2
            else
            echo "ERROR: Value must be: dev"
                help 1
            fi
        ;;

        "-u" | "--ui")
            if [ -n "$2" ]; then
                UI_REVISION="$2"
                shift 2
            else
                help 1
            fi
            shift 2
        ;;

        "-b"|"--branch")
            if [ -n "$2" ]; then
                BRANCH="$2"
                shift 2
            else
                echo "ERROR: Need a value"
                help 1
            fi
        ;;

        "-d"|"--doc")
            if [ -n "$2" ]; then
                BRANCHDOC="$2"
                shift 2
            else
                echo "ERROR: Need a value"
                help 1
            fi
        ;;

        "-s"|"--store-path")
            if [ -n "$2" ]; then
                OUTPUT_DIR="$2"
                shift 2
            else
                echo "ERROR: Need store path"
                help 1
            fi
        ;;

        "-c"|"--checksum")
            if [ -n "$2" ]; then
                CHECKSUM_DIR="$2"
                CHECKSUM="yes"
                shift 2
            else
                CHECKSUM="no"
                shift 1
            fi
        ;;
        *)
            help 1
        ;;
        esac
    done

    if [ -z "${CHECKSUM_DIR}" ]; then
        CHECKSUM_DIR="${OUTPUT_DIR}"
    fi
    # Check if versions of main packages have been specified
    if  [ "${HAVE_VERSION}" = true ] && [ "${HAVE_ELK_VERSION}" = true ] && [ "${HAVE_OPENDISTRO_VERSION}" = true ]; then
       
        if [ ${BRANCH} != ${BRANCHDOC} ] && [ ${PACKAGES_REPOSITORY} = "prod" ]; then
            echo "Wazuh branch must be equal to Documentation branch in production."
            clean 1
        fi

        export UI_REVISION="${UI_REVISION}"
        check_version

        OVA_VERSION="${WAZUH_VERSION}_${OPENDISTRO_VERSION}"
        [[ ${PACKAGES_REPOSITORY} = "prod" ]] && REPO="production" || REPO="development"
        echo "Version to build: ${WAZUH_VERSION}-${OPENDISTRO_VERSION} with ${REPO} repository and ${BRANCH} branch"
        
        # Build OVA file (no standard)
        build_ova ${WAZUH_VERSION} ${OVA_VERSION} ${BRANCH} ${BRANCHDOC}

        # Standarize OVA
        bash setOVADefault.sh "${scriptpath}" "${OUTPUT_DIR}/${OVA_VM}" "${OUTPUT_DIR}/${OVA_VM}" "${scriptpath}/wazuh_ovf_template" "${WAZUH_VERSION}" "${OPENDISTRO_VERSION}"
        
        echo "Process finished"
        clean 0

    else
        echo "ERROR: Need more parameters."
        help 1
    fi

    return 0
}

main "$@"
