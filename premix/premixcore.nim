import json, strutils

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

proc copyAccount*(acc: JsonNode): JsonNode =
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

proc processNimbusData*(nimbus: JsonNode) =
  # remove duplicate accounts with same address
  # and only take newest one
  removePostStateDup(nimbus)

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
