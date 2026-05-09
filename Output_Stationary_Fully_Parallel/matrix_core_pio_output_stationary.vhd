library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- ============================================================
-- matrix_core_pio_output_stationary_fixed.vhd
--
-- Output-Stationary Parallel Matrix Multiplier
-- Fixed version: copies PE accumulators to C one clock AFTER
-- the final MAC, so the last k-step is included.
-- ============================================================

entity matrix_core_pio_output_stationary is
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
end entity matrix_core_pio_output_stationary;

architecture rtl of matrix_core_pio_output_stationary is

    type mat8_t  is array (0 to 63) of unsigned(7 downto 0);
    type mat16_t is array (0 to 63) of unsigned(15 downto 0);

    signal A : mat8_t  := (others => (others => '0'));
    signal B : mat8_t  := (others => (others => '0'));
    signal C : mat16_t := (others => (others => '0'));

    signal pe_sum : mat16_t := (others => (others => '0'));

    type state_t is (IDLE, RUN, COPY_RESULT, DONE, ERROR_STATE);
    signal state : state_t := IDLE;

    signal M_s : integer range 0 to 8 := 0;
    signal K_s : integer range 0 to 8 := 0;
    signal N_s : integer range 0 to 8 := 0;

    signal k_step : integer range 0 to 7 := 0;

    signal cycles : unsigned(31 downto 0) := (others => '0');

    signal ctrl_d  : std_logic_vector(31 downto 0) := (others => '0');
    signal wr_en_d : std_logic := '0';

    signal busy_s  : std_logic := '0';
    signal done_s  : std_logic := '0';
    signal error_s : std_logic := '0';

    signal selected_index : integer range 0 to 63;

    function valid_dims(Mv, Kv, Nv : integer) return boolean is
    begin
        return (Mv >= 1 and Mv <= 8 and
                Kv >= 1 and Kv <= 8 and
                Nv >= 1 and Nv <= 8);
    end function;

begin

    selected_index <= to_integer(unsigned(matrix_index));

    matrix_status <= (31 downto 3 => '0') & error_s & done_s & busy_s;
    matrix_data   <= x"0000" & std_logic_vector(C(selected_index));
    matrix_cycles <= std_logic_vector(cycles);

    process(clk, reset_n)
        variable start_pulse : std_logic;
        variable write_pulse : std_logic;

        variable addr_i : integer range 0 to 255;
        variable M_v    : integer range 0 to 15;
        variable K_v    : integer range 0 to 15;
        variable N_v    : integer range 0 to 15;
    begin
        if reset_n = '0' then
            A        <= (others => (others => '0'));
            B        <= (others => (others => '0'));
            C        <= (others => (others => '0'));
            pe_sum   <= (others => (others => '0'));

            state    <= IDLE;
            M_s      <= 0;
            K_s      <= 0;
            N_s      <= 0;
            k_step   <= 0;
            cycles   <= (others => '0');

            ctrl_d   <= (others => '0');
            wr_en_d  <= '0';

            busy_s   <= '0';
            done_s   <= '0';
            error_s  <= '0';

        elsif rising_edge(clk) then
            start_pulse := matrix_ctrl(0) and not ctrl_d(0);
            write_pulse := matrix_write_en(0) and not wr_en_d;

            ctrl_d  <= matrix_ctrl;
            wr_en_d <= matrix_write_en(0);

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

                        C      <= (others => (others => '0'));
                        pe_sum <= (others => (others => '0'));
                        k_step <= 0;
                        cycles <= (others => '0');

                        if not valid_dims(M_v, K_v, N_v) then
                            error_s <= '1';
                            state   <= ERROR_STATE;
                        else
                            M_s    <= M_v;
                            K_s    <= K_v;
                            N_s    <= N_v;
                            busy_s <= '1';
                            state  <= RUN;
                        end if;
                    end if;

                when RUN =>
                    busy_s <= '1';
                    done_s <= '0';
                    cycles <= cycles + 1;

                    for row in 0 to 7 loop
                        for col in 0 to 7 loop
                            if (row < M_s) and (col < N_s) then
                                pe_sum(row * 8 + col) <= pe_sum(row * 8 + col) +
                                    resize(A(row * 8 + k_step) * B(k_step * 8 + col), 16);
                            end if;
                        end loop;
                    end loop;

                    if k_step = K_s - 1 then
                        state <= COPY_RESULT;
                    else
                        k_step <= k_step + 1;
                    end if;

                when COPY_RESULT =>
                    -- Important:
                    -- pe_sum now contains the final k-step from the previous clock.
                    -- Copy it into C in this separate cycle.
                    C      <= pe_sum;
                    busy_s <= '0';
                    done_s <= '1';
                    state  <= DONE;

                when DONE =>
                    busy_s <= '0';
                    done_s <= '1';

                    if start_pulse = '1' then
                        M_v := to_integer(unsigned(matrix_dims(3 downto 0)));
                        K_v := to_integer(unsigned(matrix_dims(7 downto 4)));
                        N_v := to_integer(unsigned(matrix_dims(11 downto 8)));

                        C      <= (others => (others => '0'));
                        pe_sum <= (others => (others => '0'));
                        k_step <= 0;
                        cycles <= (others => '0');
                        done_s <= '0';

                        if not valid_dims(M_v, K_v, N_v) then
                            error_s <= '1';
                            state   <= ERROR_STATE;
                        else
                            M_s     <= M_v;
                            K_s     <= K_v;
                            N_s     <= N_v;
                            busy_s  <= '1';
                            error_s <= '0';
                            state   <= RUN;
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
