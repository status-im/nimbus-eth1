# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth_common,
  ../constants, ../validation, ../vm_types

proc `origin=`*(message: var Message, value: EthAddress) =
  message.internalOrigin = value

proc `codeAddress=`*(message: var Message, value: EthAddress) =
  message.internalCodeAddress = value

proc `storageAddress=`*(message: var Message, value: EthAddress) =
  message.internalStorageAddress = value

proc newMessageOptions*(
    origin = ZERO_ADDRESS,
    depth: int = 0,
    createAddress = ZERO_ADDRESS,
    codeAddress = ZERO_ADDRESS,
    flags: MsgFlags = static(emvcNoFlags)): MessageOptions =

  result = MessageOptions(
    origin: origin,
    depth: depth,
    createAddress: createAddress,
    codeAddress: codeAddress,
    flags: flags)

proc newMessage*(
    gas: GasInt,
    gasPrice: GasInt,
    to: EthAddress,
    sender: EthAddress,
    value: UInt256,
    data: seq[byte],
    code: string,
    options: MessageOptions = newMessageOptions()): Message =

  validateGte(options.depth, minimum=0, title="Message.depth")

  new(result)
  result.gas = gas
  result.gasPrice = gasPrice
  result.destination = to
  result.sender = sender
  result.value = value
  result.data = data
  result.depth = options.depth
  result.storageAddress = options.createAddress
  result.codeAddress = options.codeAddress
  result.flags = options.flags
  result.code = code

  if options.origin != ZERO_ADDRESS:
    result.internalOrigin = options.origin
  else:
    result.internalOrigin = sender

proc origin*(message: Message): EthAddress =
  if message.internalOrigin != ZERO_ADDRESS:
    message.internalOrigin
  else:
    message.sender

proc isOrigin*(message: Message): bool =
  message.sender == message.origin

proc codeAddress*(message: Message): EthAddress =
  if message.internalCodeAddress != ZERO_ADDRESS:
    message.internalCodeAddress
  else:
    message.destination

proc `storageAddress`*(message: Message): EthAddress =
  if message.internalStorageAddress != ZERO_ADDRESS:
    message.internalStorageAddress
  else:
    message.destination

proc isCreate(message: Message): bool =
  message.destination == CREATE_CONTRACT_ADDRESS
