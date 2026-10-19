namespace Australis.Kernel.Graphics {
    // Executes a fenced controlq request and validates the response header.
    // The native queue binding is part of the later display backend work.
    public interface IVirtioGpuControl {
        bool Execute(byte[] request, int requestLength,
            int expectedResponseType);
    }

    public class VirtioGpuResource {
        private int id;
        private int width;
        private int height;
        private long backing;
        private int backingBytes;
        private bool attached;
        public VirtioGpuResource(int inputId, int inputWidth,
            int inputHeight, long inputBacking, int inputBytes) {
            id = inputId; width = inputWidth; height = inputHeight;
            backing = inputBacking; backingBytes = inputBytes;
            attached = true;
        }
        public int Id() { return id; }
        public int Width() { return width; }
        public int Height() { return height; }
        public long Backing() { return backing; }
        public int BackingBytes() { return backingBytes; }
        public bool Attached() { return attached; }
        public void MarkDetached() { attached = false; }
    }

    // VirtIO-GPU 2D controlq command layout and bounded resource lifetime.
    // One resource can be attached to a scanout; ownership stays in the kernel.
    public class VirtioGpu2D {
        private IVirtioGpuControl control;
        private VirtioGpuResource resource;
        private int nextId;
        private long nextFence;
        private byte[] commandBuffer;
        private int commandLength;
        public VirtioGpu2D(IVirtioGpuControl inputControl) {
            control = inputControl; resource = null;
            nextId = 1; nextFence = 1;
            commandBuffer = new byte[56]; commandLength = 0;
        }
        private void Write32(byte[] bytes, int offset, long value) {
            int i = 0;
            while (i < 4) {
                bytes[offset + i] = (byte)(value % 256);
                value = value / 256; i = i + 1;
            }
        }
        private void Write64(byte[] bytes, int offset, long value) {
            int i = 0;
            while (i < 8) {
                bytes[offset + i] = (byte)(value % 256);
                value = value / 256; i = i + 1;
            }
        }
        private byte[] Command(int type, int length) {
            byte[] command = commandBuffer;
            int i = 0;
            while (i < length) { command[i] = 0; i = i + 1; }
            commandLength = length;
            Write32(command, 0, type);
            Write32(command, 4, 1); // VIRTIO_GPU_FLAG_FENCE
            Write64(command, 8, nextFence);
            nextFence = nextFence + 1;
            return command;
        }
        private void Rect(byte[] command, int offset, int x, int y,
            int width, int height) {
            Write32(command, offset, x); Write32(command, offset + 4, y);
            Write32(command, offset + 8, width);
            Write32(command, offset + 12, height);
        }
        private bool Send(byte[] command) {
            return control != null &&
                control.Execute(command, commandLength, 4352);
        }
        public VirtioGpuResource Current() { return resource; }
        public bool Create(int width, int height, long backing,
            int backingBytes) {
            long required = (long)width * height * 4;
            if (control == null || resource != null || width < 1 ||
                height < 1 || width > 2048 || height > 2048 ||
                required > 4194304 || backing < 4096 ||
                backing % 4096 != 0 || backingBytes < required ||
                backingBytes > 4194304 || nextId < 1) { return false; }
            int id = nextId;
            byte[] create = Command(257, 40);
            Write32(create, 24, id);
            Write32(create, 28, 2); // B8G8R8X8_UNORM
            Write32(create, 32, width); Write32(create, 36, height);
            if (!Send(create)) { return false; }
            byte[] attach = Command(262, 48);
            Write32(attach, 24, id); Write32(attach, 28, 1);
            Write64(attach, 32, backing);
            Write32(attach, 40, backingBytes);
            if (!Send(attach)) {
                byte[] undo = Command(258, 32);
                Write32(undo, 24, id);
                if (!Send(undo)) {
                    resource = new VirtioGpuResource(id, width, height,
                        backing, backingBytes);
                    resource.MarkDetached();
                    nextId = nextId + 1;
                }
                return false;
            }
            resource = new VirtioGpuResource(id, width, height,
                backing, backingBytes);
            nextId = nextId + 1;
            return true;
        }
        private bool ValidRect(int x, int y, int width, int height) {
            return resource != null && x >= 0 && y >= 0 &&
                width > 0 && height > 0 &&
                (long)x + width <= resource.Width() &&
                (long)y + height <= resource.Height();
        }
        public bool Scanout(int scanoutId) {
            if (resource == null || !resource.Attached() ||
                scanoutId < 0 || scanoutId >= 16) { return false; }
            byte[] command = Command(259, 48);
            Rect(command, 24, 0, 0, resource.Width(), resource.Height());
            Write32(command, 40, scanoutId);
            Write32(command, 44, resource.Id());
            return Send(command);
        }
        public bool DisableScanout(int scanoutId) {
            if (resource == null || scanoutId < 0 ||
                scanoutId >= 16) { return false; }
            byte[] command = Command(259, 48);
            Write32(command, 40, scanoutId);
            return Send(command);
        }
        public bool Update(int x, int y, int width, int height) {
            if (!ValidRect(x, y, width, height) ||
                !resource.Attached()) { return false; }
            byte[] transfer = Command(261, 56);
            Rect(transfer, 24, x, y, width, height);
            Write64(transfer, 40, ((long)y * resource.Width() + x) * 4);
            Write32(transfer, 48, resource.Id());
            if (!Send(transfer)) { return false; }
            byte[] flush = Command(260, 48);
            Rect(flush, 24, x, y, width, height);
            Write32(flush, 40, resource.Id());
            return Send(flush);
        }
        public bool Destroy() {
            if (resource == null) { return false; }
            if (resource.Attached()) {
                byte[] detach = Command(263, 32);
                Write32(detach, 24, resource.Id());
                if (!Send(detach)) { return false; }
                resource.MarkDetached();
            }
            byte[] unref = Command(258, 32);
            Write32(unref, 24, resource.Id());
            if (!Send(unref)) { return false; }
            resource = null;
            return true;
        }
    }
}
