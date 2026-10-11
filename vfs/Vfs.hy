using Australis.Kernel.Storage;

namespace Australis.Kernel.Vfs {
    // Filesystem drivers mount a bounded partition instead of an entire disk.
    // Paths are deliberately left as UTF-8 strings at this layer; HyFS and
    // compatibility drivers own their on-disk name encoding and lookup rules.
    public interface IFileSystem {
        int Mount(BlockDevice device, Partition partition);
        bool Exists(string path);
        VfsFileInfo Stat(string path);
        int ReadFile(string path, long offset, byte[] destination);
        int DirectorySlotCount();
        int CopyDirectoryEntryName(int index, byte[] destination);
        int DirectorySlotCountAt(string path);
        int CopyDirectoryEntryNameAt(string path, int index, byte[] destination);
    }

    public interface IWritableFileSystem : IFileSystem {
        int MountWritable(BlockDevice device, Partition partition);
        bool IsWritable();
        int CreateFile(string path, byte[] contents);
        int ReplaceFile(string path, byte[] contents);
        int AppendFile(string path, byte[] contents);
        int TruncateFile(string path, long length);
        int DeleteFile(string path);
        int Mkdir(string path);
        int Rmdir(string path);
        int Rename(string source, string destination);
    }

    public class VfsStatus {
        public static int Ok() { return 0; }
        public static int InvalidArgument() { return 1; }
        public static int MountFailed() { return 2; }
        public static int NotMounted() { return 3; }
        public static int NotFound() { return 4; }
        public static int EndOfFile() { return 5; }
        public static int IoFailure() { return 6; }
        public static int Corrupt() { return 7; }
        public static int ReadOnly() { return 8; }
        public static int AlreadyExists() { return 9; }
        public static int NotEmpty() { return 10; }
        public static int NoSpace() { return 11; }
        public static int StaleHandle() { return 12; }
        public static int CrossDevice() { return 13; }
    }

    // File metadata returned by a filesystem lookup. A status-bearing value
    // avoids treating a zero-length file as indistinguishable from a missing
    // file, while keeping the VFS free of filesystem-specific metadata.
    public class VfsFileInfo {
        private int status;
        private long byteLength;
        private int kind;
        private long objectId;
        private long created;
        private long modified;
        private int timeFlags;
        private long attributes;

        public VfsFileInfo(int inputStatus, long inputByteLength) {
            status = inputStatus;
            byteLength = inputByteLength;
            kind = 0;
            if (inputStatus == VfsStatus.Ok()) { kind = 1; }
            objectId = 0; created = 0; modified = 0; timeFlags = 0; attributes = 0;
        }
        public int Status() { return status; }
        public long ByteLength() { return byteLength; }
        public int Kind() { return kind; }
        public long ObjectId() { return objectId; }
        public long CreatedUnixSeconds() { return created; }
        public long ModifiedUnixSeconds() { return modified; }
        public bool HasCreationTime() { return timeFlags % 2 != 0; }
        public bool HasModificationTime() { return (timeFlags / 2) % 2 != 0; }
        public long Attributes() { return attributes; }
        public void SetMetadata(int inputKind, long inputId, long inputCreated,
            long inputModified, int inputTimeFlags, long inputAttributes) {
            kind = inputKind; objectId = inputId; created = inputCreated;
            modified = inputModified; timeFlags = inputTimeFlags;
            attributes = inputAttributes;
        }
        public bool Exists() { return status == VfsStatus.Ok(); }
    }

