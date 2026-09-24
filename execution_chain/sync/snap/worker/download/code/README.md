Contract Code
=============

Representation rules for contract codes
---------------------------------------

* A contract code is addressed by an account path which also addresses
  the corresponding account.

* A contract code data is stored as a blob (i.e. seq[byte])

* The corresponding account record has a valid *codeHash* field.

* A complete contract code consists of

  + a valid *codeHash* field of the corresponding account record
  + a *dirtyCode* field reset to *false* of the corresponding account record
  + *no MissingBlob* table record relative to this contract code
  + a non-empty *FlatCode* table entry holding this contract code
  + *no* lock record for this contract code

* A missing contract code consists of

  + a valid *codeHash* field of the corresponding account record
  + a *dirtyCode* field set to *true* of the corresponding account record
  + a *MissingBlob* table record relative to this contract code
  + *no FlatCode* table entry holding this contract code
  +  *no* lock record for this contract code

Download and updating rules for contract codes
----------------------------------------------

While updating a contract code in a quasi multi-threaded environment
by downloading *snap* data, the following actions take place.

* A lock record for the contract code is created (identified by account path.)
* From the *MissingBlob* table, the corresopnding record is removed.
* Download and save the contract code if it could be fetched.
* Depending of whether the contract code could be fetched, do
  + if it could be fetched, reset the *dirtyCode* field of the corresponding
	account record
  + otherwise update and save the contract code address on the *MissingBlob*
    table
* Remove the lock record

Consequences
------------

After a state root change due to BAL forwarding, updating a missing contract
code would require an update of the corresponding account record in order to
fetch the current code via *codeHash*, which is stored in the account record.

For that reason, all missing contract code addresses and the corresponding
account records will be deleted. The account will then be declared missing
before BAL forwarding takes place.
