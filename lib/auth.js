/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * Copyright 2019 Joyent, Inc.
 *
 * Authentication for grafana proxy server. Sets headers for use with the
 * auth-proxy authentication mode in Grafana - see
 * http://docs.grafana.org/auth/auth-proxy/
 */

'use strict';

const assert = require('assert-plus');
const basicAuth = require('basic-auth');

const errors = require('./errors');

const AUTH_USERNAME_HEADER = 'X-Grafana-Username';
const AUTH_EMAIL_HEADER = 'X-Grafana-Email';
const AUTH_NAME_HEADER = 'X-Grafana-Name';

/**
 * authenticate
 *
 * @requires
 * - req.ufds
 */
function authenticate(req, res, next) {
    assert.object(req.ufds, 'req.ufds');

    // Retrieve credentials from request
    const creds = basicAuth(req);
    // User hasn't submitted credentials yet -- prompt them
    if (!creds) {
        next(setAuthHeader());
        return;
    }
    const username = creds.name;
    const password = creds.pass;

    // Prompt user again if blank username or password
    if (username === '') {
        next(setAuthHeader());
        return;
    }
    if (password === '') {
        next(setAuthHeader());
        return;
    }

    // Verify that user exists
    req.ufds.getUserEx({
        'searchType': 'login',
        'value': username
    }, function getUserExCb(err, user) {
        if (err) {
            // Username doesn't exist in UFDS - prompt again
            if (err.restCode === 'ResourceNotFound') {
                next(setAuthHeader());
                return;
            } else {
                next(new errors.UfdsError(err));
                return;
            }
        }

        /*
         * Check for lockout. Note that, because node-ufds caches user objects
         * on the client side, a user who is locked out on the server may appear
         * to be unlocked from the client perspective. This means that the user
         * will receive the authentication prompt instead of a proper 403 until
         * the cache times out -- the user will still be properly unable to
         * authenticate to the server regardless.
         */
        const lockedTime = user.pwdaccountlockedtime;
        if (lockedTime && lockedTime > Date.now()) {
            next(new errors.AccountLockedError());
            return;
        }

        // Check for password expiry
        const pwdEndTime = user.pwdendtime;
        if (pwdEndTime && pwdEndTime <= Date.now()) {
            next(new errors.PasswordExpiredError());
            return;
        }

        // Authenticate user
        doAuth();
        return;
    });

    function doAuth() {
        req.ufds.authenticate(username, password,
            function authenticateCb(err, user) {
            if (err) {
                // Invalid password or username - prompt user again
                if (err.restCode === 'InvalidCredentials' ||
                    err.restCode === 'ResourceNotFound') {
                    next(setAuthHeader());
                    return;
                }

                next(new errors.UfdsError(err));
                return;
            }

            if (!user.isAdmin()) {
                next(new errors.PermissionError());
                return;
            }

            // Set headers needed by grafana
            res.header('Content-Type', 'application/json');
            res.header(AUTH_USERNAME_HEADER, user.login);
            res.header(AUTH_EMAIL_HEADER, user.email);
            // Given name is optional in UFDS
            res.header(AUTH_NAME_HEADER, user.givenname || '');
            res.send(200);
            next();
            return;
        });
    }

    // Convenience function for prompting user for credentials
    function setAuthHeader() {
        res.header('WWW-Authenticate', 'Basic realm="Joyent Grafana"');
        return (new errors.AuthError());
    }
}

module.exports = {
    authenticate: authenticate
};
