Storage Sub-MPTs
================

Representation rules for storage sub-MPTs
-----------------------------------------

1. A storage sub-MPT data is stored as a flat list of *Hash32* slot values
   in the 'FlatSlot' table indexed by its account address and slot key.

2. The corresponding account record has a valid *storageRoot* field which can
   have values
   + *EMPTY_ROOT_HASH* if there is no storage sub-MPT
   + *zeroHash32* if there is a non-empty storage sub-MPT but the hash has not
     been calculated, yet (note that sub-MPT data is addressed by its account
	 path)
   + Otherwise, the *storageRoot* field must match the root hash of storage
     sub-MPT (which can be calculated only if it is fully downloaded)

3. A completed storage sub-MPT is represented as
   + a valid account record as described in 2
   + a non-empty list of *FlatSlot* table entries for this storage sub-MPT
     holding slot data (see 1)
   + there is no *StoMissingIntv* table record

4. A partially completed existing storage sub-MPT is represented as
   + a valid account record as described in 2
   + a non-empty list of *FlatSlot* table entries for this storage sub-MPT
     holding slot data (see 1)
   + a *StoMissingIntv* table record which lists missing storage slot ranges

Download and updating rules for storage sub-MPTs
------------------------------------------------

A storage sub-MPT code is registered to be downloaded when the corresponding
account record was downloaded for the first time (i.e. not a refresh download.)
Formally, this will be a partially completed sub-MPT where the whole key
range is missing.

The storage sub-MPT later downloaded, indexed by the *storageRoot* field of
the account record and saved in the *FlatSlot* table (indexed by its account
path.) The downloaded slots might not make up for the whole sub-MPT. So a
partial sub-MPT remains and needs to be completed later.

After applying a BAL update to a storage sub-MPT, the *storageRoot* field of
the account record will be set to *zeroHash32*.

When applying BALs to a partially complete storage sub-MPT, the account record
is marked to be re-fetched /refreshed in the next state download cycle (in
addition to setting the *storageRoot* field to *zeroHash32*.)

Core DB import rules
--------------------

If a storage sub-MPT code is to be imported into *Core DB*, the hash of the
sub-MPT must be compiled.

If the *storageRoot* field of the corresponding account record is not
*zeroHash32*, it must be made certain that the *storageRoot* matches hash
compiled earlier.

Otherwise, compiling the *storageRoot* field will be managed by the Core DB
importer (no explicit *storageRoot* field.)

Miscellaneous
-------------

While processing storage sub-MPTs, administrative table entries may temporarily
be removed from the cache DB and replaced by a lock record. This lock record
must be removed after processing has finished.

Lock records are intended to support error/disaster recovery.
