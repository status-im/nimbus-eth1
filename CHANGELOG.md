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
