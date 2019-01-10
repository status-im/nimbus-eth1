import
  json, downloader, stint, strutils, os,
  ../nimbus/tracer, chronicles, prestate

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

proc requestPostState(n: JsonNode, jsTracer: string): JsonNode =
  let txs = n["transactions"]
  if txs.len > 0:
    result = newJArray()
    let tracer = %{
      "tracer": %jsTracer
    }
    for tx in txs:
      let txHash = tx["hash"]
      let txTrace = request("debug_traceTransaction", %[txHash, tracer])
      if txTrace.kind == JNull:
        error "requested postState not available", txHash=txHash
        raise newException(ValueError, "Error when retrieving transaction postState")
      result.add txTrace

proc requestLastPostState(n: JsonNode, jsTracer: string, arr: JsonNode) =
  let txs = n["transactions"]
  if txs.len > 0:
    let tracer = %{
      "tracer": %jsTracer
    }

    let
      tx = txs[txs.len - 1]
      txHash = tx["hash"]
      txTrace = request("debug_traceTransaction", %[txHash, tracer])
    if txTrace.kind == JNull:
      error "requested postState not available", txHash=txHash
      raise newException(ValueError, "Error when retrieving transaction postState")
    arr.add txTrace

proc requestPostState(thisBlock: Block): JsonNode =
  let
    tmp = readFile("poststate_tracer.js.template")
    tracer = tmp % [ $thisBlock.jsonData["miner"] ]
  result = requestPostState(thisBlock.jsonData, tracer)

  var uncles = ""
  for i, uncle in thisBlock.body.uncles:
    uncles.add $uncle.coinbase
    if i < thisBlock.body.uncles.len - 1:
      uncles.add ", "

  if uncles.len > 0:
    let tracer = tmp % [uncles]
    requestLastPostState(thisBlock.jsonData, tracer, result)

proc copyAccount(acc: JsonNode): JsonNode =
  result = newJObject()
  result["balance"] = newJString(acc["balance"].getStr)
  result["nonce"] = newJString(toHex(acc["nonce"].getInt))
  result["code"] = newJString(acc["code"].getStr)
  var storage = newJObject()
  for k, v in acc["storage"]:
    storage[k] = newJString(v.getStr)
  result["storage"] = storage

proc updateAccount(a, b: JsonNode) =
  a["balance"] = newJString(b["balance"].getStr)
  a["nonce"] = newJString(toHex(b["nonce"].getInt))
  a["code"] = newJString(b["code"].getStr)
  var storage = a["storage"]
  for k, v in b["storage"]:
    storage[k] = newJString(v.getStr)

proc processPostState(postState: JsonNode): JsonNode =
  var accounts = newJObject()

  for state in postState:
    for address, account in state:
      if accounts.hasKey(address):
        updateAccount(accounts[address], account)
      else:
        accounts[address] = copyAccount(account)

  result = accounts

proc generatePremixData(nimbus: JsonNode, blockNumber: Uint256, thisBlock: Block, postState, accounts: JsonNode) =
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
    "postState": postState,
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
      postState   = requestPostState(thisBlock)
      accounts    = processPostState(postState)

    generatePremixData(nimbus, blockNumber, thisBlock, postState, accounts)
    generatePrestate(nimbus, blockNumber, thisBlock)
    printDebugInstruction(blockNumber)
  except:
    echo getCurrentExceptionMsg()

main()
