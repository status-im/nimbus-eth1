* Re-implement *getOldestJournalBlockNumber()* and
  *getLatestJournalBlockNumber()* (from the `core_apps` module) via the CoreDb
  base api. Currently this api is bypassed (via the *backend()* directive). The
  functionality is directly provided by the `Aristo` backend.

* Rename `newKvt()` to `getKvt()` as it is a shared KVT

* Fix `ctx` logic (mpt must be associated to a dedicated `ctx`, not via the
  default one freom the `CoreDbRef` as it is currently the case)
