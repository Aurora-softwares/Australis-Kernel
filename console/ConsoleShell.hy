using Australis.Kernel.Vfs;
using Australis.Kernel.Usb;
using Australis.User;

namespace Australis.Kernel.Console {
    public class ShellLaunch {
        private string name;
        private UserArguments arguments;
        public ShellLaunch(string inputName, UserArguments inputArguments) {
            name = inputName; arguments = inputArguments;
        }
        public string Name() { return name; }
        public UserArguments Arguments() { return arguments; }
    }

    // A bounded command loop over the mounted read-only root. The line buffer
    // and command text are retained for the life of the loop, so ordinary
    // typing does not allocate a page for every received character.
    public class ConsoleShell {
        private IConsoleInput input;
        private ConsoleWriter output;
        private Vfs root;
        private Vfs removable;
        private Vfs data;
        private NativeXhci usb;
        private long bootInfo;
        private LineEditor editor;
        private ConsoleEventQueue events;
        private SerialKeyDecoder decoder;
        private byte[] line;
        private byte[] searchPath;
        private int searchPathLength;
        private int length;
        private int commandCount;
        private int bootMode;
        private int[] traceIds;
        private int traceNext;
        private int traceCount;
        private string prompt;
        private VfsNamespace mountNamespace;
        private UserShellRegistry registry;
        private NativeUserProgramHost programHost;
        private int lastProgramState;
        private int lastProgramExit;
        private int lastProgramFault;
		private string versionText;
		private string banner;
        private string helpText;
        private string unknownText;
        private string notFoundText;
        private string readErrorText;
        private string overflowText;
        private string lostText;
        private bool lookupIoFailure;

        public ConsoleShell(IConsoleInput inputSource, ConsoleWriter outputWriter, Vfs inputRoot,
            Vfs inputRemovable, Vfs inputData, NativeXhci inputUsb, long inputBootInfo) {
            input = inputSource;
            output = outputWriter;
            root = inputRoot;
            removable = inputRemovable;
            data = inputData;
            usb = inputUsb;
            bootInfo = inputBootInfo;
            editor = new LineEditor();
            events = new ConsoleEventQueue();
            decoder = new SerialKeyDecoder(input, events);
            line = editor.Bytes();
            searchPath = new byte[255];
            string defaultPath = "/System/Bin:/System:/";
            searchPathLength = defaultPath.Length;
            int pathByte = 0;
            while (pathByte < searchPathLength) {
                searchPath[pathByte] = (byte)System.Kernel.String.ByteAt(defaultPath, pathByte);
                pathByte = pathByte + 1;
            }
            length = 0;
            commandCount = 0;
            traceIds = new int[8]; traceNext = 0; traceCount = 0;
            prompt = "kmon> ";
            mountNamespace = new VfsNamespace(root, removable, data);
            registry = new UserShellRegistry();
            programHost = new NativeUserProgramHost(mountNamespace,
                new NativeUserTerminal(input, output, events, decoder, usb), bootInfo);
            lastProgramState = 0; lastProgramExit = 0; lastProgramFault = 0;
            banner = "kmon serial console ready. Type help.";
            bootMode = System.Kernel.Memory.Read32(bootInfo + 3472);
            if (bootMode == 3) {
                prompt = "rescue> ";
                banner = "Australis Rescue monitor ready. Type help.";
            } else if (bootMode == 1) {
                banner = "Australis debug console ready. Type help.";
            }
            versionText = "version: 0.0.1";
            helpText = "Commands: help, echo, ls [path], stat <path>, cat <path>, devices, mounts, pwd, path [dirs], run <program>, ps, version, status, bootinfo, memmap, pages, continue, reboot, halt, trace, registers, panic (D boot)";
            unknownText = "Unknown command. Type help.";
            notFoundText = "File not found.";
            readErrorText = "File read failed.";
            overflowText = "Input line is too long.";
            lostText = "Input dropped. Retype command.";
        }

        private void NewLine() { output.WriteByte(13); output.WriteByte(10); }

        private void WriteNumber(long value) {
            long divisor = 1;
            while (value / divisor >= 10) { divisor = divisor * 10; }
            while (divisor > 0) {
                output.WriteByte(48 + (int)((value / divisor) % 10));
                divisor = divisor / 10;
            }
        }

        private void RecordCommand(int identifier) {
            traceIds[traceNext] = identifier;
            traceNext = (traceNext + 1) % traceIds.Length;
            if (traceCount < traceIds.Length) { traceCount = traceCount + 1; }
        }

