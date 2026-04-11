static int q16_div(int num_q16, int den_q16) {
    int int_part = num_q16 / den_q16;
    int rem = num_q16 % den_q16;

    int q1 = (rem << 8) / den_q16;
    int r1 = (rem << 8) % den_q16;
    int q2 = (r1 << 8) / den_q16;

    return (int_part << 16) + (q1 << 8) + q2;
}

int main(void) {
    volatile int *result_ptr = (volatile int *)0x100;
    int S = 2 * 65536;
    int x = 65536;
    int i;

    for (i = 0; i < 8; i++) {
        int t = q16_div(S, x);
        x = (x + t) >> 1;
    }

    *result_ptr = x;

    while (1) {
    }
    return 0;
}
