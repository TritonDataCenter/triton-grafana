/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * Copyright 2019 Joyent, Inc.
 *
 * UFDS client utility functions for grafana proxy server and associated tests.
 */

'use strict';

const UFDS = require('ufds');
const assert = require('assert-plus');

const UFDS_DEFAULT_CONNECT_TIMEOUT = 4000;
const UFDS_DEFAULT_CLIENT_TIMEOUT = 10000;
const UFDS_DEFAULT_IDLE_TIMEOUT = 10000;

/**
 * createUfdsClient
 *
 * @param
 * - config: from loadConfig
 */
function createUfdsClient(config, isMaster) {
    assert.object(config, 'config');
    assert.bool(isMaster, 'isMaster');

    config.connectTimeout = config.connectTimeout ||
        UFDS_DEFAULT_CONNECT_TIMEOUT;
    config.clientTimeout = config.clientTimeout || UFDS_DEFAULT_CLIENT_TIMEOUT;
    config.idleTimeout = config.idleTimeout || UFDS_DEFAULT_IDLE_TIMEOUT;

    const ufds = new UFDS(config);

    const log = config.log.child({
        isMaster: isMaster
    });
    log.info('Connecting to UFDS: ', config.url);

    let count = 0;
    ufds.on('connect', function onceConnectCb() {
        count++;
        log.info({
            count: count
        }, 'Connected to UFDS: ', config.url);
    });

    ufds.on('close', function closeCb() {
        log.info('UFDS Connection Closed');
    });

    ufds.on('error', function errorCb(err) {
        log.warn(err, 'UFDS: unexpected error occurred');
    });

    return ufds;
}

module.exports = {
    createUfdsClient: createUfdsClient
};
