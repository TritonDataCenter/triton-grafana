#!/bin/bash
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# Copyright 2019 Joyent, Inc.
#

#
# One-time setup of a Triton grafana core zone.
#
# It is expected that this is run via the standard Triton user-script,
# i.e. as part of the "mdata:execute" SMF service. That user-script ensures
# this setup.sh is run once for each (re)provision of the image. However, the
# script should also attempt to be idempotent.
#

export PS4='[\D{%FT%TZ}] ${BASH_SOURCE}:${LINENO}: ' \
'${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -o errexit
set -o pipefail
set -o xtrace

PATH=/opt/local/bin:/opt/local/sbin:/usr/bin:/usr/sbin

ARG0=$(basename "${0}")

DATACENTER_NAME=
DNS_DOMAIN=

# ---- Stateless paths

ROOT_DIR=/opt/triton/grafana
BIN_DIR=${ROOT_DIR}/bin
CONF_DIR=${ROOT_DIR}/etc
# The static set of dashboards bundled with the zone image
DASHBOARDS_DIR=${ROOT_DIR}/dashboards
MANIFESTS_DIR=${ROOT_DIR}/smf/manifests
NGINX_DIR=${ROOT_DIR}/nginx
NGINX_CONF=${NGINX_DIR}/conf/nginx.conf
TEST_DIR=${ROOT_DIR}/test

#
# named-related paths. Keep in sync with bin/update-named.sh.
#
NAMED_DIR=${ROOT_DIR}/named
NAMED_LOG_DIR=/var/log/named

#
# Templates:
#
# Config files for grafana are written at zone setup time based on
# templates included in $TEMPLATES_DIR. If a config file is named "foo", its
# template must be named "foo.in". Template variables are specified by
# including the delimiter "%%" on either side, and are replaced with the value
# of the bash variable with the corresponding name. For example, if the bash
# variable $FOO has the value "bar", all occurrences of "%%FOO%%" in a template
# file will be replaced with "bar".
#
# This functionality is implemented in the grafana_write_config function in
# this file.
#
TEMPLATES_DIR=${ROOT_DIR}/etc
# This script creates these files from templates
GRAFANA_CONF=${CONF_DIR}/grafana.ini
DASHBOARDS_CONF=${CONF_DIR}/provisioning/dashboards/triton-dashboards.yaml

# ---- Persistent paths

#
# Grafana data is stored on its delegated dataset:
#   /data/grafana/
#       data/*                          # grafana database (users, dashboards,
#                                       # etc.)
#       tls/*                           # TLS certs for nginx.
#
PERSIST_DIR=/data/grafana
DATA_DIR=${PERSIST_DIR}/data
#
# The TLS cert and key are stored on the delegated dataset so, if an operator
# replaces the default self-signed cert with a properly signed cert, it will
# persist across reprovisions.
#
TLS_DIR=${PERSIST_DIR}/tls
CERT_FILE=${TLS_DIR}/cert.pem
KEY_FILE=${TLS_DIR}/key.pem

# ---- Internal routines

function fatal() {
    printf '%s: ERROR: %s\n' "$(basename $0)" "$*" >&2
    exit 1
}

# Add user and corresponding group, if the user/group do not exist
function grafana_add_user() {
    local username="${1}"
    if [[ ! $(getent group "${username}") ]]; then
        groupadd "${username}"
    fi
    if [[ ! $(getent passwd "${username}") ]]; then
        useradd -g "${username}" "${username}"
        passwd -N "${username}"
    fi
}

# Mount our delegated dataset at /data.
function grafana_setup_delegated_dataset() {
    local dataset
    local mountpoint

    dataset=zones/$(zonename)/data
    mountpoint=$(zfs get -Ho value mountpoint "${dataset}")
    if [[ "${mountpoint}" != '/data' ]]; then
        zfs set mountpoint=/data "${dataset}"
    fi
}

function grafana_setup_env() {
    if [[ ! $(grep grafana /root/.profile) ]]; then
        echo '' >> /root/.profile
        echo "export PATH=${ROOT_DIR}/bin:${ROOT_DIR}/grafana:\$PATH" >> \
            /root/.profile
    fi
}

