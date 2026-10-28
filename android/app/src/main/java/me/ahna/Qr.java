package me.ahna;

import java.nio.charset.StandardCharsets;

/**
 * 작은 QR 코드 인코더(바이트 모드 · 오류 정정 M · 버전 1~40 자동 · 마스크 자동).
 * 외부 라이브러리 없이 QR로 보내기/받기 링크를 그리기 위해 씁니다(Nayuki의 공개 알고리즘을 따름).
 * encode()는 한 변의 모듈 수 n과 n×n 칸(true = 검정)을 돌려줍니다.
 */
final class Qr {
    private Qr() {}

    private static final int[] ECC_PER_BLOCK = {-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28};
    private static final int[] BLOCKS = {-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49};
    /** 오류 정정 M의 형식 비트 값 */
    private static final int ECL_M = 0;

    static boolean[][] encode(String text) {
        byte[] data = text.getBytes(StandardCharsets.UTF_8);
        int version = 1;
        for (; ; version++) {
            if (version > 40) throw new IllegalArgumentException("QR에 담기에는 너무 깁니다.");
            int countBits = version <= 9 ? 8 : 16;
            int needed = 4 + countBits + data.length * 8;
            if (data.length < (1 << countBits) && needed <= dataCodewords(version) * 8) break;
        }
        // 데이터 비트
        int capacity = dataCodewords(version) * 8;
        BitBuffer bb = new BitBuffer();
        bb.append(4, 4);
        bb.append(data.length, version <= 9 ? 8 : 16);
        for (byte b : data) bb.append(b & 0xFF, 8);
        bb.append(0, Math.min(4, capacity - bb.size));
        bb.append(0, (8 - bb.size % 8) % 8);
        for (int pad = 0xEC; bb.size < capacity; pad ^= 0xEC ^ 0x11) bb.append(pad, 8);
        byte[] codewords = new byte[bb.size / 8];
        for (int i = 0; i < bb.size; i++) if (bb.get(i)) codewords[i >>> 3] |= (byte) (1 << (7 - (i & 7)));
        byte[] all = addEcc(codewords, version);

        int size = version * 4 + 17;
        boolean[][] modules = new boolean[size][size];
        boolean[][] function = new boolean[size][size];
        drawFunctions(modules, function, version);
        drawCodewords(modules, function, all);
        int bestMask = 0; long bestPenalty = Long.MAX_VALUE;
        for (int mask = 0; mask < 8; mask++) {
            applyMask(modules, function, mask);
            drawFormat(modules, function, mask);
            long p = penalty(modules);
            if (p < bestPenalty) { bestPenalty = p; bestMask = mask; }
            applyMask(modules, function, mask);
        }
        applyMask(modules, function, bestMask);
        drawFormat(modules, function, bestMask);
        return modules;
    }

    private static final class BitBuffer {
        boolean[] bits = new boolean[64]; int size;
        void append(int value, int length) {
            for (int i = length - 1; i >= 0; i--) {
                if (size == bits.length) bits = java.util.Arrays.copyOf(bits, size * 2);
                bits[size++] = ((value >>> i) & 1) != 0;
            }
        }
        boolean get(int i) { return bits[i]; }
    }

    private static int rawModules(int ver) {
        int result = (16 * ver + 128) * ver + 64;
        if (ver >= 2) {
            int align = ver / 7 + 2;
            result -= (25 * align - 10) * align - 55;
            if (ver >= 7) result -= 36;
        }
        return result;
    }
    private static int dataCodewords(int ver) { return rawModules(ver) / 8 - ECC_PER_BLOCK[ver] * BLOCKS[ver]; }

