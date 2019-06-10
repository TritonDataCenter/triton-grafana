#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright 2019 Joyent, Inc.
#

#
# This script is designed to run from a cron job. It checks for changes in the
# set of triton and manta DNS resolvers, and updates the grafana zone's BIND
# server configuration appropriately.
#
# Why can't we let SAPI/config-agent handle this? Because grafana is the rare
# Triton service that depends on the _manta_ application SAPI data. Because
# grafana isn't a manta service, config-agent won't pick up changes in this
# data, so we have to do it ourselves.
#

set -o errexit
set -o pipefail
set -o xtrace

function fatal() {
    printf '%s: ERROR: %s\n' "$(basename $0)" "$*" >&2
    exit 1
}

ROOT_DIR=/opt/triton/grafana
CONF_DIR=${ROOT_DIR}/etc
CONFIG_JSON=${CONF_DIR}/update-named-config.json
MANTA_RESOLVERS_MDATA='manta-resolvers'

SAPI_URL=$(mdata-get sapi-url)
DATACENTER_NAME=$(mdata-get sdc:datacenter_name)
DNS_DOMAIN=$(mdata-get sdc:dns_domain)
REGION_NAME=$(json -f "${CONFIG_JSON}" region_name)

UPDATE_MADE=false

#
# named-related paths. Keep in sync with "boot/setup.sh".
#
NAMED_CONF=/opt/local/etc/named.conf
NAMED_DIR=${ROOT_DIR}/named
NAMED_LOG_DIR=/var/log/named

[[ -n "${SAPI_URL}" ]] || fatal 'SAPI url not found'

#
# We use the presence of a manta nic on this zone as a proxy for whether or not
# manta is deployed.
#
function is_manta_deployed() {
    #
    # Even with the introduction of RAN, we know that the manta nic tag will
    # have 'manta' in its name.
    #
    if $(mdata-get sdc:nics | json -a nic_tag | grep -q manta); then
        return 0
    else
        return 1
    fi
}

# Get the set of manta resolvers from the 'manta' SAPI application.
function get_manta_resolvers_from_sapi() {
    local manta_json_array
    local manta_app
    local resolvers

    manta_json_array=$(curl -sS "${SAPI_URL}/applications?name=manta")
    manta_app=$(echo "${manta_json_array}" | json 0)
    [[ -n "${manta_app}" ]] || fatal 'manta application not found'
    [[ -z "$(echo "${manta_json_array}" | json 1)" ]] || \
        fatal 'more than one SAPI application found with name "manta"'

    resolvers=$(echo "${manta_app}" | json metadata.ZK_SERVERS | json -a host)
    [[ -n "${resolvers}" ]] || fatal 'no manta nameservce IPs found'
    echo "${resolvers}"
}

#
# Get the triton binder IPs from the built-in sdc metadata, filtering for
# public internet resolvers.
#
function get_triton_resolvers() {
    local resolvers

    resolvers=$(mdata-get sdc:resolvers | json -a | grep -Ev '8.8.8.8|8.8.4.4')
    [[ -n "${resolvers}" ]] || fatal 'no triton binder IPs found'
    echo "${resolvers}"
}

#
# We have to look up the manta resolvers ourselves. Once we find them, we store
# them in a $MANTA_RESOLVERS_MDATA mdata variable.
#
# If the variable exists, we can query any known resolver for an updated list
# of all the resolvers.
#
# If the variable doesn't exist or none of the resolvers are responsive, we have
# to reach out to SAPI. This is more expensive, so we try to avoid it.
#
function get_manta_resolvers() {
    local existing_resolvers
    local updated_resolvers

    existing_resolvers=$(mdata-get "${MANTA_RESOLVERS_MDATA}")

    #
    # Query the known resolvers for the updated list
    #
    for resolver in ${existing_resolvers}; do
        updated_resolvers=$(dig +short "@${resolver}" \
            "nameservice.${REGION_NAME}.${DNS_DOMAIN}")
        if [[ -n "${updated_resolvers}" ]]; then
            break
        fi
    done

    #
    # If we didn't get the updated list of resolvers, fall back to getting the
    # resolvers from SAPI. This case will also occur the first time this script
    # is run.
    #
    if [[ -z "${updated_resolvers}" ]]; then
        updated_resolvers=$(get_manta_resolvers_from_sapi)
    fi

    [[ -n "${updated_resolvers}" ]] || fatal 'no manta resolvers found'

    if [[ "${existing_resolvers}" != "${updated_resolvers}" ]]; then
        mdata-put "${MANTA_RESOLVERS_MDATA}" "${updated_resolvers}"
    fi
    echo "${updated_resolvers}"
}