        private string TraceName(int identifier) {
            if (identifier == UserShellCommandId.Help()) { return "help"; }
            if (identifier == UserShellCommandId.Echo()) { return "echo"; }
            if (identifier == UserShellCommandId.List()) { return "ls"; }
            if (identifier == UserShellCommandId.Cat()) { return "cat"; }
            if (identifier == UserShellCommandId.Version()) { return "version"; }
            if (identifier == UserShellCommandId.Devices()) { return "devices"; }
            if (identifier == UserShellCommandId.Mounts()) { return "mounts"; }
            if (identifier == UserShellCommandId.WorkingDirectory()) { return "pwd"; }
            if (identifier == UserShellCommandId.Run()) { return "run"; }
            if (identifier == UserShellCommandId.Processes()) { return "ps"; }
            if (identifier == UserShellCommandId.Stat()) { return "stat"; }
            if (identifier == UserShellCommandId.Path()) { return "path"; }
            if (identifier == UserShellCommandId.ContinueBoot()) { return "continue"; }
            if (identifier == UserShellCommandId.Reboot()) { return "reboot"; }
            if (identifier == UserShellCommandId.Halt()) { return "halt"; }
            if (identifier == UserShellCommandId.Trace()) { return "trace"; }
            if (identifier == UserShellCommandId.Panic()) { return "panic"; }
            if (identifier == UserShellCommandId.Registers()) { return "registers"; }
            if (identifier == UserShellCommandId.MemoryMap()) { return "memmap"; }
            if (identifier == UserShellCommandId.Pages()) { return "pages"; }
            if (identifier == UserShellCommandId.Status()) { return "status"; }
            if (identifier == UserShellCommandId.BootInfo()) { return "bootinfo"; }
            return "unknown";
        }

        private void Status() {
            output.WriteLine("KMon system status:");
            output.WriteText("boot mode: "); WriteNumber(bootMode); NewLine();
            output.WriteText("boot phase: ");
            WriteNumber(System.Kernel.Memory.Read32(bootInfo + 3476)); NewLine();
            output.WriteText("storage: ");
            int storage = System.Kernel.Memory.Read32(bootInfo + 304);
            if (bootMode == 3 || storage == 0) { output.WriteLine("not initialized"); }
            else if (storage == 1) { output.WriteLine("AHCI"); }
            else if (storage == 2) { output.WriteLine("NVMe"); }
            else { output.WriteLine("unknown"); }
            output.WriteText("root: ");
            if (root != null && root.IsRootMounted()) { output.WriteLine("mounted"); }
            else { output.WriteLine("unavailable"); }
            output.WriteText("data: ");
            if (data != null && data.IsRootMounted()) { output.WriteLine("mounted"); }
            else { output.WriteLine("unavailable"); }
            output.WriteText("dropped input: "); WriteNumber(events.Dropped()); NewLine();
        }

        private void BootInfo() {
            output.WriteLine("KernelBootInfo:");
            output.WriteText("ABI version: ");
            WriteNumber(System.Kernel.Memory.Read32(bootInfo + 4)); NewLine();
            output.WriteText("memory map bytes: ");
            WriteNumber(System.Kernel.Memory.Read64(bootInfo + 16)); NewLine();
            output.WriteText("descriptor bytes: ");
            WriteNumber(System.Kernel.Memory.Read64(bootInfo + 24)); NewLine();
            output.WriteText("kernel code bytes: ");
            WriteNumber(System.Kernel.Memory.Read64(bootInfo + 1032)); NewLine();
            output.WriteText("framebuffer: ");
            WriteNumber(System.Kernel.Memory.Read32(bootInfo + 128));
            output.WriteText("x");
            WriteNumber(System.Kernel.Memory.Read32(bootInfo + 132)); NewLine();
        }

