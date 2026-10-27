// AUDR images are trusted kernel code, loaded only from the read-only system
// volume and named explicitly in /drivers.list. v1 has a boot-time entry;
// v2 adds bounded device matching and a probe context.
public class KernelDriverLoader {
    private long bootInfo;
    private int loadedCount;
    private string[] loadedPaths;
    private long[] entryAddresses;
    private int[] matchKinds;
    private int[] matchVendors;
    private int[] matchDevices;
    private int[] matchClasses;
    private int[] matchSubclasses;
    private int[] matchInterfaces;
    private int lastProbeAttempts;

    public KernelDriverLoader(long context) {
        bootInfo = context;
        loadedCount = 0;
        loadedPaths = new string[8];
        entryAddresses = new long[8];
        matchKinds = new int[8];
        matchVendors = new int[8];
        matchDevices = new int[8];
        matchClasses = new int[8];
        matchSubclasses = new int[8];
        matchInterfaces = new int[8];
        lastProbeAttempts = 0;
    }

    public int LoadedCount() { return loadedCount; }
    public int LastProbeAttempts() { return lastProbeAttempts; }

    private int MatchField(int rule, int value, int wildcard, int weight) {
        if (rule == wildcard) { return 0; }
        if (rule != value) { return -1; }
        return weight;
    }

    private int MatchScore(int index, int kind, int vendor, int device,
        int category, int subclass, int interfaceCode) {
        if (entryAddresses[index] == 0 || matchKinds[index] != kind) { return -1; }
        int score = MatchField(matchVendors[index], vendor, 65535, 16);
        if (score < 0) { return -1; }
        int part = MatchField(matchDevices[index], device, 65535, 16);
        if (part < 0) { return -1; }
        score = score + part;
        part = MatchField(matchClasses[index], category, 255, 4);
        if (part < 0) { return -1; }
        score = score + part;
        part = MatchField(matchSubclasses[index], subclass, 255, 2);
        if (part < 0) { return -1; }
        score = score + part;
        part = MatchField(matchInterfaces[index], interfaceCode, 255, 1);
        if (part < 0) { return -1; }
        return score + part;
    }

    // A v2 entry receives one page for this call only: version at +0, kind
    // at +4, boot-info address at +8, vendor/device at +16/+20, device key
    // at +24, resource address/length at +32/+40, class tuple at +48/+52/+56,
    // and operation 1 (probe) at +64. It writes its result at +72. No pointer
    // into this page may be retained after the call.
    private int ProbeMatched(int kind, int vendor, int device, int category,
        int subclass, int interfaceCode, int deviceKey, long resource,
        long resourceLength) {
        lastProbeAttempts = 0;
        bool[] tried = new bool[8];
        int attempt = 0;
        while (attempt < loadedCount) {
            int best = -1;
            int bestScore = -1;
            int i = 0;
            while (i < loadedCount) {
                if (!tried[i]) {
                    int score = MatchScore(i, kind, vendor, device,
                        category, subclass, interfaceCode);
                    if (score > bestScore) { best = i; bestScore = score; }
                }
                i = i + 1;
            }
            if (best < 0) { return 0; }
            tried[best] = true;
            lastProbeAttempts = lastProbeAttempts + 1;
            long context = PhysicalPages.AllocateZeroed(bootInfo);
            if (context == 0) { return 0; }
            System.Kernel.Memory.Write32(context, 2);
            System.Kernel.Memory.Write32(context + 4, kind);
            System.Kernel.Memory.Write64(context + 8, bootInfo);
            System.Kernel.Memory.Write32(context + 16, vendor);
            System.Kernel.Memory.Write32(context + 20, device);
            System.Kernel.Memory.Write32(context + 24, deviceKey);
            System.Kernel.Memory.Write64(context + 32, resource);
            System.Kernel.Memory.Write64(context + 40, resourceLength);
            System.Kernel.Memory.Write32(context + 48, category);
            System.Kernel.Memory.Write32(context + 52, subclass);
            System.Kernel.Memory.Write32(context + 56, interfaceCode);
            System.Kernel.Memory.Write32(context + 64, 1);
            long status = System.Kernel.Cpu.CallKernel(entryAddresses[best], context);
            int result = System.Kernel.Memory.Read32(context + 72);
            PhysicalPages.Free(bootInfo, context);
            if (status == 0 && result > 0 && result <= 255) { return result; }
            attempt = attempt + 1;
        }
        return 0;
    }

