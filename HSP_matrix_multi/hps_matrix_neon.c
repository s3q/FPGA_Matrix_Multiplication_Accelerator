#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <time.h>
#include <arm_neon.h>

#define MAX_N 8

static char *read_file(const char *filename)
{
    FILE *fp;
    long size;
    char *buf;

    fp = fopen(filename, "rb");
    if (!fp) {
        perror("fopen");
        return NULL;
    }

    fseek(fp, 0, SEEK_END);
    size = ftell(fp);
    rewind(fp);

    buf = (char *)malloc(size + 1);
    if (!buf) {
        fclose(fp);
        return NULL;
    }

    if (fread(buf, 1, size, fp) != (size_t)size) {
        fclose(fp);
        free(buf);
        return NULL;
    }

    buf[size] = '\0';
    fclose(fp);
    return buf;
}

static char *find_key(char *json, const char *key)
{
    char pattern[64];
    char *p;

    snprintf(pattern, sizeof(pattern), "\"%s\"", key);

    p = strstr(json, pattern);
    if (!p)
        return NULL;

    p = strchr(p, ':');
    if (!p)
        return NULL;

    return p + 1;
}

static int parse_uint_after_key(char *json, const char *key, uint32_t *out)
{
    char *p;

    p = find_key(json, key);
    if (!p)
        return -1;

    while (*p && !isdigit((unsigned char)*p))
        p++;

    if (!*p)
        return -1;

    *out = (uint32_t)strtoul(p, NULL, 10);
    return 0;
}

static int parse_matrix_after_key(char *json, const char *key,
                                  uint32_t rows, uint32_t cols,
                                  uint8_t matrix[MAX_N][MAX_N])
{
    char *p;
    uint32_t r;
    uint32_t c;
    uint32_t value;

    p = find_key(json, key);
    if (!p)
        return -1;

    while (*p && *p != '[')
        p++;

    if (!*p)
        return -1;

    for (r = 0; r < rows; r++) {
        for (c = 0; c < cols; c++) {
            while (*p && !isdigit((unsigned char)*p))
                p++;

            if (!*p)
                return -1;

            value = (uint32_t)strtoul(p, &p, 10);

            if (value > 255) {
                printf("Error: matrix values must be 0 to 255.\n");
                return -1;
            }

            matrix[r][c] = (uint8_t)value;
        }
    }

    return 0;
}

static uint64_t time_diff_ns(struct timespec start, struct timespec end)
{
    uint64_t s;
    uint64_t e;

    s = (uint64_t)start.tv_sec * 1000000000ULL + (uint64_t)start.tv_nsec;
    e = (uint64_t)end.tv_sec   * 1000000000ULL + (uint64_t)end.tv_nsec;

    return e - s;
}

/*
 * NEON dot product for up to 8 elements.
 *
 * The arrays are always 8 bytes wide. For K < 8, the unused elements are zero.
 * This lets NEON calculate a full 8-lane dot product safely.
 */
static inline uint32_t dot_product_u8_neon_8(const uint8_t a[8], const uint8_t b[8])
{
    uint8x8_t va;
    uint8x8_t vb;
    uint16x8_t prod16;
    uint32x4_t low32;
    uint32x4_t high32;
    uint32x4_t sum32;
    uint32_t temp[4];

    va = vld1_u8(a);
    vb = vld1_u8(b);

    /* 8 parallel unsigned 8-bit multiplications, result is 16-bit lanes. */
    prod16 = vmull_u8(va, vb);

    /* Convert 8 x 16-bit products into 8 x 32-bit values, split as low/high. */
    low32  = vmovl_u16(vget_low_u16(prod16));
    high32 = vmovl_u16(vget_high_u16(prod16));

    /* Pairwise add low and high groups. */
    sum32 = vaddq_u32(low32, high32);

    vst1q_u32(temp, sum32);

    return temp[0] + temp[1] + temp[2] + temp[3];
}

/*
 * NEON matrix multiplication:
 *
 * A is M x K.
 * B is K x N.
 * C is M x N.
 *
 * B_T is the transpose of B, so each B column becomes a contiguous row.
 * This is important because NEON loads 8 adjacent bytes efficiently.
 */
