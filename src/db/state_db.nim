import
  strformat, tables,
  ../constants, ../errors, ../validation, ../account, ../logging, bigints

type
  AccountStateDB* = ref object
    db*: Table[cstring, Int256]

proc newAccountStateDB*(db: Table[cstring, Int256], readOnly: bool = false): AccountStateDB =
  result = AccountStateDB(db: db)

proc logger*(db: AccountStateDB): Logger =
  logging.getLogger("db.State")

proc getAccount(db: AccountStateDB, address: cstring): Account = 
  # let rlpAccount = db.trie[address]
  # if not rlpAccount.isNil:
  #   account = rlp.decode[Account](rlpAccount)
  #   account.mutable = true
  # else:
  #   account = newAccount()
  result = newAccount() # TODO

proc setAccount(db: AccountStateDB, address: cstring, account: Account) =
  # db.trie[address] = rlp.encode[Account](account)
  discard # TODO 

# public

proc getBalance*(db: AccountStateDB, address: cstring): Int256 =
  validateCanonicalAddress(address, title="Storage Address")
  let account = db.getAccount(address)
  account.balance

proc setBalance*(db: var AccountStateDB, address: cstring, balance: Int256) =
  validateCanonicalAddress(address, title="Storage Address")
  let account = db.getAccount(address)
  account.balance = balance
  db.setAccount(address, account)

proc deltaBalance*(db: var AccountStateDB, address: cstring, delta: Int256) =
  db.setBalance(address, db.getBalance(address) + delta)