    private static byte[] addEcc(byte[] data, int ver) {
        int blocks = BLOCKS[ver], eccLen = ECC_PER_BLOCK[ver];
        int raw = rawModules(ver) / 8;
        int shortBlocks = blocks - raw % blocks, shortLen = raw / blocks;
        byte[] divisor = rsDivisor(eccLen);
        byte[][] out = new byte[blocks][];
        for (int i = 0, k = 0; i < blocks; i++) {
            int len = shortLen - eccLen + (i < shortBlocks ? 0 : 1);
            byte[] dat = java.util.Arrays.copyOfRange(data, k, k + len);
            k += len;
            byte[] block = java.util.Arrays.copyOf(dat, shortLen + 1);
            byte[] ecc = rsRemainder(dat, divisor);
            System.arraycopy(ecc, 0, block, block.length - eccLen, eccLen);
            out[i] = block;
        }
        byte[] result = new byte[raw];
        for (int i = 0, k = 0; i < out[0].length; i++) {
            for (int j = 0; j < out.length; j++) {
                if (i != shortLen - eccLen || j >= shortBlocks) result[k++] = out[j][i];
            }
        }
        return result;
    }
    private static byte[] rsDivisor(int degree) {
        byte[] result = new byte[degree];
        result[degree - 1] = 1;
        int root = 1;
        for (int i = 0; i < degree; i++) {
            for (int j = 0; j < result.length; j++) {
                result[j] = (byte) mul(result[j] & 0xFF, root);
                if (j + 1 < result.length) result[j] ^= result[j + 1];
            }
            root = mul(root, 0x02);
        }
        return result;
    }
    private static byte[] rsRemainder(byte[] data, byte[] divisor) {
        byte[] result = new byte[divisor.length];
        for (byte b : data) {
            int factor = (b ^ result[0]) & 0xFF;
            System.arraycopy(result, 1, result, 0, result.length - 1);
            result[result.length - 1] = 0;
            for (int i = 0; i < result.length; i++) result[i] ^= (byte) mul(divisor[i] & 0xFF, factor);
        }
        return result;
    }
    private static int mul(int x, int y) {
        int z = 0;
        for (int i = 7; i >= 0; i--) {
            z = (z << 1) ^ ((z >>> 7) * 0x11D);
            z ^= ((y >>> i) & 1) * x;
        }
        return z;
    }

    private static void set(boolean[][] m, boolean[][] f, int x, int y, boolean dark) { m[y][x] = dark; f[y][x] = true; }

