namespace Australis.User {
    // This policy is read from the checked, read-only system volume. AUEX
    // programs cannot grant themselves rights by choosing a file name under
    // /data. Unknown paths and malformed policies receive no capabilities.
    public class UserCapabilityPolicy {
        private string[] paths;
        private int[] grants;
        private int count;
        private bool valid;

        public UserCapabilityPolicy(byte[] image) {
            paths = new string[32]; grants = new int[32]; count = 0;
            valid = Parse(image);
            if (!valid) { count = 0; }
        }
        public bool IsValid() { return valid; }
        public int Grant(string path) {
            if (!valid || path == null) { return 0; }
            int i = 0;
            while (i < count) {
                if (paths[i] == path) { return grants[i]; }
                i = i + 1;
            }
            return 0;
        }
        private bool Parse(byte[] image) {
            if (image == null || image.Length < 10 || image.Length > 4096 ||
                image[0] != 65 || image[1] != 85 || image[2] != 83 ||
                image[3] != 67 || image[4] != 49 || image[5] != 10) { return false; }
            int cursor = 6;
            while (cursor < image.Length) {
                if (count >= paths.Length || image[cursor] != 47) { return false; }
                int pathStart = cursor;
                while (cursor < image.Length && image[cursor] != 124) {
                    if (image[cursor] < 33 || image[cursor] > 126) { return false; }
                    cursor = cursor + 1;
                }
                int pathLength = cursor - pathStart;
                if (pathLength < 2 || pathLength > 255 || cursor >= image.Length) {
                    return false;
                }
                byte[] pathBytes = new byte[pathLength];
                int copied = 0;
                while (copied < pathLength) {
                    pathBytes[copied] = image[pathStart + copied];
                    copied = copied + 1;
                }
                string path = System.Kernel.String.FromBytes(pathBytes, pathLength);
                int prior = 0;
                while (prior < count) {
                    if (paths[prior] == path) { return false; }
                    prior = prior + 1;
                }
                cursor = cursor + 1;
                int mask = 0; int digits = 0;
                while (cursor < image.Length && image[cursor] >= 48 &&
                    image[cursor] <= 57 && digits < 3) {
                    mask = mask * 10 + image[cursor] - 48;
                    digits = digits + 1; cursor = cursor + 1;
                }
                if (digits < 1 || mask < 1 || mask > 127 ||
                    cursor >= image.Length || image[cursor] != 10) { return false; }
                paths[count] = path; grants[count] = mask; count = count + 1;
                cursor = cursor + 1;
            }
            return count > 0;
        }
    }
}
