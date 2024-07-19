# Nimbus
# Copyright (c) 2020-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  json,
  strutils,
  os,
  chronicles,
  eth/common,
  ../nimbus/transaction,
  ../nimbus/launcher,
  ./js_tracer,
  ./parser,
  ./downloader

proc fakeAlloc(n: JsonNode) =
  const chunk = repeat('0', 64)

  for i in 1 ..< n.len:
    if not n[i].hasKey("memory"):
      return
    let
      prevMem = n[i - 1]["memory"]
      currMem = n[i]["memory"]
      prevPc = n[i - 1]["pc"].getInt()
      currPc = n[i]["pc"].getInt()

    if currMem.len > prevMem.len and prevPc == currPc - 1:
      let diff = currMem.len - prevMem.len
      for _ in 0 ..< diff:
        prevMem.add %chunk

proc updateAccount*(a, b: JsonNode) =
  if b.hasKey("name"):
    a["name"] = newJString(b["name"].getStr)
  a["balance"] = newJString(b["balance"].getStr)
  a["nonce"] = newJString(b["nonce"].getStr)
  a["code"] = newJString(b["code"].getStr)
  var storage = a["storage"]
  for k, v in b["storage"]:
    storage[k] = newJString(v.getStr)
  a["storageRoot"] = newJString(b["storageRoot"].getStr)
  a["codeHash"] = newJString(b["codeHash"].getStr)

proc copyAccount*(acc: JsonNode): JsonNode =
  result = newJObject()
  result["storage"] = newJObject()
  updateAccount(result, acc)

proc removePostStateDup*(postState: JsonNode): JsonNode =
  var accounts = newJObject()
  for acc in postState:
    let address = acc["address"].getStr
    if accounts.hasKey(address):
      updateAccount(accounts[address], acc)
    else:
      accounts[address] = copyAccount(acc)
  accounts

proc processNimbusData*(nimbus: JsonNode) =
  # remove duplicate accounts with same address
  # and only take newest one
  let postState = nimbus["stateDump"]["after"]
  nimbus["stateDump"]["after"] = removePostStateDup(postState)

  let txTraces = nimbus["txTraces"]

  for trace in txTraces:
    trace["structLogs"].fakeAlloc()

proc generatePremixData*(nimbus, geth: JsonNode) =
  var premixData = %{"nimbus": nimbus, "geth": geth}

  var data = "var premixData = " & premixData.pretty & "\n"
  writeFile(getFileDir("index.html") / "premixData.js", data)

proc hasInternalTx(
    tx: Transaction, blockNumber: BlockNumber, sender: EthAddress
): bool =
  let
    number = %(blockNumber.prefixHex)
    recipient = tx.getRecipient(sender)
    code = request("eth_getCode", %[%recipient.prefixHex, number])
    recipientHasCode = code.getStr.len > 2 # "0x"

  if tx.contractCreation:
    return recipientHasCode or tx.payload.len > 0

  recipientHasCode

proc jsonTracer(tracer: string): JsonNode =
  result = %{"tracer": %tracer}

proc requestInternalTx(txHash, tracer: JsonNode): JsonNode =
  let txTrace = request("debug_traceTransaction", %[txHash, tracer])
  if txTrace.kind == JNull:
    error "requested postState not available", txHash = txHash
    raise newException(ValueError, "Error when retrieving transaction postState")
  result = txTrace

proc requestAccount*(premix: JsonNode, blockNumber: BlockNumber, address: EthAddress) =
  let
    number = %(blockNumber.prefixHex)
    address = address.prefixHex
    proof = request("eth_getProof", %[%address, %[], number])

  let account =
    %{
      "address": %address,
      "codeHash": proof["codeHash"],
      "storageRoot": proof["storageHash"],
      "balance": proof["balance"],
      "nonce": proof["nonce"],
      "code": newJString("0x"),
      "storage": newJObject(),
      "accountProof": proof["accountProof"],
      "storageProof": proof["storageProof"],
    }
  premix.add account

proc padding(x: string): JsonNode =
  let val = x.substr(2)
  let pad = repeat('0', 64 - val.len)
  result = newJString("0x" & pad & val)

proc updateAccount*(address: string, account: JsonNode, blockNumber: BlockNumber) =
  let number = %(blockNumber.prefixHex)

  var storage = newJArray()
  for k, _ in account["storage"]:
    storage.add %k

  let proof = request("eth_getProof", %[%address, storage, number])
  account["address"] = %address
  account["codeHash"] = proof["codeHash"]
  account["storageRoot"] = proof["storageHash"]
  account["nonce"] = proof["nonce"]
  account["balance"] = proof["balance"]
  account["accountProof"] = proof["accountProof"]
  account["storageProof"] = proof["storageProof"]
  for x in proof["storageProof"]:
    x["value"] = padding(x["value"].getStr())
    account["storage"][x["key"].getStr] = x["value"]

proc requestPostState*(premix, n: JsonNode, blockNumber: BlockNumber) =
  type TxKind {.pure.} = enum
    Regular
    ContractCreation
    ContractCall

  let txs = n["transactions"]
  if txs.len == 0:
    return

  let tracer = jsonTracer(postStateTracer)
  for t in txs:
    var txKind = TxKind.Regular
    let tx = parseTransaction(t)
    let sender = tx.getSender
    if tx.contractCreation:
      txKind = TxKind.ContractCreation
    if hasInternalTx(tx, blockNumber, sender):
      let txTrace = requestInternalTx(t["hash"], tracer)
      for address, account in txTrace:
        updateAccount(address, account, blockNumber)
        premix.add account
      if not tx.contractCreation:
        txKind = TxKind.ContractCall
    else:
      premix.requestAccount(blockNumber, tx.getRecipient(sender))
      premix.requestAccount(blockNumber, sender)

    t["txKind"] = %($txKind)

proc requestPostState*(thisBlock: Block): JsonNode =
  let blockNumber = thisBlock.header.number
  var premix = newJArray()

  premix.requestPostState(thisBlock.jsonData, blockNumber)
  premix.requestAccount(blockNumber, thisBlock.header.coinbase)
  for uncle in thisBlock.body.uncles:
    premix.requestAccount(blockNumber, uncle.coinbase)

  removePostStateDup(premix)
