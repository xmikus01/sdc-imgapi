#!/usr/bin/env node
/*
 * Copyright 2012 Joyent, Inc.  All rights reserved.
 *
 * Main entry-point for the Image API (IMGAPI) for SmartDataCenter (SDC).
 */

var util = require('util');
var path = require('path');
var fs = require('fs');

var nopt = require('nopt');
var restify = require('restify');
var bunyan = require('bunyan');
var async = require('async');
var assert = require('assert-plus');

var createApp = require('./lib/app').createApp;
var objCopy = require('./lib/utils').objCopy;



//---- globals

var NAME = 'imgapi';
var VERSION = require('./package.json').version;
var DEFAULT_CFG = path.resolve(__dirname, 'etc', NAME + '.config.json');

var theConfig;
var theApp;
var log;
var serviceUnavailable = false;
var serviceUnavailableDetails = [];



//---- internal support functions

function usage(code, msg) {
    if (msg) {
        console.error('ERROR: ' + msg + '\n');
    }
    printHelp();
    process.exit(code);
}

function printHelp() {
    util.puts('Usage: node main.js [OPTIONS]');
    util.puts('');
    util.puts('The SDC Image API (IMGAPI).');
    util.puts('');
    util.puts('Options:');
    util.puts('  -h, --help     Print this help info and exit.');
    util.puts('  --version      Print version and exit.');
    util.puts('  -d, --debug    Debug level. Once for DEBUG log output.');
    util.puts('                 Twice for TRACE. Thrice to add "src=true"');
    util.puts('                 to Bunyan log records.');
    util.puts('  -f, --file CONFIG-FILE-PATH');
    util.puts('                 Specify config file to load.');
}


/**
 * Load config.
 *
 * This loads factory settings (etc/defaults.json) and any given `configPath`.
 * Note that this is synchronous.
 *
 * @param configPath {String} Optional. Path to JSON config file to load.
 */
function loadConfigSync(configPath) {
    var defaultsPath = path.resolve(__dirname, 'etc', 'defaults.json');
    log.info('Loading default config from "%s".', defaultsPath);
    var config = JSON.parse(fs.readFileSync(defaultsPath, 'utf-8'));

    if (configPath) {
        if (! fs.existsSync(configPath)) {
            usage(1, 'Config file not found: "' + configPath +
              '" does not exist. Aborting.');
        }
        log.info('Loading additional config from "%s".', configPath);
        var extraConfig = JSON.parse(fs.readFileSync(configPath, 'utf-8'));
        for (var name in extraConfig) {
            config[name] = extraConfig[name];
        }
    } else {
        config.configPath = null;
    }

    // Validation and defaults.
    assert.number(config.port, 'config.port');
    if (config.mode === undefined) {
        config.mode = 'public';
    }
    assert.string(config.mode, 'config.mode');
    assert.optionalString(config.serverName, 'config.serverName');
    assert.ok(['public', 'dc'].indexOf(config.mode) !== -1,
        'invalid config.mode');
    assert.object(config.storage, 'config.storage');
    if (config.storage.manta) {
        var manta = config.storage.manta;
        assert.string(manta.url, 'config.storage.manta.url');
        assert.string(manta.user, 'config.storage.manta.user');
        assert.string(manta.key, 'config.storage.manta.key');
        assert.string(manta.keyId, 'config.storage.manta.keyId');
    }
    if (config.storage.dcls) {
        var dcls = config.storage.dcls;
        assert.string(dcls.dir, 'config.storage.dcls.dir');
    }
    if (config.storage.local) {
        var local = config.storage.local;
        assert.string(local.dir, 'config.storage.local.dir');
    }
    assert.object(config.database, 'config.database');
    if (!config.database.type) {
        config.database.type = 'ufds';
    }
    assert.notEqual(['ufds', 'local'].indexOf(config.database.type), -1,
        'config.database.type not "ufds" or "local"');
    if (config.database.type === 'ufds') {
        assert.string(config.database.url, 'config.database.url');
        assert.string(config.database.bindDN, 'config.database.bindDN');
        assert.string(config.database.bindPassword, 'config.database.bindPassword');
    } else if (config.database.type === 'local') {
        assert.string(config.database.dir, 'config.database.dir');
    }
    if (config.wfapi) {
        assert.object(config.wfapi, 'config.wfapi');
        assert.string(config.wfapi.url, 'config.wfapi.url');
        assert.arrayOfString(config.wfapi.workflows, 'config.wfapi.workflows');
    }

    return config;
}


