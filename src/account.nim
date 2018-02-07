import
  constants, errors, ttmath, rlp

type
  Account* = ref object
    nonce*:             Int256
    balance*:           Int256
    #storageRoot*:       
    #codeHash*:

rlpFields Account, nonce, balance

proc newAccount*(nonce: Int256 = 0.i256, balance: Int256 = 0.i256): Account =
  Account(nonce: nonce, balance: balance)
