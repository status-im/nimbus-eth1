# Nimbus - Services available to EVM code that is run for a transaction
#
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#{.push raises: [].}

import
  std/typetraits,
  stint, chronicles,
  eth/common/eth_types, ../db/ledger,
  ../common/[evmforks, common],
  ../evm/[state, internals],
  ./host_types, ./host_trace, ./host_call_nested,
  stew/saturation_arith

import ../evm/computation except fromEvmc, toEvmc

proc setupTxContext(host: TransactionHost) =
  # Conversion issues:
  #
  # `txContext.tx_gas_price` is 256-bit, but `vmState.txGasPrice` is 64-bit
  # signed (`GasInt`), and in reality it tends to be a fairly small integer,
  # usually < 16 bits.  Our EVM truncates whatever it gets blindly to 64-bit
  # anyway.  Largest ever so far may be 100,000,000.
  # https://medium.com/amberdata/most-expensive-transaction-in-ethereum-blockchain-history-99d9a30d8e02
  #
  # `txContext.block_number` is 64-bit signed. Nimbus `BlockNumber` is
  #  64-bit unsigned, so we use int64.saturate to avoid overflow assertion.
  #
  # `txContext.chain_id` is 256-bit, but `vmState.chaindb.config.chainId` is
  # 64-bit or 32-bit depending on the target CPU architecture (Nim `uint`).
  # Our EVM truncates whatever it gets blindly to 64-bit or 32-bit.
  #
  # No conversion required with the other fields:
  #
  # `txContext.tx_origin` and `txContext.block_coinbase` are 20-byte Ethereum
  # addresses, no issues with these.
  #
  # `txContext.block_timestamp` is 64-bit signed. Nimbus `EthTime` is
  # `distinct uint64`, but the wrapped value comes from std/times
  # `getTime().utc.toTime.toUnix` when EthTime.now() called.
  # So the wrapped value is actually in int64 range.
  # Value from other sources e.g. test vectors can overflow this int64.
  #
  # `txContext.block_gas_limit` is 64-bit signed (EVMC assumes
  # [EIP-1985](https://eips.ethereum.org/EIPS/eip-1985) although it's not
  # officially accepted), and `vmState.gasLimit` is too (`GasInt`).
  #
  # `txContext.block_prev_randao` is 256-bit, and this one can genuinely take
  # values over much of the 256-bit range.

  let vmState = host.vmState
  host.txContext.tx_gas_price     = vmState.txCtx.gasPrice.u256.toEvmc
  host.txContext.tx_origin        = vmState.txCtx.origin.toEvmc
  # vmState.coinbase now unused
  host.txContext.block_coinbase   = vmState.blockCtx.coinbase.toEvmc
  # vmState.number now unused
  host.txContext.block_number     = int64.saturate(vmState.blockNumber)
  # vmState.timestamp now unused

  # TODO: do not use int64.saturate for timestamp for the moment
  # while the choice of using int64 in evmc will not affect the evm/evmc operations
  # but some of the tests will fail if the value from test vector overflow
  # see getTimestamp of computation.nim too.
  # probably block timestamp should be checked before entering EVM
  # problematic test vectors:
  #  - BlockchainTests/GeneralStateTests/Pyspecs/cancun/eip4788_beacon_root/beacon_root_contract_timestamps.json
  #  - BlockchainTests/GeneralStateTests/Pyspecs/cancun/eip4788_beacon_root/beacon_root_equal_to_timestamp.json
  host.txContext.block_timestamp  = cast[int64](vmState.blockCtx.timestamp)

  # vmState.gasLimit now unused
  host.txContext.block_gas_limit  = int64.saturate(vmState.blockCtx.gasLimit)
  # vmState.difficulty now unused
  host.txContext.chain_id         = vmState.com.chainId.uint.u256.toEvmc
  host.txContext.block_base_fee   = vmState.blockCtx.baseFeePerGas.get(0.u256).toEvmc

  if vmState.txCtx.versionedHashes.len > 0:
    type
      BlobHashPtr = typeof host.txContext.blob_hashes
    host.txContext.blob_hashes = cast[BlobHashPtr](vmState.txCtx.versionedHashes[0].addr)
  else:
    host.txContext.blob_hashes = nil

  host.txContext.blob_hashes_count= vmState.txCtx.versionedHashes.len.csize_t
  host.txContext.blob_base_fee    = vmState.txCtx.blobBaseFee.toEvmc

  # Most host functions do `flip256` in `evmc_host_glue`, but due to this
  # result being cached, it's better to do `flip256` when filling the cache.
  host.txContext.tx_gas_price     = flip256(host.txContext.tx_gas_price)
  host.txContext.chain_id         = flip256(host.txContext.chain_id)
  host.txContext.block_base_fee   = flip256(host.txContext.block_base_fee)
  host.txContext.blob_base_fee    = flip256(host.txContext.blob_base_fee)

  # EIP-4399
  # Transfer block randomness to difficulty OPCODE
  let difficulty = vmState.difficultyOrPrevRandao.toEvmc
  host.txContext.block_prev_randao = flip256(difficulty)

  host.cachedTxContext = true

