/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * Copyright 2019 Joyent, Inc.
 *
 * Errors for grafana proxy server.
 */

'use strict';

const restify_errors = require('restify-errors');
const util = require('util');

const HttpError = restify_errors.HttpError;

const ACCOUNT_LOCKED_MESSAGE = 'Account is temporarily locked after too many ' +
    'failed auth attempts';
const AUTH_ERROR_MESSAGE = 'Credentials Invalid';
const INSUFFICIENT_PERMISSION_MESSAGE = 'User does not have permission to ' +
    'access Grafana';
const PASSWORD_EXPIRED_MESSAGE = 'Your password has expired';
const UFDS_ERROR_MESSAGE = 'Error while authenticating via UFDS';

function GrafProxyError(obj) {
    obj.constructorOpt = this.constructor;
    HttpError.call(this, obj);
}
util.inherits(GrafProxyError, HttpError);

function AccountLockedError(err) {
    GrafProxyError.call(this, {
        restCode: 'Forbidden',
        statusCode: 403,
        cause: err,
        message: ACCOUNT_LOCKED_MESSAGE
    });
}
util.inherits(AccountLockedError, GrafProxyError);

function AuthError(err) {
    GrafProxyError.call(this, {
        restCode: 'Unauthorized',
        statusCode: 401,
        cause: err,
        message: AUTH_ERROR_MESSAGE
    });
}
util.inherits(AuthError, GrafProxyError);

function PermissionError(err) {
    GrafProxyError.call(this, {
        restCode: 'Forbidden',
        statusCode: 403,
        cause: err,
        message: INSUFFICIENT_PERMISSION_MESSAGE
    });
}
util.inherits(PermissionError, GrafProxyError);

function PasswordExpiredError(err) {
    GrafProxyError.call(this, {
        restCode: 'Forbidden',
        statusCode: 403,
        cause: err,
        message: PASSWORD_EXPIRED_MESSAGE
    });
}
util.inherits(PasswordExpiredError, GrafProxyError);

function UfdsError(err) {
    GrafProxyError.call(this, {
        restCode: 'Internal',
        statusCode: 500,
        cause: err,
        message: UFDS_ERROR_MESSAGE
    });
}
util.inherits(UfdsError, GrafProxyError);

module.exports = {
    AccountLockedError: AccountLockedError,
    AuthError: AuthError,
    PermissionError: PermissionError,
    PasswordExpiredError: PasswordExpiredError,
    UfdsError: UfdsError
};
