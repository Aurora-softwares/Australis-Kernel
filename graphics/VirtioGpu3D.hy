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
        private int contextId;
        private int resourceId;
        private long nextFence;
        private bool probeVertexCreated;
        private bool probeVertexBacked;
        private bool probeVertexAttached;
        private byte[] command;
        public VirtioGpu3D(IVirtioGpuControl inputControl,
            bool inputFeatureEnabled, int inputCapsetCount) {
            Initialize(inputControl, inputFeatureEnabled, inputCapsetCount,
                1, 65536);
        }
        public VirtioGpu3D(IVirtioGpuControl inputControl,
            bool inputFeatureEnabled, int inputCapsetCount,
            int inputContextId, int inputResourceId) {
            Initialize(inputControl, inputFeatureEnabled, inputCapsetCount,
                inputContextId, inputResourceId);
        }
        private void Initialize(IVirtioGpuControl inputControl,
            bool inputFeatureEnabled, int inputCapsetCount,
            int inputContextId, int inputResourceId) {
            control = inputControl;
            featureEnabled = inputFeatureEnabled;
            capsetCount = inputCapsetCount;
            contextId = inputContextId; resourceId = inputResourceId;
            capsetId = 0; capsetVersion = 0; capsetBytes = 0;
            contextReady = false; faulted = false;
            nextFence = (long)(contextId - 1) * 1000000 + 1;
            probeVertexCreated = false;
            probeVertexBacked = false;
            probeVertexAttached = false;
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
                contextId < 1 || contextId > 32 ||
                resourceId < 65536 || resourceId > 65567 ||
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
            Header(512, 96, contextId); // CTX_CREATE
            if (!ExecuteActive(96, 4352)) { return false; }
            contextReady = true; return true;
        }
        // The transport is intentionally limited to 224 bytes of kernel
        // generated, four-byte aligned VirGL commands per fenced request.
        public bool SubmitKernelCommands(byte[] stream, int length) {
            if (!Ready() || stream == null || length < 4 ||
                length > 224 || length > stream.Length ||
                length % 4 != 0) { return false; }
            Header(519, length + 32, contextId); // SUBMIT_3D
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
                height < 1 || width > 2048 || height > 2048 ||
                bytes > 4194304 || backing < 4096 ||
                backing % 4096 != 0 || backingBytes < bytes ||
                backingBytes > 4194304) { return false; }
            Header(516, 72, 0); // RESOURCE_CREATE_3D
            Write32(24, resourceId); // Separate from the 2D resource IDs.
            Write32(28, 2); // PIPE_TEXTURE_2D
            Write32(32, 1); // PIPE_FORMAT_B8G8R8A8_UNORM
            Write32(36, 10); // RENDER_TARGET | SAMPLER_VIEW
            Write32(40, width); Write32(44, height);
            Write32(48, 1); Write32(52, 1); // depth, array size
            if (!ExecuteActive(72, 4352)) { return false; }
            textureCreated = true; textureWidth = width;
            textureHeight = height;
            Header(262, 48, 0); // RESOURCE_ATTACH_BACKING
            Write32(24, resourceId); Write32(28, 1);
            Write64(32, backing); Write32(40, backingBytes);
            if (!ExecuteActive(48, 4352)) { return false; }
            textureBacked = true;
            Header(514, 32, contextId); // CTX_ATTACH_RESOURCE
            Write32(24, resourceId);
            if (!ExecuteActive(32, 4352)) { return false; }
            textureAttached = true;
            return UploadTexture();
        }
        public bool UploadTexture() {
            return UploadTextureRegion(0, 0, textureWidth, textureHeight);
        }
        // The transfer box and backing offset describe the same subregion.
        // Keeping the full texture stride avoids repacking unaffected rows.
        public bool UploadTextureRegion(int x, int y, int width,
            int height) {
            if (!TextureReady() || x < 0 || y < 0 || width < 1 ||
                height < 1 || (long)x + width > textureWidth ||
                (long)y + height > textureHeight) { return false; }
            Header(517, 72, contextId); // TRANSFER_TO_HOST_3D
            Write32(24, x); Write32(28, y);
            Write32(36, width); Write32(40, height);
            Write32(44, 1); // depth
            Write64(48, ((long)y * textureWidth + x) * 4);
            Write32(56, resourceId);
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
            Stream32(stream, 4, resourceId); // resource handle
            Stream32(stream, 24, textureWidth);
            Stream32(stream, 28, textureHeight);
            Stream32(stream, 32, 1); // depth
            Stream32(stream, 36, (long)rgb + 4278190080);
            return SubmitKernelCommands(stream, 52);
        }
        // Exercise the render-target and source-alpha state needed by the
        // compositor before attaching a shader and drawing window geometry.
        // The handles are private to this short-lived probe context.
        public bool ProbeBlendState() {
            if (!TextureReady()) { return false; }
            byte[] surface = new byte[24];
            Stream32(surface, 0, 1 + 8 * 256 + 5 * 65536);
            Stream32(surface, 4, 1);
            Stream32(surface, 8, resourceId);
            Stream32(surface, 12, 1);
            if (!SubmitKernelCommands(surface, 24)) { return false; }
            byte[] framebuffer = new byte[16];
            Stream32(framebuffer, 0, 5 + 3 * 65536);
            Stream32(framebuffer, 4, 1);
            Stream32(framebuffer, 12, 1);
            bool configured = SubmitKernelCommands(framebuffer, 16);
            byte[] blend = new byte[48];
            Stream32(blend, 0, 1 + 256 + 11 * 65536);
            Stream32(blend, 4, 2);
            // RGB = src * src-alpha + dst * (1 - src-alpha).
            // Alpha = src + dst * (1 - src-alpha).
            Stream32(blend, 16, 1 + 3 * 16 + 19 * 512 +
                1 * 131072 + 19 * 4194304 + 15 * 134217728);
            bool created = configured && SubmitKernelCommands(blend, 48);
            byte[] bind = new byte[8];
            Stream32(bind, 0, 2 + 256 + 65536);
            Stream32(bind, 4, 2);
            return created && SubmitKernelCommands(bind, 8);
        }
        private bool SubmitShader(int handle, int stage,
            byte[] text, int textLength) {
            if (!TextureReady() || text == null || textLength < 4 ||
                textLength > text.Length || text[textLength - 1] != 0) {
                return false;
            }
            int padded = (textLength + 3) / 4 * 4;
            if (24 + padded > 224) { return false; }
            byte[] stream = new byte[24 + padded];
            Stream32(stream, 0, 1 + 4 * 256 +
                (5 + padded / 4) * 65536);
            Stream32(stream, 4, handle);
            Stream32(stream, 8, stage);
            Stream32(stream, 12, textLength);
            Stream32(stream, 16, 128); // ample TGSI token capacity
            int i = 0;
            while (i < textLength) {
                stream[24 + i] = text[i]; i = i + 1;
            }
            return SubmitKernelCommands(stream, stream.Length);
        }
        public bool ProbeShaderState() {
            if (!TextureReady()) { return false; }
            // Little-endian ASCII TGSI text. Vertex: pass IN[0] to POSITION.
            // Fragment: output (1, 0, 0, 0.5) for a measurable blend test.
            byte[] vertex = new byte[60];
            Stream32(vertex, 0, 1414677846);
            Stream32(vertex, 4, 1279476746);
            Stream32(vertex, 8, 1531857184);
            Stream32(vertex, 12, 1141529904);
            Stream32(vertex, 16, 1327516739);
            Stream32(vertex, 20, 811291733);
            Stream32(vertex, 24, 1344285789);
            Stream32(vertex, 28, 1414091599);
            Stream32(vertex, 32, 172904265);
            Stream32(vertex, 36, 542527309);
            Stream32(vertex, 40, 1532253519);
            Stream32(vertex, 44, 539778352);
            Stream32(vertex, 48, 811290185);
            Stream32(vertex, 52, 1313147485);
            Stream32(vertex, 56, 2628);
            byte[] fragment = new byte[80];
            Stream32(fragment, 0, 1195463238);
            Stream32(fragment, 4, 1279476746);
            Stream32(fragment, 8, 1414876960);
            Stream32(fragment, 12, 744304731);
            Stream32(fragment, 16, 1280262944);
            Stream32(fragment, 20, 811291215);
            Stream32(fragment, 24, 1296632413);
            Stream32(fragment, 28, 1563450189);
            Stream32(fragment, 32, 1414284832);
            Stream32(fragment, 36, 2065707571);
            Stream32(fragment, 40, 539767072);
            Stream32(fragment, 44, 807414832);
            Stream32(fragment, 48, 774905900);
            Stream32(fragment, 52, 175972405);
            Stream32(fragment, 56, 542527309);
            Stream32(fragment, 60, 1532253519);
            Stream32(fragment, 64, 539778352);
            Stream32(fragment, 68, 1531792713);
            Stream32(fragment, 72, 1158307120);
            Stream32(fragment, 76, 672846);
            if (!SubmitShader(3, 0, vertex, 59) ||
                !SubmitShader(4, 1, fragment, 80)) { return false; }
            byte[] command = new byte[12];
            Stream32(command, 0, 31 + 2 * 65536);
            Stream32(command, 4, 3);
            if (!SubmitKernelCommands(command, 12)) { return false; }
            Stream32(command, 4, 4);
            Stream32(command, 8, 1);
            if (!SubmitKernelCommands(command, 12)) { return false; }
            byte[] link = new byte[28];
            Stream32(link, 0, 52 + 6 * 65536);
            Stream32(link, 4, 3);
            Stream32(link, 8, 4);
            return SubmitKernelCommands(link, 28);
        }
        private bool ProbeTriangleStates() {
            byte[] viewport = new byte[32];
            Stream32(viewport, 0, 4 + 7 * 65536);
            Stream32(viewport, 8, 1107296256); // 32.0f
            Stream32(viewport, 12, 1107296256);
            Stream32(viewport, 16, 1065353216);
            Stream32(viewport, 20, 1107296256);
            Stream32(viewport, 24, 1107296256);
            if (!SubmitKernelCommands(viewport, 32)) { return false; }
            byte[] dsa = new byte[24];
            Stream32(dsa, 0, 1 + 3 * 256 + 5 * 65536);
            Stream32(dsa, 4, 5);
            if (!SubmitKernelCommands(dsa, 24)) { return false; }
            byte[] raster = new byte[40];
            Stream32(raster, 0, 1 + 2 * 256 + 9 * 65536);
            Stream32(raster, 4, 6);
            Stream32(raster, 8, 1610645506);
            Stream32(raster, 12, 1065353216);
            Stream32(raster, 24, 1065353216);
            if (!SubmitKernelCommands(raster, 40)) { return false; }
            byte[] elements = new byte[24];
            Stream32(elements, 0, 1 + 5 * 256 + 5 * 65536);
            Stream32(elements, 4, 7);
            Stream32(elements, 20, 31); // R32G32B32A32_FLOAT
            if (!SubmitKernelCommands(elements, 24)) { return false; }
            byte[] bind = new byte[8];
            Stream32(bind, 0, 2 + 3 * 256 + 65536);
            Stream32(bind, 4, 5);
            if (!SubmitKernelCommands(bind, 8)) { return false; }
            Stream32(bind, 0, 2 + 2 * 256 + 65536);
            Stream32(bind, 4, 6);
            if (!SubmitKernelCommands(bind, 8)) { return false; }
            Stream32(bind, 0, 2 + 5 * 256 + 65536);
            Stream32(bind, 4, 7);
            return SubmitKernelCommands(bind, 8);
        }
        public bool ProbeAlphaTriangle(long vertexBacking) {
            if (!TextureReady() || vertexBacking < 4096 ||
                vertexBacking % 4096 != 0 || !ProbeTriangleStates()) {
                return false;
            }
            byte[] clear = new byte[36];
            Stream32(clear, 0, 7 + 8 * 65536);
            Stream32(clear, 4, 4); // PIPE_CLEAR_COLOR0
            Stream32(clear, 12, 1065353216); // green
            Stream32(clear, 20, 1065353216); // alpha
            Stream32(clear, 28, 1072693248); // depth 1.0 high word
            if (!SubmitKernelCommands(clear, 36)) { return false; }
            int vertexId = resourceId + 16;
            Header(516, 72, 0); // RESOURCE_CREATE_3D, PIPE_BUFFER
            Write32(24, vertexId);
            Write32(32, 64); // PIPE_FORMAT_R8_UNORM for buffer bytes
            Write32(36, 16); // VERTEX_BUFFER bind
            Write32(40, 48); // three vec4 vertices
            Write32(44, 1); Write32(48, 1); Write32(52, 1);
            if (!ExecuteActive(72, 4352)) { return false; }
            probeVertexCreated = true;
            Header(262, 48, 0);
            Write32(24, vertexId); Write32(28, 1);
            Write64(32, vertexBacking); Write32(40, 4096);
            if (!ExecuteActive(48, 4352)) { return false; }
            probeVertexBacked = true;
            Header(514, 32, contextId);
            Write32(24, vertexId);
            if (!ExecuteActive(32, 4352)) { return false; }
            probeVertexAttached = true;
            System.Kernel.Memory.Write32(vertexBacking, 3212836864);
            System.Kernel.Memory.Write32(vertexBacking + 4, 3212836864);
            System.Kernel.Memory.Write32(vertexBacking + 8, 0);
            System.Kernel.Memory.Write32(vertexBacking + 12, 1065353216);
            System.Kernel.Memory.Write32(vertexBacking + 16, 1077936128);
            System.Kernel.Memory.Write32(vertexBacking + 20, 3212836864);
            System.Kernel.Memory.Write32(vertexBacking + 24, 0);
            System.Kernel.Memory.Write32(vertexBacking + 28, 1065353216);
            System.Kernel.Memory.Write32(vertexBacking + 32, 3212836864);
            System.Kernel.Memory.Write32(vertexBacking + 36, 1077936128);
            System.Kernel.Memory.Write32(vertexBacking + 40, 0);
            System.Kernel.Memory.Write32(vertexBacking + 44, 1065353216);
            System.Kernel.Memory.Fence();
            Header(517, 72, contextId); // TRANSFER_TO_HOST_3D
            Write32(36, 48); Write32(40, 1); Write32(44, 1);
            Write32(56, vertexId);
            if (!ExecuteActive(72, 4352)) { return false; }
            byte[] vertexBuffer = new byte[16];
            Stream32(vertexBuffer, 0, 6 + 3 * 65536);
            Stream32(vertexBuffer, 4, 16);
            Stream32(vertexBuffer, 12, vertexId);
            if (!SubmitKernelCommands(vertexBuffer, 16)) { return false; }
            byte[] draw = new byte[52];
            Stream32(draw, 0, 8 + 12 * 65536);
            Stream32(draw, 8, 3);
            Stream32(draw, 12, 4); // TRIANGLES
            Stream32(draw, 20, 1); // instance count
            Stream32(draw, 44, 2); // max vertex index
            return SubmitKernelCommands(draw, 52);
        }
        public bool DestroyProbeVertex() {
            if (!probeVertexCreated || control == null) { return false; }
            int vertexId = resourceId + 16;
            bool detached = true;
            if (probeVertexAttached) {
                Header(515, 32, contextId);
                Write32(24, vertexId);
                detached = control.Execute(command, 32, 4352);
            }
            bool backingDetached = true;
            if (probeVertexBacked) {
                Header(263, 32, 0);
                Write32(24, vertexId);
                backingDetached = control.Execute(command, 32, 4352);
            }
            Header(258, 32, 0);
            Write32(24, vertexId);
            bool released = control.Execute(command, 32, 4352);
            if (!detached || !backingDetached || !released) {
                faulted = true;
            }
            if (detached && backingDetached && released) {
                probeVertexCreated = false; probeVertexBacked = false;
                probeVertexAttached = false;
            }
            return detached && backingDetached && released;
        }
        public bool ProbeVertexCreated() { return probeVertexCreated; }
        // Select this kernel-owned texture as a scanout and flush its changed
        // rectangle. A compositor must keep a software scanout to restore if
        // this path fails or VirGL becomes unavailable.
        public bool ScanoutTexture(int scanoutId) {
            if (!TextureReady() || scanoutId < 0 || scanoutId >= 16) {
                return false;
            }
            Header(259, 48, 0); // SET_SCANOUT
            Write32(32, textureWidth); Write32(36, textureHeight);
            Write32(40, scanoutId); Write32(44, resourceId);
            return ExecuteActive(48, 4352);
        }
        public bool FlushTexture(int x, int y, int width, int height) {
            if (!TextureReady() || x < 0 || y < 0 || width < 1 ||
                height < 1 || (long)x + width > textureWidth ||
                (long)y + height > textureHeight) { return false; }
            Header(260, 48, 0); // RESOURCE_FLUSH
            Write32(24, x); Write32(28, y);
            Write32(32, width); Write32(36, height);
            Write32(40, resourceId);
            return ExecuteActive(48, 4352);
        }
        public bool DisableScanout(int scanoutId) {
            if (!Ready() || scanoutId < 0 || scanoutId >= 16) {
                return false;
            }
            Header(259, 48, 0); // SET_SCANOUT with resource zero
            Write32(40, scanoutId);
            return ExecuteActive(48, 4352);
        }
        // Copy between two kernel-owned textures. The source is attached to
        // this destination context only for the duration of the fenced copy.
        public bool CopyTextureRegionFrom(VirtioGpu3D source,
            int sourceX, int sourceY, int width, int height,
            int targetX, int targetY) {
            if (!TextureReady() || source == null || source == this ||
                !source.TextureReady() ||
                source.contextId == contextId ||
                sourceX < 0 || sourceY < 0 || targetX < 0 ||
                targetY < 0 || width < 1 || height < 1 ||
                (long)sourceX + width > source.textureWidth ||
                (long)sourceY + height > source.textureHeight ||
                (long)targetX + width > textureWidth ||
                (long)targetY + height > textureHeight) {
                return false;
            }
            Header(514, 32, contextId); // CTX_ATTACH_RESOURCE
            Write32(24, source.resourceId);
            if (!ExecuteActive(32, 4352)) { return false; }
            byte[] stream = new byte[56];
            Stream32(stream, 0, 17 + 13 * 65536);
            Stream32(stream, 4, resourceId);
            Stream32(stream, 12, targetX);
            Stream32(stream, 16, targetY);
            Stream32(stream, 24, source.resourceId);
            Stream32(stream, 32, sourceX);
            Stream32(stream, 36, sourceY);
            Stream32(stream, 44, width);
            Stream32(stream, 48, height);
            Stream32(stream, 52, 1);
            bool copied = SubmitKernelCommands(stream, 56);
            Header(515, 32, contextId); // CTX_DETACH_RESOURCE
            Write32(24, source.resourceId);
            bool detached = control.Execute(command, 32, 4352);
            if (!detached) { faulted = true; }
            return copied && detached;
        }
        public bool DownloadTexture() {
            return DownloadTextureRegion(0, 0, textureWidth,
                textureHeight);
        }
        public bool DownloadTextureRegion(int x, int y, int width,
            int height) {
            if (!TextureReady() || x < 0 || y < 0 || width < 1 ||
                height < 1 || (long)x + width > textureWidth ||
                (long)y + height > textureHeight) { return false; }
            Header(518, 72, contextId); // TRANSFER_FROM_HOST_3D
            Write32(24, x); Write32(28, y);
            Write32(36, width); Write32(40, height);
            Write32(44, 1);
            Write64(48, ((long)y * textureWidth + x) * 4);
            Write32(56, resourceId);
            Write32(64, textureWidth * 4);
            Write32(68, textureWidth * textureHeight * 4);
            return ExecuteActive(72, 4352);
        }
        public bool DestroyTexture() {
            if (!textureCreated || control == null) { return false; }
            if (textureAttached) {
                Header(515, 32, contextId); // CTX_DETACH_RESOURCE
                Write32(24, resourceId);
                if (!control.Execute(command, 32, 4352)) {
                    faulted = true; return false;
                }
                textureAttached = false;
            }
            if (textureBacked) {
                Header(263, 32, 0); // RESOURCE_DETACH_BACKING
                Write32(24, resourceId);
                if (!control.Execute(command, 32, 4352)) {
                    faulted = true; return false;
                }
                textureBacked = false;
            }
            Header(258, 32, 0); // RESOURCE_UNREF
            Write32(24, resourceId);
            if (!control.Execute(command, 32, 4352)) {
                faulted = true; return false;
            }
            textureCreated = false; textureWidth = 0;
            textureHeight = 0; return true;
        }
        public bool DestroyContext() {
            if (!contextReady || control == null) { return false; }
            if (probeVertexCreated && !DestroyProbeVertex()) { return false; }
            if (textureCreated && !DestroyTexture()) { return false; }
            Header(513, 24, contextId); // CTX_DESTROY
            if (!control.Execute(command, 24, 4352)) {
                faulted = true; return false;
            }
            contextReady = false; faulted = false; return true;
        }
        // A failed synchronous command leaves no queued guest work. Reuse the
        // texture backing only after the old resource and context are fully
        // detached, then create a fresh context with the same bounded shape.
        public bool RecoverTexture(long backing, int backingBytes) {
            int width = textureWidth; int height = textureHeight;
            if (!faulted || !contextReady || !textureCreated ||
                width < 1 || height < 1 || backing < 4096 ||
                backing % 4096 != 0 ||
                backingBytes < (long)width * height * 4 ||
                !DestroyContext() || !CreateContext()) { return false; }
            return CreateTexture(width, height, backing, backingBytes);
        }
        public void Abandon() {
            contextReady = false; faulted = false;
            textureCreated = false;
            textureBacked = false; textureAttached = false;
            textureWidth = 0; textureHeight = 0;
            probeVertexCreated = false;
            probeVertexBacked = false;
            probeVertexAttached = false;
        }
    }
}
