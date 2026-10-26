# Loadable Australis drivers

The kernel loads AUDR v1 modules only when `/drivers.list` exists on the
system volume. Put one absolute `.driver` path per line; at most eight paths
are accepted. For example, with `/Example.driver` on the same volume:

```text
/Example.driver
```

Hydrogen `type = "driver"` projects produce these files. The header and entry
ABI are specified in the [Hydrogen AUDR v1 document](https://github.com/Aurora-softwares/Hylang-Compiler/blob/Development/docs/audr-v1.md).
`DriverMain.Run(long context)` receives the `KernelBootInfo` address and must
return zero to complete initialization. The serial console reports a loaded
module or a negative rejection code; the loader validates the entire image
before mapping executable pages. A missing list leaves built-in drivers alone.

AUDR v1 modules execute with kernel privilege. Install only trusted images on
a trusted system volume. CRC-32 detects corruption but provides no publisher
authentication. The current entry is a boot-time initializer. Device matching,
typed hardware registration, interrupt callbacks, unload, and isolation remain
to be specified before replacing built-in networking, graphics, or USB drivers.

Run `make test-audr-driver` from the Australis-OS checkout to boot a valid
module, a corrupt module, and a system without a driver list under QEMU.
