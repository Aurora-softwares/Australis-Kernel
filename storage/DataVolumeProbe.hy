namespace Australis.Kernel.Storage {
    // Only a deliberately marked, disposable test volume activates this probe.
    // Blocks 4..12 are free in the empty HyFS 2 fixture. Ordinary data
    // volumes do not carry this marker. A successful second boot reads them
    // without rewriting, proving that the first boot's Flush reached media.
    public class DataVolumeProbe {
        private static bool Marker(byte[] block) {
            string magic = "HYFS2-BLOCK-PROBE";
            int i = 0;
            while (i < magic.Length) {
                if (block[i] != System.Kernel.String.ByteAt(magic, i)) { return false; }
                i = i + 1;
            }
            while (i < block.Length) {
                if (block[i] != 0) { return false; }
                i = i + 1;
            }
            return true;
        }

        private static byte Pattern(int index) { return (byte)((index * 29 + 7) % 256); }

        // 0 absent, 1 freshly written/flushed/read, 2 durable after reboot,
        // 3 read failure, 4 write failure, 5 flush failure, 6 verify failure,
        // 7 unexpected occupied test blocks. Never write beyond data volume.
        public static int Run(BlockDevice device, Partition partition) {
            if (device == null || partition == null || !partition.Present() ||
                device.SectorSize() != 512 || partition.BlockCount() < 16) { return 0; }
            long baseLba = partition.FirstLba();
            byte[] marker = new byte[512];
            if (device.Read(baseLba + 3, 1, marker) != BlockStatus.Ok()) { return 3; }
            if (!Marker(marker)) { return 0; }
            byte[] observed = new byte[4608];
            if (device.Read(baseLba + 4, 9, observed) != BlockStatus.Ok()) { return 3; }
            bool matches = true;
            bool empty = true;
            int i = 0;
            while (i < observed.Length) {
                if (observed[i] != Pattern(i)) { matches = false; }
                if (observed[i] != 0) { empty = false; }
                i = i + 1;
            }
            if (matches) { return 2; }
            if (!empty) { return 7; }
            byte[] expected = new byte[4608];
            i = 0;
            while (i < expected.Length) { expected[i] = Pattern(i); i = i + 1; }
            if (device.Write(baseLba + 4, 9, expected) != BlockStatus.Ok()) { return 4; }
            if (device.Flush() != BlockStatus.Ok()) { return 5; }
            if (device.Read(baseLba + 4, 9, observed) != BlockStatus.Ok()) { return 3; }
            i = 0;
            while (i < expected.Length) {
                if (observed[i] != expected[i]) { return 6; }
                i = i + 1;
            }
            return 1;
        }
    }
}
