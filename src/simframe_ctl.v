//====================================================================================
//                        ------->  Revision History  <------
//====================================================================================
//
//   Date     Who   Ver  Changes
//====================================================================================
// 25-Oct-23  DWW     1  Initial creation
//====================================================================================

/*
    The purpose of this module is to stream out byte patterns that have been recorded  
    in a FIFO.   There are two input FIFOs, and only one at a time can be streaming out
    its contents.

    Whenever a byte is extracted from a FIFO it is written back into that FIFO so that
    the vector of values in the FIFO can be re-used in a continuous loop.
*/


module simframe_ctl #
(
    parameter PATTERN_WIDTH = 32    
)
(
    input clk, resetn,

    //================== This is an AXI4-Lite slave interface ==================
        
    // "Specify write address"              -- Master --    -- Slave --
    input[31:0]                             S_AXI_AWADDR,   
    input                                   S_AXI_AWVALID,  
    output                                                  S_AXI_AWREADY,
    input[2:0]                              S_AXI_AWPROT,

    // "Write Data"                         -- Master --    -- Slave --
    input[31:0]                             S_AXI_WDATA,      
    input                                   S_AXI_WVALID,
    input[3:0]                              S_AXI_WSTRB,
    output                                                  S_AXI_WREADY,

    // "Send Write Response"                -- Master --    -- Slave --
    output[1:0]                                             S_AXI_BRESP,
    output                                                  S_AXI_BVALID,
    input                                   S_AXI_BREADY,

    // "Specify read address"               -- Master --    -- Slave --
    input[31:0]                             S_AXI_ARADDR,     
    input                                   S_AXI_ARVALID,
    input[2:0]                              S_AXI_ARPROT,     
    output                                                  S_AXI_ARREADY,

    // "Read data back to master"           -- Master --    -- Slave --
    output[31:0]                                            S_AXI_RDATA,
    output                                                  S_AXI_RVALID,
    output[1:0]                                             S_AXI_RRESP,
    input                                   S_AXI_RREADY,
    //==========================================================================
 

    //=========================   The output stream   ==========================
    output [PATTERN_WIDTH-1:0] AXIS_OUT_TDATA,
    output reg                 AXIS_OUT_TVALID,
    input                      AXIS_OUT_TREADY,
    //==========================================================================


    //=========  These configure the geometry of the generated frame  ==========
    output reg[15:0] CYCLES_PER_PKT,
    output reg[15:0] PKTS_PER_FRAME,
    //========================================================================== 

    // This will strobe high for one cycle any time a new job starts
    output reg new_job
);  

    // Any time the register map of this module changes, this number should
    // be bumped
    localparam MODULE_VERSION = 1;

    //=========================  AXI Register Map  =============================
    localparam REG_MODULE_REV = 0;      /*  RO   */

    localparam REG_FIFO_CTL = 1;
        localparam BIT_F0_RESET = 0;    /*  R/W  */
        localparam BIT_F1_RESET = 1;    /*  R/W  */
        localparam BIT_F0_LOAD  = 2;    /*  WO   */
        localparam BIT_F1_LOAD  = 3;    /*  WO   */

    localparam REG_LOAD_F0 = 2;         /*  R/W  */
    localparam REG_LOAD_F1 = 3;         /*  R/W  */
    
    localparam REG_START = 4;            
        localparam BIT_F0_START = 0;    /*  R/W  */
        localparam BIT_F1_START = 1;    /*  R/W  */

    localparam REG_CYCLES_PER_PKT = 5;  /*  R/W  */
    localparam REG_PKTS_PER_FRAME = 6;  /*  R/W  */

    localparam REG_INPUT_00 = 16;       /*  R/W  */
    localparam REG_INPUT_01 = 17;       /*  R/W  */
    localparam REG_INPUT_02 = 18;       /*  R/W  */
    localparam REG_INPUT_03 = 19;       /*  R/W  */
    localparam REG_INPUT_04 = 20;       /*  R/W  */
    localparam REG_INPUT_05 = 21;       /*  R/W  */
    localparam REG_INPUT_06 = 22;       /*  R/W  */
    localparam REG_INPUT_07 = 23;       /*  R/W  */
    localparam REG_INPUT_08 = 24;       /*  R/W  */
    localparam REG_INPUT_09 = 25;       /*  R/W  */
    localparam REG_INPUT_10 = 26;       /*  R/W  */
    localparam REG_INPUT_11 = 27;       /*  R/W  */
    localparam REG_INPUT_12 = 28;       /*  R/W  */
    localparam REG_INPUT_13 = 29;       /*  R/W  */
    localparam REG_INPUT_14 = 30;       /*  R/W  */
    localparam REG_INPUT_15 = 31;       /*  R/W  */
    //==========================================================================


    //==========================================================================
    // We'll communicate with the AXI4-Lite Slave core with these signals.
    //==========================================================================
    // AXI Slave Handler Interface for write requests
    wire[31:0]  ashi_waddr;     // Input:  Write-address
    wire[31:0]  ashi_wdata;     // Input:  Write-data
    wire        ashi_write;     // Input:  1 = Handle a write request
    reg[1:0]    ashi_wresp;     // Output: Write-response (OKAY, DECERR, SLVERR)
    wire        ashi_widle;     // Output: 1 = Write state machine is idle

    // AXI Slave Handler Interface for read requests
    wire[31:0]  ashi_raddr;     // Input:  Read-address
    wire        ashi_read;      // Input:  1 = Handle a read request
    reg[31:0]   ashi_rdata;     // Output: Read data
    reg[1:0]    ashi_rresp;     // Output: Read-response (OKAY, DECERR, SLVERR);
    wire        ashi_ridle;     // Output: 1 = Read state machine is idle
    //==========================================================================

    // The state of the state-machines that handle AXI4-Lite read and AXI4-Lite write
    reg[3:0] axi4_write_state, axi4_read_state;

    // The AXI4 slave state machines are idle when in state 0 and their "start" signals are low
    assign ashi_widle = (ashi_write == 0) && (axi4_write_state == 0);
    assign ashi_ridle = (ashi_read  == 0) && (axi4_read_state  == 0);

   
    // These are the valid values for ashi_rresp and ashi_wresp
    localparam OKAY   = 0;
    localparam SLVERR = 2;
    localparam DECERR = 3;

    // An AXI slave is gauranteed a minimum of 128 bytes of address space
    // (128 bytes is 32 32-bit registers)
    localparam ADDR_MASK = 7'h7F;

    // Coming out of reset, these are the default values of CYCLES_PER_PKT and PKTS_PER_FRAME
    localparam DEFAULT_CYCLES_PER_PKT = 32;
    localparam DEFAULT_PKTS_PER_FRAME = 2048;

    // When one of these counters is non-zero, the associated FIFO is held in reset
    reg[3:0] f0_reset_counter, f1_reset_counter;

    // These two wires control the reset input of the FIFOs
    wire f0_reset = (resetn == 0 || f0_reset_counter != 0);
    wire f1_reset = (resetn == 0 || f1_reset_counter != 0);

    // These signals are the input bus to fifo_0
    reg[PATTERN_WIDTH-1:0]  f0in_tdata;
    reg                     f0in_tvalid;
    wire                    f0in_tready;

    // These signals are the output bus of fifo_0
    wire[PATTERN_WIDTH-1:0] f0out_tdata;
    wire                    f0out_tvalid;
    wire                    f0out_tready;

    // These signals are the input bus to fifo_1
    reg[PATTERN_WIDTH-1:0]  f1in_tdata;
    reg                     f1in_tvalid;
    wire                    f1in_tready;

    // These signals are the output bus of fifo_1
    wire[PATTERN_WIDTH-1:0] f1out_tdata;
    wire                    f1out_tvalid;
    wire                    f1out_tready;

    // The number of data elements stored in each FIFO
    reg[14:0] f0_count, f1_count;

    // When a FIFO is being filled, it will be filled with this bit-pattern
    reg[511:0] input_value;

    // When one of these bits are strobed high, "input value" is loaded into that FIFO
    reg[1:0] fifo_load_strobe;

    // These bits indicate which FIFO will be output next
    reg[1:0] fifo_on_deck;

    // These bits indicate which FIFO is actively outputting data
    reg[1:0] active_fifo;

    //==========================================================================
    // This state machine handles AXI4-Lite write requests
    //
    // Drives:
    //   f0_reset_counter (and therefore, f0_reset)
    //   f1_reset_counter (and therefore, f1_reset)
    //   f0_count and f1_count
    //   fifo_load_strobe
    //   input_value
    //   fifo_on_deck   
    //   CYCLES_PER_PKT
    //   PKTS_PER_FRAME
    //==========================================================================
    always @(posedge clk) begin

        // The reset counters for the two FIFOs always count down to zero
        if (f0_reset_counter) f0_reset_counter <= f0_reset_counter - 1;
        if (f1_reset_counter) f1_reset_counter <= f1_reset_counter - 1;

        // This will strobe-high for one cycle to indicate start of a new job
        new_job <= 0;

        // When one of these bit strobes high, "input_value" is loaded into a FIFO
        fifo_load_strobe <= 0;

        // If we're in reset, initialize important registers
        if (resetn == 0) begin
            axi4_write_state <= 0;
            f0_reset_counter <= 0;
            f1_reset_counter <= 0;
            f0_count         <= 0;
            f1_count         <= 0;
            fifo_on_deck     <= 0;
            CYCLES_PER_PKT   <= DEFAULT_CYCLES_PER_PKT;
            PKTS_PER_FRAME   <= DEFAULT_PKTS_PER_FRAME;

        // If we're not in reset, and a write-request has occured...        
        end else case (axi4_write_state)
        
        0:  if (ashi_write) begin
       
                // Assume for the moment that the result will be OKAY
                ashi_wresp <= OKAY;              
            
                // Convert the byte address into a register index
                case ((ashi_waddr & ADDR_MASK) >> 2)
                
                    REG_FIFO_CTL:
                        begin
                            
                            // If the user wants to clear fifo_0...
                            if (ashi_wdata[BIT_F0_RESET] && ~active_fifo[0]) begin
                                f0_count         <= 0;
                                f0_reset_counter <= -1;
                                axi4_write_state <= 1;    
                            end
                            
                            // If the user wants to clear fifo_1...
                            if (ashi_wdata[BIT_F1_RESET] && ~active_fifo[1]) begin
                                f1_count         <= 0;
                                f1_reset_counter <= -1;
                                axi4_write_state <= 1;
                            end   
                            
                            // If the user wants to load fifo_0...
                            if (ashi_wdata[BIT_F0_LOAD ] && ~active_fifo[0]) begin
                                fifo_load_strobe[0] <= 1;
                                f0_count            <= f0_count + 1;
                            end
                            
                            // If the user wants to load fifo_1...
                            if (ashi_wdata[BIT_F1_LOAD ] && ~active_fifo[1]) begin
                                fifo_load_strobe[1] <= 1;
                                f1_count            <= f1_count + 1;
                            end
                        
                        end

                    // Is the user doing an "immediate" load of fifo_0?
                    REG_LOAD_F0:
                        if (~active_fifo[0]) begin
                            input_value      <= ashi_wdata;
                            fifo_load_strobe <= 1;
                            f0_count         <= f0_count + 1;
                        end

                    // Is the user doing an "immediate" load of fifo_1?
                    REG_LOAD_F1:
                        if (~active_fifo[1]) begin
                            input_value      <= ashi_wdata;
                            fifo_load_strobe <= 2;
                            f1_count         <= f1_count + 1;
                        end


                    // Don't allow the user to attempt to start both FIFOs at once
                    REG_START:
                        if (ashi_wdata[1:0] == 2'b00) begin
                            fifo_on_deck <= 0;
                        end
                        
                        else if (ashi_wdata[1:0] == 2'b01 && f0_count) begin
                            fifo_on_deck <= 1;
                            new_job      <= (active_fifo == 0);
                        end
                        
                        else if (ashi_wdata[1:0] == 2'b10 && f1_count) begin
                            fifo_on_deck <= 2;
                            new_job      <= (active_fifo == 0);                            
                        end

                    // Allow the user to configure the number of data-cycles per packet
                    REG_CYCLES_PER_PKT:
                        if (ashi_wdata && ~active_fifo) CYCLES_PER_PKT <= ashi_wdata;
                    
                    // Allow the user to configure the number of packets per frame
                    REG_PKTS_PER_FRAME:
                        if (ashi_wdata && ~active_fifo) PKTS_PER_FRAME <= ashi_wdata;

                    // Allow the user to store values into the "input" field
                    REG_INPUT_00:  input_value[ 0 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_01:  input_value[ 1 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_02:  input_value[ 2 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_03:  input_value[ 3 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_04:  input_value[ 4 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_05:  input_value[ 5 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_06:  input_value[ 6 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_07:  input_value[ 7 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_08:  input_value[ 8 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_09:  input_value[ 9 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_10:  input_value[10 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_11:  input_value[11 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_12:  input_value[12 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_13:  input_value[13 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_14:  input_value[14 * 32 +: 32] <= ashi_wdata;
                    REG_INPUT_15:  input_value[15 * 32 +: 32] <= ashi_wdata;

                    // Writes to any other register are a decode-error
                    default: ashi_wresp <= DECERR;
                endcase
            end

        // In this state, we're just waiting for the FIFO reset counters 
        // to both go back to zero
        1:  if (f0_reset_counter == 0 && f1_reset_counter == 0)
                axi4_write_state <= 0;

        endcase
    end
    //==========================================================================





    //==========================================================================
    // World's simplest state machine for handling AXI4-Lite read requests
    //==========================================================================
    always @(posedge clk) begin

        // If we're in reset, initialize important registers
        if (resetn == 0) begin
            axi4_read_state <= 0;
        
        // If we're not in reset, and a read-request has occured...        
        end else if (ashi_read) begin
       
            // Assume for the moment that the result will be OKAY
            ashi_rresp <= OKAY;              
            
            // Convert the byte address into a register index
            case ((ashi_raddr & ADDR_MASK) >> 2)
 
                // Allow a read from any valid register                
                REG_MODULE_REV:     ashi_rdata <= MODULE_VERSION;
                REG_FIFO_CTL:       ashi_rdata <= {f1_reset, f0_reset};
                REG_LOAD_F0:        ashi_rdata <= f0_count;
                REG_LOAD_F1:        ashi_rdata <= f1_count;
                REG_START:          ashi_rdata <= active_fifo;
                REG_CYCLES_PER_PKT: ashi_rdata <= CYCLES_PER_PKT;
                REG_PKTS_PER_FRAME: ashi_rdata <= PKTS_PER_FRAME;
                REG_INPUT_00:       ashi_rdata <= input_value[ 0 * 32 +: 32];
                REG_INPUT_01:       ashi_rdata <= input_value[ 1 * 32 +: 32];
                REG_INPUT_02:       ashi_rdata <= input_value[ 2 * 32 +: 32];
                REG_INPUT_03:       ashi_rdata <= input_value[ 3 * 32 +: 32];
                REG_INPUT_04:       ashi_rdata <= input_value[ 4 * 32 +: 32];
                REG_INPUT_05:       ashi_rdata <= input_value[ 5 * 32 +: 32];
                REG_INPUT_06:       ashi_rdata <= input_value[ 6 * 32 +: 32];
                REG_INPUT_07:       ashi_rdata <= input_value[ 7 * 32 +: 32];
                REG_INPUT_08:       ashi_rdata <= input_value[ 8 * 32 +: 32];
                REG_INPUT_09:       ashi_rdata <= input_value[ 9 * 32 +: 32];
                REG_INPUT_10:       ashi_rdata <= input_value[10 * 32 +: 32];
                REG_INPUT_11:       ashi_rdata <= input_value[11 * 32 +: 32];
                REG_INPUT_12:       ashi_rdata <= input_value[12 * 32 +: 32];
                REG_INPUT_13:       ashi_rdata <= input_value[13 * 32 +: 32];
                REG_INPUT_14:       ashi_rdata <= input_value[14 * 32 +: 32];
                REG_INPUT_15:       ashi_rdata <= input_value[15 * 32 +: 32];

                // Reads of any other register are a decode-error
                default: ashi_rresp <= DECERR;
            endcase
        end
    end
    //==========================================================================



    //====================================================================================
    // This state machine controls the inputs to the FIFOs
    //
    // Drives:
    //    f0in_tvalid (TVALID line for input to fifo_0)
    //    f1in_tvalid (TVALID line for input to fifo_1)
    //    f0in_tdata  (TDATA lines for input to fifo_0)
    //    f1in_tdata  (TDATA lines for input to fifo_1)
    //====================================================================================
    always @(posedge clk) begin
        
        // By default, we're not writing to either FIFO
        f0in_tvalid <= 0;
        f1in_tvalid <= 0;

        // If F0 load_strobe is high, we write the input value to fif0_0
        if (fifo_load_strobe[0]) begin
            f0in_tdata  <= input_value;
            f0in_tvalid <= 1;
        end

        // If F1 load_strobe is high, we write the input value to fif0_1
        if (fifo_load_strobe[1]) begin
            f1in_tdata  <= input_value;
            f1in_tvalid <= 1;
        end

        // When an entry is output from fifo_0, feed it back to the input
        if (f0out_tvalid & f0out_tready) begin
            f0in_tdata  <= f0out_tdata;
            f0in_tvalid <= 1;
        end

        // When an entry is output from fifo_1, feed it back to the input
        if (f1out_tvalid & f1out_tready) begin
            f1in_tdata  <= f1out_tdata;
            f1in_tvalid <= 1;
        end
    end
    //====================================================================================



    //====================================================================================
    // This state machine moves data from a FIFO to the output stream
    //
    // Drives:
    //  AXIS_OUT_TDATA
    //  AXIS_OUT_TVALID
    //  active_fifo
    //  f0out_tready
    //  f1out_tready
    //
    // "osm" means "output state machine"
    //
    // When reading this state machine, keep in mind that when AXIS_OUT_TVALID is low,
    // it means we're not outputting any data to the output stream and we're waiting to
    // be told which FIFO to output from
    //====================================================================================
    reg       osm_state;
    reg[15:0] osm_counter;

    // The data being driven out on AXIS_OUT_TDATA is the output of one of the FIFOs
    assign AXIS_OUT_TDATA = (active_fifo == 1) ? f0out_tdata :
                            (active_fifo == 2) ? f1out_tdata : 8'h55;

    assign f0out_tready = (active_fifo == 1) ? AXIS_OUT_TREADY : 0;
    assign f1out_tready = (active_fifo == 2) ? AXIS_OUT_TREADY : 0;                                
    //====================================================================================
    always @(posedge clk) begin

        if (resetn == 0) begin
            osm_state       <= 0; 
            active_fifo     <= 0;
            AXIS_OUT_TVALID <= 0;
        
        end else case(osm_state)

            
            0:  begin
                    AXIS_OUT_TVALID <= 0;
                    osm_state <= 1;
                end
                
            // If we're waiting for a start command or this data-cycle is a handshake on AXIS_OUT...
            1:  if (AXIS_OUT_TVALID == 0 || (AXIS_OUT_TVALID & AXIS_OUT_TREADY)) begin
                    
                    // Don't forget that this doesn't take effect until the end of the cycle!
                    osm_counter <= osm_counter - 1;

                    // If we're either waiting for a "start" or if we've output the entire FIFO already...
                    if (AXIS_OUT_TVALID == 0 || osm_counter == 1) begin

                        // If we've been told to start outputting from fifo_0...    
                        if (fifo_on_deck == 1) begin
                            active_fifo     <= 1;
                            osm_counter     <= f0_count;
                            AXIS_OUT_TVALID <= 1;
                        end else

                        // If we've been told to start outputting from fifo_1....
                        if (fifo_on_deck == 2) begin
                            active_fifo     <= 2;
                            osm_counter     <= f1_count;
                            AXIS_OUT_TVALID <= 1;
                        end else

                        begin
                            active_fifo     <= 0;
                            AXIS_OUT_TVALID <= 0;
                        end
                    end
                end
        endcase

    end
    //====================================================================================




    //==========================================================================
    // This connects us to an AXI4-Lite slave core
    //==========================================================================
    axi4_lite_slave axi_slave
    (
        .clk            (clk),
        .resetn         (resetn),
        
        // AXI AW channel
        .AXI_AWADDR     (S_AXI_AWADDR),
        .AXI_AWVALID    (S_AXI_AWVALID),   
        .AXI_AWPROT     (S_AXI_AWPROT),
        .AXI_AWREADY    (S_AXI_AWREADY),
        
        // AXI W channel
        .AXI_WDATA      (S_AXI_WDATA),
        .AXI_WVALID     (S_AXI_WVALID),
        .AXI_WSTRB      (S_AXI_WSTRB),
        .AXI_WREADY     (S_AXI_WREADY),

        // AXI B channel
        .AXI_BRESP      (S_AXI_BRESP),
        .AXI_BVALID     (S_AXI_BVALID),
        .AXI_BREADY     (S_AXI_BREADY),

        // AXI AR channel
        .AXI_ARADDR     (S_AXI_ARADDR), 
        .AXI_ARVALID    (S_AXI_ARVALID),
        .AXI_ARPROT     (S_AXI_ARPROT),
        .AXI_ARREADY    (S_AXI_ARREADY),

        // AXI R channel
        .AXI_RDATA      (S_AXI_RDATA),
        .AXI_RVALID     (S_AXI_RVALID),
        .AXI_RRESP      (S_AXI_RRESP),
        .AXI_RREADY     (S_AXI_RREADY),

        // ASHI write-request registers
        .ASHI_WADDR     (ashi_waddr),
        .ASHI_WDATA     (ashi_wdata),
        .ASHI_WRITE     (ashi_write),
        .ASHI_WRESP     (ashi_wresp),
        .ASHI_WIDLE     (ashi_widle),

        // ASHI read registers
        .ASHI_RADDR     (ashi_raddr),
        .ASHI_RDATA     (ashi_rdata),
        .ASHI_READ      (ashi_read ),
        .ASHI_RRESP     (ashi_rresp),
        .ASHI_RIDLE     (ashi_ridle)
    );
    //==========================================================================



//====================================================================================
// This FIFO holds a vector of 8-bit cell-values
//====================================================================================
xpm_fifo_axis #
(
   .FIFO_DEPTH(8192),              // DECIMAL
   .TDATA_WIDTH(PATTERN_WIDTH),    // DECIMAL
   .FIFO_MEMORY_TYPE("auto"),      // String
   .PACKET_FIFO("false"),          // String
   .USE_ADV_FEATURES("0000")       // String
)
fifo_0
(
    // Clock and reset
   .s_aclk   (clk   ),
   .m_aclk   (clk   ),
   .s_aresetn(~f0_reset),

    // The input bus to the FIFO
   .s_axis_tdata (f0in_tdata ),
   .s_axis_tvalid(f0in_tvalid),
   .s_axis_tready(f0in_tready),

    // The output bus of the FIFO
   .m_axis_tdata (f0out_tdata ),
   .m_axis_tvalid(f0out_tvalid),
   .m_axis_tready(f0out_tready),

    // Unused input stream signals
   .s_axis_tdest(),
   .s_axis_tid  (),
   .s_axis_tstrb(),
   .s_axis_tuser(),
   .s_axis_tkeep(),
   .s_axis_tlast(),

    // Unused output stream signals
   .m_axis_tdest(),
   .m_axis_tid  (),
   .m_axis_tstrb(),
   .m_axis_tuser(),
   .m_axis_tkeep(),
   .m_axis_tlast(),

    // Other unused signals
   .almost_empty_axis(),
   .almost_full_axis(),
   .dbiterr_axis(),
   .prog_empty_axis(),
   .prog_full_axis(),
   .rd_data_count_axis(),
   .sbiterr_axis(),
   .wr_data_count_axis(),
   .injectdbiterr_axis(),
   .injectsbiterr_axis()
);
//====================================================================================


//====================================================================================
// This FIFO holds a vector of 8-bit cell-values
//====================================================================================
xpm_fifo_axis #
(
   .FIFO_DEPTH(8192),              // DECIMAL
   .TDATA_WIDTH(PATTERN_WIDTH),    // DECIMAL
   .FIFO_MEMORY_TYPE("auto"),      // String
   .PACKET_FIFO("false"),          // String
   .USE_ADV_FEATURES("0000")       // String
)
fifo_1
(
    // Clock and reset
   .s_aclk   (clk   ),
   .m_aclk   (clk   ),
   .s_aresetn(~f1_reset),

    // The input bus to the FIFO
   .s_axis_tdata (f1in_tdata),
   .s_axis_tvalid(f1in_tvalid),
   .s_axis_tready(f1in_tready),

    // The output bus of the FIFO
   .m_axis_tdata (f1out_tdata),
   .m_axis_tvalid(f1out_tvalid),
   .m_axis_tready(f1out_tready),

    // Unused input stream signals
   .s_axis_tdest(),
   .s_axis_tid  (),
   .s_axis_tstrb(),
   .s_axis_tuser(),
   .s_axis_tkeep(),
   .s_axis_tlast(),

    // Unused output stream signals
   .m_axis_tdest(),
   .m_axis_tid  (),
   .m_axis_tstrb(),
   .m_axis_tuser(),
   .m_axis_tkeep(),
   .m_axis_tlast(),

    // Other unused signals
   .almost_empty_axis(),
   .almost_full_axis(),
   .dbiterr_axis(),
   .prog_empty_axis(),
   .prog_full_axis(),
   .rd_data_count_axis(),
   .sbiterr_axis(),
   .wr_data_count_axis(),
   .injectdbiterr_axis(),
   .injectsbiterr_axis()
);
//====================================================================================

endmodule
