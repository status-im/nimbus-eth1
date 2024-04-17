# Database pruning

Default Fluffy runs with a specific storage capacity (`--storage-capacity=x`, default set to 2GB). This means that the node's radius is dynamically adjusted to not exceed the configured capacity. As soon as the storage capacity is to be exceeded the pruning of content takes place and a new smaller radius is set.

As long as the configured storage capacity remains the same, pruning is done
automatically.

In case the storage capacity of a Fluffy node is changed, a manual step might
be required. There are two scenarios possible:
- Adjusting to a higher storage capacity
- Adjusting to a lower storage capacity

## Adjusting to a higher storage capacity

This requires no manual steps as no pruning will be required. On the restart of the Fluffy node with a higher configured storage capacity, the initial radius will be increased to the maximum radius until the new storage capacity is reached. Then the automatic pruning will take place and the radius will be decreased.

## Adjusting to a lower storage capacity

When a Fluffy node is restarted with a lower storage capacity, pruning will take
place automatically. The database will be pruned in intervals until the storage
drops under the newly configured storage capacity. The radius will also be adjusted with each pruning cycle.

However, on disk the database will not lower in size. This is because empty
pages are kept in the SQL database until a [vacuum command](https://www.sqlite.org/lang_vacuum.html) is done.
To do this you can run the `--force-prune` option at start-up. Note that this will temporarily double the database storage capacity as a temporary copy of the database needs to be made.
Because of this, the vacuum is not executed automatically but requires you to manually enable the `--force-prune` flag.

You can also use the `fcli_db` tool its  `prune` command on the database directly to force this vacuuming.

Another simple but more drastic solution is to delete the `db` subdirectory in the `--data-dir` provided to your Fluffy node. This will start your Fluffy node with a fresh database.
