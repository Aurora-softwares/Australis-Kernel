using Australis.Kernel.Vfs;
using Australis.Kernel.Usb;
using Australis.User;

namespace Australis.Kernel.Console {
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
        private byte[] nameBuffer;
        private int length;
        private int commandCount;
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
        private string usageText;
        private string notFoundText;
        private string readErrorText;
        private string tooLargeText;
        private string overflowText;
        private string lostText;

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
            nameBuffer = new byte[64];
            length = 0;
            commandCount = 0;
            prompt = "australis> ";
            mountNamespace = new VfsNamespace(root, removable, data);
            registry = new UserShellRegistry();
            programHost = new NativeUserProgramHost(mountNamespace,
                new NativeUserTerminal(input, output, events, decoder, usb));
            lastProgramState = 0; lastProgramExit = 0; lastProgramFault = 0;
            banner = "Australis serial console ready. Type help.";
            versionText = "version: 0.0.1";
            helpText = "Commands: help, echo, ls [path], stat <path>, cat <path>, devices, mounts, pwd, run <path>, ps, version, panic-test";
            unknownText = "Unknown command. Type help.";
            usageText = "Usage: cat /filename";
            notFoundText = "File not found.";
            readErrorText = "File read failed.";
            tooLargeText = "File exceeds the 64 KiB console limit.";
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

        private string Argument(UserShellCommand command) {
            if (command == null || !command.HasArgument()) { return null; }
            byte[] bytes = new byte[command.ArgumentLength()];
            int i = 0;
            while (i < bytes.Length) {
                bytes[i] = line[command.ArgumentStart() + i]; i = i + 1;
            }
            return System.Kernel.String.FromBytes(bytes, bytes.Length);
        }

        private void ListPath(string path) {
            VfsPath resolved = mountNamespace.Resolve(path);
            if (!resolved.IsValid()) { output.WriteLine(notFoundText); return; }
            string canonical = resolved.CanonicalPath();
            int slots = mountNamespace.DirectorySlotCount(canonical);
            if (slots < 0) { output.WriteLine(readErrorText); return; }
            int index = 0;
            while (index < slots) {
                int nameLength = mountNamespace.CopyDirectoryEntryName(canonical, index, nameBuffer);
                if (nameLength < 0) { output.WriteLine(readErrorText); return; }
                if (nameLength > 0) {
                    if (canonical != "/") { output.WriteText(canonical); }
                    output.WriteByte(47);
                    output.WriteBytes(nameBuffer, nameLength);
                    NewLine();
                }
                index = index + 1;
            }
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

        private void Cat(UserShellCommand command) {
            string path = Argument(command);
            if (path == null || path.Length < 1 || System.Kernel.String.ByteAt(path, 0) != 47) {
                output.WriteLine(usageText); return;
            }
            VfsFileInfo info = mountNamespace.Stat(path);
            if (!info.Exists()) {
                if (info.Status() == VfsStatus.NotFound()) { output.WriteLine(notFoundText); }
                else { output.WriteLine(readErrorText); }
                return;
            }
            if (info.ByteLength() > 65536) { output.WriteLine(tooLargeText); return; }
            VfsFileHandle handle = mountNamespace.Open(path);
            long remaining = info.ByteLength();
            int lastByte = -1;
            while (remaining > 0) {
                int count = 512; if (remaining < count) { count = (int)remaining; }
                byte[] content = new byte[count];
                if (handle.Read(content) != VfsStatus.Ok()) {
                    handle.Close(); output.WriteLine(readErrorText); return;
                }
                output.WriteBytes(content, content.Length);
                lastByte = content[content.Length - 1];
                remaining = remaining - count;
            }
            handle.Close();
            if (info.ByteLength() == 0 || lastByte != 10) { NewLine(); }
        }

        private void RunProgram(UserShellCommand command) {
            string path = Argument(command);
            if (path == null || path.Length < 1 || System.Kernel.String.ByteAt(path, 0) != 47) {
                output.WriteLine("Usage: run /program.exec"); return;
            }
            // Print that it is running a program
			//output.WriteLine("Starting user program.");
            UserProgramResult result = programHost.Run(path);
            lastProgramState = result.State(); lastProgramExit = result.ExitCode();
            lastProgramFault = result.Fault();
            System.Kernel.Memory.Write32(bootInfo + 2576, lastProgramState);
            System.Kernel.Memory.Write32(bootInfo + 2580, lastProgramExit);
            System.Kernel.Memory.Write32(bootInfo + 2584, lastProgramFault);
            System.Kernel.Memory.Write32(bootInfo + 2588,
                System.Kernel.Memory.Read32(bootInfo + 2588) + 1);
            System.Kernel.Memory.Write64(bootInfo + 2592, result.Instructions());
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

        private void Processes() {
            if (lastProgramState == 0) { output.WriteLine("No user programs have run."); }
            else if (lastProgramState == UserProgramState.Exited()) {
                output.WriteLine("pid 1: exited");
            } else { output.WriteLine("pid 1: faulted"); }
        }

        private void Devices() {
            output.WriteLine("boot0: system storage ready");
            if (usb == null) { output.WriteLine("usb0: absent"); }
            else if (usb.IsStorage()) { output.WriteLine("usb0: mass-storage ready"); }
            else if (usb.IsKeyboard()) { output.WriteLine("usb0: keyboard ready"); }
            else { output.WriteLine("usb0: removed or unavailable"); }
        }

        private void Mounts() {
            output.WriteLine("/: hyfs boot0");
            if (data != null && data.IsRootMounted()) {
                output.WriteLine("/data: hyfs2 data0 read-write");
            }
            if (removable != null && removable.IsRootMounted()) {
                if (usb != null && usb.IsStorage()) { output.WriteLine("/usb: hyfs usb0"); }
                else { output.WriteLine("/usb: hyfs offline"); }
            }
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
            if (identifier == UserShellCommandId.Help() && !command.HasArgument()) {
                output.WriteLine(helpText); return;
            }
            if (identifier == UserShellCommandId.Version() && !command.HasArgument()) {
                output.WriteLine(versionText); return;
            }
            if (identifier == UserShellCommandId.Devices() && !command.HasArgument()) { Devices(); return; }
            if (identifier == UserShellCommandId.Mounts() && !command.HasArgument()) { Mounts(); return; }
            if (identifier == UserShellCommandId.WorkingDirectory() && !command.HasArgument()) {
                output.WriteLine("/"); return;
            }
            if (identifier == UserShellCommandId.List()) {
                string listPath = Argument(command);
                if (listPath == null) { listPath = "/"; }
                ListPath(listPath); return;
            }
            if (identifier == UserShellCommandId.Stat()) { StatPath(command); return; }
            if (identifier == UserShellCommandId.Echo()) {
                int i = command.ArgumentStart();
                while (i < length) { output.WriteByte(line[i]); i = i + 1; }
                NewLine(); return;
            }
            if (identifier == UserShellCommandId.Cat()) { Cat(command); return; }
            if (identifier == UserShellCommandId.Run()) { RunProgram(command); return; }
            if (identifier == UserShellCommandId.Processes() && !command.HasArgument()) {
                Processes(); return;
            }
            if (identifier == UserShellCommandId.PanicTest() && !command.HasArgument()) {
                output.WriteLine("Triggering kernel page fault for panic diagnostics.");
                long unreachable = System.Kernel.Memory.Read64(0);
                if (unreachable == 1) { output.WriteLine("Panic test unexpectedly returned."); }
                return;
            }
            output.WriteLine(unknownText);
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
