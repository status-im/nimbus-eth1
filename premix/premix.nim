# Nimbus
# Copyright (c) 2020-2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or
#    http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or
#    http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except
# according to those terms.

import
  std/[json, strutils, os],
  downloader, stint,
  ../nimbus/tracer, prestate,
  eth/common, premixcore

proc generateGethData(thisBlock: Block, blockNumber: UInt256, accounts: JsonNode): JsonNode =
  let
    receipts = toJson(thisBlock.receipts)

  let geth = %{
    "blockNumber": %blockNumber.toHex,
    "txTraces": thisBlock.traces,
    "receipts": receipts,
    "block": thisBlock.jsonData,
    "accounts": accounts
  }

  result = geth

proc printDebugInstruction(blockNumber: UInt256) =
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
      chainId     = nimbus["chainId"].getInt().ChainId
      blockNumber = UInt256.fromHex(nimbus["blockNumber"].getStr())
      thisBlock   = requestBlock(
        blockNumber, chainId, {DownloadReceipts, DownloadTxTrace})
      accounts    = requestPostState(thisBlock, chainId)
      geth        = generateGethData(thisBlock, blockNumber, accounts)
      parentNumber = blockNumber - 1.u256
      parentBlock  = requestBlock(parentNumber, chainId)

    processNimbusData(nimbus)

    # premix data goes to report page
    generatePremixData(nimbus, geth)

    # prestate data goes to debug tool and contains data
    # needed to execute single block
    generatePrestate(nimbus, geth, blockNumber, parentBlock.header, thisBlock.header, thisBlock.body)

    printDebugInstruction(blockNumber)
  except CatchableError:
    echo getCurrentExceptionMsg()

main()
