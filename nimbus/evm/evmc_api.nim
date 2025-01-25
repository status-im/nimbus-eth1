# Nimbus
# Copyright (c) 2019-2025 Status Research & Development GmbH
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
    tx_gas_price*     : evmc_uint256be   # The transaction gas price.
    tx_origin*        : Address       # The transaction origin account.
    block_coinbase*   : Address       # The miner of the block.
    block_number*     : int64            # The block number.
    block_timestamp*  : int64            # The block timestamp.
    block_gas_limit*  : int64            # The block gas limit.
    block_prev_randao*: evmc_uint256be   # The block difficulty.
    chain_id*         : evmc_uint256be   # The blockchain's ChainID.
    block_base_fee*   : evmc_uint256be   # The block base fee.
    blob_hashes*      : ptr evmc_bytes32 # The array of blob hashes (EIP-4844).
    blob_hashes_count*: csize_t          # The number of blob hashes (EIP-4844).
    blob_base_fee*    : evmc_uint256be   # The blob base fee (EIP-7516).
    initcodes*        : ptr evmc_tx_initcode # The array of transaction initcodes (TXCREATE).
    initcodes_count*  : csize_t              # The number of transaction initcodes (TXCREATE).

  nimbus_message* = object
    kind*        : evmc_call_kind
    flags*       : evmc_flags
    depth*       : int32
    gas*         : int64
    recipient*   : Address
    sender*      : Address
    input_data*  : ptr byte
    input_size*  : uint
    value*       : evmc_uint256be
    create2_salt*: evmc_bytes32
    code_address*: Address
    code*        : ptr byte
    code_size*   : csize_t

  nimbus_result* = object
    status_code*   : evmc_status_code
    gas_left*      : int64
    gas_refund*    : int64
    output_data*   : ptr byte
    output_size*   : uint
    release*       : proc(result: var nimbus_result)
                       {.cdecl, gcsafe, raises: [].}
    create_address*: Address
    padding*       : array[4, byte]

  nimbus_host_interface* = object
    account_exists*: proc(context: evmc_host_context, address: ptr evmc_address): bool {.cdecl, gcsafe, raises: [].}
    get_storage*: proc(context: evmc_host_context, address: ptr evmc_address, key: ptr evmc_uint256be): evmc_uint256be {.cdecl, gcsafe, raises: [].}
    set_storage*: proc(context: evmc_host_context, address: ptr evmc_address,
                       key, value: ptr evmc_uint256be): evmc_storage_status {.cdecl, gcsafe, raises: [].}
    get_balance*: proc(context: evmc_host_context, address: ptr evmc_address): evmc_uint256be {.cdecl, gcsafe, raises: [].}
    get_code_size*: proc(context: evmc_host_context, address: ptr evmc_address): uint {.cdecl, gcsafe, raises: [].}
    get_code_hash*: proc(context: evmc_host_context, address: ptr evmc_address): evmc_bytes32 {.cdecl, gcsafe, raises: [].}
    copy_code*: proc(context: evmc_host_context, address: ptr evmc_address,
                     code_offset: int, buffer_data: ptr byte,
                     buffer_size: int): int {.cdecl, gcsafe, raises: [].}
    selfdestruct*: proc(context: evmc_host_context, address, beneficiary: ptr evmc_address) {.cdecl, gcsafe, raises: [].}
    call*: proc(context: evmc_host_context, msg: ptr nimbus_message): nimbus_result {.cdecl, gcsafe, raises: [].}
    get_tx_context*: proc(context: evmc_host_context): nimbus_tx_context {.cdecl, gcsafe, raises: [].}
    get_block_hash*: proc(context: evmc_host_context, number: int64): evmc_bytes32 {.cdecl, gcsafe, raises: [].}
    emit_log*: proc(context: evmc_host_context, address: ptr evmc_address,
                    data: ptr byte, data_size: uint,
                    topics: ptr evmc_bytes32, topics_count: uint) {.cdecl, gcsafe, raises: [].}
    access_account*: proc(context: evmc_host_context,
                          address: ptr evmc_address): evmc_access_status {.cdecl, gcsafe, raises: [].}
    access_storage*: proc(context: evmc_host_context, address: ptr evmc_address,
                          key: ptr evmc_bytes32): evmc_access_status {.cdecl, gcsafe, raises: [].}
    get_transient_storage*: proc(context: evmc_host_context, address: ptr evmc_address,
                       key: ptr evmc_uint256be): evmc_uint256be {.cdecl, gcsafe, raises: [].}
    set_transient_storage*: proc(context: evmc_host_context, address: ptr evmc_address,
                       key, value: ptr evmc_uint256be) {.cdecl, gcsafe, raises: [].}
    get_delegate_address*: proc(context: evmc_host_context, address: ptr evmc_address): evmc_address
                            {.cdecl, gcsafe, raises: [].}

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

