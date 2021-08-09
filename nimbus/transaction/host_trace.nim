# Nimbus - Trace EVMC host calls when EVM code is run for a transaction
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  macros, strformat, strutils, stint, chronicles,
  stew/byteutils, stew/ranges/ptr_arith,
  ./host_types

# Set `true` or `false` to control host call tracing.
const showTxCalls  = false
const showTxNested = true

proc `$`(val: EvmcCallKind | EvmcStatusCode |
         EvmcStorageStatus | EvmcAccessStatus): string =
  result = val.repr
  result.removePrefix("EVMC_")

proc `$`(address: HostAddress): string = toHex(address)

# Don't use both types in the overload, as Nim <= 1.2.x gives "ambiguous call".
#func `$`(n: HostKey | HostValue): string = toHex(n)
proc `$`(n: HostKey): string =
  # Show small keys and values as decimal, and large ones as "0x"-prefix hex.
  # These are often small numbers despite the 256-bit type, so low digits is
  # helpful.  But "key=d" looks odd.  Hex must be used for large values as they
  # are sometimes 256-bit hashes, and then decimal is unhelpful.
  if n <= 65535.u256.HostKey:
    $n.truncate(uint16)
  else:
    "0x" & n.toHex

proc depthPrefix(host: TransactionHost): string =
  let depth = host.depth
  if depth <= 20:
    return spaces(depth * 2)
  else:
    let num = '(' & $depth & ')'
    return num & spaces(42 - num.len)

proc showEvmcMessage(msg: EvmcMessage): string =
  let kindStr =
    if msg.flags == {}: $msg.kind
    elif msg.flags == {EVMC_STATIC} and msg.kind == EVMC_CALL: "CALL_STATIC"
    else: &"{$msg.kind} flags={$msg.flags}"
  var inputStr = "(" & $msg.input_size & ")"
  if msg.input_size > 0:
    inputStr.add toHex(makeOpenArray(msg.input_data,
                                     min(msg.input_size, 256).int))
    if msg.input_size > 256:
      inputStr.add "..."
  result = &"kind={kindStr}" &
    &" depth={$msg.depth}" &
    &" gas={$msg.gas}" &
    &" value={$msg.value.fromEvmc}" &
    &" sender={$msg.sender.fromEvmc}" &
    &" destination={$msg.destination.fromEvmc}" &
    &" input_data={inputStr}"
  if msg.kind == EVMC_CREATE2:
    result.add &" create2_salt={$msg.create2_salt.fromEvmc}"

proc showEvmcResult(res: EvmcResult, withCreateAddress = true): string =
  if res.status_code != EVMC_SUCCESS and res.status_code != EVMC_REVERT and
     res.gas_left == 0 and res.output_size == 0:
    return &"status={$res.status_code}"

  var outputStr = "(" & $res.output_size & ")"
  if res.output_size > 0:
    outputStr.add toHex(makeOpenArray(res.output_data,
                                      min(res.output_size, 256).int))
    if res.output_size > 256:
      outputStr.add "..."

  result = &"status={$res.status_code}" &
    &" gas_left={$res.gas_left}" &
    &" output_data={outputStr}"
  if withCreateAddress:
    result.add &" create_address={$res.create_address.fromEvmc}"

proc showEvmcTxContext(txc: EvmcTxContext): string =
  return &"tx_gas_price={$txc.tx_gas_price.fromEvmc}" &
    &" tx_origin={$txc.tx_origin.fromEvmc}" &
    &" block_coinbase={$txc.block_coinbase.fromEvmc}" &
    &" block_number={$txc.block_number}" &
    &" block_timestamp={$txc.block_timestamp}" &
    &" block_gas_limit={$txc.block_gas_limit}" &
    &" block_difficulty={$txc.block_difficulty.fromEvmc}" &
    &" chain_id={$txc.chain_id.fromEvmc}" &
    &" block_base_fee={$txc.block_base_fee.fromEvmc}"

proc showEvmcArgsExpr(fn: NimNode, callName: string): auto =
  var args: seq[NimNode] = newSeq[NimNode]()
  var types: seq[NimNode] = newSeq[NimNode]()
  for i in 1 ..< fn.params.len:
    let idents = fn.params[i]
    for j in 0 ..< idents.len-2:
      args.add idents[j]
      types.add idents[^2]
  let hostExpr = args[0]
  var msgExpr = quote do:
    `depthPrefix`(`hostExpr`) & "evmc." & `callName` & ":"
  var skip = 0
  for i in 1 ..< args.len:
    if i == skip:
      continue
    var arg = args[i]
    let argNameString = " " & $arg & "="
    if (types[i].repr == "ptr byte" or types[i].repr == "ptr HostTopic") and
       (i < args.len-1 and types[i+1].repr == "HostSize"):
      skip = i+1
      arg = newPar(args[i], args[i+1])
    msgExpr = quote do:
      `msgExpr` & `argNameString` & $(`arg`)
  return (msgExpr, args)

macro show*(fn: untyped): auto =
  if not showTxCalls:
    return fn

  let (msgExpr, args) = showEvmcArgsExpr(fn, $fn.name)
  let hostExpr = args[0]
  if fn.params[0].kind == nnkEmpty:
    fn.body.insert 0, quote do:
      if showTxNested or `hostExpr`.depth > 1:
        echo `msgExpr`
  else:
    let innerFn = newProc(name = fn.name, body = fn.body)
    innerFn.params = fn.params.copy
    innerFn.addPragma(newIdentNode("inline"))
    fn.body = newStmtList(innerFn)
    let call = newCall(fn.name, args)
    let msgVar = genSym(nskLet, "msg")
    fn.body.add quote do:
      if not (showTxNested or `hostExpr`.depth > 1):
        return `call`
      let `msgVar` = `msgExpr`
      result = `call`
    if fn.params[0].repr == "EvmcTxContext":
      fn.body.add quote do:
        echo `msgVar` & " -> " & showEvmcTxContext(result)
    else:
      fn.body.add quote do:
        echo `msgVar` & " -> result=" & $result
  return fn

template showCallEntry*(host: TransactionHost, msg: EvmcMessage) =
  if showTxCalls and (showTxNested or host.depth > 0):
    echo depthPrefix(host) & "evmc.call: " &
      showEvmcMessage(msg)
    inc host.depth

template showCallReturn*(host: TransactionHost, res: EvmcResult,
                         forNestedCreate = false) =
  if showTxCalls and (showTxNested or host.depth > 1):
    echo depthPrefix(host) & "evmc.return -> " &
      showEvmcResult(res, forNestedCreate)
    dec host.depth
