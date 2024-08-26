After change to the *Aristo* single state database, the proof logic in
*p2p.nim* is not supported anymore.

The proof logic in question refers to functions *state_db.getAccountProof()*
and *state_db.getStorageProof()* which used now unsupported internal access
to the differently organised legacy database.
