Core database replacement wrapper object
========================================
This wrapper replaces the *TrieDatabaseRef* and its derivatives by the new
object *CoreDbRef*.

Relations to current *TrieDatabaseRef* implementation
-----------------------------------------------------
Here are some incomplete translations for objects and constructors.

### Object types:

| **Legacy notation**         | **CoreDbRef based replacement**       |
|:----------------------------|:--------------------------------------|
|                             |                                       |
| ChainDB                     | (don't use/avoid)                     |
| ChainDbRef                  | CoreDbRef                             |
| TrieDatabaseRef             | CoreDbKvtRef                          |
| HexaryTrie                  | CoreDbMptRef                          |
| SecureHexaryTrie            | CoreDbPhkRef                          |
| DbTransaction               | CoreDbTxRef                           |
| TransactionID               | CoreDbTxID                            |


### Constructors:

| **Legacy notation**         | **CoreDbRef based replacement**       |
|:----------------------------|:--------------------------------------|
|                             |                                       |
| trieDB newChainDB("..")     | newCoreDbRef(LegacyDbPersistent,"..") |
| newMemoryDB()               | newCoreDbRef(LegacyDbMemory)          |
| --                          |                                       |
| initHexaryTrie(db,..)       | db.mpt(..)      (no pruning)          |
|                             | db.mptPrune(..) (w/pruning true/false)|
| --                          |                                       |
| initSecureHexaryTrie(db,..) | db.phk(..)      (no pruning)          |
|                             | db.phkPrune(..) (w/pruning true/false)|
| --                          |                                       |
| newCaptureDB(db,memDB)      | newCoreDbCaptRef(db) (see below)      |


Usage of the replacement wrapper
--------------------------------

### Objects pedigree:

        CoreDbRef                   -- base descriptor
         | | | |
         | | | +-- CoreDbMptRef     -- hexary trie instance
         | | | |    :                    :
         | | | +-- CoreDbMptRef     -- hexary trie instance
         | | |
         | | |
         | | +---- CoreDbPhkRef     -- pre-hashed key hexary trie instance
         | | |      :                    :
         | | +---- CoreDbPhkRef     -- pre-hashed key hexary trie instance
         | |
         | |
         | +------ CoreDbKvtRef     -- single static key-value table
         |
         |
         +-------- CoreDbCaptRef    -- tracer support descriptor

### Instantiating standard database object descriptors works as follows:

        let
          db = newCoreDbRef(..)           # new base descriptor
          mpt = db.mpt(..)                # hexary trie/Merkle Patricia Tree
          phk = db.phk(..)                # pre-hashed key hexary trie/MPT
          kvt = db.kvt                    # key-value table

### Tracer support setup by hiding the current *CoreDbRef* behind a replacement:

        let
          capture = newCoreDbCaptRef(db)
          db = capture.recorder           # use the recorder in place of db
        ...

        for key,value in capture:         # process recorded data
         ...
