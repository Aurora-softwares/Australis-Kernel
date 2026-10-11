namespace Australis.Kernel.Console {
    public interface IConsoleByteSink {
        bool WriteByte(int value);
    }

    // Serial is the primary diagnostic output. A framebuffer can mirror it
    // without becoming a dependency of the command interpreter.
    public class ConsoleWriter {
        private IConsoleByteSink primary;
        private IConsoleByteSink mirror;

        public ConsoleWriter(IConsoleByteSink inputPrimary, IConsoleByteSink inputMirror) {
            primary = inputPrimary;
            mirror = inputMirror;
        }

        public bool WriteByte(int value) {
            if (primary == null) { return false; }
            bool written = primary.WriteByte(value);
            if (mirror != null) { mirror.WriteByte(value); }
            return written;
        }

        public bool WriteText(string value) {
            if (value == null) { return false; }
            int i = 0;
            while (i < value.Length) {
                if (!WriteByte(System.Kernel.String.ByteAt(value, i))) { return false; }
                i = i + 1;
            }
            return true;
        }

        public bool WriteLine(string value) {
            return WriteText(value) && WriteByte(13) && WriteByte(10);
        }

        public bool WriteBytes(byte[] value, int count) {
            if (value == null || count < 0 || count > value.Length) { return false; }
            int i = 0;
            while (i < count) {
                if (!WriteByte(value[i])) { return false; }
                i = i + 1;
            }
            return true;
        }

        public void ClearLine() {
            WriteByte(13);
            WriteByte(27); WriteByte(91); WriteByte(50); WriteByte(75);
        }

        public void ClearScreen() {
            WriteByte(27); WriteByte(91); WriteByte(50); WriteByte(74);
            WriteByte(27); WriteByte(91); WriteByte(72);
        }
    }
}
