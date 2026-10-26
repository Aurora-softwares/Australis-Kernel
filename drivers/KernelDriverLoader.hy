// AUDR v1 images are trusted kernel code, loaded only from the read-only
// system volume and named explicitly in /drivers.list. The first ABI has one
// boot-time entry; callback registration and unloading are future contracts.
public class KernelDriverLoader {
    private long bootInfo;
    private int loadedCount;
    private string[] loadedPaths;

    public KernelDriverLoader(long context) {
        bootInfo = context;
        loadedCount = 0;
        loadedPaths = new string[8];
    }

    public int LoadedCount() { return loadedCount; }

    private long Read32(byte[] bytes, int offset) {
        return (long)bytes[offset] + (long)bytes[offset + 1] * 256 +
            (long)bytes[offset + 2] * 65536 + (long)bytes[offset + 3] * 16777216;
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
        long crc = 4294967295;
        long polynomial = 3988292384;
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
        return Xor32(crc, 4294967295);
    }

    // Return zero only for an exact, supported image. Never inspect payload
    // bytes outside the checked length, even for a short or hostile file.
    public int Validate(byte[] image) {
        if (image == null || image.Length < 25 || image.Length > 65560) { return -1; }
        if (image[0] != 65 || image[1] != 85 || image[2] != 68 || image[3] != 82 ||
            image[4] != 1 || image[5] != 1 || image[6] != 0 || image[7] != 0) { return -2; }
        if (Read32(image, 12) != 0 || Read32(image, 20) != 0) { return -3; }
        long length = Read32(image, 8);
        if (length < 1 || length > 65536 || length != image.Length - 24) { return -4; }
        if (Crc32(image, 24, (int)length) != Read32(image, 16)) { return -5; }
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
        int pages = (length + 4095) / 4096;
        long codeAddress = KernelAddressSpace.FindUnmappedRange(bootInfo, pages);
        if (codeAddress == 0) { return -7; }
        long[] frames = new long[16];
        int i = 0;
        while (i < pages) {
            long frame = PhysicalPages.AllocateZeroed(bootInfo);
            if (frame == 0) { Release(codeAddress, frames, i); return -8; }
            frames[i] = frame;
            int copied = 0;
            while (copied < 4096 && i * 4096 + copied < length) {
                System.Kernel.Memory.Write8(frame + copied,
                    image[24 + i * 4096 + copied]);
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
        long result = System.Kernel.Cpu.CallKernel(codeAddress, bootInfo);
        if (result != 0) {
            Release(codeAddress, frames, pages);
            return -11;
        }
        // Successful modules stay mapped for their lifetime. AUDR v1 has no
        // unload or callback API, so a module must not register an external
        // pointer whose lifetime exceeds the kernel boot.
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
            info.ByteLength() > 65560) { return -12; }
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
