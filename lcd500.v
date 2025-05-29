// HD44780 CGROM 기반 문자 코드 사용
// 100 MHz → 1 ms, 4 ms, 1 s tick
// 날짜(YYYY/MM/DD)와 시간(hh:mm:ss)를 16×2 LCD에 출력

module digital_clock_lcd #(
    parameter CNT1MS = 100_000  // 100 MHz → 1 ms
)(
    input             clk,
    input             resetn,
    output reg        lcd_e,
    output reg        lcd_rs,
    output            lcd_rw,
    output reg [7:0]  lcd_data
);

// 500× 속도용 내부 1초 틱 생성 (100 MHz → 10 ns)
// 100 000 000 / 500 = 200 000 클럭 = 2 ms
reg [17:0] fast_sec_cnt;  // 2^18=262 144 > 200 000
reg        fast_tick1s;
always @(posedge clk or negedge resetn) begin
  if (!resetn) begin
    fast_sec_cnt  <= 0;
    fast_tick1s   <= 0;
  end else if (fast_sec_cnt == 200_000-1) begin
    fast_sec_cnt  <= 0;
    fast_tick1s   <= 1;    // 2 ms마다 1초 틱 → 500×속도
  end else begin
    fast_sec_cnt  <= fast_sec_cnt + 1;
    fast_tick1s   <= 0;
  end
