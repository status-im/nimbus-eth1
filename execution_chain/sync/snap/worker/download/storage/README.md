Storage Sub-MPT
===============

Representation rules for storage sub-MPTs
-----------------------------------------

* A storage sub-MPT is addressed by an account path which also addresses
  the corresponding account.

* A storage sub-MPT data is stored as a flat list of slots (i.e.
  sub-MPT leafs.)

* The corresponding account record has a valid *storageRoot* field.

* A complete storage sub-MPT just downloaded consists of

  + a valid *storageRoot* field of the corresponding account record
  + a *dirtyStorage* field reset to *false* of the corresponding account record
  + *no StoMissingIntv* table record (which lists missing storage slot ranges)
  + a non-empty *FlatSlot* table of storage slots (i.e. sub-MPT leafs)
  + *no* lock record for this sub-MPT

* A post-complete storage sub-MPT (after applying BALs) consists of

  + a *storageRoot* field of the corresponding account record set
    to `zeroHash32`
  + a *dirtyStorage* field set to *false* of the corresponding account record
  + *no StoMissingIntv* table record (which lists missing storage slot ranges)
  + a non-empty *FlatSlot* table of storage slots (i.e. sub-MPT leafs)
  + *no* lock record for this sub-MPT

* A partial, non-complete storage sub-MPT just downloaded consists of

  + a valid *storageRoot* field of the corresponding account record
  + a *dirtyStorage* field set to *true* of the corresponding account record
  + a *StoMissingIntv* table record with a non-empty list of missing storage
    slot ranges)
  + a possibly empty *FlatSlot* table of storage slots (i.e. sub-MPT leafs)
  + *no* lock record for this sub-MPT

Download and updating rules for storage sub-MPTs
------------------------------------------------

While updating a partial storage sub-MPT in a quasi multi-threaded environment
by downloading *snap* data, the following actions take place.
  
* A lock record for the sub-MPT is created (identified by account path.)
* From the *StoMissingIntv* table, the corresopnding record is removed.
* Download and save/update the list of storage slots.
* Depending of whether the storage sub-MPT is complete now, do
  + if complete, reset the *dirtyStorage* field of the corresponding
	account record
  + otherwise update and save the sub-MPT record on the *StoMissingIntv* table
* Remove the lock record

Consequences
------------

For a partial storage sub-MPT, a change of storage slots due to BAL forwarding
cannot happen (is not allowed) because it would need a change the *storageRoot*
field of the corresponding account record.

Instead, the whole account and storage sub-MPT (and contract code) must be
deleted, and the account declared missing so that it can be re-fetched, along
with the new *storageRoot*.

Currently, all partial storage sub-MPTs will be deleted before BAL forwarding
takes place.

By prioritising non-empty partial storage sub-MPTs, it is expected that there
is some reduction of downloaded storage slots that go to waste when preparing
for BAL forwarding.
