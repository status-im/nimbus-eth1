# Nimbus
# Copyright (c) 2019-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import evmc/evmc, ./evmc_helpers, eth/common, ../constants

{.push raises: [].}

type
  # we are not using EVMC original signature here
  # because we want to trick the compiler
  # and reduce unnecessary conversion/typecast
  # TODO: move this type definition to nim-evmc
  #       after we have implemented ABI compatibility test
  # TODO: investigate the possibility to use Big Endian VMWord
  #       directly if it's not involving stint computation
  #       and we can reduce unecessary conversion further
  nimbus_tx_context* = object
    tx_gas_price*: evmc_uint256be # The transaction gas price.
    tx_origin*: EthAddress # The transaction origin account.
    block_coinbase*: EthAddress # The miner of the block.
    block_number*: int64 # The block number.
    block_timestamp*: int64 # The block timestamp.
    block_gas_limit*: int64 # The block gas limit.
    block_prev_randao*: evmc_uint256be # The block difficulty.
    chain_id*: evmc_uint256be # The blockchain's ChainID.
    block_base_fee*: evmc_uint256be # The block base fee.
    blob_hashes*: ptr evmc_bytes32 # The array of blob hashes (EIP-4844).
    blob_hashes_count*: csize_t # The number of blob hashes (EIP-4844).
    blob_base_fee*: evmc_uint256be # The blob base fee (EIP-7516).
    initcodes*: ptr evmc_tx_initcode # The array of transaction initcodes (TXCREATE).
    initcodes_count*: csize_t # The number of transaction initcodes (TXCREATE).

  nimbus_message* = object
    kind*: evmc_call_kind
    flags*: evmc_flags
    depth*: int32
    gas*: int64
    recipient*: EthAddress
    sender*: EthAddress
    input_data*: ptr byte
    input_size*: uint
    value*: evmc_uint256be
    create2_salt*: evmc_bytes32
    code_address*: EthAddress
    code*: ptr byte
    code_size*: csize_t

  nimbus_result* = object
    status_code*: evmc_status_code
    gas_left*: int64
    gas_refund*: int64
    output_data*: ptr byte
    output_size*: uint
    release*: proc(result: var nimbus_result) {.cdecl, gcsafe, raises: [].}
    create_address*: EthAddress
    padding*: array[4, byte]

  nimbus_host_interface* = object
    account_exists*: proc(context: evmc_host_context, address: EthAddress): bool {.
      cdecl, gcsafe, raises: []
    .}
    get_storage*: proc(
      context: evmc_host_context, address: EthAddress, key: ptr evmc_uint256be
    ): evmc_uint256be {.cdecl, gcsafe, raises: [].}
    set_storage*: proc(
      context: evmc_host_context, address: EthAddress, key, value: ptr evmc_uint256be
    ): evmc_storage_status {.cdecl, gcsafe, raises: [].}
    get_balance*: proc(context: evmc_host_context, address: EthAddress): evmc_uint256be {.
      cdecl, gcsafe, raises: []
    .}
    get_code_size*: proc(context: evmc_host_context, address: EthAddress): uint {.
      cdecl, gcsafe, raises: []
    .}
    get_code_hash*: proc(context: evmc_host_context, address: EthAddress): Hash256 {.
      cdecl, gcsafe, raises: []
    .}
    copy_code*: proc(
      context: evmc_host_context,
      address: EthAddress,
      code_offset: int,
      buffer_data: ptr byte,
      buffer_size: int,
    ): int {.cdecl, gcsafe, raises: [].}
    selfdestruct*: proc(context: evmc_host_context, address, beneficiary: EthAddress) {.
      cdecl, gcsafe, raises: []
    .}
    call*: proc(context: evmc_host_context, msg: ptr nimbus_message): nimbus_result {.
      cdecl, gcsafe, raises: []
    .}
    get_tx_context*:
      proc(context: evmc_host_context): nimbus_tx_context {.cdecl, gcsafe, raises: [].}
    get_block_hash*: proc(context: evmc_host_context, number: int64): Hash256 {.
      cdecl, gcsafe, raises: []
    .}
    emit_log*: proc(
      context: evmc_host_context,
      address: EthAddress,
      data: ptr byte,
      data_size: uint,
      topics: ptr evmc_bytes32,
      topics_count: uint,
    ) {.cdecl, gcsafe, raises: [].}
    access_account*: proc(
      context: evmc_host_context, address: EthAddress
    ): evmc_access_status {.cdecl, gcsafe, raises: [].}
    access_storage*: proc(
      context: evmc_host_context, address: EthAddress, key: var evmc_bytes32
    ): evmc_access_status {.cdecl, gcsafe, raises: [].}
    get_transient_storage*: proc(
      context: evmc_host_context, address: EthAddress, key: ptr evmc_uint256be
    ): evmc_uint256be {.cdecl, gcsafe, raises: [].}
    set_transient_storage*: proc(
      context: evmc_host_context, address: EthAddress, key, value: ptr evmc_uint256be
    ) {.cdecl, gcsafe, raises: [].}