proc getTxContext*(ctx: HostContext): nimbus_tx_context =
  ctx.host.get_tx_context(ctx.context)

proc getBlockHash*(ctx: HostContext, number: BlockNumber): Hash32 =
  Hash32.fromEvmc ctx.host.get_block_hash(ctx.context, number.int64)

proc accountExists*(ctx: HostContext, address: Address): bool =
  var address = toEvmc(address)
  ctx.host.account_exists(ctx.context, address.addr)

proc getStorage*(ctx: HostContext, address: Address, key: UInt256): UInt256 =
  var
    address = toEvmc(address)
    key = toEvmc(key)
  UInt256.fromEvmc ctx.host.get_storage(ctx.context, address.addr, key.addr)

proc setStorage*(ctx: HostContext, address: Address,
                 key, value: UInt256): evmc_storage_status =
  var
    address = toEvmc(address)
    key = toEvmc(key)
    value = toEvmc(value)
  ctx.host.set_storage(ctx.context, address.addr, key.addr, value.addr)

proc getBalance*(ctx: HostContext, address: Address): UInt256 =
  var address = toEvmc(address)
  UInt256.fromEvmc ctx.host.get_balance(ctx.context, address.addr)

proc getCodeSize*(ctx: HostContext, address: Address): uint =
  var address = toEvmc(address)
  ctx.host.get_code_size(ctx.context, address.addr)

proc getCodeHash*(ctx: HostContext, address: Address): Hash32 =
  var address = toEvmc(address)
  Hash32.fromEvmc ctx.host.get_code_hash(ctx.context, address.addr)

proc copyCode*(ctx: HostContext, address: Address, codeOffset: int = 0): seq[byte] =
  let size = ctx.getCodeSize(address).int
  if size - codeOffset > 0:
    result = newSeq[byte](size - codeOffset)
    var address = toEvmc(address)
    let read = ctx.host.copy_code(ctx.context, address.addr,
        codeOffset, result[0].addr, result.len)
    doAssert(read == result.len)

proc selfDestruct*(ctx: HostContext, address, beneficiary: Address) =
  var
    address = toEvmc(address)
    beneficiary = toEvmc(beneficiary)
  ctx.host.selfdestruct(ctx.context, address.addr, beneficiary.addr)

proc emitLog*(ctx: HostContext, address: Address, data: openArray[byte],
              topics: ptr evmc_bytes32, topicsCount: int) =
  var address = toEvmc(address)
  ctx.host.emit_log(ctx.context, address.addr, if data.len > 0: data[0].unsafeAddr else: nil,
                    data.len.uint, topics, topicsCount.uint)

proc call*(ctx: HostContext, msg: nimbus_message): nimbus_result =
  ctx.host.call(ctx.context, msg.unsafeAddr)

proc accessAccount*(ctx: HostContext,
                    address: Address): evmc_access_status =
  var address = toEvmc(address)
  ctx.host.access_account(ctx.context, address.addr)

proc accessStorage*(ctx: HostContext, address: Address,
                    key: UInt256): evmc_access_status =
  var
    address = toEvmc(address)
    key = toEvmc(key)
  ctx.host.access_storage(ctx.context, address.addr, key.addr)

proc getTransientStorage*(ctx: HostContext, address: Address, key: UInt256): UInt256 =
  var
    address = toEvmc(address)
    key = toEvmc(key)
  UInt256.fromEvmc ctx.host.get_transient_storage(ctx.context, address.addr, key.addr)

proc setTransientStorage*(ctx: HostContext, address: Address,
                 key, value: UInt256) =
  var
    address = toEvmc(address)
    key = toEvmc(key)
    value = toEvmc(value)
  ctx.host.set_transient_storage(ctx.context, address.addr, key.addr, value.addr)

# The following two templates put here because the stupid style checker
# complaints about block_number vs blockNumber and chain_id vs chainId
# if they are written directly in computation.nim
template getBlockNumber*(ctx: HostContext): uint64 =
  ctx.getTxContext().block_number.uint64

template getChainId*(ctx: HostContext): uint64 =
  UInt256.fromEvmc(ctx.getTxContext().chain_id).truncate(uint64)
