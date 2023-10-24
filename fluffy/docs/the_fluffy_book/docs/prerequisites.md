# Prerequisites

The Fluffy client runs on Linux, macOS, Windows, and Android.

## Build prerequisites

When building from source, you will need additional build dependencies to be
installed:

- Developer tools (C compiler, Make, Bash, Git 2.9.4 or newer)
- [CMake](https://cmake.org/)

=== "Linux"

    On common Linux distributions the dependencies can be installed with:

    ```sh
    # Debian and Ubuntu
    sudo apt-get install build-essential git cmake

    # Fedora
    dnf install @development-tools cmake

    # Arch Linux, using an AUR manager
    yourAURmanager -S base-devel cmake
    ```

=== "macOS"

    With [Homebrew](https://brew.sh/):

    ```sh
    brew install cmake
    ```

=== "Windows"
    To build Fluffy on Windows, the MinGW-w64 build environment is recommended.

    - Install Mingw-w64 for your architecture using the "[MinGW-W64 Online Installer](https://sourceforge.net/projects/mingw-w64/files/)":

        1. Select your architecture in the setup menu (`i686` on 32-bit, `x86_64` on 64-bit).
        2. Set threads to `win32`.
        3. Set exceptions to "dwarf" on 32-bit and "seh" on 64-bit.
        4. Change the installation directory to `C:\mingw-w64` and add it to your system PATH in `"My Computer"/"This PC" -> Properties -> Advanced system settings -> Environment Variables -> Path -> Edit -> New -> C:\mingw-w64\mingw64\bin` (`C:\mingw-w64\mingw32\bin` on 32-bit).

        !!! note
            If the online installer isn't working you can try installing `mingw-w64` through [MSYS2](https://www.msys2.org/).

    - Install [cmake](https://cmake.org/).

    - Install [Git for Windows](https://gitforwindows.org/) and use a "Git Bash"
    shell to clone nimbus-eth1 and build fluffy.


=== "Android"

    - Install the [Termux](https://termux.com) app from FDroid or the Google Play store
    - Install a [PRoot](https://wiki.termux.com/wiki/PRoot) of your choice following the instructions for your preferred distribution.
    The Ubuntu PRoot is known to contain all Fluffy prerequisites compiled on Arm64 architecture (the most common architecture for Android devices).

    Assuming you use Ubuntu PRoot:

    ```sh
    apt install build-essential git
    ```