        private void MemoryMap() {
            long address = System.Kernel.Memory.Read64(bootInfo + 8);
            long byteSize = System.Kernel.Memory.Read64(bootInfo + 16);
            long stride = System.Kernel.Memory.Read64(bootInfo + 24);
            if (address < 4096 || byteSize <= 0 || stride < 40 || stride > 256 ||
                byteSize % stride != 0 || byteSize / stride > 1024) {
                output.WriteLine("EFI memory map unavailable or invalid."); return;
            }
            long entries = byteSize / stride;
            long conventional = 0; long other = 0; long index = 0;
            output.WriteLine("EFI memory map:");
            output.WriteText("descriptors: "); WriteNumber(entries); NewLine();
            if (bootMode == 1) { output.WriteLine("type physical-start pages:"); }
            while (index < entries) {
                long entry = address + index * stride;
                int kind = System.Kernel.Memory.Read32(entry);
                long pages = System.Kernel.Memory.Read64(entry + 24);
                if (pages < 0) { output.WriteLine("Invalid EFI page count."); return; }
                if (kind == 7) { conventional = conventional + pages; }
                else { other = other + pages; }
                if (bootMode == 1 && index < 128) {
                    WriteNumber(kind); output.WriteByte(32);
                    WriteNumber(System.Kernel.Memory.Read64(entry + 8)); output.WriteByte(32);
                    WriteNumber(pages); NewLine();
                }
                index = index + 1;
            }
            if (bootMode == 1 && entries > 128) {
                output.WriteLine("Additional descriptors omitted.");
            }
            output.WriteText("conventional pages: "); WriteNumber(conventional); NewLine();
            output.WriteText("other pages: "); WriteNumber(other); NewLine();
            if (bootMode != 1) {
                output.WriteLine("Boot D for physical ranges.");
            }
        }

        private void Pages() {
            long next = System.Kernel.Memory.Read64(bootInfo + 40);
            long limit = System.Kernel.Memory.Read64(bootInfo + 48);
            long recycled = System.Kernel.Memory.Read64(bootInfo + 1192);
            if (next < 4096 || next % 4096 != 0 || limit < next ||
                limit % 4096 != 0 || recycled < 0) {
                output.WriteLine("Physical page allocator unavailable."); return;
            }
            long fresh = (limit - next) / 4096;
            output.WriteLine("Physical pages (4 KiB):");
            output.WriteText("fresh: "); WriteNumber(fresh); NewLine();
            output.WriteText("recycled: "); WriteNumber(recycled); NewLine();
            output.WriteText("available: "); WriteNumber(fresh + recycled); NewLine();
            output.WriteText("allocator status: ");
            WriteNumber(System.Kernel.Memory.Read32(bootInfo + 1160)); NewLine();
        }

        private void Trace() {
            output.WriteLine("KMon diagnostic trace:");
            output.WriteText("boot mode: "); WriteNumber(bootMode); NewLine();
            output.WriteText("boot phase: "); WriteNumber(System.Kernel.Memory.Read32(bootInfo + 3476)); NewLine();
            output.WriteText("root state: "); WriteNumber(System.Kernel.Memory.Read32(bootInfo + 1072)); NewLine();
            output.WriteText("root mount status: "); WriteNumber(System.Kernel.Memory.Read32(bootInfo + 1076)); NewLine();
            output.WriteText("last storage status: "); WriteNumber(System.Kernel.Memory.Read32(bootInfo + 508)); NewLine();
            output.WriteText("NVMe failure cause: "); WriteNumber(System.Kernel.Memory.Read32(bootInfo + 1236)); NewLine();
            output.WriteText("NVMe recovery state: "); WriteNumber(System.Kernel.Memory.Read32(bootInfo + 1240)); NewLine();
            output.WriteText("program runs: "); WriteNumber(System.Kernel.Memory.Read32(bootInfo + 2588)); NewLine();
            output.WriteText("last program fault: "); WriteNumber(System.Kernel.Memory.Read32(bootInfo + 2584)); NewLine();
            output.WriteText("dropped input: "); WriteNumber(events.Dropped()); NewLine();
            output.WriteLine("recent commands (oldest first):");
            int start = traceNext - traceCount;
            if (start < 0) { start = start + traceIds.Length; }
            int i = 0;
            while (i < traceCount) {
                int index = (start + i) % traceIds.Length;
                output.WriteText("  "); output.WriteLine(TraceName(traceIds[index]));
                i = i + 1;
            }
        }