end


    // 항상 쓰기 모드
    assign lcd_rw = 1'b0;

    // 1) Tick 생성: 1 ms, 4 ms, 1 s
    reg [31:0] cnt_clk;
    reg        tick1ms;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cnt_clk <= 0; tick1ms <= 0;
        end else if (cnt_clk == CNT1MS-1) begin
            cnt_clk <= 0; tick1ms <= 1;
        end else begin
            cnt_clk <= cnt_clk + 1; tick1ms <= 0;
        end
    end

    reg [1:0] t4_cnt;
    reg       tick4ms;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            t4_cnt  <= 0; tick4ms <= 0;
        end else if (tick1ms) begin
            if (t4_cnt == 3) begin t4_cnt <= 0; tick4ms <= 1; end
            else begin t4_cnt <= t4_cnt + 1; tick4ms <= 0; end
        end else tick4ms <= 0;
    end

    reg [7:0] cnt1s;
    reg       tick1s;
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            cnt1s <= 0; tick1s <= 0;
        end else if (tick4ms) begin
            if (cnt1s == 249) begin cnt1s <= 0; tick1s <= 1; end
            else begin cnt1s <= cnt1s + 1; tick1s <= 0; end
        end else tick1s <= 0;
    end

    // 2) 날짜·시간 카운터
    reg [11:0] year;
    reg [4:0]  month;
    reg [7:0]  day;
    reg [4:0]  hour;
    reg [5:0]  min;
    reg [5:0]  sec;

    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            year  <= 12'd2024;
            month <= 5'd1;
            day   <= 8'd1;
            hour  <= 5'd0;
            min   <= 6'd0;
            sec   <= 6'd0;
        end else if (fast_tick1s) begin
            if (sec == 59) begin sec <= 0;
                if (min == 59) begin min <= 0;
                    if (hour == 23) begin hour <= 0;
                        if (day == days_in_month(month)) begin day <= 1;
                            if (month == 12) begin month <= 1; year <= year + 1; end
                            else month <= month + 1;
                        end else day <= day + 1;
                    end else hour <= hour + 1;
                end else min <= min + 1;
            end else sec <= sec + 1;
        end
    end

    function [7:0] days_in_month;
        input [4:0] m;
        begin
            case (m)
                1,3,5,7,8,10,12: days_in_month = 31;
                4,6,9,11:        days_in_month = 30;
                2:               days_in_month = 28;
                default:         days_in_month = 31;
            endcase
        end
    endfunction

    // 3) FSM 상태 정의
    parameter S_INIT   = 2'd0;
    parameter S_WRITE  = 2'd1;
    parameter S_RETURN = 2'd2;

    reg [1:0] state;
    reg [2:0] init_cnt;
    reg [4:0] pos;
    reg       line_sel;
    reg [1:0] e_cnt;  // 4 ms 구간 내 E 펄스 위치

    // 4) FSM 전이 (tick4ms마다 상태 변경, tick1ms마다 E 카운터)
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            state    <= S_INIT;
            init_cnt <= 0;
            pos      <= 0;
            line_sel <= 0;
            e_cnt    <= 0;
        end else begin
            if (tick1ms) begin
                // E 카운터 0→1→2→3
                if (e_cnt == 3) e_cnt <= 0;
                else             e_cnt <= e_cnt + 1;
            end
            if (tick4ms) begin
                case (state)
                    S_INIT:    if (init_cnt < 5) init_cnt <= init_cnt + 1;
                               else              state    <= S_WRITE;

                    S_WRITE:   if (pos < 16) pos <= pos + 1;
                               else begin pos <= 0; state <= S_RETURN; end

                    S_RETURN:  begin state <= S_WRITE;
                               line_sel <= ~line_sel; end

                    default:   state <= S_INIT;
                endcase
            end
        end
    end

    // 5) 명령·데이터·E 제어
    always @(posedge clk or negedge resetn) begin
        if (!resetn) begin
            lcd_rs   <= 0;
            lcd_data <= 0;
            lcd_e    <= 0;
        end else begin
            if (tick4ms) begin
                case (state)
                    S_INIT: begin
                        lcd_rs   <= 0;
                        lcd_data <= init_cmds[init_cnt];
                    end
                    S_WRITE: begin
                        if (pos == 0) begin
                            lcd_rs   <= 0;
                            lcd_data <= (line_sel ? CMD_SET_LINE2 : CMD_SET_LINE1);
                        end else begin
                            lcd_rs   <= 1;
                            lcd_data <= get_char(line_sel, pos-1);
                        end
                    end
                    S_RETURN: begin
                        lcd_rs   <= 0;
                        lcd_data <= CMD_RETURN_HOME;
                    end
                endcase
            end
            // E 펄스: e_cnt == 1일 때만 High
            lcd_e <= (e_cnt == 2'd1);
        end
    end

    // 6) 초기화 명령 목록
    reg [7:0] init_cmds [0:5];
    initial begin
        init_cmds[0] = CMD_FUNCTION_SET;
        init_cmds[1] = CMD_DISPLAY_OFF;
        init_cmds[2] = CMD_CLEAR;
        init_cmds[3] = CMD_ENTRY_MODE;
        init_cmds[4] = CMD_DISPLAY_ON;
        init_cmds[5] = CMD_RETURN_HOME;
    end

    // 7) LCD 커맨드 코드
    localparam [7:0] CMD_FUNCTION_SET = 8'b0011_1000;
    localparam [7:0] CMD_DISPLAY_OFF  = 8'b0000_1000;
    localparam [7:0] CMD_CLEAR        = 8'b0000_0001;
    localparam [7:0] CMD_ENTRY_MODE   = 8'b0000_0110;
    localparam [7:0] CMD_DISPLAY_ON   = 8'b0000_1100;
    localparam [7:0] CMD_RETURN_HOME  = 8'b0000_0010;
    localparam [7:0] CMD_SET_LINE1    = 8'b1000_0000;
    localparam [7:0] CMD_SET_LINE2    = 8'b1100_0000;

    // 8) CGROM 문자 코드 상수
    localparam [7:0] CG_SPACE  = 8'h20;
    localparam [7:0] CG_DIGIT0 = 8'h30; // '0'
    localparam [7:0] CG_SLASH  = 8'h2F;
    localparam [7:0] CG_COLON  = 8'h3A;

    // 9) CGROM 기반 문자 반환 함수
    function [7:0] get_char;
        input        line;
        input [4:0]  idx;
        begin
            if (!line) begin
                // 날짜 모드: YYYY/MM/DD
                case (idx)
                    0:  get_char = CG_DIGIT0 + (year / 1000);
                    1:  get_char = CG_DIGIT0 + ((year / 100)   % 10);
                    2:  get_char = CG_DIGIT0 + ((year / 10)    % 10);
                    3:  get_char = CG_DIGIT0 + (year           % 10);
                    4:  get_char = CG_SLASH;
                    5:  get_char = CG_DIGIT0 + (month / 10);
                    6:  get_char = CG_DIGIT0 + (month % 10);
                    7:  get_char = CG_SLASH;
                    8:  get_char = CG_DIGIT0 + (day   / 10);
                    9:  get_char = CG_DIGIT0 + (day   % 10);
                    default: get_char = CG_SPACE;
                endcase
            end else begin
                // 시간 모드: hh:mm:ss
                case (idx)
                    0:  get_char = CG_DIGIT0 + (hour  / 10);
                    1:  get_char = CG_DIGIT0 + (hour  % 10);
                    2:  get_char = CG_COLON;
                    3:  get_char = CG_DIGIT0 + (min   / 10);
                    4:  get_char = CG_DIGIT0 + (min   % 10);
                    5:  get_char = CG_COLON;
                    6:  get_char = CG_DIGIT0 + (sec   / 10);
                    7:  get_char = CG_DIGIT0 + (sec   % 10);
                    default: get_char = CG_SPACE;
                endcase
            end
        end
    endfunction

endmodule