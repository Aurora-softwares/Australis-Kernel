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
		private bool persistentVertexCreated;
		private bool persistentVertexBacked;
		private bool persistentVertexAttached;
		private long persistentVertexBacking;
        private VirtioGpu3D[] persistentSamplerSources;
        private bool[] persistentSamplerAttached;
        private bool[] persistentSamplerViewCreated;
        private int persistentSamplerBoundSlot;
        private byte[] command;
        public VirtioGpu3D(IVirtioGpuControl inputControl, bool inputFeatureEnabled, int inputCapsetCount) {
            Initialize(inputControl, inputFeatureEnabled, inputCapsetCount, 1, 65536);
        }
        public VirtioGpu3D(IVirtioGpuControl inputControl, bool inputFeatureEnabled, int inputCapsetCount, int inputContextId, int inputResourceId) {
            Initialize(inputControl, inputFeatureEnabled, inputCapsetCount, inputContextId, inputResourceId);
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
			persistentVertexCreated = false;
			persistentVertexBacked = false;
			persistentVertexAttached = false;
			persistentVertexBacking = 0;
            persistentSamplerSources = new VirtioGpu3D[2];
            persistentSamplerAttached = new bool[2];
            persistentSamplerViewCreated = new bool[2];
            persistentSamplerBoundSlot = -1;
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
		public bool ProbeCreateSamplerState() {
			if (!TextureReady()) {
				return false;
			}

			// Create sampler state object, handle 9.
			// Default nearest filtering and repeat addressing.
			byte[] sampler = new byte[40];

			Stream32(sampler, 0,
				1 + 7 * 256 + 9 * 65536);

			Stream32(sampler, 4, 9);

			if (!SubmitKernelCommands(sampler, 40)) {
				return false;
			}

			// Bind the sampler to fragment stage slot 0.
			byte[] bind = new byte[16];

			Stream32(bind, 0, 18 + 3 * 65536);
			Stream32(bind, 4, 1);
			Stream32(bind, 8, 0);
			Stream32(bind, 12, 9);

			return SubmitKernelCommands(bind, 16);
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
		public bool ProbeUvShaderState() {
			if (!TextureReady()) { return false; }

			// TGSI vertex shader:
			// VERT
			// DCL IN[0]
			// DCL IN[1]
			// DCL OUT[0], POSITION
			// DCL OUT[1], GENERIC[0]
			// MOV OUT[0], IN[0]
			// MOV OUT[1], IN[1]
			// END

			byte[] vertex = new byte[112];
			Stream32(vertex, 0, 1414677846);
			Stream32(vertex, 4, 1279476746);
			Stream32(vertex, 8, 1531857184);
			Stream32(vertex, 12, 1141529904);
			Stream32(vertex, 16, 1226853443);
			Stream32(vertex, 20, 1563515726);
			Stream32(vertex, 24, 1279476746);
			Stream32(vertex, 28, 1414876960);
			Stream32(vertex, 32, 744304731);
			Stream32(vertex, 36, 1397706784);
			Stream32(vertex, 40, 1330205769);
			Stream32(vertex, 44, 1128532558);
			Stream32(vertex, 48, 1431248972);
			Stream32(vertex, 52, 1563515732);
			Stream32(vertex, 56, 1162289196);
			Stream32(vertex, 60, 1230128462);
			Stream32(vertex, 64, 1563450179);
			Stream32(vertex, 68, 1448037642);
			Stream32(vertex, 72, 1414876960);
			Stream32(vertex, 76, 744304731);
			Stream32(vertex, 80, 1531857184);
			Stream32(vertex, 84, 1292524848);
			Stream32(vertex, 88, 1327519311);
			Stream32(vertex, 92, 828068949);
			Stream32(vertex, 96, 1226845277);
			Stream32(vertex, 100, 1563515726);
			Stream32(vertex, 104, 1145980170);
			Stream32(vertex, 108, 10);

			// TGSI fragment shader:
			// FRAG
			// DCL IN[0], GENERIC[0], LINEAR
			// DCL OUT[0], COLOR[0]
			// DCL SAMP[0]
			// DCL SVIEW[0], 2D, FLOAT
			// TEX OUT[0], IN[0], SAMP[0], 2D
			// END

			byte[] fragment = new byte[128];
			Stream32(fragment, 0, 1195463238);
			Stream32(fragment, 4, 1279476746);
			Stream32(fragment, 8, 1531857184);
			Stream32(fragment, 12, 539778352);
			Stream32(fragment, 16, 1162757447);
			Stream32(fragment, 20, 1531136338);
			Stream32(fragment, 24, 539778352);
			Stream32(fragment, 28, 1162758476);
			Stream32(fragment, 32, 1141527105);
			Stream32(fragment, 36, 1327516739);
			Stream32(fragment, 40, 811291733);
			Stream32(fragment, 44, 1126181981);
			Stream32(fragment, 48, 1380928591);
			Stream32(fragment, 52, 173879387);
			Stream32(fragment, 56, 541868868);
			Stream32(fragment, 60, 1347240275);
			Stream32(fragment, 64, 173879387);
			Stream32(fragment, 68, 541868868);
			Stream32(fragment, 72, 1162434131);
			Stream32(fragment, 76, 1563450199);
			Stream32(fragment, 80, 1144135724);
			Stream32(fragment, 84, 1279664172);
			Stream32(fragment, 88, 173293903);
			Stream32(fragment, 92, 542655828);
			Stream32(fragment, 96, 1532253519);
			Stream32(fragment, 100, 539778352);
			Stream32(fragment, 104, 811290185);
			Stream32(fragment, 108, 1394617437);
			Stream32(fragment, 112, 1531989313);
			Stream32(fragment, 116, 539778352);
			Stream32(fragment, 120, 1158300722);
			Stream32(fragment, 124, 672846);

			if (!SubmitShader(11, 0, vertex, 110) ||
				!SubmitShader(12, 1, fragment, 128)) {
				return false;
			}

			// Bind vertex shader 11.
			byte[] bind = new byte[12];
			Stream32(bind, 0, 31 + 2 * 65536);
			Stream32(bind, 4, 11);

			if (!SubmitKernelCommands(bind, 12)) {
				return false;
			}

			// Bind fragment shader 12.
			Stream32(bind, 4, 12);
			Stream32(bind, 8, 1);

			if (!SubmitKernelCommands(bind, 12)) {
				return false;
			}

			// Link vertex outputs to fragment inputs.
			byte[] link = new byte[28];
			Stream32(link, 0, 52 + 6 * 65536);
			Stream32(link, 4, 11);
			Stream32(link, 8, 12);

			return SubmitKernelCommands(link, 28);
		}
		public bool ProbeUvVertexElements() {
			if (!TextureReady()) {
				return false;
			}

			// Two vertex attributes, both vec4 float32:
			// Attribute 0: position, offset 0
			// Attribute 1: UV, offset 16
			// Both use vertex buffer slot 0.

			byte[] elements = new byte[40];

			// CREATE_OBJECT, VERTEX_ELEMENTS, 9 payload words
			Stream32(elements, 0, 1 + 5 * 256 + 9 * 65536);
			Stream32(elements, 4, 13); // New object handle

			// Attribute 0: position
			Stream32(elements, 8, 0);  // Source byte offset
			Stream32(elements, 20, 31); // R32G32B32A32_FLOAT

			// Attribute 1: UV
			Stream32(elements, 24, 16); // Source byte offset
			Stream32(elements, 36, 31); // R32G32B32A32_FLOAT

			if (!SubmitKernelCommands(elements, 40)) {
				return false;
			}

			// Bind the new vertex-elements object.
			byte[] bind = new byte[8];
			Stream32(bind, 0, 2 + 5 * 256 + 65536);
			Stream32(bind, 4, 13);

			return SubmitKernelCommands(bind, 8);
		}
		private long RatioToFloatBits(long numerator, long denominator) {
			if (numerator == 0) {
				return 0;
			}

			long sign = 0;

			if (numerator < 0) {
				sign = 2147483648;
				numerator = 0 - numerator;
			}

			int exponent = 0;

			while (numerator < denominator) {
				numerator = numerator * 2;
				exponent = exponent - 1;
			}

			while (numerator >= denominator * 2) {
				denominator = denominator * 2;
				exponent = exponent + 1;
			}

			long mantissa =
				((numerator - denominator) * 8388608 +
				denominator / 2) / denominator;

			if (mantissa >= 8388608) {
				mantissa = 0;
				exponent = exponent + 1;
			}

			return sign +
				(long)(exponent + 127) * 8388608 +
				mantissa;
		}
		private bool WriteUvRectangleVertices(
			long backing,
			int targetWidth,
			int targetHeight,
			int x,
			int y,
			int width,
			int height) {

			if (backing < 4096 ||
				backing % 4096 != 0 ||
				targetWidth < 1 ||
				targetHeight < 1 ||
				targetWidth > 2048 ||
				targetHeight > 2048 ||
				x < 0 ||
				y < 0 ||
				width < 1 ||
				height < 1 ||
				width > targetWidth ||
				height > targetHeight ||
				x > targetWidth - width ||
				y > targetHeight - height) {
				return false;
			}

			// Convert pixel bounds to normalized device coordinates.
			// The destination uses a top-left pixel origin.
			long x0 = RatioToFloatBits((long)x * 2 - targetWidth, targetWidth);
			long x1 = RatioToFloatBits((long)(x + width) * 2 - targetWidth, targetWidth);
            long y0 = RatioToFloatBits((long)y * 2 - targetHeight, targetHeight);
            long y1 = RatioToFloatBits((long)(y + height) * 2 - targetHeight, targetHeight);
			long zero = 0;
			long one = 1065353216;

			// Two triangles:
			//
			// 2 ----- 4
			// |     / |
			// |   /   |
			// | /     |
			// 0 ----- 1
			//
			// Triangle 1: 0, 1, 2
			// Triangle 2: 3, 4, 5
			// Vertices 3 and 1 are identical.
			// Vertices 5 and 2 are identical.

			int vertex = 0;

			while (vertex < 6) {
				long address = backing + vertex * 32;

				long px = x0;
				long py = y1;
				long u = zero;
				long v = zero;

				// Right-side vertices.
				if (vertex == 1 || vertex == 3 || vertex == 4) {
					px = x1;
					u = one;
				}

				// Top-side vertices.
				if (vertex == 2 || vertex == 4 || vertex == 5) {
					py = y0;
					v = one;
				}

				// Position: vec4(x, y, 0, 1).
				System.Kernel.Memory.Write32(address, px);
				System.Kernel.Memory.Write32(address + 4, py);
				System.Kernel.Memory.Write32(address + 8, zero);
				System.Kernel.Memory.Write32(address + 12, one);

				// Texture coordinates: vec4(u, v, 0, 1).
				System.Kernel.Memory.Write32(address + 16, u);
				System.Kernel.Memory.Write32(address + 20, v);
				System.Kernel.Memory.Write32(address + 24, zero);
				System.Kernel.Memory.Write32(address + 28, one);

				vertex = vertex + 1;
			}

			return true;
		}
		public bool ProbeUvMappedDrawFrom(
			VirtioGpu3D source, long vertexBacking) {

			return ProbeUvMappedDrawGeometryFrom(
				source, vertexBacking,
				false, 0, 0, 0, 0, true, false);
		}
		public bool ProbePositionedUvMappedDrawFrom(
			VirtioGpu3D source, long vertexBacking) {

			return ProbeUvRectangleFrom(
				source, vertexBacking, 16, 16, 32, 32);
		}
		public bool ProbeUvRectangleOverlayFrom(
			VirtioGpu3D source, long vertexBacking,
			int x, int y, int width, int height) {

			return ProbeUvMappedDrawGeometryFrom(
				source, vertexBacking,
				true, x, y, width, height, false, false);
		}
		public bool ProbeUvRectanglePersistentFrom(
			VirtioGpu3D source,
			int x, int y, int width, int height,
			bool clearDestination) {

			if (!PersistentVertexBufferReady()) {
				return false;
			}

			return ProbeUvMappedDrawGeometryFrom(
				source, persistentVertexBacking,
				true, x, y, width, height,
				clearDestination, true);
		}

        public bool ProbeUvRectangleWithPersistentSampler(
            int slot,
            int x, int y, int width, int height) {

            // Both persistent resources must already exist.
            if (!PersistentVertexBufferReady() ||
                !PersistentSamplerViewReady(slot) ||
                x < 0 || y < 0 ||
                width < 1 || height < 1 ||
                width > textureWidth ||
                height > textureHeight ||
                x > textureWidth - width ||
                y > textureHeight - height) {
                return false;
            }

            int vertexId = resourceId + 256;

            // Reuse the same 192-byte GPU vertex buffer.
            // Update only the rectangle's geometry.
            if (!WriteUvRectangleVertices(
                persistentVertexBacking,
                textureWidth,
                textureHeight,
                x, y, width, height)) {
                return false;
            }

            System.Kernel.Memory.Fence();

            // Upload the six updated vertices.
            Header(517, 72, contextId);

            Write32(36, 192);
            Write32(40, 1);
            Write32(44, 1);
            Write32(56, vertexId);

            if (!ExecuteActive(72, 4352)) {
                return false;
            }

            // Bind the existing vertex buffer.
            byte[] vertexBuffer = new byte[16];

            Stream32(vertexBuffer, 0, 6 + 3 * 65536);
            Stream32(vertexBuffer, 4, 32);
            Stream32(vertexBuffer, 12, vertexId);

            if (!SubmitKernelCommands(vertexBuffer, 16)) {
                return false;
            }

            // Rebind an EXISTING sampler view.
            // No resource attachment or sampler creation.
            bool ok = BindPersistentSamplerView(slot);

            if (ok) {
                byte[] draw = new byte[52];

                Stream32(draw, 0, 8 + 12 * 65536);
                Stream32(draw, 8, 6);  // Six vertices
                Stream32(draw, 12, 4); // TRIANGLES
                Stream32(draw, 20, 1); // One instance
                Stream32(draw, 44, 5); // Highest vertex index

                ok = SubmitKernelCommands(draw, 52);
            }

            // Unbind vertices, but keep the sampler view alive.
            byte[] unbindVertex = new byte[16];

            Stream32(unbindVertex, 0, 6 + 3 * 65536);

            bool unbound =
                SubmitKernelCommands(unbindVertex, 16);

            if (!unbound) {
                faulted = true;
            }

            return ok && unbound;
        }

		public bool ProbeUvRectangleFrom(VirtioGpu3D source, long vertexBacking, int x, int y, int width, int height) {
			return ProbeUvMappedDrawGeometryFrom(source, vertexBacking, true, x, y, width, height, true, false);
		}
		private bool ProbeUvMappedDrawGeometryFrom(VirtioGpu3D source, long vertexBacking, bool positioned, int x, int y, int width, int height, bool clearDestination, bool usePersistent) {
			if (!TextureReady() || source == null ||
				source == this || !source.TextureReady() ||
				source.control != control ||
				source.contextId == contextId ||
				textureWidth < 1 || textureHeight < 1 ||
				source.textureWidth < 1 ||
				source.textureHeight < 1 ||
				vertexBacking < 4096 ||
				vertexBacking % 4096 != 0) {
				return false;
			}
			if (usePersistent && (!positioned || !PersistentVertexBufferReady() || vertexBacking != persistentVertexBacking)) {
				return false;
			}
			if (positioned && (x < 0 || y < 0 || width < 1 || height < 1 || width > textureWidth || height > textureHeight || x > textureWidth - width || y > textureHeight - height)) {
				return false;
			}
			int vertexCount = 3;
			if (positioned) {
				vertexCount = 6;
			}
			int vertexBytes = vertexCount * 32;
			int vertexId = resourceId + 17;

			if (positioned) {
				vertexId = resourceId + 18;
			}

			if (usePersistent) {
				vertexId = resourceId + 256;
			}
			if (vertexId == source.resourceId) {
				return false;
			}

			bool vertexCreated = false;
			bool vertexBacked = false;
			bool vertexAttached = false;
			bool vertexBound = false;
			bool sourceAttached = false;
			bool viewCreated = false;

			bool ok = true;

			// Only create a GPU vertex resource for temporary draws.
			// The persistent buffer was already created and attached.
			if (!usePersistent) {
				Header(516, 72, 0);
				Write32(24, vertexId);
				Write32(32, 64);
				Write32(36, 16);
				Write32(40, vertexBytes);
				Write32(44, 1);
				Write32(48, 1);
				Write32(52, 1);

				ok = ExecuteActive(72, 4352);
				vertexCreated = ok;
			}

			if (ok && !usePersistent) {
				Header(262, 48, 0);
				Write32(24, vertexId);
				Write32(28, 1);
				Write64(32, vertexBacking);
				Write32(40, 4096);

				ok = ExecuteActive(48, 4352);
				vertexBacked = ok;
			}

			if (ok && !usePersistent) {
				Header(514, 32, contextId);
				Write32(24, vertexId);

				ok = ExecuteActive(32, 4352);
				vertexAttached = ok;
			}

			// Fullscreen triangle with interpolated UVs.
			if (ok) {
				if (positioned) {
					// Generate two triangles at arbitrary pixel coordinates.
					ok = WriteUvRectangleVertices(
						vertexBacking,
						textureWidth,
						textureHeight,
						x, y, width, height);
				} else {
					// Preserve the original fullscreen triangle test.
					int vertex = 0;

					while (vertex < 3) {
						long address = vertexBacking + vertex * 32;

						long px = 3212836864;
						long py = 3212836864;
						long u = 0;
						long v = 0;

						if (vertex == 1) {
							px = 1077936128;
							u = 1073741824;
						}

						if (vertex == 2) {
							py = 1077936128;
							v = 1073741824;
						}

						System.Kernel.Memory.Write32(address, px);
						System.Kernel.Memory.Write32(address + 4, py);
						System.Kernel.Memory.Write32(address + 8, 0);
						System.Kernel.Memory.Write32(
							address + 12, 1065353216);

						System.Kernel.Memory.Write32(address + 16, u);
						System.Kernel.Memory.Write32(address + 20, v);
						System.Kernel.Memory.Write32(address + 24, 0);
						System.Kernel.Memory.Write32(
							address + 28, 1065353216);

						vertex = vertex + 1;
					}
				}

				if (ok) {
					System.Kernel.Memory.Fence();

					Header(517, 72, contextId);
					Write32(36, vertexBytes);
					Write32(40, 1);
					Write32(44, 1);
					Write32(56, vertexId);

					ok = ExecuteActive(72, 4352);
				}
			}

			if (ok) {
				byte[] buffer = new byte[16];
				Stream32(buffer, 0, 6 + 3 * 65536);
				Stream32(buffer, 4, 32); // 32-byte stride
				Stream32(buffer, 12, vertexId);
				ok = SubmitKernelCommands(buffer, 16);
				vertexBound = ok;
			}

			// Attach the independent source texture.
			if (ok) {
				Header(514, 32, contextId);
				Write32(24, source.resourceId);
				ok = ExecuteActive(32, 4352);
				sourceAttached = ok;
			}

			if (ok) {
				byte[] view = new byte[28];
				Stream32(view, 0, 1 + 6 * 256 + 6 * 65536);
				Stream32(view, 4, 10);
				Stream32(view, 8, source.resourceId);
				Stream32(view, 12, 1);
				Stream32(view, 24, 1672);
				ok = SubmitKernelCommands(view, 28);
				viewCreated = ok;
			}

			if (ok) {
				byte[] views = new byte[16];
				Stream32(views, 0, 10 + 3 * 65536);
				Stream32(views, 4, 1);
				Stream32(views, 12, 10);
				ok = SubmitKernelCommands(views, 16);
			}

			// Clear only when requested by the caller.
			if (ok && clearDestination) {
				byte[] clear = new byte[36];
				Stream32(clear, 0, 7 + 8 * 65536);
				Stream32(clear, 4, 4);
				Stream32(clear, 12, 1065353216);
				Stream32(clear, 20, 1065353216);
				Stream32(clear, 28, 1072693248);
				ok = SubmitKernelCommands(clear, 36);
			}

			if (ok) {
				byte[] draw = new byte[52];
				Stream32(draw, 0, 8 + 12 * 65536);
				Stream32(draw, 8, vertexCount);
				Stream32(draw, 12, 4); // TRIANGLES
				Stream32(draw, 20, 1);
				Stream32(draw, 44, vertexCount - 1);
				ok = SubmitKernelCommands(draw, 52);
			}

			// Clean up in reverse order, even after failure.
			bool cleaned = true;

			if (viewCreated) {
				byte[] unbind = new byte[16];
				Stream32(unbind, 0, 10 + 3 * 65536);
				Stream32(unbind, 4, 1);
				if (!SubmitKernelCommands(unbind, 16)) {
					cleaned = false;
				}

				Header(519, 40, contextId);
				Write32(24, 8);
				Write32(32, 3 + 6 * 256 + 65536);
				Write32(36, 10);
				if (!control.Execute(command, 40, 4352)) {
					cleaned = false;
				}
			}

			if (sourceAttached) {
				Header(515, 32, contextId);
				Write32(24, source.resourceId);
				if (!control.Execute(command, 32, 4352)) {
					cleaned = false;
				}
			}

			// Unbind vertex buffer slot 0 before releasing its resource.
			if (vertexBound) {
				byte[] unbindVertex = new byte[16];

				Stream32(unbindVertex, 0, 6 + 3 * 65536);

				if (!SubmitKernelCommands(unbindVertex, 16)) {
					cleaned = false;
				}
			}
			if (vertexAttached) {
				Header(515, 32, contextId);
				Write32(24, vertexId);

				if (!control.Execute(command, 32, 4352)) {
					cleaned = false;
				}
			}
			if (vertexBacked) {
				Header(263, 32, 0);
				Write32(24, vertexId);
				if (!control.Execute(command, 32, 4352)) {
					cleaned = false;
				}
			}

			if (vertexCreated) {
				Header(258, 32, 0);
				Write32(24, vertexId);
				if (!control.Execute(command, 32, 4352)) {
					cleaned = false;
				}
			}

			if (!cleaned) {
				faulted = true;
			}

			return ok && cleaned;
		}
        private bool ProbeTriangleStates() {
            if (!TextureReady() ||
                textureWidth < 1 ||
                textureHeight < 1) {
                return false;
            }

            // Gallium viewport:
            // scale = (width / 2, height / 2, 1)
            // translate = (width / 2, height / 2, 0)
            //
            // Convert dynamically instead of assuming 64x64.
            long halfWidth =
                RatioToFloatBits(textureWidth, 2);

            long halfHeight =
                RatioToFloatBits(textureHeight, 2);

            byte[] viewport = new byte[32];

            Stream32(viewport, 0, 4 + 7 * 65536);
            Stream32(viewport, 8, halfWidth);
            Stream32(viewport, 12, halfHeight);
            Stream32(viewport, 16, 1065353216);
            Stream32(viewport, 20, halfWidth);
            Stream32(viewport, 24, halfHeight);
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
        public bool ConfigureUvRenderStates() {
            return TextureReady() && ProbeTriangleStates();
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
		public bool PersistentVertexBufferReady() {
			return TextureReady() &&
				persistentVertexCreated &&
				persistentVertexBacked &&
				persistentVertexAttached &&
				persistentVertexBacking >= 4096;
		}

        public bool CreatePersistentVertexBuffer(long backing) {
			if (!TextureReady() ||
				persistentVertexCreated ||
				backing < 4096 ||
				backing % 4096 != 0) {
				return false;
			}

			// Reserve a per-context resource ID outside the
			// existing temporary probe vertex-buffer range.
			int vertexId = resourceId + 256;

			// Create a 192-byte vertex buffer:
			// six vertices x 32 bytes per vertex.
			Header(516, 72, 0); // RESOURCE_CREATE_3D

			Write32(24, vertexId);
			Write32(32, 64);  // R8_UNORM byte storage
			Write32(36, 16);  // VERTEX_BUFFER binding
			Write32(40, 192);
			Write32(44, 1);
			Write32(48, 1);
			Write32(52, 1);

			if (!ExecuteActive(72, 4352)) {
				return false;
			}

			persistentVertexCreated = true;

			// Attach a full DMA page as backing memory.
			Header(262, 48, 0); // RESOURCE_ATTACH_BACKING

			Write32(24, vertexId);
			Write32(28, 1);
			Write64(32, backing);
			Write32(40, 4096);

			if (!ExecuteActive(48, 4352)) {
				return false;
			}

			persistentVertexBacked = true;

			// Attach the vertex buffer to this VirGL context.
			Header(514, 32, contextId); // CTX_ATTACH_RESOURCE

			Write32(24, vertexId);

			if (!ExecuteActive(32, 4352)) {
				return false;
			}

			persistentVertexAttached = true;
			persistentVertexBacking = backing;

			return PersistentVertexBufferReady();
		}

        public bool PersistentSamplerViewReady(int slot) {
            if (slot < 0 || slot >= 2 || !TextureReady()) {
                return false;
            }

            VirtioGpu3D source = persistentSamplerSources[slot];

            return source != null &&
                source.TextureReady() &&
                source.control == control &&
                source.contextId != contextId &&
                persistentSamplerAttached[slot] &&
                persistentSamplerViewCreated[slot];
        }

        public bool CreatePersistentSamplerView(
            VirtioGpu3D source, int slot) {

            if (!TextureReady() ||
                slot < 0 || slot >= 2 ||
                source == null ||
                source == this ||
                !source.TextureReady() ||
                source.control != control ||
                source.contextId == contextId ||
                source.resourceId == resourceId ||
                persistentSamplerSources[slot] != null ||
                persistentSamplerAttached[slot] ||
                persistentSamplerViewCreated[slot]) {
                return false;
            }

            // A source may occupy only one slot in this probe.
            int other = 1 - slot;

            if (persistentSamplerSources[other] != null &&
                persistentSamplerSources[other].resourceId ==
                    source.resourceId) {
                return false;
            }

            // Attach the source texture to the destination context.
            Header(514, 32, contextId);
            Write32(24, source.resourceId);

            if (!ExecuteActive(32, 4352)) {
                return false;
            }

            // Record ownership immediately after successful attachment.
            // Even if view creation fails, the attachment must be cleaned up.
            persistentSamplerSources[slot] = source;
            persistentSamplerAttached[slot] = true;

            int handle = 14 + slot;

            // Create a VirGL sampler-view object.
            byte[] view = new byte[28];

            Stream32(view, 0, 1 + 6 * 256 + 6 * 65536);
            Stream32(view, 4, handle);
            Stream32(view, 8, source.resourceId);
            Stream32(view, 12, 1);     // B8G8R8A8_UNORM
            Stream32(view, 24, 1672); // XYZW swizzle

            if (!SubmitKernelCommands(view, 28)) {
                return false;
            }

            persistentSamplerViewCreated[slot] = true;

            return PersistentSamplerViewReady(slot);
        }

        public bool BindPersistentSamplerView(int slot) {
            if (!PersistentSamplerViewReady(slot)) {
                return false;
            }

            int handle = 14 + slot;

            // Bind the existing view to fragment sampler slot 0.
            byte[] bind = new byte[16];

            Stream32(bind, 0, 10 + 3 * 65536);
            Stream32(bind, 4, 1); // Fragment shader stage
            Stream32(bind, 8, 0); // First sampler slot
            Stream32(bind, 12, handle);

            if (!SubmitKernelCommands(bind, 16)) {
                return false;
            }

            persistentSamplerBoundSlot = slot;

            return true;
        }

        public bool DestroyPersistentSamplerView(int slot) {
            if (slot < 0 || slot >= 2 ||
                !contextReady || control == null) {
                return false;
            }

            // Already empty.
            if (persistentSamplerSources[slot] == null &&
                !persistentSamplerAttached[slot] &&
                !persistentSamplerViewCreated[slot]) {
                return true;
            }

            // Unbind before destroying an active sampler view.
            if (persistentSamplerBoundSlot == slot) {
                byte[] unbind = new byte[16];

                Stream32(unbind, 0, 10 + 3 * 65536);
                Stream32(unbind, 4, 1);

                if (!SubmitKernelCommands(unbind, 16)) {
                    return false;
                }

                persistentSamplerBoundSlot = -1;
            }

            // Destroy the sampler-view object.
            if (persistentSamplerViewCreated[slot]) {
                byte[] destroy = new byte[8];

                Stream32(destroy, 0,
                    3 + 6 * 256 + 65536);
                Stream32(destroy, 4, 14 + slot);

                if (!SubmitKernelCommands(destroy, 8)) {
                    return false;
                }

                persistentSamplerViewCreated[slot] = false;
            }

            // The destination context no longer needs the source.
            if (persistentSamplerAttached[slot]) {
                VirtioGpu3D source =
                    persistentSamplerSources[slot];

                if (source == null) {
                    return false;
                }

                Header(515, 32, contextId);
                Write32(24, source.resourceId);

                if (!ExecuteActive(32, 4352)) {
                    return false;
                }

                persistentSamplerAttached[slot] = false;
            }

            persistentSamplerSources[slot] = null;

            return true;
        }
		public bool DestroyPersistentVertexBuffer() {
			if (!persistentVertexCreated || control == null) {
				return false;
			}

			int vertexId = resourceId + 256;

			// No vertex-input binding is created by this method.
			// Later, when draws use this buffer, we must unbind
			// it before entering this destruction sequence.

			if (persistentVertexAttached) {
				Header(515, 32, contextId); // CTX_DETACH_RESOURCE
				Write32(24, vertexId);

				if (!control.Execute(command, 32, 4352)) {
					faulted = true;
					return false;
				}

				persistentVertexAttached = false;
			}

			if (persistentVertexBacked) {
				Header(263, 32, 0); // RESOURCE_DETACH_BACKING
				Write32(24, vertexId);

				if (!control.Execute(command, 32, 4352)) {
					faulted = true;
					return false;
				}

				persistentVertexBacked = false;
			}

			Header(258, 32, 0); // RESOURCE_UNREF
			Write32(24, vertexId);

			if (!control.Execute(command, 32, 4352)) {
				faulted = true;
				return false;
			}

			persistentVertexCreated = false;
			persistentVertexBacking = 0;

			return true;
		}
        // Sample a texture owned by another context into the alpha-enabled
        // render target. The source is attached only for this fenced draw.
        public bool ProbeTexturedAlphaFrom(VirtioGpu3D source) {
            if (!TextureReady() || !probeVertexCreated ||
                !probeVertexAttached || source == null ||
                !source.TextureReady() || source == this ||
                source.control != control ||
                source.contextId == contextId ||
                textureWidth != 64 || textureHeight != 64 ||
                source.textureWidth != 64 ||
                source.textureHeight != 64) { return false; }
            Header(514, 32, contextId); // CTX_ATTACH_RESOURCE
            Write32(24, source.resourceId);
            if (!ExecuteActive(32, 4352)) { return false; }
            byte[] view = new byte[28];
            Stream32(view, 0, 1 + 6 * 256 + 6 * 65536);
            Stream32(view, 4, 10); // private sampler-view handle
            Stream32(view, 8, source.resourceId);
            Stream32(view, 12, 1); // B8G8R8A8_UNORM
            Stream32(view, 24, 1672); // XYZW swizzle
            bool viewCreated = SubmitKernelCommands(view, 28);
            bool drawn = false;
            if (viewCreated) {
                byte[] views = new byte[16];
                Stream32(views, 0, 10 + 3 * 65536);
                Stream32(views, 4, 1); // fragment stage
                Stream32(views, 12, 10);
                bool bound = SubmitKernelCommands(views, 16);
                // TGSI fragment shader: sample the source texture at its
                // center and preserve the fetched alpha channel.
                byte[] fragment = new byte[132];
                Stream32(fragment, 0, 1195463238);
                Stream32(fragment, 4, 1279476746);
                Stream32(fragment, 8, 1414876960);
                Stream32(fragment, 12, 744304731);
                Stream32(fragment, 16, 1280262944);
                Stream32(fragment, 20, 811291215);
                Stream32(fragment, 24, 1128532573);
                Stream32(fragment, 28, 1095966796);
                Stream32(fragment, 32, 811290701);
                Stream32(fragment, 36, 1128532573);
                Stream32(fragment, 40, 1448288332);
                Stream32(fragment, 44, 1532446025);
                Stream32(fragment, 48, 539778352);
                Stream32(fragment, 52, 539771954);
                Stream32(fragment, 56, 1095715910);
                Stream32(fragment, 60, 1296632404);
                Stream32(fragment, 64, 1563450189);
                Stream32(fragment, 68, 1414284832);
                Stream32(fragment, 72, 2065707571);
                Stream32(fragment, 76, 892219424);
                Stream32(fragment, 80, 774905900);
                Stream32(fragment, 84, 807414837);
                Stream32(fragment, 88, 540090412);
                Stream32(fragment, 92, 1163135613);
                Stream32(fragment, 96, 1431248984);
                Stream32(fragment, 100, 1563450196);
                Stream32(fragment, 104, 1296637996);
                Stream32(fragment, 108, 1563450189);
                Stream32(fragment, 112, 1095966764);
                Stream32(fragment, 116, 811290701);
                Stream32(fragment, 120, 840969309);
                Stream32(fragment, 124, 1313147460);
                Stream32(fragment, 128, 2628);
                bool shader = bound && SubmitShader(8, 1,
                    fragment, 131);
                byte[] bind = new byte[12];
                Stream32(bind, 0, 31 + 2 * 65536);
                Stream32(bind, 4, 8);
                Stream32(bind, 8, 1);
                bool linked = shader && SubmitKernelCommands(bind, 12);
                byte[] link = new byte[28];
                Stream32(link, 0, 52 + 6 * 65536);
                Stream32(link, 4, 3);
                Stream32(link, 8, 8);
                linked = linked && SubmitKernelCommands(link, 28);
                byte[] clear = new byte[36];
                Stream32(clear, 0, 7 + 8 * 65536);
                Stream32(clear, 4, 4);
                Stream32(clear, 12, 1065353216); // green
                Stream32(clear, 20, 1065353216); // alpha
                Stream32(clear, 28, 1072693248);
                linked = linked && SubmitKernelCommands(clear, 36);
                byte[] draw = new byte[52];
                Stream32(draw, 0, 8 + 12 * 65536);
                Stream32(draw, 8, 3);
                Stream32(draw, 12, 4); // TRIANGLES
                Stream32(draw, 20, 1);
                Stream32(draw, 44, 2);
                drawn = linked && SubmitKernelCommands(draw, 52);
            }
            bool viewDestroyed = true;
            if (viewCreated) {
                // Cleanup also runs after a failed shader submission.
                Header(519, 40, contextId);
                Write32(24, 8);
                Write32(32, 3 + 6 * 256 + 65536);
                Write32(36, 10);
                viewDestroyed = control.Execute(command, 40, 4352);
            }
            Header(515, 32, contextId); // CTX_DETACH_RESOURCE
            Write32(24, source.resourceId);
            bool detached = control.Execute(command, 32, 4352);
            if (!viewDestroyed || !detached) { faulted = true; }
            return drawn && viewDestroyed && detached;
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
            if (!contextReady || control == null) {
				return false;
			}
            if (!DestroyPersistentSamplerView(0) ||
                !DestroyPersistentSamplerView(1)) {
                return false;
            }
			if (persistentVertexCreated && !DestroyPersistentVertexBuffer()) {
				return false;
			}
            if (probeVertexCreated && !DestroyProbeVertex()) {
				return false;
			}
            if (textureCreated && !DestroyTexture()) {
				return false;
			}
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
			persistentVertexCreated = false;
			persistentVertexBacked = false;
			persistentVertexAttached = false;
			persistentVertexBacking = 0;
            persistentSamplerSources[0] = null;
            persistentSamplerSources[1] = null;
            persistentSamplerAttached[0] = false;
            persistentSamplerAttached[1] = false;
            persistentSamplerViewCreated[0] = false;
            persistentSamplerViewCreated[1] = false;
            persistentSamplerBoundSlot = -1;
        }
    }
}
