#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <time.h>
#include "hps_0.h"

#define HW_REGS_BASE 0xFF200000
#define HW_REGS_SPAN 0x00200000

#define STATUS_BUSY   0x1
#define STATUS_DONE   0x2
#define STATUS_ERROR  0x4

#define MAX_N 8
#define FPGA_CLK_HZ 50000000.0

static volatile uint32_t *reg_ptr(void *base, unsigned int offset)
{
    return (volatile uint32_t *)((char *)base + offset);
}

static uint64_t now_ns(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return ((uint64_t)t.tv_sec * 1000000000ULL) + (uint64_t)t.tv_nsec;
}

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
                                  uint32_t matrix[MAX_N][MAX_N])
{
    char *p;
    uint32_t r;
    uint32_t c;

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

            matrix[r][c] = (uint32_t)strtoul(p, &p, 10);

            if (matrix[r][c] > 255) {
                printf("Error: matrix values must be 0 to 255.\n");
                return -1;
            }
        }
    }

    return 0;
}

/*
 * Fast PIO write pulse.
 * This version intentionally does not use usleep().
 * It measures the real software + lightweight-bridge register-access overhead.
 */
static void write_matrix_value_fast(volatile uint32_t *addr_reg,
                                    volatile uint32_t *data_reg,
                                    volatile uint32_t *en_reg,
                                    uint32_t addr,
                                    uint32_t value)
{
    *addr_reg = addr;
    *data_reg = value & 0xFF;
    *en_reg = 0;
    *en_reg = 1;
    *en_reg = 0;
}

static void cleanup(void *virtual_base, int fd)
{
    if (virtual_base && virtual_base != MAP_FAILED)
        munmap(virtual_base, HW_REGS_SPAN);

    if (fd >= 0)
        close(fd);
}

static void print_time_line(const char *name, uint64_t ns)
{
    printf("%-24s = %12llu ns  = %12.3f us  = %llu ps\n",
           name,
           (unsigned long long)ns,
           (double)ns / 1000.0,
           (unsigned long long)(ns * 1000ULL));
}

