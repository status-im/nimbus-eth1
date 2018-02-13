import
  strformat, tables,
  ../constants, ../errors, ../validation, ../account, ../logging, ../utils/keccak, ttmath

type
  AccountStateDB* = ref object
    db*: Table[string, string]
    rootHash*: string # TODO trie

proc newAccountStateDB*(db: Table[string, string], readOnly: bool = false): AccountStateDB =
  result = AccountStateDB(db: db)

proc logger*(db: AccountStateDB): Logger =
  logging.getLogger("db.State")

proc getAccount(db: AccountStateDB, address: string): Account = 
  # let rlpAccount = db.trie[address]
  # if not rlpAccount.isNil:
  #   account = rlp.decode[Account](rlpAccount)
  #   account.mutable = true
  # else:
  #   account = newAccount()
  result = newAccount() # TODO

proc setAccount(db: AccountStateDB, address: string, account: Account) =
  # db.trie[address] = rlp.encode[Account](account)
  discard # TODO 


proc getCodeHash*(db: AccountStateDB, address: string): string =
  validateCanonicalAddress(address, title="Storage Address")
  let account = db.getAccount(address)
  result = account.codeHash

proc getBalance*(db: AccountStateDB, address: string): Int256 =
  validateCanonicalAddress(address, title="Storage Address")
  let account = db.getAccount(address)
  account.balance

proc setBalance*(db: var AccountStateDB, address: string, balance: Int256) =
  validateCanonicalAddress(address, title="Storage Address")
  let account = db.getAccount(address)
  account.balance = balance
  db.setAccount(address, account)

proc deltaBalance*(db: var AccountStateDB, address: string, delta: Int256) =
  db.setBalance(address, db.getBalance(address) + delta)


proc setStorage*(db: var AccountStateDB, address: string, slot: Int256, value: Int256) =
  validateGte(value, 0, title="Storage Value")
  validateGte(slot, 0, title="Storage Slot")
  validateCanonicalAddress(address, title="Storage Address")

  let account = db.getAccount(address)
  # TODO
  # var storage = HashTrie(HexaryTrie(self.db, account.storageRoot))

  # let slotAsKey = pad32(intToBigEndian(slot))

  # if value:
  #   let encodedValue = rlp.encode(value)
  #   storage[slotAsKey] = encodedValue
  # else:
  #   del storage[slotAsKey]

  # account.storageRoot = storage.rootHash
  # db.setAccount(address, account)

proc getStorage*(db: var AccountStateDB, address: string, slot: Int256): Int256 =
  validateCanonicalAddress(address, title="Storage Address")
  validateGte(slot, 0, title="Storage Slot")
  0.i256
  
  # TODO
  # let account = db.GetAccount(address)
  # var storage = HashTrie(HexaryTrie(self.db, account.storageRoot))

  # let slotAsKey = pad32(intToBigEndian(slot))

  # if slotAsKey in storage:
  #   let encodedValue = storage[slotAsKey]
  #   return rlp.decode(encodedValue)
  # else:
  #   return 0.i256

proc setNonce*(db: var AccountStateDB, address: string, nonce: Int256) =
  validateCanonicalAddress(address, title="Storage Address")
  validateGte(nonce, 0, title="Nonce")

  var account = db.getAccount(address)
  account.nonce = nonce

  db.setAccount(address, account)

proc getNonce*(db: AccountStateDB, address: string): Int256 =
  validateCanonicalAddress(address, title="Storage Address")

  let account = db.getAccount(address)
  return account.nonce

proc setCode*(db: var AccountStateDB, address: string, code: string) =
  validateCanonicalAddress(address, title="Storage Address")

  var account = db.getAccount(address)

  account.codeHash = keccak(code)
  db.db[account.codeHash] = code
  db.setAccount(address, account)

proc getCode*(db: var AccountStateDB, address: string): string =
  let codeHash = db.getCodeHash(address)
  if db.db.hasKey(codeHash):
    result = db.db[codeHash]
  else:
    result = ""

# proc rootHash*(db: AccountStateDB): string =
  # TODO return self.Trie.rootHash

# proc `rootHash=`*(db: var AccountStateDB, value: string) =
  # TODO: self.Trie.rootHash = value