proc nim_host_get_interface*(): ptr nimbus_host_interface {.importc, cdecl.}
proc nim_host_create_context*(
  vmstate: pointer, msg: ptr evmc_message
): evmc_host_context {.importc, cdecl.}

proc nim_host_destroy_context*(ctx: evmc_host_context) {.importc, cdecl.}
proc nim_create_nimbus_vm*(): ptr evmc_vm {.importc, cdecl.}

type HostContext* = object
  host*: ptr nimbus_host_interface
  context*: evmc_host_context

proc init*(
    x: var HostContext, host: ptr nimbus_host_interface, context: evmc_host_context
) =
  x.host = host
  x.context = context

proc init*(
    x: typedesc[HostContext],
    host: ptr nimbus_host_interface,
    context: evmc_host_context,
): HostContext =
  result.init(host, context)

proc getTxContext*(ctx: HostContext): nimbus_tx_context =
  ctx.host.get_tx_context(ctx.context)

proc getBlockHash*(ctx: HostContext, number: BlockNumber): Hash256 =
  ctx.host.get_block_hash(ctx.context, number.int64)

proc accountExists*(ctx: HostContext, address: EthAddress): bool =
  ctx.host.account_exists(ctx.context, address)

proc getStorage*(ctx: HostContext, address: EthAddress, key: UInt256): UInt256 =
  var key = toEvmc(key)
  UInt256.fromEvmc ctx.host.get_storage(ctx.context, address, key.addr)

proc setStorage*(
    ctx: HostContext, address: EthAddress, key, value: UInt256
): evmc_storage_status =
  var
    key = toEvmc(key)
    value = toEvmc(value)
  ctx.host.set_storage(ctx.context, address, key.addr, value.addr)

proc getBalance*(ctx: HostContext, address: EthAddress): UInt256 =
  UInt256.fromEvmc ctx.host.get_balance(ctx.context, address)

proc getCodeSize*(ctx: HostContext, address: EthAddress): uint =
  ctx.host.get_code_size(ctx.context, address)

proc getCodeHash*(ctx: HostContext, address: EthAddress): Hash256 =
  ctx.host.get_code_hash(ctx.context, address)

proc copyCode*(ctx: HostContext, address: EthAddress, codeOffset: int = 0): seq[byte] =
  let size = ctx.getCodeSize(address).int
  if size - codeOffset > 0:
    result = newSeq[byte](size - codeOffset)
    let read =
      ctx.host.copy_code(ctx.context, address, codeOffset, result[0].addr, result.len)
    doAssert(read == result.len)

proc selfDestruct*(ctx: HostContext, address, beneficiary: EthAddress) =
  ctx.host.selfdestruct(ctx.context, address, beneficiary)

proc emitLog*(
    ctx: HostContext,
    address: EthAddress,
    data: openArray[byte],
    topics: ptr evmc_bytes32,
    topicsCount: int,
) =
  ctx.host.emit_log(
    ctx.context,
    address,
    if data.len > 0:
      data[0].unsafeAddr
    else:
      nil,
    data.len.uint,
    topics,
    topicsCount.uint,
  )

proc call*(ctx: HostContext, msg: nimbus_message): nimbus_result =
  ctx.host.call(ctx.context, msg.unsafeAddr)

proc accessAccount*(ctx: HostContext, address: EthAddress): evmc_access_status =
  ctx.host.access_account(ctx.context, address)

proc accessStorage*(
    ctx: HostContext, address: EthAddress, key: UInt256
): evmc_access_status =
  var key = toEvmc(key)
  ctx.host.access_storage(ctx.context, address, key)

proc getTransientStorage*(
    ctx: HostContext, address: EthAddress, key: UInt256
): UInt256 =
  var key = toEvmc(key)
  UInt256.fromEvmc ctx.host.get_transient_storage(ctx.context, address, key.addr)

proc setTransientStorage*(ctx: HostContext, address: EthAddress, key, value: UInt256) =
  var
    key = toEvmc(key)
    value = toEvmc(value)
  ctx.host.set_transient_storage(ctx.context, address, key.addr, value.addr)

# The following two templates put here because the stupid style checker
# complaints about block_number vs blockNumber and chain_id vs chainId
# if they are written directly in computation.nim
template getBlockNumber*(ctx: HostContext): uint64 =
  ctx.getTxContext().block_number.uint64

template getChainId*(ctx: HostContext): uint64 =
  UInt256.fromEvmc(ctx.getTxContext().chain_id).truncate(uint64)
