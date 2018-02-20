import
  constants, errors, ttmath, rlp

type
  Account* = ref object
    nonce*:             UInt256
    balance*:           UInt256
    storageRoot*:       string
    codeHash*:          string

rlpFields Account, nonce, balance

proc newAccount*(nonce: UInt256 = 0.u256, balance: UInt256 = 0.u256): Account =
  Account(nonce: nonce, balance: balance)
