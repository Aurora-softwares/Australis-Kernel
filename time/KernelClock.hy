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
        private long MaxTick() {
            long unit = 65536;
            long square = unit * unit;
            return square * 2147483647 + square - 1;
        }
        public long DeadlineAfter(int milliseconds) {
            if (!IsValid() || milliseconds < 1) { return 0; }
            long now = counter.Now();
            if (now < 0 || ticksPerMillisecond >
                (MaxTick() - now) / milliseconds) { return 0; }
            long delta = ticksPerMillisecond * milliseconds;
            return now + delta;
        }
        public bool Expired(long deadline) {
            return deadline <= 0 || counter == null || counter.Now() >= deadline;
        }
    }

}
