# Nimbus - Services available to EVM code that is run for a transaction
#
# Copyright (c) 2021 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import macros, strformat, stew/byteutils, stint, ./host_types

const show_tx_calls = false

# Don't use both types in the overload, as Nim <= 1.2.x gives "ambiguous call".
#func `$`(n: HostKey | HostValue): string = toHex(n)
func `$`(n: HostKey): string = toHex(n)

func `$`(address: HostAddress): string = toHex(address)
func `$`(txc: EvmcTxContext): string = &"gas_price={txc.tx_gas_price.fromEvmc}"
func `$`(n: typeof(EvmcMessage().sender)): string = $n.fromEvmc
func `$`(n: typeof(EvmcMessage().value)): string = $n.fromEvmc
func `$`(host: TransactionHost): string = &"(fork={host.vmState.fork} message=${host.msg})"

macro show*(fn: untyped): auto =
  if not show_tx_calls:
    return fn
  var args: seq[NimNode] = newSeq[NimNode]()
  var types: seq[NimNode] = newSeq[NimNode]()
  for i in 1 ..< fn.params.len:
    let idents = fn.params[i]
    for j in 0 ..< idents.len-2:
      args.add idents[j]
      types.add idents[^2]

  let procName = $fn.name
  let msgVar = genSym(nskLet, "msg")
  var msgExpr = quote do:
    "tx." & `procName`
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
  let call = newCall(fn.name, args)

  let wrapFn = newProc(name = fn.name)
  wrapFn.params = fn.params.copy
  wrapFn.body.add fn
  if fn.params[0].kind == nnkEmpty:
    wrapFn.body.add quote do:
      echo `msgExpr`
      `call`
  else:
    wrapFn.body.add quote do:
      let `msgVar` = `msgExpr`
      let res = `call`
      echo `msgVar` & " -> result=" & $res
      res
  return wrapFn