        private void Registers() {
            output.WriteLine("Live CPU registers (decimal):");
            output.WriteText("RIP: "); WriteNumber(System.Kernel.Cpu.ReadInstructionPointer()); NewLine();
            output.WriteText("RSP: "); WriteNumber(System.Kernel.Cpu.ReadStackPointer()); NewLine();
            output.WriteText("RBP: "); WriteNumber(System.Kernel.Cpu.ReadBasePointer()); NewLine();
            output.WriteText("RFLAGS: "); WriteNumber(System.Kernel.Cpu.ReadFlags()); NewLine();
            output.WriteText("CR3: "); WriteNumber(System.Kernel.Cpu.ReadCr3()); NewLine();
            if (System.Kernel.Memory.Read32(bootInfo + 2672) == 2) {
                output.WriteLine("Last fatal frame:");
                output.WriteText("RIP: "); WriteNumber(System.Kernel.Memory.Read64(bootInfo + 2616)); NewLine();
                output.WriteText("RSP: "); WriteNumber(System.Kernel.Memory.Read64(bootInfo + 2640)); NewLine();
                output.WriteText("RFLAGS: "); WriteNumber(System.Kernel.Memory.Read64(bootInfo + 2632)); NewLine();
            }
        }

        private void Reboot() {
            output.WriteLine("Rebooting system.");
            System.Kernel.Cpu.DisableInterrupts();
            System.Kernel.Port.Write8(3321, 2); // chipset reset-control port 0xcf9
            System.Kernel.Port.Write8(3321, 6);
            int attempts = 0;
            while (attempts < 100000) { System.Kernel.Cpu.Pause(); attempts = attempts + 1; }
            System.Kernel.Port.Write8(100, 254); // 8042 reset fallback
            output.WriteLine("Reset did not complete; halting.");
            while (true) { System.Kernel.Cpu.Halt(); }
        }

        private void Halt() {
            output.WriteLine("System halted.");
            System.Kernel.Cpu.DisableInterrupts();
            while (true) { System.Kernel.Cpu.Halt(); }
        }

        private string Argument(UserShellCommand command) {
            if (command == null || !command.HasArgument()) { return null; }
            byte[] bytes = new byte[command.ArgumentLength()];
            int i = 0;
            while (i < bytes.Length) {
                bytes[i] = line[command.ArgumentStart() + i]; i = i + 1;
            }
            return System.Kernel.String.FromBytes(bytes, bytes.Length);
        }

        private string Word(UserShellCommand command) {
            if (command == null || command.WordLength() < 1) { return null; }
            byte[] bytes = new byte[command.WordLength()];
            int i = 0;
            while (i < bytes.Length) {
                bytes[i] = line[command.WordStart() + i]; i = i + 1;
            }
            return System.Kernel.String.FromBytes(bytes, bytes.Length);
        }

        private void PathCommand(UserShellCommand command) {
            if (!command.HasArgument()) {
                output.WriteText("PATH=");
                output.WriteBytes(searchPath, searchPathLength);
                NewLine(); return;
            }
            int first = command.ArgumentStart();
            int count = command.ArgumentLength();
            if (count < 1 || count > searchPath.Length) {
                output.WriteLine("Invalid PATH directory."); return;
            }
            int start = 0;
            while (start < count) {
                int end = start;
                while (end < count && line[first + end] != 58) {
                    int value = line[first + end];
                    if (value < 33 || value > 126) {
                        output.WriteLine("Invalid PATH directory."); return;
                    }
                    end = end + 1;
                }
                if (end == start || line[first + start] != 47) {
                    output.WriteLine("Invalid PATH directory."); return;
                }
                byte[] bytes = new byte[end - start];
                int i = 0;
                while (i < bytes.Length) {
                    bytes[i] = line[first + start + i]; i = i + 1;
                }
                string directory = System.Kernel.String.FromBytes(bytes, bytes.Length);
                VfsFileInfo info = mountNamespace.Stat(directory);
                if (!info.Exists() || info.Kind() != 2) {
                    output.WriteLine("PATH directory not found."); return;
                }
                start = end + 1;
                if (end < count && start == count) {
                    output.WriteLine("Invalid PATH directory."); return;
                }
            }
            int copy = 0;
            while (copy < count) {
                searchPath[copy] = line[first + copy]; copy = copy + 1;
            }
            searchPathLength = count;
            output.WriteText("PATH=");
            output.WriteBytes(searchPath, searchPathLength);
            NewLine();
        }

        private bool ExecSuffix(string name) {
            int n = name.Length;
            return n >= 5 && System.Kernel.String.ByteAt(name, n - 5) == 46 &&
                System.Kernel.String.ByteAt(name, n - 4) == 101 &&
                System.Kernel.String.ByteAt(name, n - 3) == 120 &&
                System.Kernel.String.ByteAt(name, n - 2) == 101 &&
                System.Kernel.String.ByteAt(name, n - 1) == 99;
        }

