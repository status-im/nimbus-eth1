* Re-implement *getOldestJournalBlockNumber()* and
  *getLatestJournalBlockNumber()* (from the `core_apps` module) via the CoreDb
  base api. Currently this api is bypassed (via the *backend()* directive). The
  functionality is directly provided by the `Aristo` backend.
