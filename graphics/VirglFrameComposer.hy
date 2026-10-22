namespace Australis.Kernel.Graphics {
    // Compositor-owned frame lifecycle for VirGL.
    //
    // The underlying VirtioGpu3D instance owns the render
    // target, vertex buffer and sampler views.
    //
    // This class controls frame ordering. It does not own
    // or release GPU resources.

    public class VirglFrameComposer {

        private VirtioGpu3D gpu;
        private bool frameOpen;
        private bool failed;
        private int drawCount;
        private int completedFrames;

        public VirglFrameComposer(VirtioGpu3D renderer) {
            gpu = renderer;
            frameOpen = false;
            failed = false;
            drawCount = 0;
            completedFrames = 0;
        }

        public bool Ready() {
            return !failed &&
                gpu != null &&
                gpu.TextureReady() &&
                gpu.PersistentVertexBufferReady();
        }

        public bool BeginFrame(int backgroundRgb) {
            if (!Ready() ||
                frameOpen ||
                backgroundRgb < 0 ||
                backgroundRgb > 16777215) {
                return false;
            }

            // Clear the existing GPU render target.
            // No new texture or vertex buffer is created.
            if (!gpu.ClearTexture(backgroundRgb)) {
                failed = true;
                return false;
            }

            frameOpen = true;
            drawCount = 0;

            return true;
        }

        public bool DrawWindow(
            int samplerSlot,
            int x, int y,
            int width, int height) {

            if (!frameOpen ||
                !Ready() ||
                samplerSlot < 0 ||
                samplerSlot >= 2 ||
                drawCount >= 32) {
                return false;
            }

            if (!gpu.PersistentSamplerViewReady(
                samplerSlot)) {
                return false;
            }

            // Reuse existing shaders, GPU vertex buffer
            // and persistent sampler view.
            if (!gpu.ProbeUvRectangleWithPersistentSampler(
                samplerSlot, x, y, width, height)) {

                failed = true;
                frameOpen = false;
                return false;
            }

            drawCount = drawCount + 1;

            return true;
        }

        public bool EndFrame() {
            if (!frameOpen || !Ready()) {
                return false;
            }

            // All drawing submissions have already been
            // completed through the fenced VirGL path.
            //
            // This finishes composition, not presentation.
            frameOpen = false;
            completedFrames = completedFrames + 1;

            return true;
        }

        public bool FrameOpen() {
            return frameOpen;
        }

        public int LastDrawCount() {
            return drawCount;
        }

        public int CompletedFrames() {
            return completedFrames;
        }

        public bool Failed() {
            return failed;
        }

        public bool DrawSourceTexture(
            VirtioGpu3D source,
            int x, int y,
            int width, int height) {

            if (!frameOpen ||
                !Ready() ||
                source == null ||
                !source.TextureReady() ||
                drawCount >= 32) {
                return false;
            }

            // Draw a process-owned source texture into
            // the compositor's persistent render target.
            //
            // This currently creates a temporary sampler
            // view per draw, avoiding stale references
            // when windows are closed or resized.
            if (!gpu.ProbeUvRectanglePersistentFrom(
                source, x, y, width, height, false)) {

                failed = true;
                frameOpen = false;
                return false;
            }

            drawCount = drawCount + 1;
            return true;
        }
    }
}