    // Exact IDs outrank class matches; equal scores keep manifest order.
    // A failed candidate is skipped and the next match can be tried.
    public int ProbePci(int vendor, int device, int category, int subclass,
        int interfaceCode, int bdf, long mmio, long mmioLength) {
        return ProbeMatched(1, vendor, device, category, subclass,
            interfaceCode, bdf, mmio, mmioLength);
    }

    public int ProbeUsb(int vendor, int product, int category, int subclass,
        int protocol, int deviceKey) {
        return ProbeMatched(2, vendor, product, category, subclass,
            protocol, deviceKey, 0, 0);
    }

    private long Read32(byte[] bytes, int offset) {
        long a = bytes[offset];
        long b = bytes[offset + 1];
        long c = bytes[offset + 2];
        long d = bytes[offset + 3];
        return a + b * 256 + c * 65536 + d * 16777216;
    }

    private long Xor32(long left, long right) {
        long result = 0;
        long bit = 1;
        while (left > 0 || right > 0) {
            if (left % 2 != right % 2) { result = result + bit; }
            left = left / 2;
            right = right / 2;
            bit = bit * 2;
        }
        return result;
    }

    private long Crc32(byte[] image, int offset, int length) {
        long allOnes = 65535; allOnes = allOnes * 65536 + 65535;
        long polynomial = 39882; polynomial = polynomial * 100000 + 92384;
        long crc = allOnes;
        int i = 0;
        while (i < length) {
            crc = Xor32(crc, (long)image[offset + i]);
            int bit = 0;
            while (bit < 8) {
                if (crc % 2 == 1) { crc = Xor32(crc / 2, polynomial); }
                else { crc = crc / 2; }
                bit = bit + 1;
            }
            i = i + 1;
        }
        return Xor32(crc, allOnes);
    }

    // Return zero only for an exact, supported image. Never inspect payload
    // bytes outside the checked length, even for a short or hostile file.
    public int Validate(byte[] image) {
        if (image == null || image.Length < 25 || image.Length > 1048624) { return -1; }
        if (image[0] != 65 || image[1] != 85 || image[2] != 68 || image[3] != 82 ||
            image[4] < 1 || image[4] > 2 || image[5] != image[4] ||
            image[6] != 0 || image[7] != 0) { return -2; }
        if (Read32(image, 12) != 0 || Read32(image, 20) != 0) { return -3; }
        int headerLength = 24;
        long maximumCode = 65536;
        if (image[4] == 2) {
            headerLength = 48;
            maximumCode = 1048576;
            if (image.Length < 49) { return -1; }
            long kind = Read32(image, 24);
            long vendor = Read32(image, 28);
            long device = Read32(image, 32);
            long category = Read32(image, 36);
            long subclass = Read32(image, 40);
            long interfaceCode = Read32(image, 44);
            if ((kind != 1 && kind != 2) || vendor > 65535 || device > 65535 ||
                category > 255 || subclass > 255 || interfaceCode > 255 ||
                (vendor == 65535 && device == 65535 && category == 255 &&
                 subclass == 255 && interfaceCode == 255)) { return -3; }
        }
        long length = Read32(image, 8);
        if (length < 1 || length > maximumCode || length != image.Length - headerLength) { return -4; }
        if (Crc32(image, 24, (int)length + headerLength - 24) != Read32(image, 16)) { return -5; }
        return 0;
    }

    private void Release(long codeAddress, long[] frames, int count) {
        int i = 0;
        while (i < count) {
            if (frames[i] != 0) {
                KernelAddressSpace.UnmapPage(bootInfo, codeAddress + i * 4096);
                PhysicalPages.Free(bootInfo, frames[i]);
            }
            i = i + 1;
        }
    }