    public class VfsFileHandle {
        private Vfs owner;
        private string path;
        private int mountIdentity;
        private int mountGeneration;
        private long position;
        private long byteLength;
        private int status;
        private bool closed;
        private long objectId;
        private bool canWrite;
        private int mutationGeneration;
        public VfsFileHandle(Vfs inputOwner, string inputPath, int inputIdentity,
            int inputGeneration, long inputLength, int inputStatus) {
            Initialize(inputOwner, inputPath, inputIdentity, inputGeneration,
                inputLength, 0, false, inputStatus);
        }
        public VfsFileHandle(Vfs inputOwner, string inputPath, int inputIdentity,
            int inputGeneration, long inputLength, long inputObjectId,
            bool inputCanWrite, int inputStatus) {
            Initialize(inputOwner, inputPath, inputIdentity, inputGeneration,
                inputLength, inputObjectId, inputCanWrite, inputStatus);
        }
        private void Initialize(Vfs inputOwner, string inputPath, int inputIdentity,
            int inputGeneration, long inputLength, long inputObjectId,
            bool inputCanWrite, int inputStatus) {
            owner = inputOwner; path = inputPath; mountIdentity = inputIdentity;
            mountGeneration = inputGeneration; position = 0; byteLength = inputLength;
            status = inputStatus; closed = inputStatus != VfsStatus.Ok();
            objectId = inputObjectId; canWrite = inputCanWrite;
            mutationGeneration = 0;
            if (owner != null) { mutationGeneration = owner.MutationGeneration(); }
        }
        public int Status() { return status; }
        public long Position() { return position; }
        public long ByteLength() { return byteLength; }
        public long Remaining() {
            if (closed || position >= byteLength) { return 0; }
            return byteLength - position;
        }
        public int MountIdentity() { return mountIdentity; }
        public bool IsOpen() { return !closed && owner != null; }
        public int Read(byte[] destination) {
            if (closed || owner == null) { status = VfsStatus.NotMounted(); return status; }
            status = owner.OpenFileStatus(path, mountIdentity, mountGeneration,
                mutationGeneration, objectId);
            if (status != VfsStatus.Ok()) { return status; }
            if (destination == null || destination.Length > byteLength - position) {
                status = VfsStatus.InvalidArgument(); return status;
            }
            status = owner.ReadOpenFile(path, mountIdentity, mountGeneration,
                mutationGeneration, objectId, position, destination);
            if (status == VfsStatus.Ok()) { position = position + destination.Length; }
            return status;
        }
        public int Replace(byte[] contents) { return Mutate(contents, 1); }
        public int Append(byte[] contents) { return Mutate(contents, 2); }
        private int Mutate(byte[] contents, int operation) {
            if (closed || owner == null) { status = VfsStatus.NotMounted(); return status; }
            if (!canWrite) { status = VfsStatus.ReadOnly(); return status; }
            status = owner.WriteOpenFile(path, mountIdentity, mountGeneration,
                mutationGeneration, objectId, contents, operation);
            if (status == VfsStatus.Ok()) {
                VfsFileInfo info = owner.StatRootFile(path);
                byteLength = info.ByteLength(); position = 0;
                mutationGeneration = owner.MutationGeneration();
            }
            return status;
        }
        public int Truncate(long length) {
            if (closed || owner == null) { status = VfsStatus.NotMounted(); return status; }
            if (!canWrite) { status = VfsStatus.ReadOnly(); return status; }
            status = owner.TruncateOpenFile(path, mountIdentity, mountGeneration,
                mutationGeneration, objectId, length);
            if (status == VfsStatus.Ok()) {
                byteLength = length; position = 0;
                mutationGeneration = owner.MutationGeneration();
            }
            return status;
        }
        public void Close() { closed = true; owner = null; }
    }

    // A resolved namespace path keeps the mount selection separate from the
    // path passed to the filesystem. HyFS v1 remains a flat filesystem, but
    // the namespace can still canonicalize nested paths and cross the /usb
    // mount without teaching individual drivers about mount points.
    public class VfsPath {
        private int status;
        private Vfs volume;
        private string localPath;
        private string canonicalPath;
        public VfsPath(int inputStatus, Vfs inputVolume, string inputLocal,
            string inputCanonical) {
            status = inputStatus; volume = inputVolume;
            localPath = inputLocal; canonicalPath = inputCanonical;
        }
        public int Status() { return status; }
        public bool IsValid() { return status == VfsStatus.Ok() && volume != null; }
        public Vfs Volume() { return volume; }
        public string LocalPath() { return localPath; }
        public string CanonicalPath() { return canonicalPath; }
    }

