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
  + no *StoMissingIntv* table record (which lists missing storage slot ranges)
  + a non-empty *FlatSlot* table of storage slots (i.e. sub-MPT leafs)
  + *no* lock record for this sub-MPT

* A complete storage sub-MPT after applying BALs consists of

  + a *storageRoot* field of the corresponding account record set
    to `zeroHash32`
  + the rest being the same as with the sub-MPT after just downloading

* A partial, non-complete storage sub-MPT just downloaded consists of

  + a valid *storageRoot* field of the corresponding account record
  + a *dirtyStorage* field set to *true* of the corresponding account record
  + a *StoMissingIntv* table record with a non-empty list of missing storage
    slot ranges)
  + a possibly empty *FlatSlot* table of storage slots (i.e. sub-MPT leafs)
  + *no* lock record for this sub-MPT

* A partial, non-complete storage sub-MPT after applying BALs consists of

  + a *storageRoot* field of the corresponding account record set
    to `zeroHash32`
  + the rest being the same as with the partial sub-MPT after just downloading

Download and updating rules for storage sub-MPTs
------------------------------------------------

For a partial storage sub-MPTs the account must be re-fetched, after BAL
update so that the storage root can be updated which is needed for completing
the storage tree from the updated state.

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

As a consequence, there can only be one peer working on a storage tree at the
same time. This differs from managing accounts which can be completed in
quasi paralell. This might change in future if it turns out too slow.
