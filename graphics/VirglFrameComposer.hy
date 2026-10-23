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
        private int[] queuedRects;
        private int queuedRectCount;
        private int rectangleCount;

        public VirglFrameComposer(VirtioGpu3D renderer) {
            gpu = renderer;
            frameOpen = false;
            failed = false;
            drawCount = 0;
            completedFrames = 0;
            queuedRects = new int[20];
            queuedRectCount = 0;
            rectangleCount = 0;
        }

        private bool FlushSolidRects() {
            if (queuedRectCount == 0) {
                return true;
            }

            if (!gpu.ClearTextureRegions(
                queuedRects, queuedRectCount)) {

                queuedRectCount = 0;
                failed = true;
                frameOpen = false;
                queuedRectCount = 0;
                return false;
            }

            queuedRectCount = 0;
            return true;
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

            // Reset the rectangle batching state for every new frame.
            queuedRectCount = 0;
            rectangleCount = 0;

            return true;
        }

        public bool DrawWindow(int samplerSlot, int x, int y, int width, int height) {

            if (!FlushSolidRects()) {
                return false;
            }
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
                queuedRectCount = 0;
                return false;
            }

            drawCount = drawCount + 1;

            return true;
        }

        public bool EndFrame() {
            if (!frameOpen || !Ready()) {
                return false;
            }
            if (!FlushSolidRects()) {
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

        public void AbortFrame() {
            // Previously submitted GPU commands are already fenced.
            // Abandon the unfinished frame without presenting it.
            frameOpen = false;
            drawCount = 0;
        }

        public bool DrawSolidRect(
            int x, int y,
            int width, int height,
            int rgb) {

            if (!frameOpen ||
                !Ready() ||
                rectangleCount >= 128 ||
                x < 0 || y < 0 ||
                width < 1 || height < 1 ||
                rgb < 0 || rgb > 16777215) {
                return false;
            }

            int offset = queuedRectCount * 5;

            queuedRects[offset] = x;
            queuedRects[offset + 1] = y;
            queuedRects[offset + 2] = width;
            queuedRects[offset + 3] = height;
            queuedRects[offset + 4] = rgb;

            queuedRectCount = queuedRectCount + 1;
            rectangleCount = rectangleCount + 1;

            if (queuedRectCount == 4) {
                return FlushSolidRects();
            }

            return true;
        }

        public bool DrawSourceTexture(
            VirtioGpu3D source,
            int x, int y,
            int width, int height) {

                if (!FlushSolidRects()) {
                return false;
            }

            if (!frameOpen ||
                !Ready() ||
                source == null ||
                !source.TextureReady() ||
                drawCount >= 32) {
                return false;
            }

            // Attach this window's GPU texture to the
            // compositor using a managed sampler view.
            bool created =
                gpu.CreatePersistentSamplerView(source, 0);

            bool drawn = false;

            if (created) {
                drawn =
                    gpu.ProbeUvRectangleWithPersistentSampler(
                        0, x, y, width, height);
            }

            // Always attempt cleanup, including when creation
            // or the draw failed partway through.
            bool released =
                gpu.DestroyPersistentSamplerView(0);

            if (!created || !drawn || !released) {
                failed = true;
                frameOpen = false;
                queuedRectCount = 0;
                return false;
            }

            drawCount = drawCount + 1;
            return true;
        }

    }
}
