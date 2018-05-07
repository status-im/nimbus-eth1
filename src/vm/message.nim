# Nimbus
# Copyright (c) 2018 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE) or http://www.apache.org/licenses/LICENSE-2.0)
#  * MIT license ([LICENSE-MIT](LICENSE-MIT) or http://opensource.org/licenses/MIT)
# at your option. This file may not be copied, modified, or distributed except according to those terms.

import
    ../logging, ../constants, ../validation, stint

type
  Message* = ref object
    # A message for VM computation

    # depth = None

    # code = None
    # codeAddress = None

    # createAddress = None

    # shouldTransferValue = None
    # isStatic = None

    # logger = logging.getLogger("evm.vm.message.Message")

    gas*:                     UInt256
    gasPrice*:                UInt256
    to*:                      string
    sender*:                  string
    value*:                   UInt256
    data*:                    seq[byte]
    code*:                    string
    internalOrigin:           string
    internalCodeAddress:      string
    depth*:                   int
    internalStorageAddress:   string
    shouldTransferValue*:     bool
    isStatic*:                bool
    isCreate*:                bool

  MessageOptions* = ref object
    origin*:                  string
    depth*:                   int
    createAddress*:           string
    codeAddress*:             string
    shouldTransferValue*:     bool
    isStatic*:                bool

proc `origin=`*(message: var Message, value: string) =
  message.internalOrigin = value

proc `codeAddress=`*(message: var Message, value: string) =
  message.internalCodeAddress = value

proc `storageAddress=`*(message: var Message, value: string) =
  message.internalStorageAddress = value

proc newMessageOptions*(
    origin: string = "",
    depth: int = 0,
    createAddress: string = "",
    codeAddress: string = "",
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
    gas: UInt256,
    gasPrice: UInt256,
    to: string,
    sender: string,
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

  if not options.origin.isNil:
    validateCanonicalAddress(options.origin, title="Message.origin")
  result.internalOrigin = options.origin

  validateGte(options.depth, minimum=0, title="Message.depth")
  result.depth = options.depth

  result.code = code

  if not options.createAddress.isNil:
    validateCanonicalAddress(options.createAddress, title="Message.storage_address")
  result.storageAddress = options.createAddress

  if not options.codeAddress.isNil:
    validateCanonicalAddress(options.codeAddress, title="Message.code_address")
  result.codeAddress = options.codeAddress

  result.shouldTransferValue = options.shouldTransferValue

  result.isStatic = options.isStatic

proc origin*(message: Message): string =
  if not message.internalOrigin.len == 0:
    message.internalOrigin
  else:
    message.sender

proc isOrigin*(message: Message): bool =
  message.sender == message.origin

proc codeAddress*(message: Message): string =
  if not message.internalCodeAddress.len == 0:
    message.internalCodeAddress
  else:
    message.to

proc `storageAddress`*(message: Message): string =
  if not message.internalStorageAddress.len == 0:
    message.internalStorageAddress
  else:
    message.to

proc isCreate(message: Message): bool =
  message.to == CREATE_CONTRACT_ADDRESS