#
# Write config file based on template.
# Arguments:
#     $1: Desired fully qualified path of final config file
#     $2, $3, ..., $N: string names of template parameters to replace. These
#         will be replaced with the contents of identically-named bash
#         variables.
#
# Example usage:
# `grafana_write_config $GRAFANA_CONF CONF_DIR DATA_DIR`
#
# This example invocation will look for the template corresponding to
# $GRAFANA_CONF in $TEMPLATES_DIR, search for instances of CONF_DIR and
# DATA_DIR in this template file (surrounded by the delimiter "%%"), replace
# these with the contents of the bash variables $CONF_DIR and $DATA_DIR,
# respectively, and write this file to $GRAFANA_CONF.
#
# If the config file already exists and differs from the new config file, this
# function will save a backup.
#
function grafana_write_config() {
    local config_file="${1}"
    local basename
    local contents
    local template_file
    local delim='%%'
    # semicolon-separated list of sed commands to run
    local commands=''

    basename=$(basename "${config_file}")
    local template_file=${TEMPLATES_DIR}/${basename}.in
    shift

    for var in ${@}; do
        #
        # Verify that template parameter exists in template file before adding
        # to command list
        #
        grep "${delim}${var}${delim}" "${template_file}" || \
            fatal "template parameter ${var} not found in ${template_file}"
        commands="${commands}s|${delim}${var}${delim}|${!var}|g;"
    done

    contents=$(sed "${commands}" "${template_file}")

    echo "${contents}" | grep "${delim}" && \
        fatal "unused substitution delimiter found in ${basename}"

    # Write the config to a temporary file.
    echo -e "${contents}" > "${config_file}.new"

    # Update the config, if changed.
    if [[ ! -f "${config_file}" ]]; then
        # First time config.
        echo "Writing first time grafana config (${config_file})"
        mv "${config_file}.new" "${config_file}"
    elif ! diff "${config_file}" "${config_file}.new" > /dev/null; then
        # The config differs.
        echo "Updating grafana config (${config_file})"
        cp "${config_file}" "${config_file}.bak"
        mv "${config_file}.new" "${config_file}"
    else
        # The config does not differ
        rm "${config_file}.new"
    fi
}

# Set up key and certificate used for nginx
function grafana_setup_certs() {
    if [[ -f "${CERT_FILE}" && -f "${KEY_FILE}" ]]; then
        echo "Key files already exist: ${CERT_FILE}, ${KEY_FILE}"
    else
        echo "Generating tls cert and key for CMON auth"
        mkdir -p "${TLS_DIR}"
        # Create cert and key
        openssl req -x509 -nodes -subj '/CN=admin' -newkey rsa:2048 \
            -keyout "${KEY_FILE}" -out "${CERT_FILE}" -days 3650
    fi

    return 0
}

#
# Preliminary setup work for BIND server. We defer writing the config file and
# enabling the service to bin/update-named.
#
function grafana_setup_named {
    local localhost_zone
    local arpa_zone
    local cron_cmd
    local cron_job
    local cron_tmpfile

    svccfg import /opt/local/lib/svc/manifest/bind.xml

    mkdir -p "${NAMED_DIR}"
    mkdir -p "${NAMED_DIR}/master"
    mkdir -p "${NAMED_DIR}/slave"
    mkdir -p "${NAMED_LOG_DIR}"

    read -rd '' localhost_zone <<LOCALHOST_ZONE || true
\$TTL 3D

\$ORIGIN localhost.

@       1D      IN     SOA     @       root (
                       0               ; serial
                       8H              ; refresh
                       2H              ; retry
                       4W              ; expiry
                       1D              ; minimum
                       )

@       IN      NS      @
        IN      A       127.0.0.1
LOCALHOST_ZONE

    read -rd '' arpa_zone <<ARPA_ZONE || true
\$TTL 3D

@       IN      SOA     localhost. root.localhost. (
                        0               ; Serial
                        8H              ; Refresh
                        2H              ; Retry
                        4W              ; Expire
                        1D              ; Minimum TTL
                        )

       IN      NS      localhost.

1      IN      PTR     localhost.
ARPA_ZONE

    echo -e "${localhost_zone}" > "${NAMED_DIR}/master/localhost"
    echo -e "${arpa_zone}" > "${NAMED_DIR}/master/127.in-addr.arpa"

    # Run the updater script once to kick BIND off
    cron_cmd="${BIN_DIR}/update-named.sh"
    # Every 5 minutes -- illumos cron does not allow "division" syntax
    cron_job="0,5,10,15,20,25,30,35,40,45,50,55 * * * * ${cron_cmd}"
    ${cron_cmd}

    # Then, stick the script in a cron job
    cron_tmpfile="/var/tmp/${ARG0}.${$}"
    (crontab -l | grep -Fv "${cron_cmd}" ; echo "${cron_job}") \
        > "${cron_tmpfile}"
    crontab "${cron_tmpfile}"
    rm "${cron_tmpfile}"
}

function grafana_set_permissions() {
    grafana_add_user 'grafana'
    grafana_add_user 'graf-proxy'
    grafana_add_user 'nginx'

    # Grant full access to files Grafana may write to.
    chown grafana:grafana \
        "${GRAFANA_CONF}" \
        "${DASHBOARDS_CONF}" \
        "${DATA_DIR}"

    chown -R named:named \
        "${NAMED_DIR}" \
        "${NAMED_LOG_DIR}"

    # We explicitly use the chown that has the "-c" option.
    /opt/local/bin/chown -cR nginx:nginx \
        "${NGINX_DIR}"

    chmod 700 "${TEST_DIR}/runtests"
    chmod 700 "${BIN_DIR}/update-named.sh"

    return 0
}

