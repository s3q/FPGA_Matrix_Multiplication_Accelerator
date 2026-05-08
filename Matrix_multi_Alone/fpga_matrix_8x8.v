// ============================================================
// FPGA-only matrix multiplier test
// No UART, no HPS, no Qsys
//
// Suggested DE-series board connections:
//   CLOCK_50  -> 50 MHz clock
//   KEY[0]    -> reset_n, active low
//   KEY[1]    -> start_n, active low
//   KEY[2]    -> display select button, active low
//                each press toggles between result/index and cycle-count view
//   SW[3:0]   -> X / column select, valid 0 to 7; displayed as 1 to 8
//   SW[7:4]   -> Y / row select, valid 0 to 7; displayed as 1 to 8
//   SW[9]     -> mode: 0 = regular, 1 = systolic
//   LEDR[0]   -> valid/done
//   LEDR[1]   -> busy
//   LEDR[9]   -> invalid index, when X > 7 or Y > 7
//
//   Result/index view:
//     HEX0-HEX3 -> selected C[Y][X] in decimal
//     HEX4      -> X / column number, displayed as 1 to 8
//     HEX5      -> Y / row number, displayed as 1 to 8
//
//   Cycle-count view, after pressing KEY[2]:
//     HEX0-HEX5 -> cycle_count in decimal
//
// 7-segment outputs are active-low, matching common Intel/Altera
// DE-series boards such as DE1-SoC / DE10-style boards.
// ============================================================