#
# Break the list of IPs into lines with a semicolon at the end of each line.
#
# e.g. (odd whitespace very intentional):
#
#       1.1.1.1  2.2.2.2
#    3.3.3.3
#     4.4.4.4
#
# becomes:
#
# 1.1.1.1;
# 2.2.2.2;
# 3.3.3.3;
# 4.4.4.4;
#
function format_mdata() {
    #
    # We're very careful with whitespace -- `tr` replaces each region of
    # whitespace (including newlines) with a single space, the first invocation
    # of sed removes leading whitespace from the resulting string, and the
    # second invocation of sed breaks the string into IP addresses separated by
    # semicolon-newline pairs.
    #
    echo "$*" | tr -s '[:space:]' ' ' | sed -e 's/^[[:space:]]\+//g' | \
        sed -e 's/[[:space:]]\+/;\n/g'
}

function named_refresh() {
    local svc="bind"
    local currState

    # Wait for service to come out of transition, if necessary
    local try=0
    local tries=6
    currState=$(svcs -Ho state "${svc}")
    while [[ "${currState: -1}" == '*' || \
        "${currState}" == 'uninitialized' ]]; do
        ((try++)) || true
        if [[ "${try}" -eq "${tries}" ]]; then
            fatal "timeout: ${svc} service in transition state"
        fi
        sleep 5
        currState=$(svcs -Ho state "${svc}")
    done

    if [[ "${currState}" == 'disabled' ]]; then
        #
        # Zone setup starts with every service in the disabled state. We enable
        # the service after the config is generated for the first time.
        #
        echo "Enabling ${svc} SMF service"
        svcadm enable "${svc}"
    elif [[ "${currState}" == 'maintenance' ]]; then
        echo "Clearing ${svc} SMF service"
        svcadm clear "${svc}"
    elif [[ "${currState}" == 'online' ]]; then
        echo "Refreshing ${svc} SMF service"
        svcadm refresh "${svc}"
    elif [[ "${currState}" != 'offline' ]]; then
        #
        # If the service is offline, we can safely do nothing -- it will start
        # once its dependencies are satisfied. Otherwise, we exit loudly.
        #
        fatal "unexpected ${svc} service state: '${currState}'"
    fi
}

# ---- mainline

triton_resolvers=$(get_triton_resolvers)

read -rd '' named_conf_contents <<NAMED_CONF_CONTENTS || true
options {
    directory "${NAMED_DIR}";

    dnssec-enable yes;
    dnssec-validation yes;

    auth-nxdomain no;

    allow-transfer {
            127.0.0.1;
    };

    listen-on { 127.0.0.1; };

    check-integrity yes;

    recursion yes;
};

logging {
    channel default_log {
        file "${NAMED_LOG_DIR}/bind.log" versions 3 size 5m;
        severity info;
        print-time yes;
        print-severity yes;
        print-category yes;
    };
    category default {
        default_log;
    };
};

zone "." IN {
    type forward;
    forward only;
    forwarders {
        8.8.8.8;
        8.8.4.4;
    };
};

zone "${DATACENTER_NAME}.${DNS_DOMAIN}" IN {
    type forward;
    forward only;
    forwarders {
        $(format_mdata "${triton_resolvers}")
    };
};

zone "localhost" IN {
    type master;
    file "master/localhost";
};

zone "127.in-addr.arpa" IN {
    type master;
    file "master/127.in-addr.arpa";
};

NAMED_CONF_CONTENTS

named_conf_manta=''
if $(is_manta_deployed); then
    manta_resolvers=$(get_manta_resolvers)
    read -rd '' named_conf_manta <<NAMED_CONF_MANTA || true
zone "${REGION_NAME}.${DNS_DOMAIN}" IN {
    type forward;
    forward only;
    forwarders {
        $(format_mdata "${manta_resolvers}")
    };
};
NAMED_CONF_MANTA
else
    echo 'Manta is not deployed; skipping adding Manta resolvers to config'
fi

echo -e "${named_conf_contents}" > "${NAMED_CONF}.new"
echo -e "${named_conf_manta}" >> "${NAMED_CONF}.new"

# Update the config, if changed.
if [[ ! -f "${NAMED_CONF}" ]]; then
    # First time config.
    echo "Writing first time grafana config (${NAMED_CONF})"
    mv "${NAMED_CONF}.new" "${NAMED_CONF}"
    named_refresh
elif ! diff "${NAMED_CONF}" "${NAMED_CONF}.new" > /dev/null; then
    # The config differs.
    echo "Updating grafana config (${NAMED_CONF})"
    cp "${NAMED_CONF}" "${NAMED_CONF}.bak"
    mv "${NAMED_CONF}.new" "${NAMED_CONF}"
    named_refresh
else
    # The config does not differ
    rm "${NAMED_CONF}.new"
fi


exit 0
