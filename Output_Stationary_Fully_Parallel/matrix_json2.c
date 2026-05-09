#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/mman.h>
#include "hps_0.h"

#define HW_REGS_BASE 0xFF200000
#define HW_REGS_SPAN 0x00200000

#define STATUS_BUSY   0x1
#define STATUS_DONE   0x2
#define STATUS_ERROR  0x4

#define MAX_N 8

static volatile uint32_t *reg_ptr(void *base, unsigned int offset)
{
    return (volatile uint32_t *)((char *)base + offset);
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

static void write_matrix_value(volatile uint32_t *addr_reg,
                               volatile uint32_t *data_reg,
                               volatile uint32_t *en_reg,
                               uint32_t addr,
                               uint32_t value)
{
    *addr_reg = addr;
    *data_reg = value & 0xFF;

    *en_reg = 0;
    usleep(100);
    *en_reg = 1;
    usleep(100);
    *en_reg = 0;
    usleep(100);
}

static void cleanup(void *virtual_base, int fd)
{
    if (virtual_base && virtual_base != MAP_FAILED)
        munmap(virtual_base, HW_REGS_SPAN);

    if (fd >= 0)
        close(fd);
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
    uint32_t r;
    uint32_t c;

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

    printf("Output-Stationary Parallel Matrix Multiplier Test\n");
    printf("Loaded JSON file: %s\n", json_file);
    printf("A = %u x %u\n", M, K);
    printf("B = %u x %u\n", K, N);
    printf("C = %u x %u\n\n", M, N);

    /* Load A into FPGA: addresses 0..63 */
    for (r = 0; r < M; r++) {
        for (c = 0; c < K; c++) {
            write_matrix_value(matrix_write_addr, matrix_write_data, matrix_write_en,
                               r * 8 + c, A[r][c]);
        }
    }

    /* Load B into FPGA: addresses 64..127 */
    for (r = 0; r < K; r++) {
        for (c = 0; c < N; c++) {
            write_matrix_value(matrix_write_addr, matrix_write_data, matrix_write_en,
                               64 + r * 8 + c, B[r][c]);
        }
    }

    /* matrix_dims[3:0] = M, [7:4] = K, [11:8] = N */
    *matrix_dims = (N << 8) | (K << 4) | M;

    printf("Starting FPGA output-stationary multiplication...\n");

    /*
     * For output-stationary-only VHDL:
     * matrix_ctrl bit 0 = start
     * Other bits are ignored.
     */
    *matrix_ctrl = 0;
    usleep(1000);

    *matrix_ctrl = 1;
    usleep(1000);

    *matrix_ctrl = 0;

    while (((*matrix_status) & (STATUS_DONE | STATUS_ERROR)) == 0) {
        usleep(1000);
    }

    status = *matrix_status;

    if (status & STATUS_ERROR) {
        printf("FPGA error: invalid dimensions.\n");
        cleanup(virtual_base, fd);
        return 1;
    }

    printf("FPGA calculation done.\n\n");

    for (r = 0; r < M; r++) {
        for (c = 0; c < N; c++) {
            uint32_t idx = r * 8 + c;
            *matrix_index = idx;
            usleep(100);
            C[idx] = (uint16_t)((*matrix_data) & 0xFFFF);
        }
    }

    printf("Result matrix C = A x B:\n\n");

    for (r = 0; r < M; r++) {
        for (c = 0; c < N; c++) {
            printf("%6u ", C[r * 8 + c]);
        }
        printf("\n");
    }

    printf("\nCycle count = %u\n", *matrix_cycles);
    printf("Expected compute cycles approximately K = %u\n", K);

    cleanup(virtual_base, fd);
    return 0;
}
