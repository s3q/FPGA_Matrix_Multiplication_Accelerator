library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ============================================================
-- matrix_core_pio_regular_os_systolic.vhd
--
-- Regular Sequential vs Output-Stationary (OS) Systolic Array
--
-- Same HPS PIO interface as the JSON/HPS design.
--
-- Supports:
--   A = M x K
--   B = K x N
--   C = M x N
--   M,K,N from 1 to 8
--
-- matrix_ctrl(0) = start pulse
-- matrix_ctrl(1) = mode
--                  0 = regular sequential multiplication
--                  1 = output-stationary systolic multiplication
--
-- matrix_dims[3:0]   = M
-- matrix_dims[7:4]   = K
-- matrix_dims[11:8]  = N
--
-- matrix_write_addr:
--   0..63    = A[0]..A[63]
--   64..127  = B[0]..B[63]
--
-- matrix_write_data[7:0] = input value
-- matrix_write_en(0)     = write pulse
--
-- matrix_index = C index to read, 0..63
--
-- matrix_status(0) = busy
-- matrix_status(1) = done
-- matrix_status(2) = error
-- matrix_status(3) = mode used, 0 regular, 1 OS systolic
-- ============================================================

entity matrix_core_pio_oss_r is
    port (
        clk                : in  std_logic;
        reset_n            : in  std_logic;

        matrix_ctrl        : in  std_logic_vector(31 downto 0);
        matrix_dims        : in  std_logic_vector(31 downto 0);

        matrix_write_addr  : in  std_logic_vector(31 downto 0);
        matrix_write_data  : in  std_logic_vector(31 downto 0);
        matrix_write_en    : in  std_logic_vector(31 downto 0);

        matrix_index       : in  std_logic_vector(5 downto 0);

        matrix_status      : out std_logic_vector(31 downto 0);
        matrix_data        : out std_logic_vector(31 downto 0);
        matrix_cycles      : out std_logic_vector(31 downto 0)
    );
end entity matrix_core_pio_oss_r;

architecture rtl of matrix_core_pio_oss_r is

    type mat8_t  is array (0 to 63) of unsigned(7 downto 0);
    type mat16_t is array (0 to 63) of unsigned(15 downto 0);

    signal A : mat8_t  := (others => (others => '0'));
    signal B : mat8_t  := (others => (others => '0'));
    signal C : mat16_t := (others => (others => '0'));

    -- OS systolic PE registers.
    signal a_pipe : mat8_t  := (others => (others => '0'));
    signal b_pipe : mat8_t  := (others => (others => '0'));
    signal pe_sum : mat16_t := (others => (others => '0'));

    type state_t is (
        IDLE,
        REGULAR_RUN,
        SYSTOLIC_RUN,
        COPY_RESULT,
        DONE,
        ERROR_STATE
    );

    signal state : state_t := IDLE;

    signal M_s : integer range 0 to 8 := 0;
    signal K_s : integer range 0 to 8 := 0;
    signal N_s : integer range 0 to 8 := 0;

    -- Regular sequential indexes.
    signal r_i : integer range 0 to 7 := 0;
    signal r_j : integer range 0 to 7 := 0;
    signal r_k : integer range 0 to 7 := 0;
    signal acc : unsigned(31 downto 0) := (others => '0');

    -- OS systolic timing.
    signal sys_cycle : integer range 0 to 31 := 0;

    signal cycles : unsigned(31 downto 0) := (others => '0');

    signal ctrl_d  : std_logic_vector(31 downto 0) := (others => '0');
    signal wr_en_d : std_logic := '0';

    signal busy_s  : std_logic := '0';
    signal done_s  : std_logic := '0';
    signal error_s : std_logic := '0';
    signal mode_s  : std_logic := '0';

    signal selected_index : integer range 0 to 63;

    function valid_dims(Mv, Kv, Nv : integer) return boolean is
    begin
        return (Mv >= 1 and Mv <= 8 and
                Kv >= 1 and Kv <= 8 and
                Nv >= 1 and Nv <= 8);
    end function;

