namespace Australis.User {
    public class UserChannelMessage {
        private byte[] bytes;
        private int recipient;
        private int length;
        public UserChannelMessage() { bytes = new byte[256]; recipient = 0; length = 0; }
        public void Set(byte[] source, int inputLength, int inputRecipient) {
            length = inputLength; recipient = inputRecipient;
            int i = 0;
            while (i < length) { bytes[i] = source[i]; i = i + 1; }
        }
        public void Clear() { recipient = 0; length = 0; }
        public int Recipient() { return recipient; }
        public int Length() { return length; }
        public int CopyTo(byte[] destination) {
            if (destination == null || destination.Length < length) { return -4; }
            int i = 0;
            while (i < length) { destination[i] = bytes[i]; i = i + 1; }
            return length;
        }
    }

    public class UserChannel {
        private int handle;
        private int firstPid;
        private int secondPid;
        private int version;
        private UserChannelMessage[] messages;
        private int count;
        private bool active;
        public UserChannel(int inputHandle, int inputFirst, int inputSecond,
            int inputVersion) {
            messages = new UserChannelMessage[4];
            int i = 0;
            while (i < messages.Length) {
                messages[i] = new UserChannelMessage(); i = i + 1;
            }
            Reset(inputHandle, inputFirst, inputSecond, inputVersion);
        }
        public void Reset(int inputHandle, int inputFirst, int inputSecond,
            int inputVersion) {
            handle = inputHandle; firstPid = inputFirst; secondPid = inputSecond;
            version = inputVersion; count = 0; active = true;
            int i = 0;
            while (i < messages.Length) { messages[i].Clear(); i = i + 1; }
        }
        public int Handle() { return handle; }
        public bool Active() { return active; }
        public int FirstPid() { return firstPid; }
        public int SecondPid() { return secondPid; }
        public bool Owns(int pid) { return pid == firstPid || pid == secondPid; }
        public int Peer(int pid) {
            if (pid == firstPid) { return secondPid; }
            if (pid == secondPid) { return firstPid; }
            return -2;
        }
        public int Queued() { return count; }
        public int QueuedFor(int pid) {
            if (!Owns(pid)) { return -2; }
            int result = 0; int i = 0;
            while (i < count) {
                if (messages[i].Recipient() == pid) { result = result + 1; }
                i = i + 1;
            }
            return result;
        }
        public int Version() { return version; }
        public int Send(int sender, int messageVersion, byte[] source, int length) {
            if (!Owns(sender)) { return -2; }
            if (messageVersion != version) { return -3; }
            if (source == null || length < 0 || length > 256 ||
                length > source.Length) { return -4; }
            if (count == messages.Length) { return -5; }
            int recipient = firstPid;
            if (sender == firstPid) { recipient = secondPid; }
            messages[count].Set(source, length, recipient);
            count = count + 1; return 0;
        }
        public int Receive(int recipient, byte[] destination) {
            if (!Owns(recipient)) { return -2; }
            int slot = 0;
            while (slot < count && messages[slot].Recipient() != recipient) {
                slot = slot + 1;
            }
            if (slot == count) { return -1; }
            int result = messages[slot].CopyTo(destination);
            if (result < 0) { return result; }
            UserChannelMessage consumed = messages[slot];
            int i = slot;
            while (i + 1 < count) { messages[i] = messages[i + 1]; i = i + 1; }
            count = count - 1; messages[count] = consumed; consumed.Clear();
            return result;
        }
        public void Release() {
            int i = 0;
            while (i < messages.Length) { messages[i].Clear(); i = i + 1; }
            count = 0; active = false;
        }
    }

    // Handle generations prevent a closed channel's stale handle from naming
    // a later channel in the same slot. Process identity is checked on use.
    public class UserChannelTable {
        private UserProcessTable processes;
        private UserChannel[] channels;
        private int generation;
        public UserChannelTable(UserProcessTable inputProcesses) {
            processes = inputProcesses; channels = new UserChannel[16];
            generation = 0;
            int i = 0;
            while (i < channels.Length) {
                channels[i] = new UserChannel(0, 0, 0, 1);
                channels[i].Release(); i = i + 1;
            }
        }
        private bool Active(int pid) {
            if (processes == null) { return false; }
            UserProcessRecord record = processes.Find(pid);
            return record != null && (record.State() == UserProgramState.Running() ||
                record.State() == 4);
        }
        private UserChannel Find(int handle) {
            if (handle < 1) { return null; }
            int slot = (handle - 1) % channels.Length;
            if (channels[slot] == null || !channels[slot].Active() ||
                channels[slot].Handle() != handle) {
                return null;
            }
            return channels[slot];
        }
        public int Open(int firstPid, int secondPid, int version) {
            if (firstPid == secondPid || version < 1 || version > 255 ||
                !Active(firstPid) || !Active(secondPid)) { return -2; }
            UserProcessRecord first = processes.Find(firstPid);
            UserProcessRecord second = processes.Find(secondPid);
            if (first == null || second == null ||
                !first.HasCapability(1) || second.ParentPid() != firstPid) {
                return -2;
            }
            int slot = 0;
            while (slot < channels.Length && channels[slot].Active()) {
                slot = slot + 1;
            }
            if (slot == channels.Length) { return -5; }
            if (generation >= 1000000) { return -5; }
            generation = generation + 1;
            int handle = generation * channels.Length + slot + 1;
            channels[slot].Reset(handle, firstPid, secondPid, version);
            return handle;
        }
        public int Accept(int pid, int version) {
            if (!Active(pid) || version < 1 || version > 255) { return -2; }
            int i = 0;
            while (i < channels.Length) {
                if (channels[i].Active() && channels[i].SecondPid() == pid &&
                    channels[i].Version() == version) { return channels[i].Handle(); }
                i = i + 1;
            }
            return -1;
        }
        public int Peer(int handle, int pid) {
            UserChannel channel = Find(handle);
            if (channel == null) { return -1; }
            return channel.Peer(pid);
        }
        public int Send(int handle, int senderPid, int version,
            byte[] source, int length) {
            UserChannel channel = Find(handle);
            if (channel == null) { return -1; }
            if (!Active(senderPid)) { return -2; }
            return channel.Send(senderPid, version, source, length);
        }
        public int Receive(int handle, int recipientPid, byte[] destination) {
            UserChannel channel = Find(handle);
            if (channel == null) { return -1; }
            if (!Active(recipientPid)) { return -2; }
            return channel.Receive(recipientPid, destination);
        }
        public int Queued(int handle, int pid) {
            UserChannel channel = Find(handle);
            if (channel == null || !channel.Owns(pid)) { return -1; }
            return channel.Queued();
        }
        public int QueuedFor(int handle, int pid) {
            UserChannel channel = Find(handle);
            if (channel == null) { return -1; }
            return channel.QueuedFor(pid);
        }
        public bool Close(int handle, int pid) {
            UserChannel channel = Find(handle);
            if (channel == null || !channel.Owns(pid)) { return false; }
            int slot = (handle - 1) % channels.Length;
            channel.Release(); return true;
        }
        public void CloseForProcess(int pid) {
            int i = 0;
            while (i < channels.Length) {
                if (channels[i] != null && channels[i].Active() &&
                    channels[i].Owns(pid)) {
                    channels[i].Release();
                }
                i = i + 1;
            }
        }
    }
}
