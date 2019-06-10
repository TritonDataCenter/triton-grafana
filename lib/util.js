/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

/*
 * Copyright 2019 Joyent, Inc.
 *
 * Utility functions for grafana proxy server.
 */

'use strict';

const fs = require('fs');
const assert = require('assert-plus');

const DEFAULT_CFG_PATH = __dirname + '/../etc/config.json';

/**
 * loadConfig - loads config from specified file
 *
 * @param
 * - defaultConfig: path to default config file
 * - customConfig: path to user-specified config file
 *
 * @throws
 * - Error if defaultConfig is not found or unparseable
 * - Error if customConfig is specified but not found or unparseable
 */
function loadConfig(log, defaultConfig, customConfig) {
    assert.string(defaultConfig, 'defaultConfig');
    assert.optionalString(customConfig, 'customConfig');

    // Load default config
    let config;
    log.info('Loading default config from "' + DEFAULT_CFG_PATH + '".');
    if (!fs.existsSync(defaultConfig)) {
        throw new Error('Config file not found: "' + defaultConfig +
            '" does not exist.');
    }
    try {
        config = JSON.parse(fs.readFileSync(defaultConfig, 'utf8'));
    } catch (err) {
        throw new Error('Unable to parse ' + defaultConfig + ': ' +
            err.message);
    }

    // Load custom config, if specified
    if (customConfig) {
        log.info('Loading additional config from "' + customConfig + '".');

        if (!fs.existsSync(customConfig)) {
            throw new Error('Config file not found: "' + customConfig +
                '" does not exist.');
        }
        let extraConfig;
        try {
            extraConfig = JSON.parse(fs.readFileSync(customConfig,
                'utf8'));
        } catch (err) {
            throw new Error('Unable to parse ' + extraConfig + ': ' +
                err.message);
        }
        for (let name in extraConfig) {
            config[name] = extraConfig[name];
        }
    }

    log.info('Loaded config: ', JSON.stringify(config, censor));
    config.log = log;
    return config;

    function censor(key, value) {
        if (key === 'bindPassword') {
            return '***';
        }
        return value;
    }
}

module.exports = {
    DEFAULT_CFG_PATH: DEFAULT_CFG_PATH,
    loadConfig: loadConfig
};
