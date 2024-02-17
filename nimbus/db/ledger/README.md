`accounts_cache.nim` class diagram
==================================

```mermaid
classDiagram

  class AccountsCache {
    AccountsTrie
    SavePoint
    WitnessCache
    isDirty: bool
    %% ripemdSpecial: bool
  }
  AccountsCache *-- SavePoint
  AccountsCache *-- WitnessCache

    %% TBD: AccountsTrie

    class SavePoint {
      parent Savepoint
      cache
      selfDestruct: EthAddress []
      %% logEntries: Log []
      %% AccessList
      TransientStorage
      TransactionState
    }
    SavePoint o-- SavePoint
    SavePoint *-- cache
    SavePoint *-- TransientStorage
    SavePoint *-- TransactionState

      class cache {
        EthAddress → RefAccount
        EthAddress → RefAccount
        ...
      }
      cache o-- "*" RefAccount

        class RefAccount {
          Account
          AccountFlags
          code: seq[byte]
          original: StorageTable
          overlay: StorageTable
        }
        RefAccount o-- Account
        RefAccount *-- "*" AccountFlag
        RefAccount *-- StorageTable

          class Account {
            nonce
            balance
            storageRoot
            codeHash
          }

          class AccountFlag {
            <<enumeration>>
            Alive
            IsNew
            Dirty
            Touched
            CodeLoaded
            CodeChanged
            StorageChanged
            NewlyCreated
          }

      class TransientStorage {
        EthAddress → StorageTable
        EthAddress → StorageTable
        ...
      }
      TransientStorage *-- "*" StorageTable

      class StorageTable {
        UInt256 → UInt256
        UInt256 → UInt256
        ...
      }

      class TransactionState {
        <<enumeration>>
        Pending
        Committed
        RolledBack
      }

    class WitnessCache {
      EthAddress → WitnessData
      EthAddress → WitnessData
      ...
    }
    WitnessCache *-- WitnessData

      class WitnessData {
        storageKeys: UInt256[]
        codeTouched: bool
      }



```

<!-- To edit live in VSCode, download the Markdown Preview Mermaid Support extension -->


The file `accounts_cache.nim` has been relocated
================================================

Background
----------

The new *LedgerRef* module unifies different implementations of the
*accounts_cache*. It is intended to be used as new base method for all of the
*AccountsCache* implementations. Only constructors differ, depending on the
implementation.

This was needed to accomodate for different *CoreDb* API paradigms. While the
overloaded legacy *AccountsCache* implementation is just a closure based
wrapper around the *accounts_cache* module, the overloaded *AccountsLedgerRef*
is a closure based wrapper around the *accounts_ledger* module with the new
*CoreDb* API returning *Result[]* values and saparating the meaning of trie
root hash and trie root reference.

This allows to use the legacy hexary database (with the new *CoreDb* API) as
well as the *Aristo* database (only supported on new API.)

Instructions
------------

| **Legacy notation**    | **LedgerRef replacement**     | **Comment**
|:-----------------------|:------------------------------|----------------------
|                        |                               |
| import accounts_cache  | import ledger                 | preferred method,
| AccountsCache.init(..) | AccountsCache.init(..)        | wraps *AccountsCache*
|                        |                               | methods
|                        | *or*                          |
|                        |                               |
|                        | import ledger/accounts_cache  | stay with legacy
|                        | AccountsCache.init(..)        |  version of
|                        |                               | *AccountsCache*
| --                     |                               |
| fn(ac: AccountsCache)  | fn(ac: LedgerRef)             | function example for
|                        |                               | preferred wrapper
|                        | *or*                          | method
|                        |                               |
|                        | fn(ac: AccountsCache)         | with legacy version,
|                        |                               | no change here


### The constructor decides which *CoreDb* API is to be used

| **Legacy API constructor**     | **new API Constructor**            |
|:-------------------------------|:-----------------------------------|
|                                |                                    |
| import ledger                  | import ledger                      |
| let w = AccountsCache.init(..) | let w = AccountsLedgerRef.init(..) |
|                                |                                    |
