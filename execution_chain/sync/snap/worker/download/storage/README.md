Storage Sub-MPT
===============

Representation rules for storage sub-MPTs
-----------------------------------------

* A storage sub-MPT is addressed by an account path which also addresses
  the corresponding account.

* The storage sub-MPT data is stored as a flat list of slots (i.e.
  sub-MPT leafs.)

* The corresponding account record has a valid *storageRoot* field.

* A full or complete storage sub-MPT consists of

  + a valid *storageRoot* field of the corresponding account record
  + a *dirtyStorage* field set to *false* of the corresponding account record
  + a missing *StoMissingIntv* table data record
  + a flat list of *FlatSlot* table storage slots (i.e. sub-MPT leafs)

* A partial, non-complete storage sub-MPT consists of

  + a valid *storageRoot* field of the corresponding account record
  + a *dirtyStorage* field set to *true* of the corresponding account record
  + some missing slot range entry in the *StoMissingIntv* table data record
  + a flat list of *FlatSlot* table storage slots (i.e. sub-MPT leafs)

Consequences
------------

A change of storage slots due to BAL forwarding cannot happen (is not allowed)
because it would change the *storageRoot* field of the corresponding account
record.

Instead, the whole account and storage sub-MPT must be deleted and declared
missing so that it can be re-fetched, along with the new *storageRoot*.

Currently, all partial storage sub-MPTs will be deleted before BAL forwarding
takes place.

TODO
----

The problem is, that there is no way to verify the *storageRoot* recovered
from the proof of a partial storage sub-MPT message unless the corresponding
account is re-fetched (and verified against the *stateRoot* of the accounts
MPT.). At a later stage, there might be a particular accounting facility for
handling exactly that situation.

It needs to be made plausible, that this extra accounting and corresponding
actions gain overall sync time.

