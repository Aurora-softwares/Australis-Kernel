namespace Australis.Kernel.Time {
    public interface IMonotonicCounter {
        long Now();
    }

    // Converts an arbitrary monotonic counter into overflow-safe deadlines.
    // Tests inject a synthetic counter; the native clock uses the invariant TSC.
    public class DeadlineClock {
        private IMonotonicCounter counter;
        private long ticksPerMillisecond;

        public DeadlineClock(IMonotonicCounter input, long ticksPerMs) {
            counter = input; ticksPerMillisecond = ticksPerMs;
        }

        public bool IsValid() { return counter != null && ticksPerMillisecond > 0; }
        public long Now() { if (counter == null) { return 0; } return counter.Now(); }
        public long DeadlineAfter(int milliseconds) {
            if (!IsValid() || milliseconds < 1) { return 0; }
            long now = counter.Now();
            long delta = ticksPerMillisecond * milliseconds;
            if (delta < ticksPerMillisecond) { return 0; }
            long deadline = now + delta;
            if (deadline < now) { return 0; }
            return deadline;
        }
        public bool Expired(long deadline) {
            return deadline <= 0 || counter == null || counter.Now() >= deadline;
        }
    }

}
