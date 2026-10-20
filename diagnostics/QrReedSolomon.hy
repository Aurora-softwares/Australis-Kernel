
namespace Australis.Kernel.Diagnostics {

    public class QrReedSolomon {

        // XOR two bytes without using native bitwise operators.
        // Hydrogen's current freestanding backend supports
        // arithmetic, so we calculate XOR one bit at a time.
        private static int XorByte(int a, int b) {
            int result = 0;
            int bit = 1;
            int i = 0;

            while (i < 8) {
                if (a % 2 != b % 2) {
                    result = result + bit;
                }

                a = a / 2;
                b = b / 2;
                bit = bit * 2;
                i = i + 1;
            }

            return result;
        }

        // Multiply two GF(256) elements.
        // QR codes use the primitive polynomial 0x11D.
        private static int Multiply(int a, int b) {
            int result = 0;
            int i = 0;

            while (i < 8) {
                if (b % 2 != 0) {
                    result = XorByte(result, a);
                }

                b = b / 2;
                a = a * 2;

                // Drop the ninth bit and reduce by 0x1D.
                // Equivalent to polynomial reduction by 0x11D.
                if (a >= 256) {
                    a = XorByte(a - 256, 29);
                }

                i = i + 1;
            }

            return result;
        }

        // Construct the degree-15 generator polynomial.
        // The caller provides 16 writable bytes at work.
        private static void BuildGenerator(long work) {
            int i = 0;

            while (i < 16) {
                System.Kernel.Memory.Write8(work + i, 0);
                i = i + 1;
            }

            System.Kernel.Memory.Write8(work, 1);

            int root = 1;
            int degree = 0;

            while (degree < 15) {
                int tail = (int)System.Kernel.Memory.Read8(
                    work + degree);

                System.Kernel.Memory.Write8(
                    work + degree + 1,
                    Multiply(tail, root));

                int j = degree;

                while (j > 0) {
                    int current = (int)System.Kernel.Memory.Read8(
                        work + j);

                    int previous = (int)System.Kernel.Memory.Read8(
                        work + j - 1);

                    System.Kernel.Memory.Write8(
                        work + j,
                        XorByte(current, Multiply(previous, root)));

                    j = j - 1;
                }

                root = Multiply(root, 2);
                degree = degree + 1;
            }
        }

        // Generate the 15 error-correction codewords
        // required for QR Version 3, correction level L.
        //
        // data   : 55 readable bytes
        // parity : 15 writable bytes
        // work   : 16 writable bytes
        //
        // The three buffers must not overlap.
        // Returns 1 on success or 0 on invalid pointers.
        public static int EncodeV3L(
            long data,
            long parity,
            long work) {

            if (data < 4096 || parity < 4096 || work < 4096) {
                return 0;
            }

            BuildGenerator(work);

            int i = 0;

            // Initialise the remainder to zero.
            while (i < 15) {
                System.Kernel.Memory.Write8(parity + i, 0);
                i = i + 1;
            }

            // Polynomial long division over GF(256).
            i = 0;

            while (i < 55) {
                int input = (int)System.Kernel.Memory.Read8(
                    data + i);

                int leading = (int)System.Kernel.Memory.Read8(
                    parity);

                int factor = XorByte(input, leading);

                int j = 0;

                while (j < 14) {
                    int next = (int)System.Kernel.Memory.Read8(
                        parity + j + 1);

                    int coefficient = (int)System.Kernel.Memory.Read8(
                        work + j + 1);

                    int correction = Multiply(
                        factor, coefficient);

                    System.Kernel.Memory.Write8(
                        parity + j,
                        XorByte(next, correction));

                    j = j + 1;
                }

                int last = (int)System.Kernel.Memory.Read8(
                    work + 15);

                System.Kernel.Memory.Write8(
                    parity + 14,
                    Multiply(factor, last));

                i = i + 1;
            }

            return 1;
        }
    }
}
