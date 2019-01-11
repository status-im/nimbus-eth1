import
  json, downloader, stint, strutils, os,
  ../nimbus/tracer, chronicles, prestate,
  js_tracer, eth_common, byteutils, parser,
  nimcrypto

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

proc jsonTracer(tracer: string): JsonNode =
  result = %{ "tracer": %tracer }

proc requestTrace(txHash, tracer: JsonNode): JsonNode =
  let txTrace = request("debug_traceTransaction", %[txHash, tracer])
  if txTrace.kind == JNull:
    error "requested postState not available", txHash=txHash
    raise newException(ValueError, "Error when retrieving transaction postState")
  result = txTrace

proc requestBlockState(postState: JsonNode, thisBlock: Block, addresses: openArray[EthAddress]) =
  let number = %(thisBlock.header.blockNumber.prefixHex)

  var txTrace = newJObject()
  for a in addresses:
    let address = a.prefixHex
    let trace = request("eth_getProof", %[%address, %[], number])
    let account = %{
      "codeHash": trace["codeHash"],
      "storageRoot": trace["storageHash"],
      "balance": trace["balance"],
      "nonce": trace["nonce"],
      "code": newJString("0x"),
      "storage": newJObject()
    }
    txTrace[address] = account
  postState.add txTrace

proc hasTracerData(tx: JsonNode, blockNumber: Uint256): bool =
  let number = %(blockNumber.prefixHex)

  if tx["to"].kind == JNull:
    let t = parseTransaction(tx)
    let code = request("eth_getCode", %[%t.getRecipient.prefixHex, number])
    return code.getStr.len > 2 # "0x"

  let code = request("eth_getCode", %[tx["to"], number])
  result = code.getStr.len > 2 # "0x"

proc requestPostState(n: JsonNode, jsTracer: string, thisBlock: Block): JsonNode =
  let txs = n["transactions"]
  result = newJArray()
  if txs.len == 0: return

  let tracer = jsonTracer(jsTracer)
  for tx in txs:
    if hasTracerData(tx, thisBlock.header.blockNumber):
      let
        txHash = tx["hash"]
        txTrace = requestTrace(txHash, tracer)
      result.add txTrace
    else:
      let t = parseTransaction(tx)
      var address: array[2, EthAddress]
      address[0] = t.getRecipient
      address[1] = t.getSender
      requestBlockState(result, thisBlock, address)

proc padding(x: string): JsonNode =
  let val = x.substr(2)
  let pad = repeat('0', 64 - val.len)
  result = newJString("0x" & pad & val)

proc requestBlockState(postState: JsonNode, thisBlock: Block) =
  let number = %(thisBlock.header.blockNumber.prefixHex)

  for state in postState:
    for address, account in state:
      var storage = newJArray()
      for k, _ in account["storage"]:
        storage.add %k
      let trace = request("eth_getProof", %[%address, storage, number])
      account["codeHash"] = trace["codeHash"]
      account["storageRoot"] = trace["storageHash"]
      account["nonce"] = trace["nonce"]
      account["balance"] = trace["balance"]
      for x in trace["storageProof"]:
        account["storage"][x["key"].getStr] = padding(x["value"].getStr())

proc copyAccount(acc: JsonNode): JsonNode =
  result = newJObject()
  if acc.hasKey("name"):
    result["name"] = newJString(acc["name"].getStr)
  result["balance"] = newJString(acc["balance"].getStr)
  result["nonce"] = newJString(acc["nonce"].getStr)
  result["code"] = newJString(acc["code"].getStr)
  var storage = newJObject()
  for k, v in acc["storage"]:
    storage[k] = newJString(v.getStr)
  result["storage"] = storage
  result["storageRoot"] = newJString(acc["storageRoot"].getStr)
  result["codeHash"] = newJString(acc["codeHash"].getStr)

proc updateAccount(a, b: JsonNode) =
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

proc processPostState(postState: JsonNode): JsonNode =
  var accounts = newJObject()

  for state in postState:
    for address, account in state:
      if accounts.hasKey(address):
        updateAccount(accounts[address], account)
      else:
        accounts[address] = copyAccount(account)

  result = accounts

proc removePostStateDup(nimbus: JsonNode) =
  let postState = nimbus["stateDump"]["after"]
  var accounts = newJObject()
  for acc in postState:
    let address = acc["address"].getStr
    if accounts.hasKey(address):
      updateAccount(accounts[address], acc)
    else:
      accounts[address] = copyAccount(acc)
  nimbus["stateDump"]["after"] = accounts

proc requestPostState(thisBlock: Block): JsonNode =
  let postState = requestPostState(thisBlock.jsonData, postStateTracer, thisBlock)
  requestBlockState(postState, thisBlock)

  var addresses = @[thisBlock.header.coinbase]
  for uncle in thisBlock.body.uncles:
    addresses.add uncle.coinbase

  requestBlockState(postState, thisBlock, addresses)
  processPostState(postState)

proc generatePremixData(nimbus: JsonNode, blockNumber: Uint256, thisBlock: Block, accounts: JsonNode) =
  let
    receipts = toJson(thisBlock.receipts)
    txTraces = nimbus["txTraces"]

  for trace in txTraces:
    trace["structLogs"].fakeAlloc()

  var geth = %{
    "blockNumber": %blockNumber.toHex,
    "txTraces": thisBlock.traces,
    "receipts": receipts,
    "block": thisBlock.jsonData,
    "accounts": accounts
  }

  var premixData = %{
    "nimbus": nimbus,
    "geth": geth
  }

  var data = "var premixData = " & premixData.pretty & "\n"
  writeFile("premixData.js", data)

proc printDebugInstruction(blockNumber: Uint256) =
  var text = """

Successfully created debugging environment for block $1.
You can continue to find nimbus EVM bug by viewing premix report page `./index.html`.
After that you can try to debug that single block using `nim c -r debug block$1.json` command.

Happy bug hunting
""" % [$blockNumber]

  echo text

proc main() =
  if paramCount() == 0:
    echo "usage: premix debugxxx.json"
    quit(QuitFailure)

  try:
    let
      nimbus      = json.parseFile(paramStr(1))
      blockNumber = UInt256.fromHex(nimbus["blockNumber"].getStr())
      thisBlock   = downloader.requestBlock(blockNumber, {DownloadReceipts, DownloadTxTrace})
      accounts    = requestPostState(thisBlock)

    removePostStateDup(nimbus)
    generatePremixData(nimbus, blockNumber, thisBlock, accounts)
    generatePrestate(nimbus, blockNumber, thisBlock)
    printDebugInstruction(blockNumber)
  except:
    echo getCurrentExceptionMsg()

main()