const use_evmc_glue = defined(evmc_enabled)

# When using the EVMC binary interface, each of the functions below is wrapped
# in another function that converts types to be compatible with the binary
# interface, and the functions below are not called directly.  The conversions
# mostly just cast between byte-compatible types, so to avoid a redundant call
# layer, make the functions below `{.inline.}` when wrapped in this way.
when use_evmc_glue:
  {.push inline.}

proc accountExists(host: TransactionHost, address: HostAddress): bool {.show.} =
  if host.vmState.fork >= FkSpurious:
    not host.vmState.readOnlyLedger.isDeadAccount(address)
  else:
    host.vmState.readOnlyLedger.accountExists(address)

# TODO: Why is `address` an argument in `getStorage`, `setStorage` and
# `selfDestruct`, if an EVM is only allowed to do these things to its own
# contract account and the host always knows which account?

proc getStorage(host: TransactionHost, address: HostAddress, key: HostKey): HostValue {.show.} =
  host.vmState.readOnlyLedger.getStorage(address, key)

proc setStorage(host: TransactionHost, address: HostAddress,
                key: HostKey, newVal: HostValue): EvmcStorageStatus {.show.} =
  let
    db = host.vmState.readOnlyLedger
    currentVal = db.getStorage(address, key)

  if currentVal == newVal:
    return EVMC_STORAGE_ASSIGNED

  host.vmState.mutateLedger:
    db.setStorage(address, key, newVal)

  # https://eips.ethereum.org/EIPS/eip-1283
  let originalVal = db.getCommittedStorage(address, key)
  if originalVal == currentVal:
    if originalVal.isZero:
      return EVMC_STORAGE_ADDED

    # !is_zero(original_val)
    if newVal.isZero:
      return EVMC_STORAGE_DELETED
    else:
      return EVMC_STORAGE_MODIFIED

  # originalVal != currentVal
  if originalVal.isZero.not:
    if currentVal.isZero:
      if originalVal == newVal:
        return EVMC_STORAGE_DELETED_RESTORED
      else:
        return EVMC_STORAGE_DELETED_ADDED

    # !is_zero(current_val)
    if newVal.isZero:
      return EVMC_STORAGE_MODIFIED_DELETED

    # !is_zero(new_val)
    if originalVal == newVal:
      return EVMC_STORAGE_MODIFIED_RESTORED
    else:
      return EVMC_STORAGE_ASSIGNED

  # is_zero(original_val)
  if originalVal == newVal:
    return EVMC_STORAGE_ADDED_DELETED
  else:
    return EVMC_STORAGE_ASSIGNED

proc getBalance(host: TransactionHost, address: HostAddress): HostBalance {.show.} =
  host.vmState.readOnlyLedger.getBalance(address)

proc getCodeSize(host: TransactionHost, address: HostAddress): HostSize {.show.} =
  # TODO: Check this `HostSize`, it was copied as `uint` from other code.
  # Note: Old `evmc_host` uses `getCode(address).len` instead.
  host.vmState.readOnlyLedger.getCodeSize(address).HostSize

proc getCodeHash(host: TransactionHost, address: HostAddress): HostHash {.show.} =
  let db = host.vmState.readOnlyLedger
  # TODO: Copied from `Computation`, but check if that code is wrong with
  # `FkSpurious`, as it has different calls from `accountExists` above.
  if not db.accountExists(address) or db.isEmptyAccount(address):
    default(HostHash)
  else:
    db.getCodeHash(address)