    public int LoadBytes(byte[] image) {
        int validation = Validate(image);
        if (validation != 0) { return validation; }
        if (loadedCount >= 8) { return -6; }
        int length = (int)Read32(image, 8);
        int headerLength = 24;
        if (image[4] == 2) { headerLength = 48; }
        int pages = (length + 4095) / 4096;
        long codeAddress = KernelAddressSpace.FindUnmappedRange(bootInfo, pages);
        if (codeAddress == 0) { return -7; }
        long[] frames = new long[pages];
        int i = 0;
        while (i < pages) {
            long frame = PhysicalPages.AllocateZeroed(bootInfo);
            if (frame == 0) { Release(codeAddress, frames, i); return -8; }
            frames[i] = frame;
            int copied = 0;
            while (copied < 4096 && i * 4096 + copied < length) {
                System.Kernel.Memory.Write8(frame + copied,
                    image[headerLength + i * 4096 + copied]);
                copied = copied + 1;
            }
            if (!KernelAddressSpace.MapTrustedCodePage(bootInfo,
                codeAddress + i * 4096, frame)) {
                PhysicalPages.Free(bootInfo, frame);
                frames[i] = 0;
                Release(codeAddress, frames, i);
                return -9;
            }
            i = i + 1;
        }
        if (!KernelAddressSpace.IsExecutable(bootInfo, codeAddress)) {
            Release(codeAddress, frames, pages);
            return -10;
        }
        if (image[4] == 1) {
            long result = System.Kernel.Cpu.CallKernel(codeAddress, bootInfo);
            if (result != 0) {
                Release(codeAddress, frames, pages);
                return -11;
            }
        } else {
            entryAddresses[loadedCount] = codeAddress;
            matchKinds[loadedCount] = (int)Read32(image, 24);
            matchVendors[loadedCount] = (int)Read32(image, 28);
            matchDevices[loadedCount] = (int)Read32(image, 32);
            matchClasses[loadedCount] = (int)Read32(image, 36);
            matchSubclasses[loadedCount] = (int)Read32(image, 40);
            matchInterfaces[loadedCount] = (int)Read32(image, 44);
        }
        // Successful modules stay mapped for their lifetime. v2 re-entry is
        // controlled by this loader; neither ABI currently supports unload.
        loadedCount = loadedCount + 1;
        return 0;
    }

    private bool ValidPath(byte[] bytes, int offset, int length) {
        if (length < 9 || length > 127 || bytes[offset] != 47) { return false; }
        int i = 0;
        while (i < length) {
            int value = (int)bytes[offset + i];
            bool letter = (value >= 65 && value <= 90) ||
                (value >= 97 && value <= 122);
            bool digit = value >= 48 && value <= 57;
            if (!letter && !digit && value != 47 && value != 45 &&
                value != 46 && value != 95) { return false; }
            if (i > 0 && value == 47 && bytes[offset + i - 1] == 47) { return false; }
            if (i > 0 && value == 46 && bytes[offset + i - 1] == 46) { return false; }
            i = i + 1;
        }
        string suffix = ".driver";
        i = 0;
        while (i < suffix.Length) {
            if ((int)bytes[offset + length - suffix.Length + i] !=
                System.Kernel.String.ByteAt(suffix, i)) { return false; }
            i = i + 1;
        }
        return true;
    }

    public int LoadFile(Australis.Kernel.Vfs.Vfs vfs, string path) {
        Australis.Kernel.Vfs.VfsFileInfo info = vfs.StatRootFile(path);
        if (!info.Exists() || info.ByteLength() < 25 ||
            info.ByteLength() > 1048624) { return -12; }
        byte[] image = new byte[(int)info.ByteLength()];
        if (vfs.ReadRootFile(path, 0, image) != Australis.Kernel.Vfs.VfsStatus.Ok()) {
            return -13;
        }
        return LoadBytes(image);
    }

    // Newline-separated absolute .driver paths, at most eight, with no
    // comments or implicit directory scanning. A missing list is optional.
    public int LoadManifest(Australis.Kernel.Vfs.Vfs vfs) {
        Australis.Kernel.Vfs.VfsFileInfo info = vfs.StatRootFile("/drivers.list");
        if (!info.Exists()) { return 0; }
        if (info.ByteLength() < 1 || info.ByteLength() > 1024) { return -14; }
        byte[] list = new byte[(int)info.ByteLength()];
        if (vfs.ReadRootFile("/drivers.list", 0, list) !=
            Australis.Kernel.Vfs.VfsStatus.Ok()) { return -15; }
        int start = 0;
        int i = 0;
        while (i <= list.Length) {
            if (i == list.Length || list[i] == 10) {
                int length = i - start;
                if (length > 0 && list[start + length - 1] == 13) {
                    length = length - 1;
                }
                if (length > 0) {
                    if (loadedCount >= 8 || !ValidPath(list, start, length)) { return -16; }
                    byte[] pathBytes = new byte[length];
                    int p = 0;
                    while (p < length) {
                        pathBytes[p] = list[start + p];
                        p = p + 1;
                    }
                    string path = System.Kernel.String.FromBytes(pathBytes, length);
                    p = 0;
                    while (p < loadedCount) {
                        if (loadedPaths[p] == path) { return -17; }
                        p = p + 1;
                    }
                    int result = LoadFile(vfs, path);
                    if (result != 0) { return result; }
                    loadedPaths[loadedCount - 1] = path;
                }
                start = i + 1;
            }
            i = i + 1;
        }
        return loadedCount;
    }
}
