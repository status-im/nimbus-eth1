import 
    ../logging, ../constants, ../validation

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

    gas*:                     Int256
    gasPrice*:                Int256
    to*:                      cstring
    sender*:                  cstring    
    value*:                   Int256
    data*:                    cstring
    code*:                    cstring
    internalOrigin:           cstring
    internalCodeAddress:      cstring
    depth*:                   Int256
    internalStorageAddress:   cstring
    shouldTransferValue*:     bool
    isStatic*:                bool

proc `origin=`*(message: var Message, value: cstring) =
  message.internalOrigin = value

proc `codeAddress=`*(message: var Message, value: cstring) =
  message.internalCodeAddress = value

proc `storageAddress=`*(message: var Message, value: cstring) =
  message.internalStorageAddress = value

proc newMessage*(
    gas: Int256,
    gasPrice: Int256,
    to: cstring,
    sender: cstring,
    value: Int256,
    data: cstring,
    code: cstring,
    origin: cstring = nil,
    depth: Int256 = 0.Int256,
    createAddress: cstring = nil,
    codeAddress: cstring = nil,
    shouldTransferValue: bool = true,
    isStatic: bool = false): Message =
    
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

  if not origin.isNil:
    validateCanonicalAddress(origin, title="Message.origin")
  result.internalOrigin = origin

  validateGte(depth, minimum=0, title="Message.depth")
  result.depth = depth

  result.code = code

  if not createAddress.isNil:
    validateCanonicalAddress(createAddress, title="Message.storage_address")
  result.storageAddress = createAddress

  if not codeAddress.isNil:
    validateCanonicalAddress(codeAddress, title="Message.code_address")
  result.codeAddress = codeAddress

  result.shouldTransferValue = shouldTransferValue

  result.isStatic = isStatic

proc origin*(message: Message): cstring =
  if not message.internalOrigin.isNil:
    message.internalOrigin
  else:
    message.sender

proc isOrigin*(message: Message): bool =
  message.sender == message.origin

proc codeAddress*(message: Message): cstring =
  if not message.internalCodeAddress.isNil:
    message.internalCodeAddress
  else:
    message.to

proc `storageAddress`*(message: Message): cstring =
  if not message.internalStorageAddress.isNil:
    message.internalStorageAddress
  else:
    message.to

proc isCreate(message: Message): bool =
  message.to == CREATE_CONTRACT_ADDRESS