begin

    selected_index <= to_integer(unsigned(matrix_index));

    matrix_status <= (31 downto 4 => '0') & mode_s & error_s & done_s & busy_s;
    matrix_data   <= x"0000" & std_logic_vector(C(selected_index));
    matrix_cycles <= std_logic_vector(cycles);

    process(clk, reset_n)
        variable start_pulse : std_logic;
        variable write_pulse : std_logic;

        variable addr_i : integer range 0 to 255;
        variable M_v    : integer range 0 to 15;
        variable K_v    : integer range 0 to 15;
        variable N_v    : integer range 0 to 15;

        variable prod     : unsigned(15 downto 0);
        variable next_acc : unsigned(31 downto 0);
        variable c_index  : integer range 0 to 63;

        variable finish_cycle : integer range 0 to 31;
    begin
        if reset_n = '0' then
            A         <= (others => (others => '0'));
            B         <= (others => (others => '0'));
            C         <= (others => (others => '0'));

            a_pipe    <= (others => (others => '0'));
            b_pipe    <= (others => (others => '0'));
            pe_sum    <= (others => (others => '0'));

            state     <= IDLE;
            M_s       <= 0;
            K_s       <= 0;
            N_s       <= 0;

            r_i       <= 0;
            r_j       <= 0;
            r_k       <= 0;
            acc       <= (others => '0');

            sys_cycle <= 0;
            cycles    <= (others => '0');

            ctrl_d    <= (others => '0');
            wr_en_d   <= '0';

            busy_s    <= '0';
            done_s    <= '0';
            error_s   <= '0';
            mode_s    <= '0';

        elsif rising_edge(clk) then
            start_pulse := matrix_ctrl(0) and not ctrl_d(0);
            write_pulse := matrix_write_en(0) and not wr_en_d;

            ctrl_d  <= matrix_ctrl;
            wr_en_d <= matrix_write_en(0);

            -- HPS may write A/B only when accelerator is not busy.
            if write_pulse = '1' and busy_s = '0' then
                addr_i := to_integer(unsigned(matrix_write_addr(7 downto 0)));

                if addr_i < 64 then
                    A(addr_i) <= unsigned(matrix_write_data(7 downto 0));
                elsif addr_i < 128 then
                    B(addr_i - 64) <= unsigned(matrix_write_data(7 downto 0));
                end if;
            end if;

            case state is

                when IDLE =>
                    busy_s  <= '0';
                    done_s  <= '0';
                    error_s <= '0';

                    if start_pulse = '1' then
                        M_v := to_integer(unsigned(matrix_dims(3 downto 0)));
                        K_v := to_integer(unsigned(matrix_dims(7 downto 4)));
                        N_v := to_integer(unsigned(matrix_dims(11 downto 8)));

                        C         <= (others => (others => '0'));
                        a_pipe    <= (others => (others => '0'));
                        b_pipe    <= (others => (others => '0'));
                        pe_sum    <= (others => (others => '0'));

                        r_i       <= 0;
                        r_j       <= 0;
                        r_k       <= 0;
                        acc       <= (others => '0');

                        sys_cycle <= 0;
                        cycles    <= (others => '0');

                        if not valid_dims(M_v, K_v, N_v) then
                            error_s <= '1';
                            state   <= ERROR_STATE;
                        else
                            M_s    <= M_v;
                            K_s    <= K_v;
                            N_s    <= N_v;
                            mode_s <= matrix_ctrl(1);
                            busy_s <= '1';

                            if matrix_ctrl(1) = '1' then
                                state <= SYSTOLIC_RUN;
                            else
                                state <= REGULAR_RUN;
                            end if;
                        end if;
                    end if;

                -- =====================================================
                -- Regular sequential mode:
                -- One multiply-accumulate per cycle.
                -- Cycles = M * K * N.
                -- =====================================================
                when REGULAR_RUN =>
                    busy_s <= '1';
                    done_s <= '0';
                    cycles <= cycles + 1;

                    prod     := A(r_i * 8 + r_k) * B(r_k * 8 + r_j);
                    next_acc := acc + resize(prod, 32);

                    if r_k = K_s - 1 then
                        c_index := r_i * 8 + r_j;
                        C(c_index) <= next_acc(15 downto 0);

                        acc <= (others => '0');
                        r_k <= 0;

                        if r_j = N_s - 1 then
                            r_j <= 0;

                            if r_i = M_s - 1 then
                                busy_s <= '0';
                                done_s <= '1';
                                state  <= DONE;
                            else
                                r_i <= r_i + 1;
                            end if;
                        else
                            r_j <= r_j + 1;
                        end if;
                    else
                        acc <= next_acc;
                        r_k <= r_k + 1;
                    end if;

                -- =====================================================
                -- Output-Stationary Systolic mode:
                -- A streams left-to-right.
                -- B streams top-to-bottom.
                -- Partial sums stay stationary inside PEs.
                -- =====================================================
                when SYSTOLIC_RUN =>
                    busy_s <= '1';
                    done_s <= '0';
                    cycles <= cycles + 1;

                    finish_cycle := M_s + K_s + N_s - 1;

                    for row in 0 to 7 loop
                        for col in 0 to 7 loop

                            -- Stationary partial sum inside PE(row,col).
                            if (row < M_s) and (col < N_s) then
                                pe_sum(row * 8 + col) <= pe_sum(row * 8 + col) +
                                    resize(a_pipe(row * 8 + col) * b_pipe(row * 8 + col), 16);
                            end if;

                            -- Inject/shift A left-to-right.
                            if col = 0 then
                                if (row < M_s) and
                                   (sys_cycle >= row) and
                                   (sys_cycle < row + K_s) then
                                    a_pipe(row * 8 + col) <= A(row * 8 + (sys_cycle - row));
                                else
                                    a_pipe(row * 8 + col) <= (others => '0');
                                end if;
                            else
                                a_pipe(row * 8 + col) <= a_pipe(row * 8 + col - 1);
                            end if;

                            -- Inject/shift B top-to-bottom.
                            if row = 0 then
                                if (col < N_s) and
                                   (sys_cycle >= col) and
                                   (sys_cycle < col + K_s) then
                                    b_pipe(row * 8 + col) <= B((sys_cycle - col) * 8 + col);
                                else
                                    b_pipe(row * 8 + col) <= (others => '0');
                                end if;
                            else
                                b_pipe(row * 8 + col) <= b_pipe((row - 1) * 8 + col);
                            end if;

                        end loop;
                    end loop;

                    if sys_cycle = finish_cycle then
                        state <= COPY_RESULT;
                    else
                        sys_cycle <= sys_cycle + 1;
                    end if;

                -- Copy PE stationary sums to output C after final MAC has settled.
                when COPY_RESULT =>
                    C      <= pe_sum;
                    busy_s <= '0';
                    done_s <= '1';
                    state  <= DONE;

                when DONE =>
                    busy_s <= '0';
                    done_s <= '1';

                    -- Allow another run without FPGA reset.
                    if start_pulse = '1' then
                        M_v := to_integer(unsigned(matrix_dims(3 downto 0)));
                        K_v := to_integer(unsigned(matrix_dims(7 downto 4)));
                        N_v := to_integer(unsigned(matrix_dims(11 downto 8)));

                        C         <= (others => (others => '0'));
                        a_pipe    <= (others => (others => '0'));
                        b_pipe    <= (others => (others => '0'));
                        pe_sum    <= (others => (others => '0'));

                        r_i       <= 0;
                        r_j       <= 0;
                        r_k       <= 0;
                        acc       <= (others => '0');

                        sys_cycle <= 0;
                        cycles    <= (others => '0');
                        done_s    <= '0';

                        if not valid_dims(M_v, K_v, N_v) then
                            error_s <= '1';
                            state   <= ERROR_STATE;
                        else
                            M_s     <= M_v;
                            K_s     <= K_v;
                            N_s     <= N_v;
                            mode_s  <= matrix_ctrl(1);
                            busy_s  <= '1';
                            error_s <= '0';

                            if matrix_ctrl(1) = '1' then
                                state <= SYSTOLIC_RUN;
                            else
                                state <= REGULAR_RUN;
                            end if;
                        end if;
                    end if;

                when ERROR_STATE =>
                    busy_s  <= '0';
                    done_s  <= '0';
                    error_s <= '1';

                    if start_pulse = '1' then
                        error_s <= '0';
                        state   <= IDLE;
                    end if;

            end case;
        end if;
    end process;

end architecture rtl;
