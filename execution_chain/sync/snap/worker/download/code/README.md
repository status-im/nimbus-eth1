Contract Codes
==============

Representation rules for contract codes
---------------------------------------

1. A contract code data entry is stored as a *seq[byte]* in the *FlatCode*
  table, indexed by its account address

2. The corresponding account record has a valid *codeHash* field which can
   have values
   + *EMPTY_CODE_HASH* if there is no contract code (i.e. the data is empty)
   + *zeroHash32* if there is a non-empty contract code but the hash has not
     been calculated, yet (note that data is addressed by its account path)
   + Otherwise, the *codeHash* field must match the contract code

3. An exisiting contract code is represented as
   + a valid account record as described in 2
   + a non-empty *FlatCode* table entry for this contract code holding
     data (see 1)
   + there is no *MissingBlob* table record (indexed by the account path)

4. A contract code to be downloaded later is represented as
   + a valid account record as described in 2 with a non-*zeroHash32* code hash
   + there is *no* *FlatCode* table entry for this contract code holding data
   + a *MissingBlob* table record (indexed by the account path)

Download and updating rules for contract codes
----------------------------------------------

A contract code is registered to be downloaded when the corresponding account
record was downloaded for the first time (i.e. not a refresh download.)

The contract code is later downloaded, indexed by the *codehash* field of
the account record and saved in the *FlatCode* table (indexed by its account
path.)

After applying a BAL update to a contract code, the *codeHash* field of
the account record will be set to *zeroHash32*. This *codeHash* field may in
turn be reset to the contract code hash by re-fetching/refreshing the account
record (needed to complete a storage slots update.)

Core DB import rules
--------------------

If a contract code is to be imported into *Core DB*, the hash of the contract
code must be compiled.

If the *codeHash* field of the corresponding account record is not
*zeroHash32*, it must be made certain that the *codeHash* matches hash compiled
earlier.

Otherwise, the *codeHash* is set to the hash compiled earlier.

Miscellaneous
-------------

While processing contract codes, administrative table entries may temporarily
be removed from the cache DB and replaced by a lock record. This lock record
must be removed after processing has finished.

Lock records are intended to support error/disaster recovery.