proc copyCode(host: TransactionHost, address: HostAddress,
              code_offset: HostSize, buffer_data: ptr byte,
              buffer_size: HostSize): HostSize {.show.} =
  # We must handle edge cases carefully to prevent overflows.  `len` is signed
  # type `int`, but `code_offset` and `buffer_size` are _unsigned_, and may
  # have large values (deliberately if attacked) that exceed the range of `int`.
  #
  # Comparing signed and unsigned types is _unsafe_: A type-conversion will
  # take place which breaks the comparison for some values.  So here we use
  # explicit type-conversions, always compare the same types, and always
  # convert towards the type that cannot truncate because preceding checks have
  # been used to reduce the possible value range.
  #
  # Note, when there is no code, `getCode` result is empty `seq`.  It was `nil`
  # when the DB was first implemented, due to Nim language changes since then.
  let code = host.vmState.readOnlyLedger.getCode(address)
  var safe_len: int = code.len # It's safe to assume >= 0.

  if code_offset >= safe_len.HostSize:
    return 0
  let safe_offset = code_offset.int
  safe_len = safe_len - safe_offset

  if buffer_size < safe_len.HostSize:
    safe_len = buffer_size.int

  if safe_len > 0:
    copyMem(buffer_data, code.bytes()[safe_offset].addr, safe_len)
  return safe_len.HostSize

proc selfDestruct(host: TransactionHost, address, beneficiary: HostAddress) {.show.} =
  host.vmState.mutateLedger:
    let localBalance = db.getBalance(address)

    if host.vmState.fork >= FkCancun:
      # Zeroing contract balance except beneficiary
      # is the same address
      db.subBalance(address, localBalance)

      # Transfer to beneficiary
      db.addBalance(beneficiary, localBalance)

      db.selfDestruct6780(address)
    else:
      # Transfer to beneficiary
      db.addBalance(beneficiary, localBalance)
      db.selfDestruct(address)

template call(host: TransactionHost, msg: EvmcMessage): EvmcResult =
  # `call` is special.  The C stack usage must be kept small for deeply nested
  # EVM calls.  To ensure small stack, `{.show.}` must be handled at
  # `host_call_nested`, not here, and this function must use `template` to
  # inline at Nim level (same for `callEvmcNested`).  `{.inline.}` is not good
  # enough.  Due to object return it ends up using a lot more stack.
  host.callEvmcNested(msg)

proc getTxContext(host: TransactionHost): EvmcTxContext {.show.} =
  if not host.cachedTxContext:
    host.setupTxContext()
  return host.txContext

proc getBlockHash(host: TransactionHost, number: HostBlockNumber): HostHash {.show.} =
  # TODO: Clean up the different messy block number types.
  host.vmState.getAncestorHash(number.BlockNumber)

proc emitLog(host: TransactionHost, address: HostAddress,
             data: ptr byte, data_size: HostSize,
             topics: ptr HostTopic, topics_count: HostSize) {.show.} =
  var log: Log
  # Note, this assumes the EVM ensures `data_size` and `topics_count` cannot be
  # unreasonably large values.  Largest `topics_count` should be 4 according to
  # EVMC documentation, but we won't restrict it here.
  if topics_count > 0:
    let topicsArray = cast[ptr UncheckedArray[HostTopic]](topics)
    let count = topics_count.int
    log.topics = newSeq[Topic](count)
    for i in 0 ..< count:
      log.topics[i] = topicsArray[i]

  if (data_size > 0):
    log.data = newSeq[byte](data_size.int)
    copyMem(log.data[0].addr, data, data_size.int)

  log.address = address
  host.vmState.ledger.addLogEntry(log)

proc accessAccount(host: TransactionHost, address: HostAddress): EvmcAccessStatus {.show.} =
  host.vmState.mutateLedger:
    if not db.inAccessList(address):
      db.accessList(address)
      return EVMC_ACCESS_COLD
    else:
      return EVMC_ACCESS_WARM

proc accessStorage(host: TransactionHost, address: HostAddress,
                   key: HostKey): EvmcAccessStatus {.show.} =
  host.vmState.mutateLedger:
    if not db.inAccessList(address, key):
      db.accessList(address, key)
      return EVMC_ACCESS_COLD
    else:
      return EVMC_ACCESS_WARM

proc getTransientStorage(host: TransactionHost,
                         address: HostAddress, key: HostKey): HostValue {.show.} =
  host.vmState.readOnlyLedger.getTransientStorage(address, key)

proc setTransientStorage(host: TransactionHost, address: HostAddress,
                key: HostKey, newVal: HostValue) {.show.} =
  host.vmState.mutateLedger:
    db.setTransientStorage(address, key, newVal)

proc getDelegateAddress(host: TransactionHost, address: HostAddress): HostAddress {.show.} =
  let db = host.vmState.readOnlyLedger
  db.getDelegateAddress(address)

when use_evmc_glue:
  {.pop: inline.}
  const included_from_host_services {.used.} = true
  include ./evmc_host_glue
else:
  export
    accountExists, getStorage, storage, getBalance, getCodeSize, getCodeHash,
    copyCode, selfDestruct, getTxContext, call, getBlockHash, emitLog, getDelegateAddress
