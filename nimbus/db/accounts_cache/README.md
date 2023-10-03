The file `accounts_cache.nim` has been relocated
================================================

Background
----------

The new *LedgerRef* module unifies different implementations of the
*accounts_cache*. It is intended to be used as new base method for all of the
*AccountsCache* implementations. Only constructors differ, depending on the
implementation.

This was needed to accomodate for different *CoreDb* API paradigms. While the
*AccountsCache* and *WrappedAccountsCache* implementations used the legacy
API from *CoreDb*, the *WrappedLedgerCache* implementation use the new *CoreDb*
API with *Result[]* return codes and the root node abstraction. This allows to
use the legacy hexary database (with the new *CoreDb* API) as well as the
*Aristo* database (only supported on new API.)

Instructions
------------

| **Legacy notation**    | **LedgerRef replacement**     | **Comment**
|:-----------------------|:------------------------------|----------------------
|                        |                               |
| import accounts_cache  | import ledger                 | preferred method,
| AccountsCache.init(..) | WrappedAccountsCache.init(..) | wraps *AccountsCache*
|                        |                               | methods
|                        | *or*                          |
|                        |                               |
|                        | import ledger/accounts_cache  | legacy version of
|                        | AccountsCache.init(..)        | *AccountsCache*
| --                     |                               |
| fn(ac: AccountsCache)  | fn(ac: LedgerRef)             | function example for
|                        |                               | preferred wrapper
|                        | *or*                          | method
|                        |                               |
|                        | fn(ac: AccountsCache)         | with legacy version,
|                        |                               | no change here
