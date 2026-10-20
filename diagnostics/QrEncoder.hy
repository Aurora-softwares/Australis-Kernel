
namespace Australis.Kernel.Diagnostics {
    public class QrEncoder {

        // Convert a hexadecimal digit (0-15) to ASCII.
        private static int HexCharacter(int digit) {
            if (digit < 10) {
                return 48 + digit;
            }
            return 55 + digit;
        }


        // Convert ASCII into a QR alphanumeric value.
        // Returns -1 for characters outside our panic format.
        private static int AlphanumericValue(int character) {
            // 0-9
            if (character >= 48 && character <= 57) {
                return character - 48;
            }

            // A-Z
            if (character >= 65 && character <= 90) {
                return character - 65 + 10;
            }

            // Colon (:)
            if (character == 58) {
                return 44;
            }

            return -1;
        }

        // Read a value from memory in little-endian order
        // and write its hexadecimal representation.
        // No objects, arrays, or strings are allocated.
        private static void WriteHexBytes(
            long destination,
            long source,
            int byteCount) {

            int i = 0;

            while (i < byteCount) {
                int value = (int)System.Kernel.Memory.Read8(
                    source + byteCount - 1 - i);

                int high = value / 16;
                int low = value % 16;

                System.Kernel.Memory.Write8(
                    destination + i * 2,
                    HexCharacter(high));

                System.Kernel.Memory.Write8(
                    destination + i * 2 + 1,
                    HexCharacter(low));

                i = i + 1;
            }
        }

        // Append bits, most significant bit first.
        // Destination bytes must be zero-initialised.
        // No bitwise operators or allocations are required.
        private static int WriteBits(
            long destination,
            int bitPosition,
            int value,
            int bitCount) {

            int weight = 1;
            int i = 1;

            while (i < bitCount) {
                weight = weight * 2;
                i = i + 1;
            }

            i = 0;

            while (i < bitCount) {
                int bit = (value / weight) % 2;

                if (bit != 0) {
                    int byteIndex = bitPosition / 8;
                    int bitWithinByte = bitPosition % 8;

                    int mask = 128;
                    int j = 0;

                    while (j < bitWithinByte) {
                        mask = mask / 2;
                        j = j + 1;
                    }

                    long address = destination + byteIndex;

                    int current = (int)System.Kernel.Memory.Read8(
                        address);

                    System.Kernel.Memory.Write8(
                        address,
                        current + mask);
                }

                bitPosition = bitPosition + 1;
                weight = weight / 2;
                i = i + 1;
            }

            return bitPosition;
        }

        // Pack our 74-character panic report into the
        // 55 data codewords for QR Version 3-L.
        //
        // payload: 74 readable ASCII bytes
        // output : 55 writable bytes
        //
        // Buffers must not overlap.
        // Returns 1 for success, 0 for failure.
        public static int EncodeV3L(
            long payload,
            int payloadLength,
            long output) {

            if (payload < 4096 || output < 4096) {
                return 0;
            }

            if (payloadLength != 74) {
                return 0;
            }

            // Initialise the 55 codewords to zero.
            int i = 0;

            while (i < 55) {
                System.Kernel.Memory.Write8(output + i, 0);
                i = i + 1;
            }

            int bitPosition = 0;

            // QR alphanumeric mode indicator: 0010.
            bitPosition = WriteBits(
                output, bitPosition, 2, 4);

            // Character count: 74 using 9 bits.
            bitPosition = WriteBits(
                output, bitPosition, payloadLength, 9);

            // Encode character pairs.
            i = 0;

            while (i < payloadLength) {
                int firstCharacter = (int)System.Kernel.Memory.Read8(
                    payload + i);

                int firstValue = AlphanumericValue(
                    firstCharacter);

                if (firstValue < 0) {
                    return 0;
                }

                if (i + 1 < payloadLength) {
                    int secondCharacter = (int)System.Kernel.Memory.Read8(
                        payload + i + 1);

                    int secondValue = AlphanumericValue(
                        secondCharacter);

                    if (secondValue < 0) {
                        return 0;
                    }

                    int combined = firstValue * 45 + secondValue;

                    bitPosition = WriteBits(
                        output,
                        bitPosition,
                        combined,
                        11);

                    i = i + 2;
                } else {
                    bitPosition = WriteBits(
                        output,
                        bitPosition,
                        firstValue,
                        6);

                    i = i + 1;
                }
            }

            // Our fixed payload must occupy 420 bits.
            if (bitPosition != 420) {
                return 0;
            }

            // Four-bit terminator.
            bitPosition = WriteBits(
                output, bitPosition, 0, 4);

            // 424 bits = 53 bytes, already byte aligned.
            int filled = bitPosition / 8;

            // Fill the remaining data bytes with the
            // standard alternating QR padding codewords.
            int pad = 236; // 0xEC

            while (filled < 55) {
                System.Kernel.Memory.Write8(
                    output + filled, pad);

                if (pad == 236) {
                    pad = 17; // 0x11
                } else {
                    pad = 236;
                }

                filled = filled + 1;
            }

            return 1;
        }

        // Produces a fixed 74-character QR payload.
        //
        // AU1:VV:EEEEEEEEEEEEEEEE:RRRRRRRRRRRRRRRR:
        // SSSSSSSSSSSSSSSS:CCCCCCCCCCCCCCCC
        //
        // VV = exception vector
        // EE = error code
        // RR = RIP
        // SS = RSP
        // CC = CR2
        //
        // destination must have at least 75 writable bytes.
        public static int WritePanicPayload(
            long bootInfo,
            long destination) {

            if (bootInfo < 4096 || destination < 4096) {
                return 0;
            }

            // AU1:
            System.Kernel.Memory.Write8(destination + 0, 65);
            System.Kernel.Memory.Write8(destination + 1, 85);
            System.Kernel.Memory.Write8(destination + 2, 49);
            System.Kernel.Memory.Write8(destination + 3, 58);

            // Exception vector (2 hex digits).
            WriteHexBytes(destination + 4, bootInfo + 2600, 1);

            System.Kernel.Memory.Write8(destination + 6, 58);

            // Exception error code (16 hex digits).
            WriteHexBytes(destination + 7, bootInfo + 2608, 8);

            System.Kernel.Memory.Write8(destination + 23, 58);

            // Instruction pointer / RIP.
            WriteHexBytes(destination + 24, bootInfo + 2616, 8);

            System.Kernel.Memory.Write8(destination + 40, 58);

            // Stack pointer / RSP.
            WriteHexBytes(destination + 41, bootInfo + 2640, 8);

            System.Kernel.Memory.Write8(destination + 57, 58);

            // Fault address / CR2.
            WriteHexBytes(destination + 58, bootInfo + 2648, 8);

            // NUL terminator for debugging.
            System.Kernel.Memory.Write8(destination + 74, 0);

            return 74;
        }

    }
}