static void hps_matrix_multiply_neon(uint32_t M, uint32_t K, uint32_t N,
                                     uint8_t A[MAX_N][MAX_N],
                                     uint8_t B[MAX_N][MAX_N],
                                     volatile uint32_t C[MAX_N][MAX_N])
{
    uint8_t B_T[MAX_N][MAX_N];
    uint32_t r;
    uint32_t c;
    uint32_t k;

    /* Clear B_T first, so unused K lanes are zero. */
    for (r = 0; r < MAX_N; r++) {
        for (c = 0; c < MAX_N; c++) {
            B_T[r][c] = 0;
        }
    }

    /*
     * Transpose B:
     * B is K x N.
     * B_T is N x K.
     */
    for (r = 0; r < K; r++) {
        for (c = 0; c < N; c++) {
            B_T[c][r] = B[r][c];
        }
    }

    for (r = 0; r < M; r++) {
        for (c = 0; c < N; c++) {
            C[r][c] = dot_product_u8_neon_8(A[r], B_T[c]);
        }
    }
}

int main(int argc, char **argv)
{
    const char *json_file = "matrix.json";
    uint32_t iterations = 1000000;

    char *json;
    uint32_t M;
    uint32_t K;
    uint32_t N;

    uint8_t A[MAX_N][MAX_N] = {{0}};
    uint8_t B[MAX_N][MAX_N] = {{0}};
    volatile uint32_t C[MAX_N][MAX_N] = {{0}};

    struct timespec t1;
    struct timespec t2;

    uint64_t total_ns;
    double avg_ns;
    double avg_ps;

    uint32_t i;
    uint32_t r;
    uint32_t c;

    if (argc >= 2)
        json_file = argv[1];

    if (argc >= 3)
        iterations = (uint32_t)strtoul(argv[2], NULL, 10);

    if (iterations < 1)
        iterations = 1;

    json = read_file(json_file);
    if (!json) {
        printf("Error: could not read %s\n", json_file);
        return 1;
    }

    if (parse_uint_after_key(json, "M", &M) < 0 ||
        parse_uint_after_key(json, "K", &K) < 0 ||
        parse_uint_after_key(json, "N", &N) < 0) {
        printf("Error: JSON must contain M, K, and N.\n");
        free(json);
        return 1;
    }

    if (M < 1 || M > 8 || K < 1 || K > 8 || N < 1 || N > 8) {
        printf("Error: M, K, and N must be from 1 to 8.\n");
        free(json);
        return 1;
    }

    if (parse_matrix_after_key(json, "A", M, K, A) < 0) {
        printf("Error: could not parse matrix A.\n");
        free(json);
        return 1;
    }

    if (parse_matrix_after_key(json, "B", K, N, B) < 0) {
        printf("Error: could not parse matrix B.\n");
        free(json);
        return 1;
    }

    free(json);

    printf("HPS ARM NEON Matrix Multiplication Benchmark\n");
    printf("Loaded JSON file: %s\n", json_file);
    printf("A = %u x %u\n", M, K);
    printf("B = %u x %u\n", K, N);
    printf("C = %u x %u\n", M, N);
    printf("Iterations = %u\n\n", iterations);

    /*
     * Warm-up run.
     * This reduces first-run cache and branch predictor effects.
     */
    hps_matrix_multiply_neon(M, K, N, A, B, C);

    if (clock_gettime(CLOCK_MONOTONIC, &t1) != 0) {
        perror("clock_gettime start");
        return 1;
    }

    for (i = 0; i < iterations; i++) {
        hps_matrix_multiply_neon(M, K, N, A, B, C);
    }

    if (clock_gettime(CLOCK_MONOTONIC, &t2) != 0) {
        perror("clock_gettime end");
        return 1;
    }

    total_ns = time_diff_ns(t1, t2);
    avg_ns = (double)total_ns / (double)iterations;
    avg_ps = avg_ns * 1000.0;

    printf("Result matrix C = A x B:\n\n");

    for (r = 0; r < M; r++) {
        for (c = 0; c < N; c++) {
            printf("%6u ", (uint32_t)C[r][c]);
        }
        printf("\n");
    }

    printf("\nTiming result:\n");
    printf("Total time       = %llu ns\n", (unsigned long long)total_ns);
    printf("Average per run  = %.3f ns\n", avg_ns);
    printf("Average per run  = %.3f ps\n", avg_ps);

    printf("\nNotes:\n");
    printf("- This uses ARM NEON intrinsics for each dot product.\n");
    printf("- B is transposed in software so NEON can load each B column contiguously.\n");
    printf("- The ps value is converted from averaged ns timing; Linux is not truly ps-accurate.\n");

    return 0;
}