    public class VfsDirectoryResult {
        private int status;
        private int count;
        public VfsDirectoryResult(int inputStatus, int inputCount) {
            status = inputStatus; count = inputCount;
        }
        public int Status() { return status; }
        public int Count() { return count; }
    }

    // The mount namespace is deliberately small and deterministic:
    // / names the boot volume, /usb the removable volume, and /data the
    // separate HyFS 2 data partition. Path
    // normalization is shared by the shell and user syscalls, so both observe
    // the same handling of repeated separators, dot, and parent traversal.
    public class VfsNamespace {
        private Vfs root;
        private Vfs removable;
        private Vfs data;

        public VfsNamespace(Vfs inputRoot, Vfs inputRemovable) {
            root = inputRoot; removable = inputRemovable; data = null;
        }

        public VfsNamespace(Vfs inputRoot, Vfs inputRemovable, Vfs inputData) {
            root = inputRoot; removable = inputRemovable; data = inputData;
        }

        private int PathByte(string path, int index) {
            return System.Kernel.String.ByteAt(path, index);
        }

        public VfsPath Resolve(string path) {
            if (path == null || path.Length < 1 || path.Length > 255 || PathByte(path, 0) != 47) {
                return new VfsPath(VfsStatus.InvalidArgument(), null, null, null);
            }
            byte[] normalized = new byte[256];
            int[] restore = new int[64];
            normalized[0] = 47;
            int outputLength = 1;
            int depth = 0;
            int cursor = 1;
            while (cursor < path.Length) {
                while (cursor < path.Length && PathByte(path, cursor) == 47) { cursor = cursor + 1; }
                if (cursor >= path.Length) { break; }
                int start = cursor;
                while (cursor < path.Length && PathByte(path, cursor) != 47) { cursor = cursor + 1; }
                int componentLength = cursor - start;
                bool dot = componentLength == 1 && PathByte(path, start) == 46;
                bool parent = componentLength == 2 && PathByte(path, start) == 46 &&
                    PathByte(path, start + 1) == 46;
                if (dot) { continue; }
                if (parent) {
                    if (depth > 0) {
                        depth = depth - 1;
                        outputLength = restore[depth];
                    }
                    continue;
                }
                if (componentLength < 1 || componentLength > 63 || depth >= restore.Length) {
                    return new VfsPath(VfsStatus.InvalidArgument(), null, null, null);
                }
                int oldLength = outputLength;
                int required = componentLength;
                if (outputLength > 1) { required = required + 1; }
                if (required > normalized.Length - outputLength) {
                    return new VfsPath(VfsStatus.InvalidArgument(), null, null, null);
                }
                restore[depth] = oldLength;
                depth = depth + 1;
                if (outputLength > 1) {
                    normalized[outputLength] = 47;
                    outputLength = outputLength + 1;
                }
                int i = 0;
                while (i < componentLength) {
                    int value = PathByte(path, start + i);
                    if (value < 32 || value > 126) {
                        return new VfsPath(VfsStatus.InvalidArgument(), null, null, null);
                    }
                    normalized[outputLength] = (byte)value;
                    outputLength = outputLength + 1;
                    i = i + 1;
                }
            }

            string canonical = System.Kernel.String.FromBytes(normalized, outputLength);
            bool usb = outputLength >= 4 && normalized[0] == 47 && normalized[1] == 117 &&
                normalized[2] == 115 && normalized[3] == 98 &&
                (outputLength == 4 || normalized[4] == 47);
            bool dataPath = outputLength >= 5 && normalized[0] == 47 &&
                normalized[1] == 100 && normalized[2] == 97 &&
                normalized[3] == 116 && normalized[4] == 97 &&
                (outputLength == 5 || normalized[5] == 47);
            if (!usb && !dataPath) {
                if (root == null || !root.IsRootMounted()) {
                    return new VfsPath(VfsStatus.NotMounted(), null, null, canonical);
                }
                return new VfsPath(VfsStatus.Ok(), root, canonical, canonical);
            }
            Vfs selected = removable;
            int prefixLength = 4;
            if (dataPath) { selected = data; prefixLength = 5; }
            if (selected == null || !selected.IsRootMounted()) {
                return new VfsPath(VfsStatus.NotMounted(), null, null, canonical);
            }
            if (outputLength == prefixLength) {
                return new VfsPath(VfsStatus.Ok(), selected, "/", canonical);
            }
            int localLength = outputLength - prefixLength;
            byte[] localBytes = new byte[localLength];
            int localIndex = 0;
            while (localIndex < localLength) {
                localBytes[localIndex] = normalized[localIndex + prefixLength];
                localIndex = localIndex + 1;
            }
            string local = System.Kernel.String.FromBytes(localBytes, localLength);
            return new VfsPath(VfsStatus.Ok(), selected, local, canonical);
        }

