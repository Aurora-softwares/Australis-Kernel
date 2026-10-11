namespace Australis.User {
    public class UserShellCommandId {
        public static int Empty() { return 0; }
        public static int Help() { return 1; }
        public static int Echo() { return 2; }
        public static int List() { return 3; }
        public static int Cat() { return 4; }
        public static int Version() { return 5; }
        public static int Devices() { return 6; }
        public static int Mounts() { return 7; }
        public static int WorkingDirectory() { return 8; }
        public static int Run() { return 9; }
        public static int Processes() { return 10; }
        public static int PanicTest() { return 11; }
        public static int Unknown() { return 12; }
        public static int Stat() { return 13; }
    }

    public class UserShellCommand {
        private int identifier;
        private int argumentStart;
        private int argumentLength;
        public UserShellCommand(int inputIdentifier, int inputStart, int inputLength) {
            identifier = inputIdentifier; argumentStart = inputStart; argumentLength = inputLength;
        }
        public int Identifier() { return identifier; }
        public int ArgumentStart() { return argumentStart; }
        public int ArgumentLength() { return argumentLength; }
        public bool HasArgument() { return argumentLength > 0; }
    }

    // Command recognition belongs to the initial user shell rather than the
    // console transport. ConsoleShell remains a small supervisor that owns the
    // line editor, rendering, and privileged service objects.
    public class UserShellRegistry {
        private bool IsHelp(byte[] b, int s, int n) { return n == 4 && b[s] == 104 && b[s + 1] == 101 && b[s + 2] == 108 && b[s + 3] == 112; }
        private bool IsEcho(byte[] b, int s, int n) { return n == 4 && b[s] == 101 && b[s + 1] == 99 && b[s + 2] == 104 && b[s + 3] == 111; }
        private bool IsList(byte[] b, int s, int n) { return n == 2 && b[s] == 108 && b[s + 1] == 115; }
        private bool IsCat(byte[] b, int s, int n) { return n == 3 && b[s] == 99 && b[s + 1] == 97 && b[s + 2] == 116; }
        private bool IsStat(byte[] b, int s, int n) { return n == 4 && b[s] == 115 && b[s + 1] == 116 && b[s + 2] == 97 && b[s + 3] == 116; }
        private bool IsVersion(byte[] b, int s, int n) { return n == 7 && b[s] == 118 && b[s + 1] == 101 && b[s + 2] == 114 && b[s + 3] == 115 && b[s + 4] == 105 && b[s + 5] == 111 && b[s + 6] == 110; }
        private bool IsDevices(byte[] b, int s, int n) { return n == 7 && b[s] == 100 && b[s + 1] == 101 && b[s + 2] == 118 && b[s + 3] == 105 && b[s + 4] == 99 && b[s + 5] == 101 && b[s + 6] == 115; }
        private bool IsMounts(byte[] b, int s, int n) { return n == 6 && b[s] == 109 && b[s + 1] == 111 && b[s + 2] == 117 && b[s + 3] == 110 && b[s + 4] == 116 && b[s + 5] == 115; }
        private bool IsPwd(byte[] b, int s, int n) { return n == 3 && b[s] == 112 && b[s + 1] == 119 && b[s + 2] == 100; }
        private bool IsRun(byte[] b, int s, int n) { return n == 3 && b[s] == 114 && b[s + 1] == 117 && b[s + 2] == 110; }
        private bool IsPs(byte[] b, int s, int n) { return n == 2 && b[s] == 112 && b[s + 1] == 115; }
        private bool IsPanicTest(byte[] b, int s, int n) {
            return n == 10 && b[s] == 112 && b[s + 1] == 97 && b[s + 2] == 110 &&
                b[s + 3] == 105 && b[s + 4] == 99 && b[s + 5] == 45 &&
                b[s + 6] == 116 && b[s + 7] == 101 && b[s + 8] == 115 && b[s + 9] == 116;
        }

        public UserShellCommand Parse(byte[] line, int length) {
            if (line == null || length < 0 || length > line.Length) {
                return new UserShellCommand(UserShellCommandId.Unknown(), 0, 0);
            }
            int start = 0;
            while (start < length && line[start] == 32) { start = start + 1; }
            int end = length;
            while (end > start && line[end - 1] == 32) { end = end - 1; }
            if (start == end) { return new UserShellCommand(UserShellCommandId.Empty(), end, 0); }
            int wordEnd = start;
            while (wordEnd < end && line[wordEnd] != 32) { wordEnd = wordEnd + 1; }
            int argumentStart = wordEnd;
            while (argumentStart < end && line[argumentStart] == 32) {
                argumentStart = argumentStart + 1;
            }
            int wordLength = wordEnd - start;
            int identifier = UserShellCommandId.Unknown();
            if (IsHelp(line, start, wordLength)) { identifier = UserShellCommandId.Help(); }
            else if (IsEcho(line, start, wordLength)) { identifier = UserShellCommandId.Echo(); }
            else if (IsList(line, start, wordLength)) { identifier = UserShellCommandId.List(); }
            else if (IsCat(line, start, wordLength)) { identifier = UserShellCommandId.Cat(); }
            else if (IsStat(line, start, wordLength)) { identifier = UserShellCommandId.Stat(); }
            else if (IsVersion(line, start, wordLength)) { identifier = UserShellCommandId.Version(); }
            else if (IsDevices(line, start, wordLength)) { identifier = UserShellCommandId.Devices(); }
            else if (IsMounts(line, start, wordLength)) { identifier = UserShellCommandId.Mounts(); }
            else if (IsPwd(line, start, wordLength)) { identifier = UserShellCommandId.WorkingDirectory(); }
            else if (IsRun(line, start, wordLength)) { identifier = UserShellCommandId.Run(); }
            else if (IsPs(line, start, wordLength)) { identifier = UserShellCommandId.Processes(); }
            else if (IsPanicTest(line, start, wordLength)) { identifier = UserShellCommandId.PanicTest(); }
            return new UserShellCommand(identifier, argumentStart, end - argumentStart);
        }
    }
}