    private static void drawFunctions(boolean[][] m, boolean[][] f, int ver) {
        int size = m.length;
        for (int i = 0; i < size; i++) { set(m, f, 6, i, i % 2 == 0); set(m, f, i, 6, i % 2 == 0); }
        finder(m, f, 3, 3); finder(m, f, size - 4, 3); finder(m, f, 3, size - 4);
        int[] align = alignment(ver);
        int n = align.length;
        for (int i = 0; i < n; i++) for (int j = 0; j < n; j++) {
            if (i == 0 && j == 0 || i == 0 && j == n - 1 || i == n - 1 && j == 0) continue;
            for (int dy = -2; dy <= 2; dy++) for (int dx = -2; dx <= 2; dx++)
                set(m, f, align[i] + dx, align[j] + dy, Math.max(Math.abs(dx), Math.abs(dy)) != 1);
        }
        drawFormat(m, f, 0);
        if (ver >= 7) {
            int rem = ver;
            for (int i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1F25);
            int bits = ver << 12 | rem;
            for (int i = 0; i < 18; i++) {
                boolean bit = ((bits >>> i) & 1) != 0;
                int a = size - 11 + i % 3, b = i / 3;
                set(m, f, a, b, bit); set(m, f, b, a, bit);
            }
        }
    }
    private static void finder(boolean[][] m, boolean[][] f, int x, int y) {
        int size = m.length;
        for (int dy = -4; dy <= 4; dy++) for (int dx = -4; dx <= 4; dx++) {
            int d = Math.max(Math.abs(dx), Math.abs(dy)), xx = x + dx, yy = y + dy;
            if (xx >= 0 && xx < size && yy >= 0 && yy < size) set(m, f, xx, yy, d != 2 && d != 4);
        }
    }
    private static int[] alignment(int ver) {
        if (ver == 1) return new int[0];
        int num = ver / 7 + 2;
        int step = (ver == 32) ? 26 : (ver * 4 + num * 2 + 1) / (num * 2 - 2) * 2;
        int[] result = new int[num];
        result[0] = 6;
        for (int i = result.length - 1, pos = ver * 4 + 10; i >= 1; i--, pos -= step) result[i] = pos;
        return result;
    }
    private static void drawFormat(boolean[][] m, boolean[][] f, int mask) {
        int size = m.length;
        int data = ECL_M << 3 | mask, rem = data;
        for (int i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
        int bits = (data << 10 | rem) ^ 0x5412;
        for (int i = 0; i <= 5; i++) set(m, f, 8, i, bit(bits, i));
        set(m, f, 8, 7, bit(bits, 6)); set(m, f, 8, 8, bit(bits, 7)); set(m, f, 7, 8, bit(bits, 8));
        for (int i = 9; i < 15; i++) set(m, f, 14 - i, 8, bit(bits, i));
        for (int i = 0; i < 8; i++) set(m, f, size - 1 - i, 8, bit(bits, i));
        for (int i = 8; i < 15; i++) set(m, f, 8, size - 15 + i, bit(bits, i));
        set(m, f, 8, size - 8, true);
    }
    private static boolean bit(int x, int i) { return ((x >>> i) & 1) != 0; }

    private static void drawCodewords(boolean[][] m, boolean[][] f, byte[] data) {
        int size = m.length, i = 0;
        for (int right = size - 1; right >= 1; right -= 2) {
            if (right == 6) right = 5;
            for (int vert = 0; vert < size; vert++) for (int j = 0; j < 2; j++) {
                int x = right - j;
                boolean upward = ((right + 1) & 2) == 0;
                int y = upward ? size - 1 - vert : vert;
                if (!f[y][x] && i < data.length * 8) { m[y][x] = bit(data[i >>> 3], 7 - (i & 7)); i++; }
            }
        }
    }
    private static void applyMask(boolean[][] m, boolean[][] f, int mask) {
        int size = m.length;
        for (int y = 0; y < size; y++) for (int x = 0; x < size; x++) {
            boolean invert;
            switch (mask) {
                case 0: invert = (x + y) % 2 == 0; break;
                case 1: invert = y % 2 == 0; break;
                case 2: invert = x % 3 == 0; break;
                case 3: invert = (x + y) % 3 == 0; break;
                case 4: invert = (x / 3 + y / 2) % 2 == 0; break;
                case 5: invert = x * y % 2 + x * y % 3 == 0; break;
                case 6: invert = (x * y % 2 + x * y % 3) % 2 == 0; break;
                default: invert = ((x + y) % 2 + x * y % 3) % 2 == 0; break;
            }
            if (!f[y][x] && invert) m[y][x] = !m[y][x];
        }
    }
    /** 표준 감점 규칙(같은 색 줄 · 2×2 · 찾기 무늬 비슷한 줄 · 검정 비율)으로 가장 읽기 쉬운 마스크를 고릅니다. */
    private static long penalty(boolean[][] m) {
        int size = m.length; long result = 0; int dark = 0;
        for (int pass = 0; pass < 2; pass++) {
            for (int a = 0; a < size; a++) {
                int run = 0; boolean color = false;
                for (int b = 0; b < size; b++) {
                    boolean c = pass == 0 ? m[a][b] : m[b][a];
                    if (b > 0 && c == color) { run++; if (run == 5) result += 3; else if (run > 5) result++; }
                    else { color = c; run = 1; }
                }
                // 1:1:3:1:1 무늬(대략) — 가로·세로 모두
                for (int b = 0; b + 7 <= size; b++) {
                    boolean ok = true;
                    boolean[] pat = {true, false, true, true, true, false, true};
                    for (int k = 0; k < 7 && ok; k++) ok = (pass == 0 ? m[a][b + k] : m[b + k][a]) == pat[k];
                    if (ok) {
                        boolean before = true, after = true;
                        for (int k = 1; k <= 4; k++) {
                            int p = b - k, q = b + 6 + k;
                            if (p >= 0 && (pass == 0 ? m[a][p] : m[p][a])) before = false;
                            if (q < size && (pass == 0 ? m[a][q] : m[q][a])) after = false;
                        }
                        if (before || after) result += 40;
                    }
                }
            }
        }
        for (int y = 0; y < size - 1; y++) for (int x = 0; x < size - 1; x++) {
            boolean c = m[y][x];
            if (c == m[y][x + 1] && c == m[y + 1][x] && c == m[y + 1][x + 1]) result += 3;
        }
        for (boolean[] row : m) for (boolean c : row) if (c) dark++;
        int total = size * size;
        int k = (Math.abs(dark * 20 - total * 10) + total - 1) / total - 1;
        result += Math.max(0, k) * 10L;
        return result;
    }
}
