# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  strformat,
  ranges/typedranges,
  ./impl_std_import,
  ../../../db/state_db

proc balance*(computation: var BaseComputation) =
  let address = computation.stack.popAddress()
  let balance = computation.vmState.readOnlyStateDB.getBalance(address)
  computation.stack.push balance

proc origin*(computation: var BaseComputation) =
  computation.stack.push(computation.msg.origin)

proc address*(computation: var BaseComputation) =
  computation.stack.push(computation.msg.storageAddress)

proc caller*(computation: var BaseComputation) =
  computation.stack.push(computation.msg.sender)

proc callValue*(computation: var BaseComputation) =
  computation.stack.push(computation.msg.value)

proc writePaddedResult(mem: var Memory,
                       data: openarray[byte],
                       memPos, dataPos, len: Natural,
                       paddingValue = 0.byte) =
  mem.extend(memPos, len)

  let dataEndPosition = dataPos + len - 1
  if dataEndPosition < data.len:
    mem.write(memPos, data[dataPos .. dataEndPosition])
  else:
    var presentElements = data.len - dataPos
    if presentElements > 0:
      mem.write(memPos, data.toOpenArray(dataPos, data.len - 1))
    else:
      presentElements = 0

    mem.writePaddingBytes(memPos + presentElements,
                          len - presentElements,
                          paddingValue)

proc callDataLoad*(computation: var BaseComputation) =
  # Load call data into memory
  let
    dataPos = computation.stack.popInt.toInt
    dataEndPosition = dataPos + 32 - 1

  if dataEndPosition < computation.msg.data.len:
    computation.stack.push(computation.msg.data[dataPos .. dataEndPosition])
  else:
    var bytes: array[32, byte]
    var presentBytes = computation.msg.data.len - dataPos

    if presentBytes > 0:
      copyMem(addr bytes[0], addr computation.msg.data[dataPos], presentBytes)
    else:
      presentBytes = 0

    for i in presentBytes ..< 32: bytes[i] = 0
    computation.stack.push(bytes)

proc callDataSize*(computation: var BaseComputation) =
  let size = computation.msg.data.len.u256
  computation.stack.push(size)

proc callDataCopy*(computation: var BaseComputation) =
  let (memStartPosition,
       calldataStartPosition,
       size) = computation.stack.popInt(3)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CallDataCopy].d_handler(size),
    reason="CALLDATACOPY fee")

  let (memPos, callPos, len) = (memStartPosition.toInt, calldataStartPosition.toInt, size.toInt)

  computation.memory.writePaddedResult(computation.msg.data,
                                       memPos, callPos, len)

proc codeSize*(computation: var BaseComputation) =
  let size = computation.code.len.u256
  computation.stack.push(size)

proc codeCopy*(computation: var BaseComputation) =
  let (memStartPosition,
       codeStartPosition,
       size) = computation.stack.popInt(3)

  computation.gasMeter.consumeGas(
    computation.gasCosts[CodeCopy].d_handler(size),
    reason="CODECOPY: word gas cost")

  let (memPos, codePos, len) = (memStartPosition.toInt, codeStartPosition.toInt, size.toInt)

  computation.memory.writePaddedResult(computation.code.bytes, memPos, codePos, len)

proc gasPrice*(computation: var BaseComputation) =
  computation.stack.push(computation.msg.gasPrice.u256)

proc extCodeSize*(computation: var BaseComputation) =
  let account = computation.stack.popAddress()
  let codeSize = computation.vmState.readOnlyStateDB.getCode(account).len
  computation.stack.push uint(codeSize)

proc extCodeCopy*(computation: var BaseComputation) =
  let account = computation.stack.popAddress()
  let (memStartPosition, codeStartPosition, size) = computation.stack.popInt(3)

  computation.gasMeter.consumeGas(
    computation.gasCosts[ExtCodeCopy].d_handler(size),
    reason="EXTCODECOPY: word gas cost"
    )

  let (memPos, codePos, len) = (memStartPosition.toInt, codeStartPosition.toInt, size.toInt)
  let codeBytes = computation.vmState.readOnlyStateDB.getCode(account)

  computation.memory.writePaddedResult(codeBytes.toOpenArray, memPos, codePos, len)

proc returnDataSize*(computation: var BaseComputation) =
  let size = computation.returnData.len.u256
  computation.stack.push(size)

proc returnDataCopy*(computation: var BaseComputation) =
  let (memStartPosition, returnDataStartPosition, size) = computation.stack.popInt(3)

  computation.gasMeter.consumeGas(
    computation.gasCosts[ReturnDataCopy].d_handler(size),
    reason="RETURNDATACOPY fee"
    )

  let (memPos, returnPos, len) = (memStartPosition.toInt, returnDataStartPosition.toInt, size.toInt)
  if returnPos + len > computation.returnData.len:
    raise newException(OutOfBoundsRead,
      "Return data length is not sufficient to satisfy request.  Asked \n" &
      &"for data from index {returnDataStartPosition} to {returnDataStartPosition + size}. Return data is {computation.returnData.len} in \n" &
      "length")

  computation.memory.extend(memPos, len)

  let value = ($computation.returnData)[returnPos ..< returnPos + len]
  computation.memory.write(memPos, len, value)
