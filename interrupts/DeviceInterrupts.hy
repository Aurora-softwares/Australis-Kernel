namespace Australis.Kernel.Interrupts {
    public class DeviceInterruptRegistration {
        private int vector;
        private int owner;
        private bool registered;

        public DeviceInterruptRegistration(int inputVector) {
            vector = inputVector; owner = 0; registered = false;
        }
        public int Vector() { return vector; }
        public int Owner() { return owner; }
        public bool Register(int inputOwner) {
            if (registered || inputOwner <= 0 || vector < 50 || vector > 254) { return false; }
            owner = inputOwner; registered = true; return true;
        }
        public bool Unregister(int inputOwner) {
            if (!registered || owner != inputOwner) { return false; }
            owner = 0; registered = false; return true;
        }
        public bool IsRegistered() { return registered; }
    }

}
