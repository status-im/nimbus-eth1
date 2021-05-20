# Nimbus - Services available to EVM code that is run for a transaction
#
# Copyright (c) 2019-2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

#{.push raises: [Defect].}

import
  sets, times, stint, chronicles, stew/byteutils,
  eth/common/eth_types, ../db/accounts_cache, ../forks,
  ".."/[vm_types, vm_state, vm_computation, vm_internals],
  ./host_types

proc setupTxContext(host: TransactionHost) =
  # Conversion issues:
  #
  # `txContext.tx_gas_price` is 256-bit, but `vmState.txGasPrice` is 64-bit
  # signed (`GasInt`), and in reality it tends to be a fairly small integer,
  # usually < 16 bits.  Our EVM truncates whatever it gets blindly to 64-bit
  # anyway.  Largest ever so far may be 100,000,000.
  # https://medium.com/amberdata/most-expensive-transaction-in-ethereum-blockchain-history-99d9a30d8e02
  #
  # `txContext.block_number` is 64-bit signed.  This is actually too small for
  # the Nimbus `BlockNumber` type which is 256-bit (for now), so we truncate
  # the other way.
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
  # `txContext.block_timestamp` is 64-bit signed.  `vmState.timestamp.toUnix`
  # is from Nim `std/times` and returns `int64` so this matches.  (It's
  # overkill that we store a full seconds and nanoseconds object in
  # `vmState.timestamp` though.)
  #
  # `txContext.block_gas_limit` is 64-bit signed (EVMC assumes
  # [EIP-1985](https://eips.ethereum.org/EIPS/eip-1985) although it's not
  # officially accepted), and `vmState.gasLimit` is too (`GasInt`).
  #
  # `txContext.block_difficulty` is 256-bit, and this one can genuinely take
  # values over much of the 256-bit range.

  let vmState = host.vmState
  host.txContext.tx_gas_price     = vmState.txGasPrice.u256.toEvmc
  host.txContext.tx_origin        = vmState.txOrigin.toEvmc
  # vmState.coinbase now unused
  host.txContext.block_coinbase   = vmState.minerAddress.toEvmc
  # vmState.blockNumber now unused
  host.txContext.block_number     = (vmState.blockHeader.blockNumber
                                     .truncate(typeof(host.txContext.block_number)))
  # vmState.timestamp now unused
  host.txContext.block_timestamp  = vmState.blockHeader.timestamp.toUnix
  # vmState.gasLimit now unused
  host.txContext.block_gas_limit  = vmState.blockHeader.gasLimit
  # vmState.difficulty now unused
  host.txContext.block_difficulty = vmState.blockHeader.difficulty.toEvmc
  host.txContext.chain_id         = vmState.chaindb.config.chainId.uint.u256.toEvmc

const use_evmc_glue = defined(evmc_enabled)

# When using the EVMC binary interface, each of the functions below is wrapped
# in another function that converts types to be compatible with the binary
# interface, and the functions below are not called directly.  The conversions
# mostly just cast between byte-compatible types, so to avoid a redundant call
# layer, make the functions below `{.inline.}` when wrapped in this way.
when use_evmc_glue:
  {.push inline.}

proc accountExists(host: TransactionHost, address: HostAddress): bool =
  if host.vmState.fork >= FkSpurious:
    not host.vmState.readOnlyStateDB.isDeadAccount(address)
  else:
    host.vmState.readOnlyStateDB.accountExists(address)

# TODO: Why is `address` an argument in `getStorage`, `setStorage` and
# `selfDestruct`, if an EVM is only allowed to do these things to its own
# contract account and the host always knows which account?

proc getStorage(host: TransactionHost, address: HostAddress, key: HostKey): HostValue =
  host.vmState.readOnlyStateDB.getStorage(address, key)

proc setStorage1(host: TransactionHost, address: HostAddress,
                 key: HostKey, value: HostValue): EvmcStorageStatus =
  let db = host.vmState.readOnlyStateDB
  let oldValue = db.getStorage(address, key)

  if oldValue == value:
    return EVMC_STORAGE_UNCHANGED

  host.vmState.mutateStateDB:
    db.setStorage(address, key, value)

  if host.vmState.fork >= FkIstanbul or host.vmState.fork == FkConstantinople:
    let originalValue = db.getCommittedStorage(address, key)
    if oldValue != originalValue:
      return EVMC_STORAGE_MODIFIED_AGAIN

  if oldValue.isZero:
    return EVMC_STORAGE_ADDED
  elif value.isZero:
    return EVMC_STORAGE_DELETED
  else:
    return EVMC_STORAGE_MODIFIED

