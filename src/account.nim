import
  constants, errors, bigints

type
  Account* = ref object
    nonce*:             Int256
    balance*:           Int256
    #storageRoot*:       
    #codeHash*:

proc newAccount*(nonce: Int256 = 0.i256, balance: Int256 = 0.i256): Account =
  Account(nonce: nonce, balance: balance)
