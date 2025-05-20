# Upgrade

To upgrade to the latest version you need to update the nimbus-eth1 repository
and re-compile the Nimbus Portal client.

!!! note
    In this state of development there are no official releases yet nor git tags
    for different versions.

## Upgrade to the latest version

Upgrading the Nimbus Portal client when built from source is similar to the installation process.

Run:

```sh
# Download the updated source code
git pull && make update

# Build from the newly updated source
make -j4 nimbus_portal_client
```

Complete the upgrade by restarting the node.

!!! tip
    To check which version of the Nimbus Portal client you're currently running, run
    `./build/nimbus_portal_client --version`
