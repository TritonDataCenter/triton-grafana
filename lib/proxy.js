#!/opt/triton/grafana/build/node/bin/node

/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * Copyright 2019 Joyent, Inc.
 *
 * grafana proxy server.
 *
 * Usage:
 *    node proxy.js
 */

'use strict';

const assert = require('assert-plus');
const bunyan = require('bunyan');
const fs = require('fs');
const restify = require('restify');
const tritonAuditLogger = require('triton-audit-logger');

const auth = require('./auth');
const ufds = require('./ufds');
const util = require('./util');

function createProxyServer(config) {
    assert.object(config, 'config');

    const ufdsMaster = ufds.createUfdsClient({
        url: config.ufdsMaster.url,
        bindDN: config.ufdsMaster.bindDN,
        bindPassword: config.ufdsMaster.bindPassword,
        cache: config.ufdsMaster.cache,
        log: config.log
    }, true);

    const server = restify.createServer({
        name: 'graf-proxy',
        log: config.log
    });

    server.use(restify.plugins.requestLogger());

    server.on('after', tritonAuditLogger.createAuditLogHandler({
        log: config.log,
        reqBody: {},
        resBody: {},
        // eslint-disable-next-line no-unused-vars
        polish: function censorAuth(fields, req, res, route, err) {
            if (req.headers['authorization'] !== undefined) {
                req.headers['authorization'] = '***';
            }
        }
    }));

    server.get('/auth', setUfds, auth.authenticate);

    return server;

    function setUfds(req, res, next) {
        /*
         * We can only use the master UFDS. If we use the local UFDS, we could
         * inadvertently write to it (which should not be allowed) in the event
         * of a lockout. This cannot be accounted for until TRITON-947 is fixed.
         */
        req.ufds = ufdsMaster;
        setImmediate(next);
    }
}

// ---- mainline

// Log will be attached to config and to each restify req
const log = bunyan.createLogger({
    name: 'graf-proxy',
    level: 'info',
    serializers: restify.bunyan.serializers
});

let config;
const customConfigPath = process.env.GRAFANA_PROXY_CONFIG;
try {
    config = util.loadConfig(log, util.DEFAULT_CFG_PATH, customConfigPath);
} catch (err) {
    log.fatal(err);
    process.exit(1);
}

const server = createProxyServer(config);

/*
 * Set up socket to listen on. Must keep path in sync with config/nginx.conf and
 * test/auth.test.js
 */
const proxySock = '/tmp/graf-proxy.sock';
if (fs.existsSync(proxySock)) {
    fs.unlinkSync(proxySock);
}
server.listen(proxySock, function listenCb() {
    config.log.info('Server listening at %s', proxySock);
});
