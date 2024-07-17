* Check whether `HashKey` can be reduced to a simple 32 byte array (see
  *desc_identifiers.nim*)

* Re-visit `delTree()`. Suggestion is deleting small trees on the memory later,
  otherwise only deleting the root vertex (so it becomes inaccessible) and
  remember the follow up vertices which can travel through the tx-layers
  to be picked up by the backend store.

* Note that the *proof-mode* code was removed with PR #2445. An idea for a
  re-implementation would be to pre-load vertices and keep the perimeter
  hashes of the pre-loaded vertices externally in a vid-hash table. That way,
  the vid hashes can be verified should they appear in the partial MPT at a
  later stage.