int main(int argc, char **argv)
{
    const char *json_file = "matrix.json";

    uint32_t M, K, N;
    uint32_t A[MAX_N][MAX_N] = {{0}};
    uint32_t B[MAX_N][MAX_N] = {{0}};
    uint16_t C[64] = {0};

    char *json;
    int fd;
    void *virtual_base;

    volatile uint32_t *matrix_ctrl;
    volatile uint32_t *matrix_dims;
    volatile uint32_t *matrix_write_addr;
    volatile uint32_t *matrix_write_data;
    volatile uint32_t *matrix_write_en;
    volatile uint32_t *matrix_index;
    volatile uint32_t *matrix_status;
    volatile uint32_t *matrix_data;
    volatile uint32_t *matrix_cycles;

    uint32_t status;
    uint32_t fpga_cycles;
    uint32_t r;
    uint32_t c;

    uint64_t t_total0, t_total1;
    uint64_t t_a0, t_a1;
    uint64_t t_b0, t_b1;
    uint64_t t_start0, t_start1;
    uint64_t t_wait0, t_wait1;
    uint64_t t_c0, t_c1;

    uint64_t a_write_ns;
    uint64_t b_write_ns;
    uint64_t start_ns;
    uint64_t wait_ns;
    uint64_t c_read_ns;
    uint64_t total_ns;

    double fpga_core_ns;

    if (argc >= 2)
        json_file = argv[1];

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

    fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    virtual_base = mmap(NULL, HW_REGS_SPAN, PROT_READ | PROT_WRITE,
                        MAP_SHARED, fd, HW_REGS_BASE);

    if (virtual_base == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }

    matrix_ctrl       = reg_ptr(virtual_base, MATRIX_CTRL_BASE);
    matrix_dims       = reg_ptr(virtual_base, MATRIX_DIMS_BASE);
    matrix_write_addr = reg_ptr(virtual_base, MATRIX_WRITE_ADDR_BASE);
    matrix_write_data = reg_ptr(virtual_base, MATRIX_WRITE_DATA_BASE);
    matrix_write_en   = reg_ptr(virtual_base, MATRIX_WRITE_EN_BASE);
    matrix_index      = reg_ptr(virtual_base, MATRIX_INDEX_BASE);
    matrix_status     = reg_ptr(virtual_base, MATRIX_STATUS_BASE);
    matrix_data       = reg_ptr(virtual_base, MATRIX_DATA_BASE);
    matrix_cycles     = reg_ptr(virtual_base, MATRIX_CYCLES_BASE);

    printf("Output-Stationary Fully Parallel Matrix Multiplier Test\n");
    printf("Loaded JSON file: %s\n", json_file);
    printf("A = %u x %u\n", M, K);
    printf("B = %u x %u\n", K, N);
    printf("C = %u x %u\n\n", M, N);

    t_total0 = now_ns();

    /* Load A into FPGA: addresses 0..63 */
    t_a0 = now_ns();
    for (r = 0; r < M; r++) {
        for (c = 0; c < K; c++) {
            write_matrix_value_fast(matrix_write_addr, matrix_write_data, matrix_write_en,
                                    r * 8 + c, A[r][c]);
        }
    }
    t_a1 = now_ns();

    /* Load B into FPGA: addresses 64..127 */
    t_b0 = now_ns();
    for (r = 0; r < K; r++) {
        for (c = 0; c < N; c++) {
            write_matrix_value_fast(matrix_write_addr, matrix_write_data, matrix_write_en,
                                    64 + r * 8 + c, B[r][c]);
        }
    }
    t_b1 = now_ns();

    /* matrix_dims[3:0] = M, [7:4] = K, [11:8] = N */
    *matrix_dims = (N << 8) | (K << 4) | M;

    printf("Starting FPGA output-stationary fully parallel multiplication...\n");

    /*
     * For output-stationary-only VHDL:
     * matrix_ctrl bit 0 = start
     * Other bits are ignored.
     */
    t_start0 = now_ns();
    *matrix_ctrl = 0;
    *matrix_ctrl = 1;
    *matrix_ctrl = 0;
    t_start1 = now_ns();

    t_wait0 = now_ns();
    while (((*matrix_status) & (STATUS_DONE | STATUS_ERROR)) == 0) {
        /* Busy-wait without usleep to measure actual ready latency. */
    }
    t_wait1 = now_ns();

    status = *matrix_status;

    if (status & STATUS_ERROR) {
        printf("FPGA error: invalid dimensions.\n");
        cleanup(virtual_base, fd);
        return 1;
    }

    printf("FPGA calculation done.\n\n");

    /* Read C from FPGA */
    t_c0 = now_ns();
    for (r = 0; r < M; r++) {
        for (c = 0; c < N; c++) {
            uint32_t idx = r * 8 + c;
            *matrix_index = idx;
            C[idx] = (uint16_t)((*matrix_data) & 0xFFFF);
        }
    }
    t_c1 = now_ns();

    t_total1 = now_ns();

    fpga_cycles = *matrix_cycles;
    fpga_core_ns = ((double)fpga_cycles / FPGA_CLK_HZ) * 1000000000.0;

    a_write_ns = t_a1 - t_a0;
    b_write_ns = t_b1 - t_b0;
    start_ns   = t_start1 - t_start0;
    wait_ns    = t_wait1 - t_wait0;
    c_read_ns  = t_c1 - t_c0;
    total_ns   = t_total1 - t_total0;

    printf("Result matrix C = A x B:\n\n");

    for (r = 0; r < M; r++) {
        for (c = 0; c < N; c++) {
            printf("%6u ", C[r * 8 + c]);
        }
        printf("\n");
    }

    printf("\n================ Full Timing Analysis ================\n");
    printf("FPGA core cycles        = %u cycles\n", fpga_cycles);
    printf("FPGA core time @50MHz   = %.3f ns  = %.0f ps\n",
           fpga_core_ns, fpga_core_ns * 1000.0);
    printf("Expected compute cycles approximately K = %u\n\n", K);

    print_time_line("A write time", a_write_ns);
    print_time_line("B write time", b_write_ns);
    print_time_line("Start overhead", start_ns);
    print_time_line("HPS wait for done", wait_ns);
    print_time_line("C read time", c_read_ns);
    printf("------------------------------------------------------\n");
    print_time_line("Total FPGA system time", total_ns);

    printf("\nNotes:\n");
    printf("- FPGA core time is calculated from the FPGA cycle counter.\n");
    printf("- Total FPGA system time includes A/B transfer, start, wait, and C readback.\n");
    printf("- Timing uses Linux CLOCK_MONOTONIC, so ps is converted from ns scale, not true ps precision.\n");
    printf("- This version removes usleep() from register transfers to avoid artificial delays.\n");

    cleanup(virtual_base, fd);
    return 0;
}
