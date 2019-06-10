#!/opt/triton/grafana/build/node/bin/node

/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * Copyright 2019 Joyent, Inc.
 *
 * authentication test for grafana proxy server.
 *
 * Usage:
 *    node auth.test.js
 */

'use strict';

const bunyan = require('bunyan');
const restify = require('restify-clients');
const test = require('@smaller/tap').test;
const uuid = require('uuid');
const vasync = require('vasync');

const ufds = require('../proxy/lib/ufds');
const util = require('../proxy/lib/util');

/*
 * Socket graf-proxy is listening on. Must keep path in sync with
 * config/nginx.conf and test/auth.test.js
 */
const PROXY_SOCK = '/tmp/graf-proxy.sock';
const AUTH_ENDPOINT = '/auth';

const ADMIN_GROUP = 'operators';

const log = bunyan.createLogger({
    name: 'graf-proxy',
    level: 'info',
    serializers: bunyan.stdSerializers
});

let config;
const customConfigPath = process.env.GRAFANA_PROXY_CONFIG;
try {
    config = util.loadConfig(log, util.DEFAULT_CFG_PATH, customConfigPath);
} catch (err) {
    log.fatal('Could not load config: ' + err.message);
    process.exit(1);
}

const client = restify.createJsonClient({
    socketPath: PROXY_SOCK,
    connectTimeout: 1000,
    requestTimeout: 1000,
    retry: false
});

const ufdsMaster = ufds.createUfdsClient({
    url: config.ufdsMaster.url,
    bindDN: config.ufdsMaster.bindDN,
    bindPassword: config.ufdsMaster.bindPassword,
    cache: config.ufdsMaster.cache,
    log: config.log
}, true);

// Create a random valid UFDS username from a uuid
function generateLogin() {
    return 'a' + uuid().slice(0, -1).split('-').join('');
}

// Test that a client can ping the graf-proxy server
function testServerRunning(args, cb) {
    const t = args.t;
    client.get(AUTH_ENDPOINT, function getCb(err, req, res, _) {
        // We expect a 401, with no credentials
        if (err && (err.statusCode === 401)) {
            t.pass('server is responsive');
        } else if (err) {
            /*
             * err.statusCode will only exist if we actually reached the server,
             * so we must account for its absence.
             */
            const codeStr = err.statusCode ? err.statusCode.toString() : '';
            t.fail('unexpected response: ' + codeStr + ': ' + err.message);
        } else {
            t.fail('unexpected successful response');
        }
        cb();
        return;
    });
}

/*
 * Test that an authenticated client with the correct permissions can
 * successfully access the Grafana instance through graf-proxy
 */
function testPrivilegedUser(args, cb) {
    const t = args.t;
    const ufdsInstance = args.ufdsInstance;
    /*
     * After adding the test user to the operators group, we need to wait for
     * graf-proxy's cached copy of the user to expire so the user's new
     * privileges are reflected.
     */
    const waitPeriod = (ufdsInstance.cacheOptions.expiry + 1) * 1000;

    const login = generateLogin();
    const password = uuid();

    ufdsInstance.addUser({
        login: login,
        email: login + '@example.com',
        userpassword: password
    }, function addedUser(err, user) {
        if (err) {
            t.fail('unable to create user', err);
            cb();
            return;
        }
        user.addToGroup(ADMIN_GROUP, function addedToGroup(groupErr) {
            if (groupErr) {
                t.fail('error adding user to operators', groupErr);
                cleanupUser(ufdsInstance, login, cb);
                return;
            }
            log.info('Waiting for ' + (waitPeriod / 1000) + 's');
            setTimeout(tryAccess, waitPeriod, 200, t, ufdsInstance, login,
                password, cb);
        });
    });
}


/*
 * Test that an authenticated client without sufficient permissions cannot
 * access the Grafana instance through graf-proxy
 */
function testUnprivilegedUser(args, cb) {
    const t = args.t;
    const ufdsInstance = args.ufdsInstance;

    const login = generateLogin();
    const password = uuid();

    ufdsInstance.addUser({
        login: login,
        email: login + '@example.com',
        userpassword: password
    }, function addedUser(err, _) {
        if (err) {
            t.fail('unable to create user', err);
            cb();
            return;
        } else {
            tryAccess(403, t, ufdsInstance, login, password, cb);
            return;
        }
    });
}

/*
 * Checks whether the provided credentials produce the provided desired response
 * when sent to the graf-proxy server.
 */
function tryAccess(desiredCode, t, ufdsInstance, login, password, cb) {
    client.basicAuth(login, password);
    client.get(AUTH_ENDPOINT, function getCb(err, req, res, _) {
        let successMsg;
        if (desiredCode < 400) {
            successMsg = 'privileged access granted';
        } else {
            successMsg = 'unprivileged access denied';
        }

        /*
         * If the error doesn't have a status code, we didn't even reach
         * the server, so we fail no matter what.
         */
        if (err && !err.statusCode) {
            t.fail('unexpected response: ' + err.message);
        } else if (res.statusCode === desiredCode) {
            /*
             * If the error does have a status code, we did get a
             * response, so we can safely check it.
             */
            t.pass(successMsg);
        } else {
            t.fail('unexpected response: ' + res.statusCode + ': ' +
                res.statusMessage);
        }

        cleanupUser(ufdsInstance, login, cb);
    });
}

// Removes a test user account from ufds
function cleanupUser(ufdsInstance, login, cb) {
    ufdsInstance.getUser(login, function getCb(err, user) {
        if (err) {
            handleErr(err, user);
        } else if (user.dclocalconfig) {
            ufdsInstance.del(user.dclocalconfig.dn, function delCb(delErr) {
                if (delErr) {
                    cb();
                    return;
                }
                ufdsInstance.deleteUser(user, handleErr);
            });
        } else {
            ufdsInstance.deleteUser(user, handleErr);
        }
    });

    function handleErr(err, user) {
        if (err) {
            log.error('unable to delete user ' + user.login + ': ' +
                err.message);
        }
        cb();
        return;
    }
}

function runTests(ufdsInstance, cb) {
    test('graf-proxy test', function run(t) {
        const testFuncs = [
            testServerRunning,
            testPrivilegedUser,
            testUnprivilegedUser
        ];
        const args = {
            t: t,
            ufdsInstance: ufdsInstance
        };
        t.plan(testFuncs.length);

        vasync.pipeline({
            'arg': args,
            'funcs': testFuncs
        }, function pipelineCb(_, results) {
            t.end();
            cb();
        });
    });
}

// ---- mainline
runTests(ufdsMaster, function cleanup() {
    ufdsMaster.close();
});
