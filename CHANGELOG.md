2026-06-15 v0.3.1
=================

The Nimbus Ethereum client `v0.3.1` alpha, along with the Nimbus Verified Proxy, are `medium-urgency` releases which add WASM, JS, and Go bindings to the Verified Proxy and enable EIP-4444 block pruning on the execution and unified client.

### Improvements

- Enable EIP-4444 block history pruning:
  https://github.com/status-im/nimbus-eth1/pull/3953

- Implement WASM/JS bindings for verified proxy:
  https://github.com/status-im/nimbus-eth1/pull/4010

- Add verified proxy P2P backend:
  https://github.com/status-im/nimbus-eth1/pull/4208

- Support verified proxy relaying transactions to private mempools:
  https://github.com/status-im/nimbus-eth1/pull/4033

- Implement verified proxy Go bindings:
  https://github.com/status-im/nimbus-eth1/pull/4200
  https://github.com/status-im/nimbus-eth1/pull/4252

- Implement eth_getStorageValues:
  https://github.com/status-im/nimbus-eth1/pull/4146

- Improve verified proxy eth_feeHistory support:
  https://github.com/status-im/nimbus-eth1/pull/4037

- Improve execution and unified client eth_getLogs performance:
  https://github.com/status-im/nimbus-eth1/pull/4191

- Improve execution and unified client eth_getTransactionReceipt performance:
  https://github.com/status-im/nimbus-eth1/pull/4186

### Fixes

- Improve block fill rate of transactions:
  https://github.com/status-im/nimbus-eth1/pull/4143

- Fix execution and unified client eth_getLogs filtering:
  https://github.com/status-im/nimbus-eth1/pull/4237

- Fix execution and unified client debug-namespace web3 endpoints:
  https://github.com/status-im/nimbus-eth1/pull/4069

2026-03-02 v0.3.0
=================

The Nimbus Ethereum client `v0.3.0` alpha, along with the Nimbus verified Proxy, are `medium-urgency` releases which introduce a single combined binary for both the consensus and execution layers, along with a unified client interface to both consensus and execution layers; more detail on this at https://blog.nimbus.team/the-nimbus-unified-client/

### Improvements

- Provide the Nimbus client as a single binary:
  https://github.com/status-im/nimbus-eth1/pull/3966

- Provide multiarch images for the Nimbus single binary:
  https://github.com/status-im/nimbus-eth1/pull/3988

- Provide a C API for verified proxy:
  https://github.com/status-im/nimbus-eth1/pull/3745

- Support multiple Web3 endpoints for verified proxy:
  https://github.com/status-im/nimbus-eth1/pull/3891

- Support multiple frontends for verified proxy:
  https://github.com/status-im/nimbus-eth1/pull/4000

- Support by the verified proxy to download blocks in parallel:
  https://github.com/status-im/nimbus-eth1/pull/3892

- Support getBlobsV3 in execution and unified client:
  https://github.com/status-im/nimbus-eth1/pull/3893

### Fixes

- Avoid startup issues with corrupt databases:
  https://github.com/status-im/nimbus-eth1/pull/4023

2025-11-03 v0.2.2
=================

The Nimbus EL `v0.2.2` alpha is a `high-urgency` release for the impending Fusaka fork and `low-urgency` for the Hoodi and Sepolia testnets.

### Improvements

- Improve performance of certain addition, multiplication, and pairing precompiles by 80+%:
  https://github.com/status-im/nimbus-eth1/pull/3747

- Dynamically adjust block persistence batch sizes to safely maximize throughput:
  https://github.com/status-im/nimbus-eth1/pull/3750

- Optimize Portal database pruning performance by 150x:
  https://github.com/status-im/nimbus-eth1/pull/3753

- Optimize Osaka modExpFee calculation:
  https://github.com/status-im/nimbus-eth1/pull/3784

- Add support for runtime ChainId in Portal ENR field:
  https://github.com/status-im/nimbus-eth1/pull/3749

### Fixes

- Fix segfault when processing bad block:
  https://github.com/status-im/nimbus-eth1/pull/3733

- Fix crash while syncing:
  https://github.com/status-im/nimbus-eth1/pull/3751

- Fix segfault when database directory is locked or in use:
  https://github.com/status-im/nimbus-eth1/pull/3736

- Fix secp256r1 verification in certain cases:
  https://github.com/status-im/nimbus-eth1/pull/3759

- Fix forkId compatibility according to EIP-2124 and EIP-6122:
  https://github.com/status-im/nimbus-eth1/pull/3803

- Fix Portal bridge crash when JSON-RPC methods not available:
  https://github.com/status-im/nimbus-eth1/pull/3785

- Fix out-of-order execution client launch logging:
  https://github.com/status-im/nimbus-eth1/pull/3728

2025-09-26 v0.2.1
=================

The Nimbus EL `v0.2.1` alpha is a `high-urgency` release for the Hoodi, Sepolia, and Holesky testnets, due to their impending Fusaka forks. There are no Verified Proxy changes since `v0.2.0`.

### Improvements

- Improve block processing speed by 6x:
  https://github.com/status-im/nimbus-eth1/pull/3717

- Support stateless block execution:
  https://github.com/status-im/nimbus-eth1/pull/3683

- Improve precompile error-related logging:
  https://github.com/status-im/nimbus-eth1/pull/3718

### Fixes

- Prevent potential database corruption:
  https://github.com/status-im/nimbus-eth1/pull/3705

- Fix crash relating to shutting down while syncing:
  https://github.com/status-im/nimbus-eth1/pull/3695
