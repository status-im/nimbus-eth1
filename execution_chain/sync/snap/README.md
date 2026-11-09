Snap Sync
=========

See downloader docs for

* [storage sub-MPT](./worker/download/storage/README.md)
* [contract code](./worker/download/code/README.md)

Metrics
-------

| *Variable*                 | *Logic type*      | *Short description*    |
|:---------------------------|:-----------------:|:-----------------------|
|                            |                   |                        |
| nec_snap_accounts_coverage | factor 0.0 .. 1.0 | account ranges covered |
| nec_snap_storage_coverage  | factor 0.0 .. 1.0 | storage ranges covered |
| nec_snap_download_window   | factor 0.0 .. 1.0 | window availability    |
| nec_snap_dbimport_progress | factor 0.0 .. 1.0 | progress of DB import  |
| nec_snap_snap_peers        | number            | active snap peers      |

###  Graphana example

See chapter *Graphana example* of [beacon/README](../beacon/README.md)