module fpga_matrix_8x8 (
    input        CLOCK_50,
    input  [9:0] SW,
    input  [3:0] KEY,
    output [9:0] LEDR,
    output [6:0] HEX0,
    output [6:0] HEX1,
    output [6:0] HEX2,
    output [6:0] HEX3,
    output [6:0] HEX4,
    output [6:0] HEX5
);

    wire clk;
    wire rst;
    wire start_button;
    wire start_pulse;
    wire display_toggle_pulse;

    wire mode;
    wire valid;
    wire busy;
    wire [15:0] selected_result;
    wire [31:0] cycle_count;

    wire [3:0] x;
    wire [3:0] y;
    wire invalid_index;

    reg key1_d1;
    reg key1_d2;

    // Debounce registers for KEY[2].
    // KEY[2] is active-low. show_cycles toggles once per real press.
    reg key2_sync0;
    reg key2_sync1;
    reg key2_stable;
    reg key2_stable_d;
    reg [19:0] key2_cnt;
    reg show_cycles;

    assign clk = CLOCK_50;

    // KEY buttons are usually active-low on DE boards.
    assign rst = ~KEY[0];

    // Generate one-clock start pulse when KEY[1] is pressed.
    assign start_button = ~KEY[1];

    // KEY[2] toggles the display content:
    //   0 = result/index view
    //   1 = cycle-count view
    //
    // Mechanical push buttons bounce, so we debounce KEY[2].
    // The counter value 999999 gives about 20 ms at 50 MHz.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            key1_d1      <= 1'b0;
            key1_d2      <= 1'b0;

            key2_sync0   <= 1'b1;
            key2_sync1   <= 1'b1;
            key2_stable  <= 1'b1;
            key2_stable_d<= 1'b1;
            key2_cnt     <= 20'd0;

            show_cycles  <= 1'b0;
        end else begin
            // Simple edge detector for KEY[1] start button.
            key1_d1 <= start_button;
            key1_d2 <= key1_d1;

            // Synchronize raw KEY[2] first. Keep it active-low here:
            // unpressed = 1, pressed = 0.
            key2_sync0 <= KEY[2];
            key2_sync1 <= key2_sync0;

            // Debounce KEY[2]. Only accept a change after it stays
            // different for about 20 ms.
            if (key2_sync1 == key2_stable) begin
                key2_cnt <= 20'd0;
            end else begin
                if (key2_cnt == 20'd999999) begin
                    key2_stable <= key2_sync1;
                    key2_cnt    <= 20'd0;
                end else begin
                    key2_cnt <= key2_cnt + 20'd1;
                end
            end

            key2_stable_d <= key2_stable;

            // Toggle once on a debounced active-low press: 1 -> 0.
            if (display_toggle_pulse) begin
                show_cycles <= ~show_cycles;
            end
        end
    end

    assign start_pulse = key1_d1 & ~key1_d2;
    assign display_toggle_pulse = key2_stable_d & ~key2_stable;

    assign x = SW[3:0];   // column
    assign y = SW[7:4];   // row
    assign mode = SW[9];

    assign invalid_index = (x > 4'd7) || (y > 4'd7);

    fpga_matrix_core_no_uart matrix0 (
        .clk(clk),
        .rst(rst),
        .start(start_pulse),
        .mode(mode),
        .x(x[2:0]),
        .y(y[2:0]),
        .valid(valid),
        .busy(busy),
        .selected_result(selected_result),
        .cycle_count(cycle_count)
    );

    assign LEDR[0] = valid;
    assign LEDR[1] = busy;
    assign LEDR[8:2] = 7'b0;
    assign LEDR[9] = invalid_index;

    // Display has two modes, toggled by KEY[2].
    //
    // Mode 0, result/index view:
    //   HEX0-HEX3 = selected C[Y][X]
    //   HEX4      = X / column index
    //   HEX5      = Y / row index
    //
    // Mode 1, cycle-count view:
    //   HEX0-HEX5 = cycle_count
    wire [6:0] result_hex0, result_hex1, result_hex2, result_hex3;
    wire [6:0] cycle_hex0, cycle_hex1, cycle_hex2, cycle_hex3, cycle_hex4, cycle_hex5;
    wire [6:0] x_hex;
    wire [6:0] y_hex;
    wire [3:0] x_display;
    wire [3:0] y_display;

    // Switches still select internal matrix indexes 0 to 7.
    // The 7-segment display shows human-friendly numbers 1 to 8.
    assign x_display = x + 4'd1;
    assign y_display = y + 4'd1;

    sevenseg_decimal_16_4digits result_display (
        .value(selected_result),
        .blank(invalid_index),
        .HEX0(result_hex0),
        .HEX1(result_hex1),
        .HEX2(result_hex2),
        .HEX3(result_hex3)
    );

    sevenseg_decimal_32_6digits cycle_display (
        .value(cycle_count),
        .blank(1'b0),
        .HEX0(cycle_hex0),
        .HEX1(cycle_hex1),
        .HEX2(cycle_hex2),
        .HEX3(cycle_hex3),
        .HEX4(cycle_hex4),
        .HEX5(cycle_hex5)
    );

    sevenseg_digit x_index_display (
        .n(x_display),
        .blank(show_cycles || invalid_index),
        .seg(x_hex)
    );

    sevenseg_digit y_index_display (
        .n(y_display),
        .blank(show_cycles || invalid_index),
        .seg(y_hex)
    );

    assign HEX0 = show_cycles ? cycle_hex0 : result_hex0;
    assign HEX1 = show_cycles ? cycle_hex1 : result_hex1;
    assign HEX2 = show_cycles ? cycle_hex2 : result_hex2;
    assign HEX3 = show_cycles ? cycle_hex3 : result_hex3;
    assign HEX4 = show_cycles ? cycle_hex4 : x_hex;
    assign HEX5 = show_cycles ? cycle_hex5 : y_hex;

endmodule


// ============================================================
// Matrix multiplier core, UART removed.
// C is selected using x/y switches.
// ============================================================

module fpga_matrix_core_no_uart (
    input clk,
    input rst,
    input start,
    input mode,
    input [2:0] x,
    input [2:0] y,
    output reg valid,
    output reg busy,
    output [15:0] selected_result,
    output reg [31:0] cycle_count
);

    reg [7:0] A [0:63];
    reg [7:0] B [0:63];
    reg [15:0] C [0:63];

    reg [7:0] a_pipe [0:63];
    reg [7:0] b_pipe [0:63];
    reg [15:0] sum_pipe [0:63];

    reg [3:0] state;

    parameter IDLE         = 4'd0;
    parameter REGULAR_RUN  = 4'd1;
    parameter SYSTOLIC_RUN = 4'd2;
    parameter DONE         = 4'd3;

    integer i, j;

    reg [2:0] r_i, r_j, r_k;
    reg [31:0] acc;
    reg [5:0] sys_cycle;

    function [5:0] idx;
        input [2:0] row;
        input [2:0] col;
        begin
            idx = row * 8 + col;
        end
    endfunction

    assign selected_result = C[idx(y, x)];

    initial begin
        A[0]=1; A[1]=2; A[2]=3; A[3]=4; A[4]=5; A[5]=6; A[6]=7; A[7]=8;
        A[8]=2; A[9]=3; A[10]=4; A[11]=5; A[12]=6; A[13]=7; A[14]=8; A[15]=9;
        A[16]=3; A[17]=4; A[18]=5; A[19]=6; A[20]=7; A[21]=8; A[22]=9; A[23]=10;
        A[24]=4; A[25]=5; A[26]=6; A[27]=7; A[28]=8; A[29]=9; A[30]=10; A[31]=11;
        A[32]=5; A[33]=6; A[34]=7; A[35]=8; A[36]=9; A[37]=10; A[38]=11; A[39]=12;
        A[40]=6; A[41]=7; A[42]=8; A[43]=9; A[44]=10; A[45]=11; A[46]=12; A[47]=13;
        A[48]=7; A[49]=8; A[50]=9; A[51]=10; A[52]=11; A[53]=12; A[54]=13; A[55]=14;
        A[56]=8; A[57]=9; A[58]=10; A[59]=11; A[60]=12; A[61]=13; A[62]=14; A[63]=15;

        for (i = 0; i < 64; i = i + 1)
            B[i] = 0;

        // Random test matrix B.
        B[0]=4;  B[1]=7;  B[2]=2;  B[3]=9;  B[4]=1;  B[5]=6;  B[6]=3;  B[7]=8;
        B[8]=5;  B[9]=2;  B[10]=10; B[11]=4;  B[12]=7;  B[13]=1;  B[14]=9;  B[15]=3;
        B[16]=8; B[17]=6; B[18]=1;  B[19]=5;  B[20]=2;  B[21]=10; B[22]=4;  B[23]=7;
        B[24]=3; B[25]=9; B[26]=6;  B[27]=2;  B[28]=8;  B[29]=5;  B[30]=1;  B[31]=10;
        B[32]=7; B[33]=4; B[34]=9;  B[35]=3;  B[36]=6;  B[37]=2;  B[38]=8;  B[39]=1;
        B[40]=10;B[41]=5; B[42]=3;  B[43]=7;  B[44]=4;  B[45]=9;  B[46]=2;  B[47]=6;
        B[48]=1; B[49]=8; B[50]=5;  B[51]=10; B[52]=3;  B[53]=7;  B[54]=6;  B[55]=4;
        B[56]=9; B[57]=1; B[58]=7;  B[59]=6;  B[60]=10; B[61]=3;  B[62]=5;  B[63]=2;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            valid <= 0;
            busy <= 0;
            cycle_count <= 0;
            r_i <= 0;
            r_j <= 0;
            r_k <= 0;
            acc <= 0;
            sys_cycle <= 0;

            for (i = 0; i < 64; i = i + 1) begin
                C[i] <= 0;
                a_pipe[i] <= 0;
                b_pipe[i] <= 0;
                sum_pipe[i] <= 0;
            end

        end else begin
            case (state)

                IDLE: begin
                    valid <= 0;
                    busy <= 0;
                    cycle_count <= 0;

                    if (start) begin
                        for (i = 0; i < 64; i = i + 1) begin
                            C[i] <= 0;
                            a_pipe[i] <= 0;
                            b_pipe[i] <= 0;
                            sum_pipe[i] <= 0;
                        end

                        r_i <= 0;
                        r_j <= 0;
                        r_k <= 0;
                        acc <= 0;
                        sys_cycle <= 0;
                        busy <= 1;

                        if (mode)
                            state <= SYSTOLIC_RUN;
                        else
                            state <= REGULAR_RUN;
                    end
                end

                REGULAR_RUN: begin
                    busy <= 1;
                    valid <= 0;
                    cycle_count <= cycle_count + 1;

                    acc <= acc + A[idx(r_i,r_k)] * B[idx(r_k,r_j)];

                    if (r_k == 7) begin
                        C[idx(r_i,r_j)] <= acc + A[idx(r_i,r_k)] * B[idx(r_k,r_j)];
                        acc <= 0;
                        r_k <= 0;

                        if (r_j == 7) begin
                            r_j <= 0;

                            if (r_i == 7)
                                state <= DONE;
                            else
                                r_i <= r_i + 1;
                        end else begin
                            r_j <= r_j + 1;
                        end
                    end else begin
                        r_k <= r_k + 1;
                    end
                end

                SYSTOLIC_RUN: begin
                    busy <= 1;
                    valid <= 0;
                    cycle_count <= cycle_count + 1;
                    sys_cycle <= sys_cycle + 1;

                    for (i = 0; i < 8; i = i + 1) begin
                        for (j = 0; j < 8; j = j + 1) begin

                            if (j == 0) begin
                                if ((sys_cycle >= i) && (sys_cycle < i + 8))
                                    a_pipe[i*8+j] <= A[i*8 + (sys_cycle - i)];
                                else
                                    a_pipe[i*8+j] <= 0;
                            end else begin
                                a_pipe[i*8+j] <= a_pipe[i*8+j-1];
                            end

                            if (i == 0) begin
                                if ((sys_cycle >= j) && (sys_cycle < j + 8))
                                    b_pipe[i*8+j] <= B[(sys_cycle - j)*8 + j];
                                else
                                    b_pipe[i*8+j] <= 0;
                            end else begin
                                b_pipe[i*8+j] <= b_pipe[(i-1)*8+j];
                            end

                            sum_pipe[i*8+j] <= sum_pipe[i*8+j] +
                                               a_pipe[i*8+j] * b_pipe[i*8+j];
                        end
                    end

                    if (sys_cycle == 24) begin
                        for (i = 0; i < 64; i = i + 1)
                            C[i] <= sum_pipe[i];

                        state <= DONE;
                    end
                end

                DONE: begin
                    valid <= 1;
                    busy <= 0;

                    // Allow another run without pressing reset.
                    if (start) begin
                        valid <= 0;
                        busy <= 1;
                        cycle_count <= 0;
                        r_i <= 0;
                        r_j <= 0;
                        r_k <= 0;
                        acc <= 0;
                        sys_cycle <= 0;

                        for (i = 0; i < 64; i = i + 1) begin
                            C[i] <= 0;
                            a_pipe[i] <= 0;
                            b_pipe[i] <= 0;
                            sum_pipe[i] <= 0;
                        end

                        if (mode)
                            state <= SYSTOLIC_RUN;
                        else
                            state <= REGULAR_RUN;
                    end
                end

            endcase
        end
    end

endmodule


// ============================================================
// Decimal display helpers. Active-low segments.
// ============================================================

module sevenseg_decimal_16_4digits (
    input [15:0] value,
    input blank,
    output [6:0] HEX0,
    output [6:0] HEX1,
    output [6:0] HEX2,
    output [6:0] HEX3
);

    wire [3:0] d0;
    wire [3:0] d1;
    wire [3:0] d2;
    wire [3:0] d3;

    assign d0 = value % 10;
    assign d1 = (value / 10) % 10;
    assign d2 = (value / 100) % 10;
    assign d3 = (value / 1000) % 10;

    sevenseg_digit s0 (.n(d0), .blank(blank), .seg(HEX0));
    sevenseg_digit s1 (.n(d1), .blank(blank), .seg(HEX1));
    sevenseg_digit s2 (.n(d2), .blank(blank), .seg(HEX2));
    sevenseg_digit s3 (.n(d3), .blank(blank), .seg(HEX3));

endmodule


module sevenseg_decimal_32_6digits (
    input [31:0] value,
    input blank,
    output [6:0] HEX0,
    output [6:0] HEX1,
    output [6:0] HEX2,
    output [6:0] HEX3,
    output [6:0] HEX4,
    output [6:0] HEX5
);

    wire [3:0] d0;
    wire [3:0] d1;
    wire [3:0] d2;
    wire [3:0] d3;
    wire [3:0] d4;
    wire [3:0] d5;

    assign d0 = value % 10;
    assign d1 = (value / 10) % 10;
    assign d2 = (value / 100) % 10;
    assign d3 = (value / 1000) % 10;
    assign d4 = (value / 10000) % 10;
    assign d5 = (value / 100000) % 10;

    sevenseg_digit s0 (.n(d0), .blank(blank), .seg(HEX0));
    sevenseg_digit s1 (.n(d1), .blank(blank), .seg(HEX1));
    sevenseg_digit s2 (.n(d2), .blank(blank), .seg(HEX2));
    sevenseg_digit s3 (.n(d3), .blank(blank), .seg(HEX3));
    sevenseg_digit s4 (.n(d4), .blank(blank), .seg(HEX4));
    sevenseg_digit s5 (.n(d5), .blank(blank), .seg(HEX5));

endmodule


module sevenseg_digit (
    input [3:0] n,
    input blank,
    output reg [6:0] seg
);
    always @(*) begin
        if (blank) begin
            seg = 7'b1111111;
        end else begin
            case (n)
                4'd0: seg = 7'b1000000;
                4'd1: seg = 7'b1111001;
                4'd2: seg = 7'b0100100;
                4'd3: seg = 7'b0110000;
                4'd4: seg = 7'b0011001;
                4'd5: seg = 7'b0010010;
                4'd6: seg = 7'b0000010;
                4'd7: seg = 7'b1111000;
                4'd8: seg = 7'b0000000;
                4'd9: seg = 7'b0010000;
                default: seg = 7'b1111111;
            endcase
        end
    end
endmodule
