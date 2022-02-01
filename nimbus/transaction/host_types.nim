# Nimbus - Types and helpers used at the boundary of transactions/RPC and EVMC/EVM
#
# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  sets, stint, evmc/evmc, eth/common/eth_types, ../vm_types

# Object `TransactionHost` represents "EVMC host" to the EVM.  "Host services"
# manage account state outside EVM such as balance transfers, storage, logs and
# gas refunds.  This object holds transaction state hidden from the EVM, and
# the EVM passes this around as opaque `evmc_host_context`.  To the application
# outside the EVM, this object represents a computation for a transaction.
#
# `Host..` types are like EVMC types, but used in `TransactionHost` code.  They
# occupy the same positions in EVMC functions and objects as the type they map
# to/from.  But `Host..` types match internal APIs in the rest of Nimbus, to
# minimise the amount of explicit conversions when using them.  We could just
# use the Nimbus types, but these names document their use and also role.
#
# `Evmc..` types named here are actual EVMC types.  They play a similar role to
# `Host..` types, except the `Evmc` prefix indicates they are the actual EVMC
# types and more care applies.  Byte order (big/little-endian) may need to be
# swapped in object fields of these types, and enums respected.
#
# When crossing the EVMC API boundary, between internal APIs and EVMC binary
# interface there have to be type-conversions and some big/little-endian byte
# swapping.  Those conversions are mostly kept out of `TransactionHost` logic
# and delegated to glue code.

type
  HostAddress*       = EthAddress        # Mapped to/from evmc_address.
  HostKey*           = UInt256           # Mapped to/from evmc_bytes32.
  HostValue*         = UInt256           # Mapped to/from evmc_bytes32.
  HostBalance*       = UInt256           # Mapped to/from evmc_uint256be.
  HostSize*          = uint              # Mapped to/from csize_t - unsigned!
  HostHash*          = Hash256           # Mapped to/from evmc_bytes32.
  HostTopic*         = Topic             # Mapped to/from evmc_bytes32.
  HostBlockNumber*   = BlockNumber       # Mapped to/from int64.
  HostGasInt*        = GasInt            # Mapped to/from int64.
  HostGasPrice*      = GasInt            # Mapped to/from evmc_uint256be.

  EvmcStatusCode*    = evmc_status_code
  EvmcCallKind*      = evmc_call_kind
  EvmcStorageStatus* = evmc_storage_status
  EvmcAccessStatus*  = evmc_access_status
  EvmcTxContext*     = evmc_tx_context
  EvmcMessage*       = evmc_message
  EvmcResult*        = evmc_result

  TransactionHost* = ref object
    vmState*:         BaseVMState
    computation*:     Computation
    msg*:             EvmcMessage
    input*:           seq[byte]
    code*:            seq[byte]
    cachedTxContext*: bool
    txContext*:       EvmcTxContext
    logEntries*:      seq[Log]
    touchedAccounts*: HashSet[EthAddress]
    selfDestructs*:   HashSet[EthAddress]
    depth*:           int
    saveComputation*: seq[Computation]
    hostInterface*:   ptr evmc_host_interface

# These versions of `toEvmc` and `fromEvmc` don't flip big/little-endian like
# the older functions in `evmc_helpers`.  New code only flips with _explicit_
# calls to `flip256` where it is wanted.

template toEvmc*(n: Uint256): evmc_uint256be =
  cast[evmc_uint256be](n)

template toEvmc*(n: Hash256): evmc_bytes32 =
  cast[evmc_bytes32](n)

template toEvmc*(address: EthAddress): evmc_address =
  cast[evmc_address](address)

template fromEvmc*(n: evmc_uint256be): UInt256 =
  cast[UInt256](n)

template fromEvmc*(address: evmc_address): EthAddress =
  cast[EthAddress](address)

template flip256*(word256: evmc_uint256be): evmc_uint256be =
  cast[evmc_uint256be](Uint256.fromBytesBe(word256.bytes).toBytes)

template isCreate*(kind: EvmcCallKind): bool =
  kind in {EVMC_CREATE, EVMC_CREATE2}

template isStatic*(msg: EvmcMessage): bool =
  EVMC_STATIC in msg.flags

template isZero*(n: evmc_bytes32): bool =
  n == default(evmc_bytes32)

# Nim quirks: Exporting `evmc_status_code` (etc) are needed to access the enum
# values, even though alias `EnumStatusCode` is already exported.  Exporting
# `evmc_flags` won't export the flags, `evmc_flag_bit_shifts` must be used.
export
  evmc_status_code, evmc_call_kind,
  evmc_flag_bit_shifts, evmc_storage_status, evmc_access_status
