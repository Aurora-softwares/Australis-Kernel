namespace Australis.Kernel.Diagnostics {
    public class PanicQr {

        // Production entry point.
        // Only the active panic handler may invoke this.
		public static int Render(long bootInfo) {
			if (bootInfo < 4096) {
				return 1;
			}

			// Only render during a genuine kernel panic.
			if (System.Kernel.Memory.Read32(bootInfo + 2672) != 1) {
				return 2;
			}

			// Generate the complete QR matrix.
			int result = BuildMatrix(bootInfo);

			if (result != 0) {
				return result;
			}

			long scratch =
				System.Kernel.Memory.Read64(bootInfo + 3664);

			// Draw the QR without clearing the existing text.
			int drawn = QrRenderer.DrawFramebufferV3L(
				bootInfo, scratch);

			if (drawn != 1) {
				return 10;
			}

            // The firmware framebuffer is no longer the visible scanout
            // after the native VirtIO-GPU driver takes ownership.
            int gpuResult = PanicGpuScanout.Present(bootInfo, scratch);
            System.Kernel.Memory.Write32(scratch + 2112, gpuResult);

			return 0;
		}

        // Debug-only QR self-test.
        // Does not change the kernel's panic state.
        public static int SelfTest(long bootInfo) {
            if (bootInfo < 4096) { return 1; }
            if (System.Kernel.Memory.Read32(bootInfo + 3472) != 1) { return 2; }
            return BuildMatrix(bootInfo);
        }

        // Shared QR encoding pipeline.
        private static int BuildMatrix(long bootInfo) {
            long scratch = System.Kernel.Memory.Read64(bootInfo + 3664);
            if (scratch == 0) { return 3; }

			int payloadLength = Australis.Kernel.Diagnostics.QrEncoder.WritePanicPayload(bootInfo, scratch);
			if (payloadLength != 74) { return 4; }

			// Convert the ASCII report into QR data codewords.
			int encoded = QrEncoder.EncodeV3L(scratch, payloadLength, scratch + 80);
			if (encoded == 0) { return 5; }

			// Generate the 15 error-correction codewords.
			int corrected = QrReedSolomon.EncodeV3L(scratch + 80, scratch + 144, scratch + 160);
			if (corrected == 0) { return 6; }


			// Construct the fixed QR matrix.
			int prepared = QrRenderer.PrepareV3L(scratch);
			if (prepared == 0) { return 7; }

			// Place the encoded data and error-correction
			// bits into the QR module matrix.
			int placed = QrRenderer.PlaceDataV3L(scratch);
			if (placed == 0) { return 8; }

			// Apply QR mask 0 and write both format-information copies.
			int finalised = QrRenderer.FinalizeV3L(scratch);
			if (finalised == 0) { return 9; }

			return 0;
        }
    }
}
