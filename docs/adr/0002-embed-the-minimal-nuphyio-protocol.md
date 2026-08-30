# Embed the minimal NuPhyIO protocol

The project will include the smallest Air65 V3 lighting-control protocol module needed by the NuPhyIO adapter, preserving the upstream MIT license and source attribution and locking its packets with protocol tests. It will not require or spawn the `nuphyctl` CLI: an external executable would add installation and version-drift failure modes to every lighting transition, while an in-process module keeps the open-source distribution to one binary without claiming the rest of `nuphyctl`'s scope.
