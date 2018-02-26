import
  strformat, tables,
  ../constants, ../errors, ../validation, ../account, ../logging, ../utils_numeric, .. / utils / [padding, bytes, keccak], ttmath, rlp

type
  AccountStateDB* = ref object
    db*: Table[string, Bytes]
    rootHash*: string # TODO trie

proc newAccountStateDB*(db: Table[string, string], readOnly: bool = false): AccountStateDB =
  result = AccountStateDB(db: initTable[string, Bytes]())

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

proc getBalance*(db: AccountStateDB, address: string): UInt256 =
  validateCanonicalAddress(address, title="Storage Address")
  let account = db.getAccount(address)
  account.balance

proc setBalance*(db: var AccountStateDB, address: string, balance: UInt256) =
  validateCanonicalAddress(address, title="Storage Address")
  let account = db.getAccount(address)
  account.balance = balance
  db.setAccount(address, account)

proc deltaBalance*(db: var AccountStateDB, address: string, delta: UInt256) =
  db.setBalance(address, db.getBalance(address) + delta)


proc setStorage*(db: var AccountStateDB, address: string, slot: UInt256, value: UInt256) =
  #validateGte(value, 0, title="Storage Value")
  #validateGte(slot, 0, title="Storage Slot")
  validateCanonicalAddress(address, title="Storage Address")
  
  # TODO
  # let account = db.getAccount(address)
  # var storage = HashTrie(HexaryTrie(self.db, account.storageRoot))

  let slotAsKey = slot.intToBigEndian.pad32.toString
  var storage = db.db
  # TODO fix
  if value > 0:
    let encodedValue = rlp.encode(value)
    storage[slotAsKey] = encodedValue.bytes[encodedValue.ibegin..<encodedValue.iend]
  else:
    storage.del(slotAsKey)
  #storage[slotAsKey] = value
  # account.storageRoot = storage.rootHash
  # db.setAccount(address, account)

proc getStorage*(db: var AccountStateDB, address: string, slot: UInt256): (UInt256, bool) =
  validateCanonicalAddress(address, title="Storage Address")
  #validateGte(slot, 0, title="Storage Slot")
  
  # TODO
  # make it more correct
  # for now, we just use a table
  
  # let account = db.GetAccount(address)
  # var storage = HashTrie(HexaryTrie(self.db, account.storageRoot))

  let slotAsKey = slot.intToBigEndian.pad32.toString
  var storage = db.db
  if storage.hasKey(slotAsKey):
    #result = storage[slotAsKey]
    var encodedValue = storage[slotAsKey]
    var r = rlpFromBytes(encodedValue.initBytesRange)
    result = (r.read(Bytes).bigEndianToInt, true)
  else:
    result = (0.u256, false)

proc setNonce*(db: var AccountStateDB, address: string, nonce: UInt256) =
  validateCanonicalAddress(address, title="Storage Address")
  #validateGte(nonce, 0, title="Nonce")

  var account = db.getAccount(address)
  account.nonce = nonce

  db.setAccount(address, account)

proc getNonce*(db: AccountStateDB, address: string): UInt256 =
  validateCanonicalAddress(address, title="Storage Address")

  let account = db.getAccount(address)
  return account.nonce

proc setCode*(db: var AccountStateDB, address: string, code: string) =
  validateCanonicalAddress(address, title="Storage Address")

  var account = db.getAccount(address)

  account.codeHash = keccak(code)
  #db.db[account.codeHash] = code
  db.setAccount(address, account)

proc getCode*(db: var AccountStateDB, address: string): string =
  let codeHash = db.getCodeHash(address)
  #if db.db.hasKey(codeHash):
  #  result = db.db[codeHash]
  #else:
  result = ""

# proc rootHash*(db: AccountStateDB): string =
  # TODO return self.Trie.rootHash

# proc `rootHash=`*(db: var AccountStateDB, value: string) =
  # TODO: self.Trie.rootHash = value