proc setStorage(host: TransactionHost, address: HostAddress,
                key: HostKey, value: HostValue): EvmcStorageStatus =
  let status = setStorage1(host, address, key, value)
  let gasParam = GasParams(kind: Op.Sstore,
                           s_status: status,
                           s_currentValue: currValue,
                           s_originalValue: origValue)
  gasRefund = ctx.gasCosts[Sstore].c_handler(newValue, gasParam)[1]
  if gasRefund != 0:
    host.computation.gasMeter.refundGas(gasRefund)

proc getBalance(host: TransactionHost, address: HostAddress): HostBalance =
  host.vmState.readOnlyStateDB.getBalance(address)

proc getCodeSize(host: TransactionHost, address: HostAddress): HostSize =
  # TODO: Check this `HostSize`, it was copied as `uint` from other code.
  # Note: Old `evmc_host` uses `getCode(address).len` instead.
  host.vmState.readOnlyStateDB.getCodeSize(address).HostSize

proc getCodeHash(host: TransactionHost, address: HostAddress): HostHash =
  let db = host.vmState.readOnlyStateDB
  # TODO: Copied from `Computation`, but check if that code is wrong with
  # `FkSpurious`, as it has different calls from `accountExists` above.
  if not db.accountExists(address) or db.isEmptyAccount(address):
    default(HostHash)
  else:
    db.getCodeHash(address)

proc copyCode(host: TransactionHost, address: HostAddress,
              code_offset: HostSize, buffer_data: ptr byte,
              buffer_size: HostSize): HostSize =
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
  var code: seq[byte] = host.vmState.readOnlyStateDB.getCode(address)
  var safe_len: int = code.len # It's safe to assume >= 0.

  if code_offset >= safe_len.HostSize:
    return 0
  let safe_offset = code_offset.int
  safe_len = safe_len - safe_offset

  if buffer_size < safe_len.HostSize:
    safe_len = buffer_size.int

  if safe_len > 0:
    copyMem(buffer_data, code[safe_offset].addr, safe_len)
  return safe_len.HostSize

proc selfDestruct(host: TransactionHost, address, beneficiary: HostAddress) =
  host.vmState.mutateStateDB:
    let closingBalance = db.getBalance(address)
    let beneficiaryBalance = db.getBalance(beneficiary)

    # Transfer to beneficiary
    db.setBalance(beneficiary, beneficiaryBalance + closingBalance)

    # Zero balance of account being deleted.
    # This must come after sending to the beneficiary in case the
    # contract named itself as the beneficiary.
    db.setBalance(address, 0.u256)

  host.touchedAccounts.incl(beneficiary)
  host.selfDestructs.incl(address)

proc call(host: TransactionHost, msg: EvmcMessage): EvmcResult =
  echo "**** Nested call not implemented ****"
  return EvmcResult(status_code: EVMC_REJECTED)

proc getTxContext(host: TransactionHost): EvmcTxContext =
  if not host.cachedTxContext:
    host.setupTxContext()
    host.cachedTxContext = true
  return host.txContext

proc getBlockHash(host: TransactionHost, number: HostBlockNumber): HostHash =
  # TODO: Clean up the different messy block number types.
  host.vmState.getAncestorHash(number.toBlockNumber)

proc emitLog(host: TransactionHost, address: HostAddress,
             data: ptr byte, data_size: HostSize,
             topics: ptr HostTopic, topics_count: HostSize) =
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

  log.data = newSeq[byte](data_size.int)
  copyMem(log.data[0].addr, data, data_size.int)
  log.address = address
  host.logEntries.add(log)

when use_evmc_glue:
  {.pop: inline.}
  const included_from_host_services = true
  include ./evmc_host_glue
else:
  export
    accountExists, getStorage, storage, getBalance, getCodeSize, getCodeHash,
    copyCode, selfDestruct, getTxContext, call, getBlockHash, emitLog
