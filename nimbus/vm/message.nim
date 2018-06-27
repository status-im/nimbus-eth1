# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
  eth_common,
  ../logging, ../constants, ../validation, ../vm_types

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
    shouldTransferValue: bool = true,
    isStatic: bool = false): MessageOptions =

  result = MessageOptions(
    origin: origin,
    depth: depth,
    createAddress: createAddress,
    codeAddress: codeAddress,
    shouldTransferValue: shouldTransferValue,
    isStatic: isStatic)

proc newMessage*(
    gas: GasInt,
    gasPrice: GasInt,
    to: EthAddress,
    sender: EthAddress,
    value: UInt256,
    data: seq[byte],
    code: string,
    options: MessageOptions = newMessageOptions()): Message =

  new(result)
  result.gas = gas
  result.gasPrice = gasPrice

  if to != CREATE_CONTRACT_ADDRESS:
    validateCanonicalAddress(to, title="Message.to")
  result.to = to

  validateCanonicalAddress(sender, title="Message.sender")
  result.sender = sender

  result.value = value

  result.data = data

  result.internalOrigin = options.origin

  validateGte(options.depth, minimum=0, title="Message.depth")
  result.depth = options.depth

  result.code = code

  result.storageAddress = options.createAddress

  result.codeAddress = options.codeAddress

  result.shouldTransferValue = options.shouldTransferValue

  result.isStatic = options.isStatic

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
    message.to

proc `storageAddress`*(message: Message): EthAddress =
  if message.internalStorageAddress != ZERO_ADDRESS:
    message.internalStorageAddress
  else:
    message.to

proc isCreate(message: Message): bool =
  message.to == CREATE_CONTRACT_ADDRESS