        private string ExistingProgram(byte[] bytes, int count) {
            if (count < 1 || count > 255) { return null; }
            string candidate = System.Kernel.String.FromBytes(bytes, count);
            VfsFileInfo info = mountNamespace.Stat(candidate);
            if (info.Status() == VfsStatus.IoFailure()) { lookupIoFailure = true; }
            if (info.Exists() && info.Kind() == 1) { return candidate; }
            return null;
        }

        private string ResolveProgram(string name) {
            lookupIoFailure = false;
            if (name == null || name.Length < 1 || name.Length > 255) { return null; }
            int i = 0;
            bool containsSlash = false;
            while (i < name.Length) {
                int value = System.Kernel.String.ByteAt(name, i);
                if (value == 47) { containsSlash = true; }
                if (value < 33 || value > 126 || value == 58) { return null; }
                i = i + 1;
            }
            bool suffix = ExecSuffix(name);
            byte[] candidate = new byte[255];
            if (containsSlash) {
                int offset = 0;
                if (System.Kernel.String.ByteAt(name, 0) != 47) {
                    candidate[0] = 47; offset = 1;
                }
                if (name.Length > 255 - offset) { return null; }
                i = 0;
                while (i < name.Length) {
                    candidate[offset + i] = (byte)System.Kernel.String.ByteAt(name, i);
                    i = i + 1;
                }
                int length = offset + name.Length;
                string found = ExistingProgram(candidate, length);
                if (found != null) { return found; }
                if (suffix || length > 250) { return null; }
                candidate[length] = 46; candidate[length + 1] = 101;
                candidate[length + 2] = 120; candidate[length + 3] = 101;
                candidate[length + 4] = 99;
                return ExistingProgram(candidate, length + 5);
            }
            int start = 0;
            while (start < searchPathLength) {
                int end = start;
                while (end < searchPathLength && searchPath[end] != 58) { end = end + 1; }
                int length = end - start;
                if (length > 0 && searchPath[start] == 47) {
                    i = 0;
                    while (i < length) {
                        candidate[i] = searchPath[start + i]; i = i + 1;
                    }
                    if (candidate[length - 1] != 47 && length < 255) {
                        candidate[length] = 47; length = length + 1;
                    }
                    int suffixLength = 0;
                    if (!suffix) { suffixLength = 5; }
                    if (name.Length <= 255 - length - suffixLength &&
                        candidate[length - 1] == 47) {
                        i = 0;
                        while (i < name.Length) {
                            candidate[length + i] = (byte)System.Kernel.String.ByteAt(name, i);
                            i = i + 1;
                        }
                        length = length + name.Length;
                        if (!suffix) {
                            candidate[length] = 46; candidate[length + 1] = 101;
                            candidate[length + 2] = 120; candidate[length + 3] = 101;
                            candidate[length + 4] = 99;
                            length = length + 5;
                        }
                        string found = ExistingProgram(candidate, length);
                        if (found != null) { return found; }
                    }
                }
                start = end + 1;
            }
            return null;
        }

        private void StatPath(UserShellCommand command) {
            string path = Argument(command);
            if (path == null || path.Length < 1 || System.Kernel.String.ByteAt(path, 0) != 47) {
                output.WriteLine("Usage: stat /path"); return;
            }
            VfsFileInfo info = mountNamespace.Stat(path);
            if (!info.Exists()) { output.WriteLine(notFoundText); return; }
            output.WriteText("path: "); output.WriteLine(path);
            output.WriteText("type: ");
            if (info.Kind() == 2) { output.WriteLine("directory"); }
            else { output.WriteLine("file"); }
            output.WriteText("size: "); WriteNumber(info.ByteLength()); output.WriteLine(" bytes");
            output.WriteText("id: ");
            if (info.ObjectId() > 0) { WriteNumber(info.ObjectId()); NewLine(); }
            else { output.WriteLine("unavailable"); }
            output.WriteText("created: ");
            if (info.HasCreationTime()) { WriteNumber(info.CreatedUnixSeconds()); NewLine(); }
            else { output.WriteLine("unavailable"); }
            output.WriteText("modified: ");
            if (info.HasModificationTime()) { WriteNumber(info.ModifiedUnixSeconds()); NewLine(); }
            else { output.WriteLine("unavailable"); }
            output.WriteText("attributes: "); WriteNumber(info.Attributes()); NewLine();
        }

