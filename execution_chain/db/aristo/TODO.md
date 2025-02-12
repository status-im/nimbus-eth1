* Some comletions might be needed for the `aristo_part` module which is a
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

* `aristo_nearby` also qualifies for a re-write, now

* Revisit tree deletion. The idea is to finally use ranges of nodes by
  exploiting the root ID prefix of a `RootedVertexID`. The `RocksDb` backend
  seems to support this kind of operation, see
  https://rocksdb.org/blog/2018/11/21/delete-range.html. For the application
  part there are some great ideas floating which need to be followed up
  some time.
