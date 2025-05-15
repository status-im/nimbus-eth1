# Upgrade

To upgrade to the latest version you need to update the nimbus-eth1 repository
and re-compile Fluffy.

!!! note
    In this state of development there are no official releases yet nor git tags
    for different versions.

## Upgrade to the latest version

Upgrading Fluffy when built from source is similar to the installation process.

Run:

```sh
# Download the updated source code
git pull && make update

# Build Fluffy from the newly updated source
make -j4 fluffy
```

Complete the upgrade by restarting the node.

!!! tip
    To check which version of Fluffy you're currently running, run
    `./build/fluffy --version`