        private ShellLaunch ParseLaunch(int start) {
            byte[] text = new byte[256];
            int[] starts = new int[17]; int[] sizes = new int[17];
            int count = 0; int used = 0; int cursor = start;
            while (cursor < length) {
                while (cursor < length && line[cursor] == 32) { cursor = cursor + 1; }
                if (cursor >= length) { break; }
                if (count >= starts.Length) { return null; }
                starts[count] = used;
                int quote = 0;
                while (cursor < length) {
                    int value = line[cursor];
                    if (quote == 0 && value == 32) { break; }
                    if (value == 39 && quote != 34) {
                        if (quote == 39) { quote = 0; }
                        else { quote = 39; }
                        cursor = cursor + 1; continue;
                    }
                    if (value == 34 && quote != 39) {
                        if (quote == 34) { quote = 0; }
                        else { quote = 34; }
                        cursor = cursor + 1; continue;
                    }
                    if (value == 92 && quote != 39) {
                        cursor = cursor + 1;
                        if (cursor >= length) { return null; }
                        value = line[cursor];
                    }
                    if (value < 32 || used >= text.Length) { return null; }
                    text[used] = (byte)value; used = used + 1;
                    cursor = cursor + 1;
                }
                if (quote != 0) { return null; }
                sizes[count] = used - starts[count]; count = count + 1;
            }
            if (count < 1 || sizes[0] < 1) { return null; }
            byte[] nameBytes = new byte[sizes[0]];
            int i = 0;
            while (i < nameBytes.Length) {
                nameBytes[i] = text[starts[0] + i]; i = i + 1;
            }
            int[] argumentStarts = new int[count - 1];
            int[] argumentSizes = new int[count - 1];
            i = 1;
            while (i < count) {
                argumentStarts[i - 1] = starts[i];
                argumentSizes[i - 1] = sizes[i];
                i = i + 1;
            }
            UserArguments arguments = new UserArguments(text, argumentStarts,
                argumentSizes, count - 1);
            if (!arguments.IsValid()) { return null; }
            return new ShellLaunch(System.Kernel.String.FromBytes(nameBytes,
                nameBytes.Length), arguments);
        }

        private void RunProgramPath(string path, UserArguments arguments) {
            // Print that it is running a program
			//output.WriteLine("Starting user program.");
            UserProgramResult result = programHost.Run(path, arguments);
            lastProgramState = result.State(); lastProgramExit = result.ExitCode();
            lastProgramFault = result.Fault();
            System.Kernel.Memory.Write32(bootInfo + 2576, lastProgramState);
            System.Kernel.Memory.Write32(bootInfo + 2580, lastProgramExit);
            System.Kernel.Memory.Write32(bootInfo + 2584, lastProgramFault);
            System.Kernel.Memory.Write32(bootInfo + 2588,
                System.Kernel.Memory.Read32(bootInfo + 2588) + 1);
            System.Kernel.Memory.Write64(bootInfo + 2592, result.Instructions());
            // Stage 1 process ABI diagnostics: active file descriptors after wait.
            System.Kernel.Memory.Write32(bootInfo + 3460,
                programHost.ActiveDescriptors());
            System.Kernel.Memory.Write32(bootInfo + 3464, result.Pid());
            // Print the status around the program execution
            if (lastProgramState == UserProgramState.Exited()) {
                if (lastProgramExit == 0) {
					//output.WriteLine("User program exited cleanly.");
				} else {
					output.WriteLine("User program exited with an error.");
				}
            } else if (lastProgramFault == UserFault.MemoryAccess()) {
                output.WriteLine("User program blocked from kernel memory.");
            } else if (lastProgramFault == UserFault.InvalidImage()) {
                output.WriteLine("Invalid user executable.");
            } else if (lastProgramFault == UserFault.Arithmetic()) {
                output.WriteLine("User program arithmetic fault.");
            } else {
				output.WriteLine("User program faulted.");
			}
        }

        private void RunProgram(UserShellCommand command) {
            if (!command.HasArgument()) {
                output.WriteLine("Usage: run <program>"); return;
            }
            ShellLaunch launch = ParseLaunch(command.ArgumentStart());
            if (launch == null) { output.WriteLine("Invalid command line."); return; }
            string path = ResolveProgram(launch.Name());
            if (path == null) {
                if (lookupIoFailure) { output.WriteLine(readErrorText); }
                else { output.WriteLine("Executable not found."); }
                return;
            }
            RunProgramPath(path, launch.Arguments());
        }

