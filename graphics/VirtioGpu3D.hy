namespace Australis.Kernel.Graphics {
    // Kernel-owned VirGL control path. No user process can supply a stream or
    // name a context through this class; later renderers must validate their
    // higher-level operations before calling SubmitKernelCommands.
    public class VirtioGpu3D {
        private IVirtioGpuControl control;
        private bool featureEnabled;
        private int capsetCount;
        private int capsetId;
        private int capsetVersion;
        private int capsetBytes;
        private bool contextReady;
        private bool faulted;
        private bool textureCreated;
        private bool textureBacked;
        private bool textureAttached;
        private int textureWidth;
        private int textureHeight;
        private long nextFence;
        private byte[] command;
        public VirtioGpu3D(IVirtioGpuControl inputControl,
            bool inputFeatureEnabled, int inputCapsetCount) {
            control = inputControl;
            featureEnabled = inputFeatureEnabled;
            capsetCount = inputCapsetCount;
            capsetId = 0; capsetVersion = 0; capsetBytes = 0;
            contextReady = false; faulted = false; nextFence = 1;
            textureCreated = false; textureBacked = false;
            textureAttached = false; textureWidth = 0; textureHeight = 0;
            command = new byte[256];
        }
        private void Write32(int offset, long value) {
            int i = 0;
            while (i < 4) {
                command[offset + i] = (byte)(value % 256);
                value = value / 256; i = i + 1;
            }
        }
        private void Write64(int offset, long value) {
            int i = 0;
            while (i < 8) {
                command[offset + i] = (byte)(value % 256);
                value = value / 256; i = i + 1;
            }
        }
        private void Header(int type, int length, int contextId) {
            int i = 0;
            while (i < length) { command[i] = 0; i = i + 1; }
            Write32(0, type);
            Write32(4, 1); // VIRTIO_GPU_FLAG_FENCE
            Write64(8, nextFence);
            Write32(16, contextId);
            nextFence = nextFence + 1;
        }
        public int CapsetId() { return capsetId; }
        public int CapsetVersion() { return capsetVersion; }
        public int CapsetBytes() { return capsetBytes; }
        public long LastFence() { return nextFence - 1; }
        public bool Faulted() { return faulted; }
        public bool Ready() { return contextReady && !faulted; }
        public bool TextureReady() {
            return Ready() && textureCreated && textureBacked &&
                textureAttached;
        }
        private bool ExecuteActive(int requestLength,
            int responseType) {
            if (faulted || control == null ||
                !control.Execute(command, requestLength, responseType)) {
                faulted = true; return false;
            }
            return true;
        }
        public bool Probe() {
            if (!featureEnabled || control == null ||
                capsetCount < 1 || capsetCount > 64 ||
                contextReady || faulted) { return false; }
            int index = 0;
            while (index < capsetCount) {
                Header(264, 32, 0); // GET_CAPSET_INFO
                Write32(24, index);
                if (!ExecuteActive(32, 4354)) { return false; }
                int id = (int)control.Response32(24);
                int version = (int)control.Response32(28);
                int bytes = (int)control.Response32(32);
                if ((id == 1 || id == 2) && version > 0 &&
                    bytes > 0 && bytes <= 1048576 &&
                    (capsetId == 0 || id == 2)) {
                    capsetId = id; capsetVersion = version;
                    capsetBytes = bytes;
                }
                index = index + 1;
            }
            return capsetId != 0;
        }
        public bool CreateContext() {
            if (contextReady || capsetId == 0 || control == null ||
                faulted) {
                return false;
            }
            Header(512, 96, 1); // CTX_CREATE, context id 1
            if (!ExecuteActive(96, 4352)) { return false; }
            contextReady = true; return true;
        }
        // The transport is intentionally limited to 224 bytes of kernel
        // generated, four-byte aligned VirGL commands per fenced request.
        public bool SubmitKernelCommands(byte[] stream, int length) {
            if (!Ready() || stream == null || length < 4 ||
                length > 224 || length > stream.Length ||
                length % 4 != 0) { return false; }
            Header(519, length + 32, 1); // SUBMIT_3D
            Write32(24, length);
            int i = 0;
            while (i < length) {
                command[32 + i] = stream[i]; i = i + 1;
            }
            return ExecuteActive(length + 32, 4352);
        }
        public bool CreateTexture(int width, int height, long backing,
            int backingBytes) {
            long bytes = (long)width * height * 4;
            if (!Ready() || textureCreated || width < 1 ||
                height < 1 || width > 256 || height > 256 ||
                bytes > 262144 || backing < 4096 ||
                backing % 4096 != 0 || backingBytes < bytes ||
                backingBytes > 262144) { return false; }
            Header(516, 72, 0); // RESOURCE_CREATE_3D
            Write32(24, 65536); // Separate from the 2D resource IDs.
            Write32(28, 2); // PIPE_TEXTURE_2D
            Write32(32, 1); // PIPE_FORMAT_B8G8R8A8_UNORM
            Write32(36, 10); // RENDER_TARGET | SAMPLER_VIEW
            Write32(40, width); Write32(44, height);
            Write32(48, 1); Write32(52, 1); // depth, array size
            if (!ExecuteActive(72, 4352)) { return false; }
            textureCreated = true; textureWidth = width;
            textureHeight = height;
            Header(262, 48, 0); // RESOURCE_ATTACH_BACKING
            Write32(24, 65536); Write32(28, 1);
            Write64(32, backing); Write32(40, backingBytes);
            if (!ExecuteActive(48, 4352)) { return false; }
            textureBacked = true;
            Header(514, 32, 1); // CTX_ATTACH_RESOURCE
            Write32(24, 65536);
            if (!ExecuteActive(32, 4352)) { return false; }
            textureAttached = true;
            return UploadTexture();
        }
        public bool UploadTexture() {
            if (!TextureReady()) { return false; }
            Header(517, 72, 1); // TRANSFER_TO_HOST_3D
            Write32(36, textureWidth); Write32(40, textureHeight);
            Write32(44, 1); // depth
            Write32(56, 65536);
            Write32(64, textureWidth * 4); // stride
            Write32(68, textureWidth * textureHeight * 4);
            return ExecuteActive(72, 4352);
        }
        private void Stream32(byte[] stream, int offset, long value) {
            int i = 0;
            while (i < 4) {
                stream[offset + i] = (byte)(value % 256);
                value = value / 256; i = i + 1;
            }
        }
        // A fixed, validated VirGL operation; callers provide only RGB.
        public bool ClearTexture(int rgb) {
            if (!TextureReady() || rgb < 0 || rgb > 16777215) {
                return false;
            }
            byte[] stream = new byte[52];
            Stream32(stream, 0, 47 + 12 * 65536); // CLEAR_TEXTURE
            Stream32(stream, 4, 65536); // resource handle
            Stream32(stream, 24, textureWidth);
            Stream32(stream, 28, textureHeight);
            Stream32(stream, 32, 1); // depth
            Stream32(stream, 36, (long)rgb + 4278190080);
            return SubmitKernelCommands(stream, 52);
        }
        public bool DownloadTexture() {
            if (!TextureReady()) { return false; }
            Header(518, 72, 1); // TRANSFER_FROM_HOST_3D
            Write32(36, textureWidth); Write32(40, textureHeight);
            Write32(44, 1); Write32(56, 65536);
            Write32(64, textureWidth * 4);
            Write32(68, textureWidth * textureHeight * 4);
            return ExecuteActive(72, 4352);
        }
        public bool DestroyTexture() {
            if (!textureCreated || control == null) { return false; }
            if (textureAttached) {
                Header(515, 32, 1); // CTX_DETACH_RESOURCE
                Write32(24, 65536);
                if (!control.Execute(command, 32, 4352)) {
                    faulted = true; return false;
                }
                textureAttached = false;
            }
            if (textureBacked) {
                Header(263, 32, 0); // RESOURCE_DETACH_BACKING
                Write32(24, 65536);
                if (!control.Execute(command, 32, 4352)) {
                    faulted = true; return false;
                }
                textureBacked = false;
            }
            Header(258, 32, 0); // RESOURCE_UNREF
            Write32(24, 65536);
            if (!control.Execute(command, 32, 4352)) {
                faulted = true; return false;
            }
            textureCreated = false; textureWidth = 0;
            textureHeight = 0; return true;
        }
        public bool DestroyContext() {
            if (!contextReady || control == null) { return false; }
            if (textureCreated && !DestroyTexture()) { return false; }
            Header(513, 24, 1); // CTX_DESTROY
            if (!control.Execute(command, 24, 4352)) {
                faulted = true; return false;
            }
            contextReady = false; faulted = false; return true;
        }
        public void Abandon() {
            contextReady = false; faulted = false;
            textureCreated = false;
            textureBacked = false; textureAttached = false;
            textureWidth = 0; textureHeight = 0;
        }
    }
}