function grafana_setup_config_files() {
    mkdir -p "${DATA_DIR}"
    mkdir -p "${CONF_DIR}/provisioning/dashboards"
    mkdir -p "${CONF_DIR}/provisioning/datasources"
    mkdir -p "${CONF_DIR}/plugins"

    DATACENTER_NAME=$(mdata-get sdc:datacenter_name)
    grafana_write_config "${GRAFANA_CONF}" DATA_DIR CONF_DIR
    grafana_write_config "${NGINX_CONF}" CERT_FILE KEY_FILE
    grafana_write_config "${DASHBOARDS_CONF}" DASHBOARDS_DIR

    return 0
}

# First argument must be name of service to enable
function grafana_ensure_running() {
    local svc="${1}"
    local currState
    local dashId

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
    elif [[ "${currState}" != 'online' && \
        "${currState}" != 'offline' ]]; then
        #
        # If the service is online, we can safely do nothing.
        #
        # If the service is offline, we can also safely do nothing -- it will
        # start once its dependencies are satisfied. Otherwise, we exit loudly.
        #
        fatal "unexpected ${svc} service state: '${currState}'"
    fi

    # Wait for service to come up before we allow the script to continue
    try=0
    currState=$(svcs -Ho state "${svc}" )
    while [[ "${currState}" != 'online' ]]; do
        ((try++)) || true
        if [[ "${try}" -eq "${tries}" ]]; then
            fatal "timeout: ${svc} could not be (re)started"
        fi
        sleep 5
        currState=$(svcs -Ho state "${svc}")
    done
}

function grafana_setup_service() {
    local service=$1
    /usr/sbin/svccfg import ${MANIFESTS_DIR}/${service}.xml
    grafana_ensure_running ${service}
}

# Set defaults after grafana is already running
function grafana_set_defaults() {
    local grafana_addr='127.0.0.1'
    local grafana_port='3000'
    local search_path='api/search?type=dash-db&query=cnapi'
    local prefs_path='api/org/preferences'
    local tries=5

    # Set dashboard default
    dashId=$(curl -sS --header 'X-Grafana-Username: admin' \
        "http://${grafana_addr}:${grafana_port}/${search_path}" | json 0.id)

    #
    # Sometimes, after grafana has just come up, the following request will
    # fail. We thus try repeatedly.
    #
    local try=0
    local success='false'
    set +o errexit
    while [[ "${success}" != 'true' ]]; do
        ((try++)) || true
        if [[ "$try" -eq "$tries" ]]; then
            fatal 'timeout: grafana default dashboard could not be updated'
        fi

        curl -sS --header 'X-Grafana-Username: admin' \
            "http://${grafana_addr}:${grafana_port}/${prefs_path}" \
            -H content-type:application/json \
            -d '{"theme":"","homeDashboardId":'${dashId}',"timezone":"utc"}' \
            -X PUT \
            && success='true'

        sleep 2
    done
    set -o errexit

    return 0
}

# ---- mainline

DATACENTER_NAME=$(mdata-get sdc:datacenter_name)
DNS_DOMAIN=$(mdata-get sdc:dns_domain)
if [[ -z "${DNS_DOMAIN}" ]]; then
    # As of TRITON-92, we expect sdcadm to set this for all core
    # Triton zones.
    fatal 'could not determine "DNS_DOMAIN"'
fi

CONFIG_AGENT_LOCAL_MANIFESTS_DIRS="${ROOT_DIR}"
source /opt/smartdc/boot/lib/util.sh
sdc_common_setup

grafana_setup_delegated_dataset
grafana_setup_certs
grafana_setup_env
grafana_setup_config_files
grafana_setup_named
grafana_set_permissions

#
# The order we enable these services matters, because we explicitly wait for
# them to come up using grafana_ensure_running, and they have service
# dependencies that must be satisfied before they can run.
#
# We build the layers from the inside out: grafana, then graf-proxy, then nginx.
#
grafana_setup_service 'grafana'
grafana_setup_service 'graf-proxy'
grafana_setup_service 'nginx'

# We can only set the defaults once grafana is running.
grafana_set_defaults

sdc_log_rotation_add config-agent /var/svc/log/*config-agent*.log 1g
sdc_log_rotation_add registrar /var/svc/log/*registrar*.log 1g
sdc_log_rotation_add grafana /var/svc/log/*grafana*.log 1g
sdc_log_rotation_add nginx /var/svc/log/*nginx*.log 1g
sdc_log_rotation_add graf-proxy /var/svc/log/*graf-proxy*.log 1g

sdc_log_rotation_setup_end

sdc_setup_complete

exit 0