        private void RunBareProgram(UserShellCommand command) {
            ShellLaunch launch = ParseLaunch(command.WordStart());
            if (launch == null) { output.WriteLine("Invalid command line."); return; }
            string path = ResolveProgram(launch.Name());
            if (path == null) {
                if (lookupIoFailure) { output.WriteLine(readErrorText); }
                else { output.WriteLine(unknownText); }
                return;
            }
            RunProgramPath(path, launch.Arguments());
        }

        private void Devices() {
            int storage = System.Kernel.Memory.Read32(bootInfo + 304);
            int interruptStorage = System.Kernel.Memory.Read32(bootInfo + 1232);
            if (bootMode == 3 || storage != interruptStorage ||
                (storage != 1 && storage != 2)) {
                output.WriteLine("boot0: storage not initialized");
            } else if (storage == 1) { output.WriteLine("boot0: AHCI storage ready"); }
            else { output.WriteLine("boot0: NVMe storage ready"); }
            if (usb == null) { output.WriteLine("usb0: absent"); }
            else if (usb.IsStorage()) { output.WriteLine("usb0: mass-storage ready"); }
            else if (usb.IsKeyboard()) { output.WriteLine("usb0: keyboard ready"); }
            else { output.WriteLine("usb0: removed or unavailable"); }
        }

        private void Mounts() {
            bool found = false;
            if (root != null && root.IsRootMounted()) {
                output.WriteLine("/: hyfs boot0"); found = true;
            }
            if (data != null && data.IsRootMounted()) {
                output.WriteLine("/data: hyfs2 data0 read-write"); found = true;
            }
            if (removable != null && removable.IsRootMounted()) {
                if (usb != null && usb.IsStorage()) { output.WriteLine("/usb: hyfs usb0"); }
                else { output.WriteLine("/usb: hyfs offline"); }
                found = true;
            }
            if (!found) { output.WriteLine("No filesystems mounted."); }
        }

        private void Execute() {
            commandCount = commandCount + 1;
            System.Kernel.Memory.Write32(bootInfo + 1144, commandCount);
            if (editor.InputWasLost()) { output.WriteLine(lostText); return; }
            if (length == 0) { return; }
            if (editor.Overflowed()) { output.WriteLine(overflowText); return; }
            UserShellCommand command = registry.Parse(line, length);
            int identifier = command.Identifier();
            if (identifier == UserShellCommandId.Empty()) { return; }
            RecordCommand(identifier);
            if (identifier == UserShellCommandId.Help() && !command.HasArgument()) {
                output.WriteLine(helpText); return;
            }
            if (identifier == UserShellCommandId.Version() && !command.HasArgument()) {
                output.WriteLine(versionText); return;
            }
            if (identifier == UserShellCommandId.Devices()) {
                if (command.HasArgument()) { output.WriteLine("Usage: devices"); return; }
                Devices(); return;
            }
            if (identifier == UserShellCommandId.Mounts()) {
                if (command.HasArgument()) { output.WriteLine("Usage: mounts"); return; }
                Mounts(); return;
            }
            if (identifier == UserShellCommandId.WorkingDirectory() && !command.HasArgument()) {
                output.WriteLine("/"); return;
            }
            if (identifier == UserShellCommandId.List() ||
                identifier == UserShellCommandId.Cat() ||
                identifier == UserShellCommandId.Processes()) {
                RunBareProgram(command); return;
            }
            if (identifier == UserShellCommandId.Stat()) { StatPath(command); return; }
            if (identifier == UserShellCommandId.Echo()) {
                int i = command.ArgumentStart();
                while (i < length) { output.WriteByte(line[i]); i = i + 1; }
                NewLine(); return;
            }
            if (identifier == UserShellCommandId.Path()) { PathCommand(command); return; }
            if (identifier == UserShellCommandId.Run()) { RunProgram(command); return; }
            if (identifier == UserShellCommandId.ContinueBoot()) {
                if (command.HasArgument()) { output.WriteLine("Usage: continue"); return; }
                if (bootMode != 3) { output.WriteLine("Normal boot is already active."); }
                else {
                    output.WriteLine("Restarting into normal boot.");
                    Reboot();
                }
                return;
            }
            if (identifier == UserShellCommandId.Reboot()) {
                if (command.HasArgument()) { output.WriteLine("Usage: reboot"); return; }
                Reboot(); return;
            }
            if (identifier == UserShellCommandId.Halt()) {
                if (command.HasArgument()) { output.WriteLine("Usage: halt"); return; }
                Halt(); return;
            }
            if (identifier == UserShellCommandId.Trace()) {
                if (command.HasArgument()) { output.WriteLine("Usage: trace"); return; }
                Trace(); return;
            }
            if (identifier == UserShellCommandId.Status()) {
                if (command.HasArgument()) { output.WriteLine("Usage: status"); return; }
                Status(); return;
            }
            if (identifier == UserShellCommandId.BootInfo()) {
                if (command.HasArgument()) { output.WriteLine("Usage: bootinfo"); return; }
                BootInfo(); return;
            }
            if (identifier == UserShellCommandId.MemoryMap()) {
                if (command.HasArgument()) { output.WriteLine("Usage: memmap"); return; }
                MemoryMap(); return;
            }
            if (identifier == UserShellCommandId.Pages()) {
                if (command.HasArgument()) { output.WriteLine("Usage: pages"); return; }
                Pages(); return;
            }
            if (identifier == UserShellCommandId.Registers()) {
                if (command.HasArgument()) { output.WriteLine("Usage: registers"); return; }
                Registers(); return;
            }
            if (identifier == UserShellCommandId.Panic()) {
                if (command.HasArgument()) { output.WriteLine("Usage: panic"); return; }
                if (bootMode != 1) { output.WriteLine("panic requires D debug boot."); return; }
                output.WriteLine("Triggering deliberate kernel page fault.");
                long invalid = System.Kernel.Memory.Read64(0);
                if (invalid == 1) { output.WriteLine("Panic unexpectedly returned."); }
                return;
            }
            RunBareProgram(command);
        }

