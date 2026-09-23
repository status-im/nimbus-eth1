Snap Sync
=========

TODO
----

### Update BAL pruner to begin from start-of-history

See [bal_pruner](../../bal_pruner.nim)

### Check whether states *SnapClear* and *SnapReady* can be merged

Metrics
-------

| *Variable*                 | *Logic type*      | *Short description*     |
|:---------------------------|:-----------------:|:------------------------|
|                            |                   |                         |
| nec_snap_accounts_coverage | factor 0.0 .. 1.0 | account ranges covered  |
| nec_snap_download_window   | factor 0.0 .. 1.0 | window availability     |
| nec_snap_snap_peers        | number            | active snap peers       |

###  Graphana example

See chapter *Graphana example* of [beacon/README](../beacon/README.md)
