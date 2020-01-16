# Nimbus
# Copyright (c) 2019 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import evmc/evmc, evmc_helpers, eth/common

proc nim_host_get_interface*(): ptr evmc_host_interface {.importc, cdecl.}
proc nim_host_create_context*(vmstate: pointer, msg: ptr evmc_message): evmc_host_context {.importc, cdecl.}
proc nim_host_destroy_context*(ctx: evmc_host_context) {.importc, cdecl.}
proc nim_create_nimbus_vm*(): ptr evmc_vm {.importc, cdecl.}

type
  HostContext* = object
    host*: ptr evmc_host_interface
    context*: evmc_host_context

proc init*(x: var HostContext, host: ptr evmc_host_interface, context: evmc_host_context) =
  x.host = host
  x.context = context

proc init*(x: typedesc[HostContext], host: ptr evmc_host_interface, context: evmc_host_context): HostContext =
  result.init(host, context)

proc getTxContext*(ctx: HostContext): evmc_tx_context =
  {.gcsafe.}:
    ctx.host.get_tx_context(ctx.context)

proc getBlockHash*(ctx: HostContext, number: int64): Hash256 =
  {.gcsafe.}:
    Hash256.fromEvmc ctx.host.get_block_hash(ctx.context, number)

proc accountExists*(ctx: HostContext, address: EthAddress): bool =
  var address = toEvmc(address)
  ctx.host.account_exists(ctx.context, address.addr).bool

proc getStorage*(ctx: HostContext, address: EthAddress, key: Uint256): Uint256 =
  var
    address = toEvmc(address)
    key = toEvmc(key)
  Uint256.fromEvmc ctx.host.get_storage(ctx.context, address.addr, key.addr)

proc setStorage*(ctx: HostContext, address: EthAddress,
                 key, value: Uint256): evmc_storage_status =
  var
    address = toEvmc(address)
    key = toEvmc(key)
    value = toEvmc(value)
  ctx.host.set_storage(ctx.context, address.addr, key.addr, value.addr)

proc getBalance*(ctx: HostContext, address: EthAddress): Uint256 =
  var address = toEvmc(address)
  Uint256.fromEvmc ctx.host.get_balance(ctx.context, address.addr)

proc getCodeSize*(ctx: HostContext, address: EthAddress): int =
  var address = toEvmc(address)
  ctx.host.get_code_size(ctx.context, address.addr).int

proc getCodeHash*(ctx: HostContext, address: EthAddress): Hash256 =
  var address = toEvmc(address)
  Hash256.fromEvmc ctx.host.get_code_hash(ctx.context, address.addr)

proc copyCode*(ctx: HostContext, address: EthAddress, codeOffset: int = 0): seq[byte] =
  let size = ctx.getCodeSize(address)
  var address = toEvmc(address)
  if size - codeOffset > 0:
    result = newSeq[byte](size - codeOffset)
    let read = ctx.host.copy_code(ctx.context, address.addr, code_offset.uint, result[0].addr, result.len.uint).int
    doAssert(read == result.len)

proc selfdestruct*(ctx: HostContext, address, beneficiary: EthAddress) =
  var
    address = toEvmc(address)
    beneficiary = toEvmc(beneficiary)
  ctx.host.selfdestruct(ctx.context, address.addr, beneficiary.addr)

proc emitLog*(ctx: HostContext, address: EthAddress, data: openArray[byte], topics: openArray[evmc_bytes32]) =
  var address = toEvmc(address)
  ctx.host.emit_log(ctx.context, address.addr, data[0].unsafeAddr, data.len.uint, topics[0].unsafeAddr, topics.len.uint)

proc call*(ctx: HostContext, msg: evmc_message): evmc_result =
  ctx.host.call(ctx.context, msg.unsafeAddr)

#proc vmHost*(vmState: BaseVMState, gasPrice: GasInt, origin: EthAddress): HostContext =
#  let host = nim_host_get_interface()
#  let context = nim_host_create_context(cast[pointer](vmState), gasPrice, toEvmc(origin))
#  result.init(host, context)
#
#proc destroy*(hc: HostContext) =
#  nim_host_destroy_context(hc.context)
