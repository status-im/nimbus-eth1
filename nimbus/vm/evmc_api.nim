# Nimbus
# Copyright (c) 2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import evmc/evmc, evmc_helpers, eth/common, ../constants

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
    tx_gas_price*    : evmc_uint256be # The transaction gas price.
    tx_origin*       : EthAddress     # The transaction origin account.
    block_coinbase*  : EthAddress     # The miner of the block.
    block_number*    : int64          # The block number.
    block_timestamp* : int64          # The block timestamp.
    block_gas_limit* : int64          # The block gas limit.
    block_difficulty*: evmc_uint256be # The block difficulty.
    chain_id*        : evmc_uint256be # The blockchain's ChainID.

  nimbus_message* = object
    kind*: evmc_call_kind
    flags*: uint32
    depth*: int32
    gas*: int64
    destination*: EthAddress
    sender*: EthAddress
    input_data*: ptr byte
    input_size*: uint
    value*: evmc_uint256be
    create2_salt*: evmc_bytes32

  nimbus_result* = object
    status_code*: evmc_status_code
    gas_left*: int64
    output_data*: ptr byte
    output_size*: uint
    release*: proc(result: var nimbus_result) {.cdecl, gcsafe.}
    create_address*: EthAddress
    padding*: array[4, byte]

  nimbus_host_interface* = object
    account_exists*: proc(context: evmc_host_context, address: EthAddress): bool {.cdecl, gcsafe.}
    get_storage*: proc(context: evmc_host_context, address: EthAddress, key: ptr evmc_uint256be): evmc_uint256be {.cdecl, gcsafe.}
    set_storage*: proc(context: evmc_host_context, address: EthAddress,
                       key, value: ptr evmc_uint256be): evmc_storage_status {.cdecl, gcsafe.}
    get_balance*: proc(context: evmc_host_context, address: EthAddress): evmc_uint256be {.cdecl, gcsafe.}
    get_code_size*: proc(context: evmc_host_context, address: EthAddress): uint {.cdecl, gcsafe.}
    get_code_hash*: proc(context: evmc_host_context, address: EthAddress): Hash256 {.cdecl, gcsafe.}
    copy_code*: proc(context: evmc_host_context, address: EthAddress,
                     code_offset: int, buffer_data: ptr byte,
                     buffer_size: int): int {.cdecl, gcsafe.}
    selfdestruct*: proc(context: evmc_host_context, address, beneficiary: EthAddress) {.cdecl, gcsafe.}
    call*: proc(context: evmc_host_context, msg: ptr nimbus_message): nimbus_result {.cdecl, gcsafe.}
    get_tx_context*: proc(context: evmc_host_context): nimbus_tx_context {.cdecl, gcsafe.}
    get_block_hash*: proc(context: evmc_host_context, number: int64): Hash256 {.cdecl, gcsafe.}
    emit_log*: proc(context: evmc_host_context, address: EthAddress,
                    data: ptr byte, data_size: uint,
                    topics: ptr evmc_bytes32, topics_count: uint) {.cdecl, gcsafe.}

proc nim_host_get_interface*(): ptr nimbus_host_interface {.importc, cdecl.}
proc nim_host_create_context*(vmstate: pointer, msg: ptr evmc_message): evmc_host_context {.importc, cdecl.}
proc nim_host_destroy_context*(ctx: evmc_host_context) {.importc, cdecl.}
proc nim_create_nimbus_vm*(): ptr evmc_vm {.importc, cdecl.}

type
  HostContext* = object
    host*: ptr nimbus_host_interface
    context*: evmc_host_context

proc init*(x: var HostContext, host: ptr nimbus_host_interface, context: evmc_host_context) =
  x.host = host
  x.context = context

proc init*(x: typedesc[HostContext], host: ptr nimbus_host_interface, context: evmc_host_context): HostContext =
  result.init(host, context)

proc getTxContext*(ctx: HostContext): nimbus_tx_context {.inline.} =
  ctx.host.get_tx_context(ctx.context)

proc getBlockHash*(ctx: HostContext, number: Uint256): Hash256 =
  let
    blockNumber = ctx.getTxContext().block_number.u256
    ancestorDepth  = blockNumber - number - 1
  if ancestorDepth >= constants.MAX_PREV_HEADER_DEPTH:
    return
  if number >= blockNumber:
    return
  ctx.host.get_block_hash(ctx.context, number.truncate(int64))

proc accountExists*(ctx: HostContext, address: EthAddress): bool {.inline.} =
  ctx.host.account_exists(ctx.context, address)

proc getStorage*(ctx: HostContext, address: EthAddress, key: Uint256): Uint256 =
  var key = toEvmc(key)
  Uint256.fromEvmc ctx.host.get_storage(ctx.context, address, key.addr)

proc setStorage*(ctx: HostContext, address: EthAddress,
                 key, value: Uint256): evmc_storage_status {.inline.} =
  var
    key = toEvmc(key)
    value = toEvmc(value)
  ctx.host.set_storage(ctx.context, address, key.addr, value.addr)

proc getBalance*(ctx: HostContext, address: EthAddress): Uint256 {.inline.} =
  Uint256.fromEvmc ctx.host.get_balance(ctx.context, address)

proc getCodeSize*(ctx: HostContext, address: EthAddress): uint {.inline.} =
  ctx.host.get_code_size(ctx.context, address)

proc getCodeHash*(ctx: HostContext, address: EthAddress): Hash256 {.inline.} =
  ctx.host.get_code_hash(ctx.context, address)

proc copyCode*(ctx: HostContext, address: EthAddress, codeOffset: int = 0): seq[byte] =
  let size = ctx.getCodeSize(address).int
  if size - codeOffset > 0:
    result = newSeq[byte](size - codeOffset)
    let read = ctx.host.copy_code(ctx.context, address,
        codeOffset, result[0].addr, result.len)
    doAssert(read == result.len)

proc selfdestruct*(ctx: HostContext, address, beneficiary: EthAddress) {.inline.} =
  ctx.host.selfdestruct(ctx.context, address, beneficiary)

proc emitLog*(ctx: HostContext, address: EthAddress, data: openArray[byte],
              topics: ptr evmc_bytes32, topicsCount: int) {.inline.} =
  ctx.host.emit_log(ctx.context, address, if data.len > 0: data[0].unsafeAddr else: nil,
                    data.len.uint, topics, topicsCount.uint)

proc call*(ctx: HostContext, msg: nimbus_message): nimbus_result {.inline.} =
  ctx.host.call(ctx.context, msg.unsafeAddr)

#proc vmHost*(vmState: BaseVMState, gasPrice: GasInt, origin: EthAddress): HostContext =
#  let host = nim_host_get_interface()
#  let context = nim_host_create_context(cast[pointer](vmState), gasPrice, toEvmc(origin))
#  result.init(host, context)
#
#proc destroy*(hc: HostContext) =
#  nim_host_destroy_context(hc.context)