        private void Redraw() {
            output.ClearLine();
            output.WriteText(prompt);
            output.WriteBytes(line, length);
            int remaining = length - editor.Cursor();
            while (remaining > 0) { output.WriteByte(8); remaining = remaining - 1; }
        }

        // For deferred device notices, clear the active input row, print a
        // complete line, then restore the prompt and edited command.
        public void PrintNotice(string text) {
            output.ClearLine();
            output.WriteLine(text);
            Redraw();
        }

        private bool HandleKey(int value) {
            int action = editor.Apply(value);
            length = editor.Length();
            if (action == LineEditor.Submit()) {
                int remaining = length - editor.Cursor();
                while (remaining > 0) {
                    output.WriteByte(27); output.WriteByte(91); output.WriteByte(67);
                    remaining = remaining - 1;
                }
                NewLine();
                long marker = PhysicalPages.MarkTransient(bootInfo);
                Execute();
                editor.Commit();
                if (marker == 0 || !PhysicalPages.RewindTransient(bootInfo, marker)) {
                    output.WriteLine(readErrorText);
                    return false;
                }
                editor.Reset();
                length = 0;
                output.WriteText(prompt);
            } else if (action == LineEditor.Cancel()) {
                NewLine();
                editor.Reset();
                length = 0;
                output.WriteText(prompt);
            } else if (action == LineEditor.Append()) {
                output.WriteByte(value);
            } else if (action == LineEditor.EraseEnd()) {
                output.WriteByte(8); output.WriteByte(32); output.WriteByte(8);
            } else if (action == LineEditor.Redraw()) {
                Redraw();
            } else if (action == LineEditor.ClearScreen()) {
                output.ClearScreen();
                Redraw();
            } else if (action == LineEditor.Bell()) {
                output.WriteByte(7);
            }
            return true;
        }

        public void Run() {
            if (!PhysicalPages.BeginTransientRegion(bootInfo)) {
                output.WriteLine(readErrorText);
                return;
            }
            output.WriteLine(banner);
            output.WriteText(prompt);
            while (input.IsReady()) {
                // Device events and controller rebuilds own persistent state,
                // so service them outside the per-command transient arena.
                if (usb != null) { usb.Pump(); }
                decoder.Pump();
                System.Kernel.Memory.Write32(bootInfo + 1256, events.Dropped());
                int value = events.Poll();
                if (value == -1) {
                    if (input.CanHalt()) { System.Kernel.Cpu.Halt(); }
                    else { System.Kernel.Cpu.Pause(); }
                    continue;
                }
                if (!HandleKey(value)) { return; }
            }
        }
    }
}
