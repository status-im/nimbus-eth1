// nimbus_verified_proxy
// Copyright (c) 2026 Status Research & Development GmbH
// Licensed and distributed under either of
//   * MIT license (license terms in the root directory or at https://opensource.org/licenses/MIT).
//   * Apache v2 license (license terms in the root directory or at https://www.apache.org/licenses/LICENSE-2.0).
// at your option. This file may not be copied, modified, or distributed except according to those terms.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import path from 'node:path';

const here = path.dirname(fileURLToPath(import.meta.url));
const dataDir = path.join(here, '../../../../tests/data');
const wasmDir = process.env.VERIFPROXY_WASM_DIR ??
  path.join(here, '../../../../../build/nimbus_verified_proxy_wasm');

const { default: NimbusVerifiedProxy } =
  await import(pathToFileURL(path.join(wasmDir, 'verifproxy.js')).href);

const baseConfig = {
  eth2Network:      'mainnet',
  executionApiUrls: 'http://127.0.0.1:19999',
  beaconApiUrls:    'http://127.0.0.1:19998',
  logLevel:         'FATAL',
  logStdout:        'None',
  syncHeaderStore:  true,
  freezeAtSlot:     14018020,
};

const testConfig = JSON.stringify({
  ...baseConfig,
  trustedBlockRoot: '0x9bcb90ec3a294591b77dd2a58e973578715cdc0e6eeeb286bc06dd120057f18b',
});
const testConfigNoRoot = JSON.stringify(baseConfig);

const optimisticBlockHash = '0x5b34070154b4331237ca3975de14df77359f7269a65b95d01b0e81c626e3151d';

const readData = name => readFile(path.join(dataDir, name), 'utf8');

async function executionTransport(url, name, params) {
  if (name === 'eth_getBlockByNumber' || name === 'eth_getBlockByHash') {
    const p = JSON.stringify(params);
    const file = p.includes('0x17a2d65') || p.includes(optimisticBlockHash)
      ? 'block_0x17a2d65.json'
      : 'block_0x17a2d23.json';
    return `{"jsonrpc":"2.0","id":1,"result":${await readData(file)}}`;
  }
  throw new Error(`exec: no mock for ${name}`);
}

const beaconFiles = {
  getLightClientBootstrap:        'lc_bootstrap.json',
  getLightClientUpdatesByRange:   'lc_updates.json',
  getLightClientOptimisticUpdate: 'lc_optimistic.json',
  getLightClientFinalityUpdate:   'lc_finality.json',
};

async function beaconTransport(url, endpoint, params) {
  const file = beaconFiles[endpoint];
  if (file === undefined) throw new Error(`beacon: no mock for ${endpoint}`);
  return readData(file);
}

async function startProxy(config, opts = {}) {
  const proxy = new NimbusVerifiedProxy();
  await proxy.init(config, { executionTransport, beaconTransport, ...opts });
  return proxy;
}

test('basic', async () => {
  const proxy = await startProxy(testConfig);
  try {
    await assert.rejects(proxy.call('eth_blockNumber', '[]'));
    assert.ok(await proxy.call('eth_syncing', '[]'));
    assert.equal(await proxy.syncIntervalMs(), 12000);
    await proxy.sync();
    await assert.rejects(proxy.opSyncIntervalMs());
    await assert.rejects(proxy.opSync());
  } finally {
    proxy.destroy();
  }
});

test('restart', async () => {
  const first = await startProxy(testConfig);
  try {
    await first.sync();
  } finally {
    first.destroy();
  }

  const second = await startProxy(testConfig);
  try {
    await second.sync();
  } finally {
    second.destroy();
  }
});

test('concurrent', async () => {
  const a = await startProxy(testConfig);
  const b = await startProxy(testConfig);
  try {
    await Promise.all([a.sync(), b.sync()]);
  } finally {
    a.destroy();
    b.destroy();
  }
});

test('storage restore', async () => {
  const values = new Map();
  const storage = {
    get: async key => values.get(key) ?? null,
    put: async (key, bytes) => { values.set(key, bytes); },
  };

  const first = await startProxy(testConfig, { storage });
  try {
    await first.sync();
  } finally {
    first.destroy();
  }

  let bootstraps = 0;
  const countingBeacon = (url, endpoint, params) => {
    if (endpoint === 'getLightClientBootstrap') bootstraps++;
    return beaconTransport(url, endpoint, params);
  };

  const second = await startProxy(testConfigNoRoot, { storage, beaconTransport: countingBeacon });
  try {
    await second.sync();
    assert.equal(bootstraps, 0);
    await second.call('eth_blockNumber', '[]');
  } finally {
    second.destroy();
  }
});

test('storage errors', async () => {
  let gets = 0;
  let puts = 0;
  const storage = {
    get: async () => { gets++; throw new Error('get failed'); },
    put: async () => { puts++; throw new Error('put failed'); },
  };

  const proxy = await startProxy(testConfig, { storage });
  try {
    await proxy.sync();
    assert.equal(gets, 1);
    assert.equal(puts, 1);
  } finally {
    proxy.destroy();
  }
});

test('transport errors', async () => {
  const beaconDown = await startProxy(testConfig, {
    beaconTransport: async () => { throw new Error('beacon transport down'); },
  });
  try {
    await assert.rejects(beaconDown.sync(), /beacon transport down/);
  } finally {
    beaconDown.destroy();
  }

  const execDown = await startProxy(testConfig, {
    executionTransport: async () => { throw new Error('exec transport down'); },
  });
  try {
    await execDown.sync();
    await assert.rejects(execDown.call('eth_blockNumber', '[]'), /exec transport down/);
  } finally {
    execDown.destroy();
  }
});

test('invalid config', async () => {
  await assert.rejects(startProxy('{not json'), /wasmStart failed/);
});

test('destroy rejects pending calls', async () => {
  const proxy = await startProxy(testConfig, {
    beaconTransport: () => new Promise(() => {}),
  });
  const pending = proxy.sync();
  proxy.destroy();
  await assert.rejects(pending, /proxy destroyed/);
});
