#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright (c) 2018, Joyent, Inc.
#

#
# One-time setup of a Triton grafana core zone.
#
# It is expected that this is run via the standard Triton user-script,
# i.e. as part of the "mdata:execute" SMF service. That user-script ensures
# this setup.sh is run once for each (re)provision of the image. However
# script should also attempt to be idempotent.
#

export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -o errexit
set -o pipefail
set -o xtrace

PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/usr/sbin

# Grafana data is stored on its delegate dataset:
#   /data/grafana/
#       conf/*                          # configuration files
#       data/*                          # grafana database (users, dashboards,
                                        # etc.)
#       password.txt                    # Grafana password
#   /data/tls/*                         # TLS certs
GRAF_PERSIST_DIR=/data/grafana
DATA_DIR=$GRAF_PERSIST_DIR/data
CONF_DIR=$GRAF_PERSIST_DIR/conf
TLS_DIR=/data/tls

CONFIG_FILE=${CONF_DIR}/grafana.ini
DATASOURCES_FILE=${CONF_DIR}/provisioning/datasources/triton.yaml
DASHBOARDS_FILE=${CONF_DIR}/provisioning/dashboards/triton.yaml

# - TLS cert
CERT_FILE=$TLS_DIR/cert.pem
# - TLS cert key
CERT_KEY_FILE=$TLS_DIR/privkey.pem

# ---- internal routines

function fatal {
    printf '%s: ERROR: %s\n' "$(basename $0)" "$*" >&2
    exit 1
}

# Mount our delegated dataset at /data.
function grafana_setup_delegate_dataset() {
    local dataset
    local mountpoint

    dataset=zones/$(zonename)/data
    mountpoint=$(zfs get -Hp mountpoint $dataset | awk '{print $3}')
    if [[ $mountpoint != "/data" ]]; then
        zfs set mountpoint=/data $dataset
    fi
}

# Setup key and client certificate used to auth with this DC's CMON.
function grafana_setup_certs() {
    if [[ -f "$CERT_FILE" && -f "$CERT_KEY_FILE" ]]; then
        echo "Key files already exist: $CERT_FILE, $CERT_KEY_FILE"
    else
        echo "Generating tls cert and key for CMON auth"
        mkdir -p $TLS_DIR
        # Create cert and key
        openssl req -x509 -nodes -subj "/CN=admin" -newkey rsa:2048 \
            -keyout $CERT_KEY_FILE -out $CERT_FILE -days 365
    fi

    return 0
}

function grafana_setup_env {
    if ! grep grafana /root/.profile >/dev/null; then
        echo "" >>/root/.profile
        echo "export PATH=/opt/triton/grafana/bin:/opt/triton/grafana/grafana:\$PATH" >>/root/.profile
    fi
}

function grafana_ensure_nobody_owner() {
    local output

    output=$(chown -c nobody:nobody \
        $CONFIG_FILE \
        $DATASOURCES_FILE \
        $DASHBOARDS_FILE \
        $CERT_FILE \
        $CERT_KEY_FILE \
        /data/grafana/data)
    if [[ -n "$output" ]]; then
        echo "$output"
    fi

    return 0
}

# Enable/restart/clear grafana, if necessary.
function grafana_restart_grafana() {
    local currState

    currState=$(svcs -Ho state grafana)
    if [[ "$currState" == "disabled" ]]; then
        # Zone setup starts with grafana in disabled state. We enable it
        # after the config is generated for the first time.
        echo "Enabling grafana SMF service"
        svcadm enable grafana
    elif [[ "$currState" == "online" ]]; then
            svcadm restart grafana
    elif [[ "$currState" == "maintenance" ]]; then
        echo "Clearing grafana SMF service"
        svcadm clear grafana
    else
        fatal "unexpected grafana service state: '$currState'"
    fi

    return 0
}

function grafana_write_config {
    local config_file=$1
    local basename=$(basename ${config_file})

    if [[ ! -f ${config_file}.new ]]; then
        fatal "${config_file}.new not found"
    fi

    # Update the config, if changed.
    if [[ ! -f ${config_file} ]]; then
        # First time config.
        echo "Writing first time grafana config ($config_file)"
        mv ${config_file}.new ${config_file}
    elif ! diff ${config_file} ${config_file}.new >/dev/null; then
        # The config differs.
        echo "Updating grafana config ${basename}"
        cp ${config_file} ${config_file}.bak
        mv ${config_file}.new ${config_file}
    fi
}

function grafana_setup_grafana {
    local dc_name
    local dns_domain

    dc_name=$(mdata-get sdc:datacenter_name)
    dns_domain=$(mdata-get sdc:dns_domain)
    if [[ -z "$dns_domain" ]]; then
        # As of TRITON-92, we expect sdcadm to set this for all core Triton
        # zones.
        fatal "could not determine 'dns_domain'"
    fi

    mkdir -p $DATA_DIR
    mkdir -p $CONF_DIR/provisioning/dashboards
    mkdir -p $CONF_DIR/provisioning/datasources
    
    

    cat > ${CONFIG_FILE}.new <<CONFIGINI
# config file version
apiVersion: 1

[server]
http_port=443
protocol=https
cert_file=${CERT_FILE}
cert_key=${CERT_KEY_FILE}

[paths]
data=${DATA_DIR}
provisioning=${CONF_DIR}/provisioning
CONFIGINI

    cat > ${DATASOURCES_FILE}.new <<DATAYML
# config file version
apiVersion: 1

datasources:
    - name: Triton
      type: prometheus
      access: proxy
      orgId: 1
      url: http://prometheus.${dc_name}.${dns_domain}:9090
      isDefault: true
      editable: true
DATAYML

cat > ${DASHBOARDS_FILE}.new <<DASHYML
# config file version
apiVersion: 1

providers:
    - name: Triton
      orgId: 1
      folder: ''
      type: file
      options:
        path: /opt/triton/grafana/grafana/dashboards
DASHYML

    grafana_write_config ${CONFIG_FILE}
    grafana_write_config ${DATASOURCES_FILE}
    grafana_write_config ${DASHBOARDS_FILE}

    /usr/sbin/svccfg import /opt/triton/grafana/smf/manifests/grafana.xml

    return 0
}

# ---- mainline

grafana_setup_delegate_dataset
grafana_setup_certs
grafana_setup_env

# Before 'sdc_common_setup' so the grafana SMF service is imported before
# config-agent is first setup.
grafana_setup_grafana
grafana_ensure_nobody_owner
grafana_restart_grafana

CONFIG_AGENT_LOCAL_MANIFESTS_DIRS=/opt/triton/grafana
source /opt/smartdc/boot/lib/util.sh
sdc_common_setup

# Log rotation.
sdc_log_rotation_add config-agent /var/svc/log/*config-agent*.log 1g
sdc_log_rotation_add registrar /var/svc/log/*registrar*.log 1g
sdc_log_rotation_add grafana /var/svc/log/*grafana*.log 1g
sdc_log_rotation_setup_end

sdc_setup_complete

exit 0
