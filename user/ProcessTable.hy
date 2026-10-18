namespace Australis.User {
    public class UserProcessRecord {
        private int pid;
        private int parentPid;
        private int state;
        private int exitCode;
        private int fault;
        private long instructions;
        private long generation;
        private int capabilities;
        private bool reaped;

        public UserProcessRecord(int inputPid, int inputParent, long inputGeneration) {
            Reset(inputPid, inputParent, inputGeneration, 0);
        }
        public void Reset(int inputPid, int inputParent, long inputGeneration) {
            Reset(inputPid, inputParent, inputGeneration, 0);
        }
        public void Reset(int inputPid, int inputParent, long inputGeneration,
            int inputCapabilities) {
            pid = inputPid; parentPid = inputParent; generation = inputGeneration;
            capabilities = inputCapabilities;
            state = 0;
            if (pid > 0) { state = UserProgramState.Running(); }
            exitCode = 0;
            fault = UserFault.None(); instructions = 0;
            reaped = false;
        }
        public int Pid() { return pid; }
        public int ParentPid() { return parentPid; }
        public int State() { return state; }
        public int ExitCode() { return exitCode; }
        public int Fault() { return fault; }
        public long Instructions() { return instructions; }
        public long Generation() { return generation; }
        public bool Reaped() { return reaped; }
        public void MarkReaped() { reaped = true; }
        public bool HasCapability(int capability) {
            return capability > 0 && (capabilities / capability) % 2 != 0;
        }
        public void WaitForChild() {
            if (state == UserProgramState.Running()) { state = 4; }
        }
        public void Resume() {
            if (state == 4) { state = UserProgramState.Running(); }
        }
        public void Finish(UserProgramResult result) {
            if (result == null || result.Pid() != pid ||
                (state != UserProgramState.Running() && state != 4)) { return; }
            state = result.State(); exitCode = result.ExitCode();
            fault = result.Fault(); instructions = result.Instructions();
        }
    }

    // Recent process history is bounded. Live entries are never evicted.
    // This table stores kernel-owned identity and status, not caller-supplied names.
    public class UserProcessTable {
        private UserProcessRecord[] entries;
        private long generation;
        public UserProcessTable() {
            entries = new UserProcessRecord[64]; generation = 0;
            int i = 0;
            while (i < entries.Length) {
                entries[i] = new UserProcessRecord(0, 0, 0); i = i + 1;
            }
        }
        public UserProcessRecord Find(int pid) {
            if (pid < 1) { return null; }
            int i = 0;
            while (i < entries.Length) {
                if (entries[i].Pid() == pid) {
                    return entries[i];
                }
                i = i + 1;
            }
            return null;
        }
        public int ActiveCount() {
            int count = 0; int i = 0;
            while (i < entries.Length) {
                if (entries[i].Pid() > 0 &&
                    (entries[i].State() == UserProgramState.Running() ||
                    entries[i].State() == 4)) { count = count + 1; }
                i = i + 1;
            }
            return count;
        }
        public int FirstChild(int parentPid) {
            int i = 0;
            while (i < entries.Length) {
                if (entries[i].Pid() > 0 &&
                    entries[i].ParentPid() == parentPid) { return entries[i].Pid(); }
                i = i + 1;
            }
            return 0;
        }
        public void Clear(int pid) {
            UserProcessRecord entry = Find(pid);
            if (entry != null && entry.State() != UserProgramState.Running() &&
                entry.State() != 4) { entry.Reset(0, 0, 0); }
        }
        public bool Start(int pid, int parentPid) {
            return Start(pid, parentPid, 0);
        }
        public bool Start(int pid, int parentPid, int capabilities) {
            if (pid < 1 || parentPid < 0 || pid == parentPid || Find(pid) != null ||
                capabilities < 0 || capabilities > 255 ||
                (parentPid > 0 && Find(parentPid) == null)) { return false; }
            if (parentPid > 0) {
                int parentState = Find(parentPid).State();
                if (parentState != UserProgramState.Running() && parentState != 4) {
                    return false;
                }
            }
            int selected = -1; long oldest = 0;
            int i = 0;
            while (i < entries.Length) {
                if (entries[i].Pid() == 0) { selected = i; break; }
                int state = entries[i].State();
                bool recyclable = state != UserProgramState.Running() && state != 4;
                if (recyclable && entries[i].ParentPid() > 0 &&
                    !entries[i].Reaped()) {
                    UserProcessRecord parent = Find(entries[i].ParentPid());
                    if (parent != null && (parent.State() == UserProgramState.Running() ||
                        parent.State() == 4)) { recyclable = false; }
                }
                if (recyclable &&
                    (selected < 0 || entries[i].Generation() < oldest)) {
                    selected = i; oldest = entries[i].Generation();
                }
                i = i + 1;
            }
            if (selected < 0) { return false; }
            generation = generation + 1;
            entries[selected].Reset(pid, parentPid, generation, capabilities);
            return true;
        }
        public bool WaitForChild(int parentPid, int childPid) {
            UserProcessRecord parent = Find(parentPid);
            UserProcessRecord child = Find(childPid);
            if (parent == null || child == null || child.ParentPid() != parentPid ||
                child.Reaped() ||
                parent.State() != UserProgramState.Running()) { return false; }
            parent.WaitForChild(); return true;
        }
        public bool ReapChild(int parentPid, int childPid) {
            UserProcessRecord child = Find(childPid);
            if (parentPid < 1 || child == null ||
                child.ParentPid() != parentPid || child.Reaped() ||
                (child.State() != UserProgramState.Exited() &&
                child.State() != UserProgramState.Faulted())) { return false; }
            child.MarkReaped(); return true;
        }
        public bool Resume(int pid) {
            UserProcessRecord entry = Find(pid);
            if (entry == null || entry.State() != 4) { return false; }
            entry.Resume(); return true;
        }
        public bool Finish(UserProgramResult result) {
            if (result == null) { return false; }
            UserProcessRecord entry = Find(result.Pid());
            if (entry == null || (entry.State() != UserProgramState.Running() &&
                entry.State() != 4) ||
                (result.State() != UserProgramState.Exited() &&
                result.State() != UserProgramState.Faulted())) { return false; }
            entry.Finish(result); return true;
        }
    }
}