        public VfsFileInfo Stat(string path) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) { return new VfsFileInfo(resolved.Status(), 0); }
            VfsFileInfo info = resolved.Volume().StatRootFile(resolved.LocalPath());
            if (path.Length > 1 && PathByte(path, path.Length - 1) == 47 &&
                info.Exists() && info.Kind() != 2) {
                return new VfsFileInfo(VfsStatus.InvalidArgument(), 0);
            }
            return info;
        }

        public VfsFileHandle Open(string path) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) {
                return new VfsFileHandle(null, path, 0, 0, 0, resolved.Status());
            }
            if (path.Length > 1 && PathByte(path, path.Length - 1) == 47) {
                return new VfsFileHandle(null, path, 0, 0, 0,
                    VfsStatus.InvalidArgument());
            }
            return resolved.Volume().OpenRootFile(resolved.LocalPath());
        }

        public VfsFileHandle OpenWrite(string path) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) {
                return new VfsFileHandle(null, path, 0, 0, 0, resolved.Status());
            }
            if (path.Length > 1 && PathByte(path, path.Length - 1) == 47) {
                return new VfsFileHandle(null, path, 0, 0, 0,
                    VfsStatus.InvalidArgument());
            }
            return resolved.Volume().OpenRootFileWrite(resolved.LocalPath());
        }

        public int CreateFile(string path, byte[] contents) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) { return resolved.Status(); }
            if (path.Length > 1 && PathByte(path, path.Length - 1) == 47) {
                return VfsStatus.InvalidArgument();
            }
            return resolved.Volume().CreateRootFile(resolved.LocalPath(), contents);
        }

        public int DeleteFile(string path) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) { return resolved.Status(); }
            return resolved.Volume().DeleteRootFile(resolved.LocalPath());
        }

        public int Mkdir(string path) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) { return resolved.Status(); }
            return resolved.Volume().MkdirRoot(resolved.LocalPath());
        }

        public int Rmdir(string path) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) { return resolved.Status(); }
            return resolved.Volume().RmdirRoot(resolved.LocalPath());
        }

        public int Rename(string source, string destination) {
            VfsPath first = Resolve(source);
            if (!first.IsValid()) { return first.Status(); }
            VfsPath second = Resolve(destination);
            if (!second.IsValid()) { return second.Status(); }
            if (first.Volume() != second.Volume()) { return VfsStatus.CrossDevice(); }
            return first.Volume().RenameRoot(first.LocalPath(), second.LocalPath());
        }

        public VfsDirectoryResult DirectoryInfo(string path) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) { return new VfsDirectoryResult(resolved.Status(), 0); }
            return resolved.Volume().DirectoryInfoAt(resolved.LocalPath());
        }

        public int ReadDirectoryName(string path, int index, byte[] destination) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) { return -resolved.Status(); }
            return resolved.Volume().ReadDirectoryNameAt(resolved.LocalPath(), index, destination);
        }

        public int DirectorySlotCount(string path) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) { return -1; }
            return resolved.Volume().DirectorySlotCountAt(resolved.LocalPath());
        }

        public int CopyDirectoryEntryName(string path, int index, byte[] destination) {
            VfsPath resolved = Resolve(path);
            if (!resolved.IsValid()) { return -1; }
            return resolved.Volume().CopyDirectoryEntryNameAt(
                resolved.LocalPath(), index, destination);
        }
    }

    // The initial VFS has one root mount. It performs the common block-range
    // validation once, so individual filesystem drivers can assume that every
    // `Partition` they receive is inside the owning live block device.
    public class Vfs {
        private IFileSystem rootFileSystem;
        private BlockDevice rootDevice;
        private Partition rootPartition;
        private int lastStatus;
        private int mountIdentity;
        private int mountGeneration;
        private IWritableFileSystem writableRoot;
        private int mutationGeneration;

        public Vfs() {
            rootFileSystem = null;
            rootDevice = null;
            rootPartition = new Partition(false, false, 0, 0, 0);
            lastStatus = VfsStatus.NotMounted();
            mountIdentity = 0; mountGeneration = 0;
            writableRoot = null;
            mutationGeneration = 0;
        }

        public bool IsRootMounted() { return rootFileSystem != null; }
        public int LastStatus() { return lastStatus; }
        public Partition RootPartition() { return rootPartition; }
        public int MountIdentity() { return mountIdentity; }
        public int MountGeneration() { return mountGeneration; }
        public int MutationGeneration() { return mutationGeneration; }

        public int MountRoot(IFileSystem fileSystem, BlockDevice device, Partition partition) {
            return MountRootAs(fileSystem, device, partition, 1);
        }

        public int MountRootAs(IFileSystem fileSystem, BlockDevice device, Partition partition,
            int identity) {
            if (fileSystem == null || device == null || partition == null || !partition.Present() ||
                identity < 1 ||
                partition.FirstLba() < 0 || partition.BlockCount() <= 0 ||
                partition.FirstLba() >= device.SectorCount() ||
                partition.BlockCount() > device.SectorCount() - partition.FirstLba()) {
                lastStatus = VfsStatus.InvalidArgument();
                return lastStatus;
            }

            // A failed remount must not leave a stale root pointing at a
            // filesystem driver that may already have released its mount data.
            rootFileSystem = null; writableRoot = null;
            rootDevice = null;
            rootPartition = new Partition(false, false, 0, 0, 0);
            mountIdentity = 0; mountGeneration = mountGeneration + 1;
            mutationGeneration = mutationGeneration + 1;
            if (fileSystem.Mount(device, partition) != VfsStatus.Ok()) {
                lastStatus = VfsStatus.MountFailed();
                return lastStatus;
            }

            rootFileSystem = fileSystem;
            rootDevice = device;
            rootPartition = partition;
            mountIdentity = identity;
            lastStatus = VfsStatus.Ok();
            return lastStatus;
        }

        // Trusted kernel callers opt in; regular mounts never gain write access.
        public int MountRootWritableAs(IWritableFileSystem fileSystem,
            BlockDevice device,
            Partition partition, int identity) {
            if (fileSystem == null || device == null || partition == null ||
                !partition.Present() || identity < 1 ||
                partition.FirstLba() < 0 || partition.BlockCount() <= 0 ||
                partition.FirstLba() >= device.SectorCount() ||
                partition.BlockCount() > device.SectorCount() - partition.FirstLba()) {
                lastStatus = VfsStatus.InvalidArgument(); return lastStatus;
            }
            rootFileSystem = null; writableRoot = null; rootDevice = null;
            rootPartition = new Partition(false, false, 0, 0, 0);
            mountIdentity = 0; mountGeneration = mountGeneration + 1;
            mutationGeneration = mutationGeneration + 1;
            int status = fileSystem.MountWritable(device, partition);
            if (status != VfsStatus.Ok()) { lastStatus = status; return status; }
            rootFileSystem = fileSystem; writableRoot = fileSystem;
            rootDevice = device; rootPartition = partition;
            mountIdentity = identity; lastStatus = VfsStatus.Ok();
            return lastStatus;
        }

        public void UnmountRoot() {
            rootFileSystem = null; writableRoot = null; rootDevice = null;
            rootPartition = new Partition(false, false, 0, 0, 0);
            mountIdentity = 0; mountGeneration = mountGeneration + 1;
            mutationGeneration = mutationGeneration + 1;
            lastStatus = VfsStatus.NotMounted();
        }

        public VfsFileHandle OpenRootFile(string path) {
            VfsFileInfo info = StatRootFile(path);
            if (!info.Exists()) {
                return new VfsFileHandle(null, path, 0, 0, 0, info.Status());
            }
            if (info.Kind() != 1) {
                return new VfsFileHandle(null, path, 0, 0, 0, VfsStatus.InvalidArgument());
            }
            return new VfsFileHandle(this, path, mountIdentity, mountGeneration,
                info.ByteLength(), info.ObjectId(), false, VfsStatus.Ok());
        }

        public VfsFileHandle OpenRootFileWrite(string path) {
            VfsFileInfo info = StatRootFile(path);
            if (!info.Exists()) {
                return new VfsFileHandle(null, path, 0, 0, 0, info.Status());
            }
            if (info.Kind() != 1) {
                return new VfsFileHandle(null, path, 0, 0, 0, VfsStatus.InvalidArgument());
            }
            if (writableRoot == null || !writableRoot.IsWritable()) {
                return new VfsFileHandle(null, path, 0, 0, 0, VfsStatus.ReadOnly());
            }
            return new VfsFileHandle(this, path, mountIdentity, mountGeneration,
                info.ByteLength(), info.ObjectId(), true, VfsStatus.Ok());
        }

        private int CheckOpenFile(string path, int identity, int generation,
            int mutation, long objectId) {
            if (rootFileSystem == null || identity != mountIdentity ||
                generation != mountGeneration) { return VfsStatus.NotMounted(); }
            if (mutation != mutationGeneration) { return VfsStatus.StaleHandle(); }
            VfsFileInfo current = StatRootFile(path);
            if (!current.Exists() || current.Kind() != 1 ||
                (objectId != 0 && current.ObjectId() != objectId)) {
                return VfsStatus.StaleHandle();
            }
            return VfsStatus.Ok();
        }

        public int OpenFileStatus(string path, int identity, int generation,
            int mutation, long objectId) {
            lastStatus = CheckOpenFile(path, identity, generation, mutation, objectId);
            return lastStatus;
        }

        public int ReadOpenFile(string path, int identity, int generation, long offset,
            byte[] destination) {
            return ReadOpenFile(path, identity, generation, mutationGeneration,
                0, offset, destination);
        }

        public int ReadOpenFile(string path, int identity, int generation,
            int mutation, long objectId, long offset, byte[] destination) {
            int checked = CheckOpenFile(path, identity, generation, mutation, objectId);
            if (checked != VfsStatus.Ok()) { lastStatus = checked; return checked; }
            return ReadRootFile(path, offset, destination);
        }

        public int WriteOpenFile(string path, int identity, int generation,
            int mutation, long objectId, byte[] contents, int operation) {
            int checked = CheckOpenFile(path, identity, generation, mutation, objectId);
            if (checked != VfsStatus.Ok()) { lastStatus = checked; return checked; }
            if (writableRoot == null || !writableRoot.IsWritable()) {
                lastStatus = VfsStatus.ReadOnly(); return lastStatus;
            }
            if (contents == null || (operation != 1 && operation != 2)) {
                lastStatus = VfsStatus.InvalidArgument(); return lastStatus;
            }
            if (operation == 1) { lastStatus = writableRoot.ReplaceFile(path, contents); }
            else { lastStatus = writableRoot.AppendFile(path, contents); }
            return MutationResult(lastStatus);
        }

        public int TruncateOpenFile(string path, int identity, int generation,
            int mutation, long objectId, long length) {
            int checked = CheckOpenFile(path, identity, generation, mutation, objectId);
            if (checked != VfsStatus.Ok()) { lastStatus = checked; return checked; }
            if (writableRoot == null || !writableRoot.IsWritable()) {
                lastStatus = VfsStatus.ReadOnly(); return lastStatus;
            }
            return MutationResult(writableRoot.TruncateFile(path, length));
        }

        private int MutationResult(int status) {
            if (status == VfsStatus.Ok()) {
                mutationGeneration = mutationGeneration + 1;
            }
            if (status == VfsStatus.IoFailure() && writableRoot != null &&
                !writableRoot.IsWritable()) {
                UnmountRoot();
            }
            lastStatus = status; return status;
        }

        public int CreateRootFile(string path, byte[] contents) {
            if (rootFileSystem == null) { lastStatus = VfsStatus.NotMounted(); }
            else if (writableRoot == null || !writableRoot.IsWritable()) {
                lastStatus = VfsStatus.ReadOnly();
            } else { return MutationResult(writableRoot.CreateFile(path, contents)); }
            return lastStatus;
        }
        public int DeleteRootFile(string path) {
            if (rootFileSystem == null) { lastStatus = VfsStatus.NotMounted(); }
            else if (writableRoot == null || !writableRoot.IsWritable()) {
                lastStatus = VfsStatus.ReadOnly();
            } else { return MutationResult(writableRoot.DeleteFile(path)); }
            return lastStatus;
        }
        public int MkdirRoot(string path) {
            if (rootFileSystem == null) { lastStatus = VfsStatus.NotMounted(); }
            else if (writableRoot == null || !writableRoot.IsWritable()) {
                lastStatus = VfsStatus.ReadOnly();
            } else { return MutationResult(writableRoot.Mkdir(path)); }
            return lastStatus;
        }
        public int RmdirRoot(string path) {
            if (rootFileSystem == null) { lastStatus = VfsStatus.NotMounted(); }
            else if (writableRoot == null || !writableRoot.IsWritable()) {
                lastStatus = VfsStatus.ReadOnly();
            } else { return MutationResult(writableRoot.Rmdir(path)); }
            return lastStatus;
        }
        public int RenameRoot(string source, string destination) {
            if (rootFileSystem == null) { lastStatus = VfsStatus.NotMounted(); }
            else if (writableRoot == null || !writableRoot.IsWritable()) {
                lastStatus = VfsStatus.ReadOnly();
            } else { return MutationResult(writableRoot.Rename(source, destination)); }
            return lastStatus;
        }

        public VfsDirectoryResult DirectoryInfoAt(string path) {
            if (rootFileSystem == null) {
                return new VfsDirectoryResult(VfsStatus.NotMounted(), 0);
            }
            if (path != "/") {
                VfsFileInfo info = StatRootFile(path);
                if (!info.Exists()) { return new VfsDirectoryResult(info.Status(), 0); }
                if (info.Kind() != 2) {
                    return new VfsDirectoryResult(VfsStatus.InvalidArgument(), 0);
                }
            }
            int count = rootFileSystem.DirectorySlotCountAt(path);
            if (count < 0) { return new VfsDirectoryResult(VfsStatus.IoFailure(), 0); }
            return new VfsDirectoryResult(VfsStatus.Ok(), count);
        }

        // On success returns the name length; failures are negative statuses.
        public int ReadDirectoryNameAt(string path, int index, byte[] destination) {
            VfsDirectoryResult info = DirectoryInfoAt(path);
            if (info.Status() != VfsStatus.Ok()) { return -info.Status(); }
            if (index < 0 || index >= info.Count() || destination == null) {
                return -VfsStatus.InvalidArgument();
            }
            int length = rootFileSystem.CopyDirectoryEntryNameAt(path, index, destination);
            if (length < 0) { return -VfsStatus.IoFailure(); }
            return length;
        }

        public bool Exists(string path) {
            if (rootFileSystem == null) {
                lastStatus = VfsStatus.NotMounted();
                return false;
            }
            if (path == null) { lastStatus = VfsStatus.InvalidArgument(); return false; }
            VfsFileInfo result = rootFileSystem.Stat(path);
            if (result == null) { lastStatus = VfsStatus.Corrupt(); return false; }
            lastStatus = result.Status();
            return result.Exists();
        }

        public VfsFileInfo StatRootFile(string path) {
            if (rootFileSystem == null) {
                lastStatus = VfsStatus.NotMounted();
                return new VfsFileInfo(lastStatus, 0);
            }
            if (path == null) {
                lastStatus = VfsStatus.InvalidArgument();
                return new VfsFileInfo(lastStatus, 0);
            }
            VfsFileInfo result = rootFileSystem.Stat(path);
            if (result == null) {
                lastStatus = VfsStatus.Corrupt();
                return new VfsFileInfo(lastStatus, 0);
            }
            if (path == "/" && (result.Status() == VfsStatus.NotFound() ||
                result.Status() == VfsStatus.InvalidArgument()) &&
                rootFileSystem.DirectorySlotCountAt("/") >= 0) {
                VfsFileInfo rootInfo = new VfsFileInfo(VfsStatus.Ok(), 0);
                rootInfo.SetMetadata(2, 0, 0, 0, 0, 0);
                lastStatus = VfsStatus.Ok(); return rootInfo;
            }
            lastStatus = result.Status();
            return result;
        }

        public int ReadRootFile(string path, long offset, byte[] destination) {
            if (rootFileSystem == null) {
                lastStatus = VfsStatus.NotMounted();
                return lastStatus;
            }
            if (path == null || offset < 0 || destination == null) {
                lastStatus = VfsStatus.InvalidArgument();
                return lastStatus;
            }
            lastStatus = rootFileSystem.ReadFile(path, offset, destination);
            if (lastStatus == VfsStatus.IoFailure() && writableRoot != null) {
                UnmountRoot();
                lastStatus = VfsStatus.IoFailure();
            }
            return lastStatus;
        }

        // HyFS v1 has a flat root directory. Empty slots return a zero name
        // length; a negative result means the request failed.
        public int RootDirectorySlotCount() {
            if (rootFileSystem == null) { lastStatus = VfsStatus.NotMounted(); return -1; }
            lastStatus = VfsStatus.Ok();
            return rootFileSystem.DirectorySlotCount();
        }

        public int CopyRootDirectoryEntryName(int index, byte[] destination) {
            if (rootFileSystem == null) { lastStatus = VfsStatus.NotMounted(); return -1; }
            if (index < 0 || destination == null) { lastStatus = VfsStatus.InvalidArgument(); return -1; }
            int length = rootFileSystem.CopyDirectoryEntryName(index, destination);
            if (length < 0) { lastStatus = VfsStatus.InvalidArgument(); return -1; }
            lastStatus = VfsStatus.Ok();
            return length;
        }

        public int DirectorySlotCountAt(string path) {
            if (rootFileSystem == null) { lastStatus = VfsStatus.NotMounted(); return -1; }
            if (path == null) { lastStatus = VfsStatus.InvalidArgument(); return -1; }
            int count = rootFileSystem.DirectorySlotCountAt(path);
            if (count < 0) { lastStatus = VfsStatus.InvalidArgument(); return -1; }
            lastStatus = VfsStatus.Ok(); return count;
        }

        public int CopyDirectoryEntryNameAt(string path, int index, byte[] destination) {
            if (rootFileSystem == null) { lastStatus = VfsStatus.NotMounted(); return -1; }
            if (path == null || index < 0 || destination == null) {
                lastStatus = VfsStatus.InvalidArgument(); return -1;
            }
            int length = rootFileSystem.CopyDirectoryEntryNameAt(path, index, destination);
            if (length < 0) { lastStatus = VfsStatus.InvalidArgument(); return -1; }
            lastStatus = VfsStatus.Ok(); return length;
        }
    }
}
