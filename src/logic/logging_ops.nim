import
  strformat, macros,
  ../constants, ../errors, ../computation, .. / vm / [stack, memory, gas_meter, message], .. / utils / bytes, bigints

{.this: computation.}
{.experimental.}

using
  computation: var BaseComputation

macro logXX(topicCount: static[int]): untyped =
  if topicCount < 0 or topicCount > 4:
    error(&"Invalid log topic size {topicCount}  Must be 0, 1, 2, 3, or 4")
    return

  let name = ident(&"log{topicCount}")
  let computation = ident("computation")
  let topics = ident("topics")
  let topicsTuple = ident("topicsTuple")
  let size = ident("size")
  let memStartPosition = ident("memStartPosition")
  result = quote:
    proc `name`*(`computation`: var BaseComputation) =
      let (`memStartPosition`, `size`) = `computation`.stack.popInt(2)
      var `topics`: seq[Int256]

  var topicCode: NimNode
  if topicCount == 0:
    topicCode = quote:
      `topics` = @[]
  elif topicCount > 1:
    topicCode = quote:
      let `topicsTuple` = `computation`.stack.popInt(`topicCount`)
    topicCode = nnkStmtList.newTree(topicCode)
    for z in 0 ..< topicCount:
      let topicPush = quote:
        `topics`.add(`topicsTuple`[`z`])
      topicCode.add(topicPush)
  else:
    topicCode = quote:
      `topics` = @[`computation`.stack.popInt()]

  result.body.add(topicCode)

  let logicCode = quote:
    let dataGasCost = constants.GAS_LOG_DATA * `size`
    let topicGasCost = constants.GAS_LOG_TOPIC * `topicCount`.i256
    let totalGasCost = dataGasCost + topicGasCost
    `computation`.gasMeter.consumeGas(totalGasCost, reason="Log topic and data gas cost")
    `computation`.extendMemory(`memStartPosition`, `size`)
    let logData = `computation`.memory.read(`memStartPosition`, `size`).toCString
    `computation`.addLogEntry(
        account=`computation`.msg.storageAddress,
        topics=`topics`,
        data=log_data)

  result.body.add(logicCode)
  # echo result.repr

logXX(0)
logXX(1)
logXX(2)
logXX(3)
logXX(4)
