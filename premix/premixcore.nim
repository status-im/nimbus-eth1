import
  json, strutils, stint, parser, downloader,
  ../nimbus/tracer, chronicles, eth_common,
  js_tracer

proc fakeAlloc(n: JsonNode) =
  const
    chunk = repeat('0', 64)

  for i in 1 ..< n.len:
    if not n[i].hasKey("memory"): return
    let
      prevMem = n[i-1]["memory"]
      currMem = n[i]["memory"]

    if currMem.len > prevMem.len:
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
  var premixData = %{
    "nimbus": nimbus,
    "geth": geth
  }

  var data = "var premixData = " & premixData.pretty & "\n"
  writeFile("premixData.js", data)

type
  Premix* = object
    accounts*: JsonNode
    proofs*: JsonNode

proc initPremix*(): Premix =
  result.accounts = newJArray()
  result.proofs = newJArray()

proc hasInternalTx(tx: Transaction, blockNumber: Uint256): bool =
  let
    number = %(blockNumber.prefixHex)
    code = request("eth_getCode", %[%tx.getRecipient.prefixHex, number])
    recipientHasCode = code.getStr.len > 2 # "0x"

  if tx.isContractCreation:
    return recipientHasCode or tx.payload.len > 0

  recipientHasCode

proc jsonTracer(tracer: string): JsonNode =
  result = %{ "tracer": %tracer }

proc requestInternalTx(txHash, tracer: JsonNode): JsonNode =
  let txTrace = request("debug_traceTransaction", %[txHash, tracer])
  if txTrace.kind == JNull:
    error "requested postState not available", txHash=txHash
    raise newException(ValueError, "Error when retrieving transaction postState")
  result = txTrace

proc requestAccount*(premix: var Premix, blockNumber: Uint256, address: EthAddress) =
  let
    number = %(blockNumber.prefixHex)
    address = address.prefixHex
    proof = request("eth_getProof", %[%address, %[], number])

  let account = %{
    "address": %address,
    "codeHash": proof["codeHash"],
    "storageRoot": proof["storageHash"],
    "balance": proof["balance"],
    "nonce": proof["nonce"],
    "code": newJString("0x"),
    "storage": newJObject()
  }
  premix.accounts.add account
  premix.proofs.add proof

proc padding(x: string): JsonNode =
  let val = x.substr(2)
  let pad = repeat('0', 64 - val.len)
  result = newJString("0x" & pad & val)

proc updateAccount(address: string, account: JsonNode, blockNumber: Uint256): JsonNode =
  let number = %(blockNumber.prefixHex)

  var storage = newJArray()
  for k, _ in account["storage"]:
    storage.add %k

  let proof = request("eth_getProof", %[%address, storage, number])
  account["address"]     = %address
  account["codeHash"]    = proof["codeHash"]
  account["storageRoot"] = proof["storageHash"]
  account["nonce"]       = proof["nonce"]
  account["balance"]     = proof["balance"]
  for x in proof["storageProof"]:
    x["value"] = padding(x["value"].getStr())
    account["storage"][x["key"].getStr] = x["value"]
  proof

proc requestPostState*(premix: var Premix, n: JsonNode, blockNumber: Uint256) =
  let txs = n["transactions"]
  if txs.len == 0: return

  let tracer = jsonTracer(postStateTracer)
  for t in txs:
    let tx = parseTransaction(t)
    if hasInternalTx(tx, blockNumber):
      let txTrace = requestInternalTx(t["hash"], tracer)
      for address, account in txTrace:
        premix.proofs.add updateAccount(address, account, blockNumber)
        premix.accounts.add account
    else:
      premix.requestAccount(blockNumber, tx.getRecipient)
      premix.requestAccount(blockNumber, tx.getSender)
