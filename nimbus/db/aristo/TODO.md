* Re-visit `delTree()`. Suggestion is deleting small trees on the memory later,
  otherwise only deleting the root vertex (so it becomes inaccessible) and
  remember the follow up vertices which can travel through the tx-layers
  to be picked up by the backend store.

* Some comletions migh be needed for the `aristo_part` module which is a
  re-implementation of the module supporting *proof-mode*/partial trees.
  + Complete `partMergeStorageData()`. This function might not be needed at
    all unless *snap-sync* is really revived.
  + For *snap-sync*, write a `proof` function verifying whether the partial
    tree is correct relative to the `PartStateRef` descriptor.
  + One might need to re-visit the `removeCompletedNodes()` module when using
    *snap-sync* proof features. The algorithm used here assumes that the list
	of proof nodes is rather small. Also, a right boundary leaf node is
	typically cleared. This needs to be re-checked when writing the `proof`
	function mentioned above.