function handleArgv() {
    var longOpts = {
        'help': Boolean,
        'version': Boolean,
        'debug': [Boolean, Array],
        'file': path
    };
    var shortOpts = {
        'h': ['--help'],
        'd': ['--debug'],
        'f': ['--file']
    };
    var opts = nopt(longOpts, shortOpts, process.argv, 2);
    if (opts.help) {
        usage(0);
    }
    if (opts.version) {
        util.puts('IMGAPI ' + VERSION);
        process.exit(0);
    }
    if (! opts.file) {
        opts.file = DEFAULT_CFG;
    }
    var logSrc = false,
        logLevel = 'info';
    if (opts.debug) {
        logLevel = (opts.debug.length > 1 ? 'trace' : 'debug');
        if (opts.debug.length > 2)
            logSrc = true;
    }
    var serializers = objCopy(restify.bunyan.serializers);
    serializers.image = function (image) {
        // 'config.mode' isn't know yet, but that doesn't matter for internal
        // logging.
        return (image ? image.serialize('dc') : image);
    };
    log = bunyan.createLogger({  // `log` is intentionally global.
        name: NAME,
        level: logLevel,
        src: logSrc,
        serializers: serializers
    });
    log.trace({opts: opts}, 'opts');

    // Die on unknown opts.
    var extraOpts = {};
    Object.keys(opts).forEach(function (o) { extraOpts[o] = true; });
    delete extraOpts.argv;
    Object.keys(longOpts).forEach(function (o) { delete extraOpts[o]; });
    extraOpts = Object.keys(extraOpts);
    if (extraOpts.length) {
        console.error('unknown option%s: -%s\n',
            (extraOpts.length === 1 ? '' : 's'), extraOpts.join(', -'));
        usage(1);
    }

    return opts;
}



//---- mainline

function main() {
    var opts = handleArgv();
    theConfig = loadConfigSync(opts.file);
    if (!opts.debug && theConfig.logLevel) {
        log.level(theConfig.logLevel);
        if (log.level() <= bunyan.TRACE) {
          log.src = true;
        }
    }

    // Log config (but don't put passwords in the log file).
    var censorKeys = {'password': '***', 'authToken': '***', 'pass': '***'};
    function censor(key, value) {
        var censored = censorKeys[key];
        return (censored === undefined ? value : censored);
    }
    log.debug('config: %s', JSON.stringify(theConfig, censor, 2));

    async.series([
        createAndStartTheApp,   // sets `theApp` global
        setupSignalHandlers
    ], function (err) {
        if (err) {
            log.error(err, 'error starting up');
            process.exit(2);
        }
        log.info('startup complete');
    });
}

function createAndStartTheApp(next) {
    createApp(theConfig, log, function (err, app) {
        if (err)
            return next(err);
        theApp = app;  // `theApp` is intentionally global
        theApp.listen(function () {
            var addr = theApp.server.address();
            log.info('Image API listening on <http://%s:%s>.',
                addr.address, addr.port);
            next();
        });
    });
}

function setupSignalHandlers(next) {
    // Try to ensure we clean up properly on exit.
    function closeApp(callback) {
        if (theApp) {
            log.info('Closing app.');
            theApp.close(callback);
        } else {
            log.debug('No app to close.');
            callback();
        }
    }
    process.on('SIGINT', function () {
        log.debug('SIGINT. Cleaning up.');
        closeApp(function () {
            process.exit(1);
        });
    });
    next();
}


main();
