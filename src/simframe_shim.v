

//====================================================================================
//                        ------->  Revision History  <------
//====================================================================================
//
//   Date     Who   Ver  Changes
//====================================================================================
// 30-Nov-23  DWW     1  Initial creation
//====================================================================================


/*
     This module reads packets from the input stream and:

     (1) Outputs them on the M_AXI memory-mapped AXI interface
     (2) After outputting a full frame, it outputs a 128-byte "meta-command"
     (3) It then outputs an 8-byte "frame_count"

     When writing frame data, the addresses they are written to are in a circular ring
     buffer.   Meta-commands are written to a separate ring buffer.

*/

module simframe_shim #
(
    parameter DATA_WBITS = 512
)
(
    input clk, resetn,

    // The number of data-cycles in a packet
    input[15:0] CYCLES_PER_PACKET,

    // The number of packets in a data-frame
    input[15:0] PACKETS_PER_FRAME,

    // Geometry of the frame-data ring buffer
    input[63:0] FD_RING_ADDR, FD_RING_SIZE,

    // Geometry of the meta-command ring buffer
    input[63:0] MC_RING_ADDR, MC_RING_SIZE,

    // The remote address where the frame-counter should be stored
    input[63:0] FC_ADDR,

    // The fixed portion of the meta-command to be emitted after every frame
    input[511:0] MC_FIXED,

    // Will strobe high for one cycle at the start of a new job
    input new_job,

    //=========================   The input stream   ===========================
    input [DATA_WBITS-1:0] AXIS_IN_TDATA,
    input                  AXIS_IN_TVALID,
    input                  AXIS_IN_TLAST,
    output reg             AXIS_IN_TREADY,
    //==========================================================================


    //=================   This is the AXI4 output interface   ==================

    // "Specify write address"              -- Master --    -- Slave --
    output reg [63:0]                        M_AXI_AWADDR,
    output reg [7:0]                         M_AXI_AWLEN,
    output     [2:0]                         M_AXI_AWSIZE,
    output     [3:0]                         M_AXI_AWID,
    output     [1:0]                         M_AXI_AWBURST,
    output                                   M_AXI_AWLOCK,
    output     [3:0]                         M_AXI_AWCACHE,
    output     [3:0]                         M_AXI_AWQOS,
    output     [2:0]                         M_AXI_AWPROT,
    output reg                               M_AXI_AWVALID,
    input                                                   M_AXI_AWREADY,

    // "Write Data"                         -- Master --    -- Slave --
    output reg[DATA_WBITS-1:0]              M_AXI_WDATA,
    output reg[(DATA_WBITS/8)-1:0]          M_AXI_WSTRB,
    output reg                              M_AXI_WVALID,
    output reg                              M_AXI_WLAST,
    input                                                   M_AXI_WREADY,

    // "Send Write Response"                -- Master --    -- Slave --
    input[1:0]                                              M_AXI_BRESP,
    input                                                   M_AXI_BVALID,
    output                                  M_AXI_BREADY,

    // "Specify read address"               -- Master --    -- Slave --
    output[63:0]                            M_AXI_ARADDR,
    output                                  M_AXI_ARVALID,
    output[2:0]                             M_AXI_ARPROT,
    output                                  M_AXI_ARLOCK,
    output[3:0]                             M_AXI_ARID,
    output[7:0]                             M_AXI_ARLEN,
    output[1:0]                             M_AXI_ARBURST,
    output[3:0]                             M_AXI_ARCACHE,
    output[3:0]                             M_AXI_ARQOS,
    input                                                   M_AXI_ARREADY,

    // "Read data back to master"           -- Master --    -- Slave --
    input[DATA_WBITS-1:0]                                   M_AXI_RDATA,
    input                                                   M_AXI_RVALID,
    input[1:0]                                              M_AXI_RRESP,
    input                                                   M_AXI_RLAST,
    output                                  M_AXI_RREADY
    //==========================================================================
);

// Compute the width of the data bus, in bytes
localparam DATA_WBYTS = (DATA_WBITS / 8);

// The width of a meta-command in bytes
localparam METACOMMAND_WIDTH = 128;

// The number of packets in 1/2 of a data-frame
wire[15:0] packets_per_half_frame = PACKETS_PER_FRAME / 2;

// Compute the size of a data packet (which is also the size of a write-burst)
wire[15:0] packet_size = CYCLES_PER_PACKET * DATA_WBYTS;

// Offset where we'll write the next frame-data 
reg [63:0] fd_ptr;
wire[63:0] next_fd_ptr = fd_ptr + packet_size;   

// Offset where we'll write the next meta-command
reg [63:0] mc_ptr;
wire[63:0] next_mc_ptr = mc_ptr + METACOMMAND_WIDTH;

// Every time we output a complete frame, this is incremented and output
reg[63:0] frame_count;

// When writing data-bursts to the output interface, this is the current beat
reg[8:0] beat;

// This will be high when outputting the first beat of a burst 
wire first_beat = (M_AXI_WVALID & M_AXI_WREADY & (beat == 0));

// States of our main finite-state-machine
reg[2:0]   fsm_state;
localparam FSM_RESET       = 0;
localparam FSM_START       = 1;
localparam FSM_XFER_PACKET = 2;
localparam FSM_OUTPUT_MC1  = 3;
localparam FSM_OUTPUT_MC2  = 4;
localparam FSM_OUTPUT_FC   = 5;

// The meta-command timestamp.  For now, it's just the frame counter.
wire[63:0] metacommand_ts;
byte_swap#(64) bs3(.I(frame_count), .O(metacommand_ts));

// Padding for the metacommand
localparam[56*8-1:0] mc_padding = 0;

// This is the meta-command in big endian
wire[(METACOMMAND_WIDTH*8)-1:0] metacommand_be = {metacommand_ts, MC_FIXED, mc_padding};

// This is the meta-command in little endian
wire[(METACOMMAND_WIDTH*8)-1:0] metacommand_le;

// metacommand_le is metacommand_be with the bytes in reverse order
byte_swap#(METACOMMAND_WIDTH*8) bs1(.I(metacommand_be), .O(metacommand_le));

// Create a byte-swapped version of the data on the input stream
wire[DATA_WBITS-1:0] axis_in_tdata_swapped;
byte_swap#(DATA_WBITS) bs2(.I(AXIS_IN_TDATA), .O(axis_in_tdata_swapped));


//-----------------------------------------------------------------------------
// This block determines the output_mode by looking at the state of the
// main state machine
//-----------------------------------------------------------------------------

// The current output mode : Frame-Data, Meta-Command, or Frame-Counter
reg[2:0]   output_mode;
localparam OM_RESET = 0;
localparam OM_FD    = 1;  /* Output Mode : Frame Data              */
localparam OM_MC1   = 2;  /* Output Mode : Meta Command, 1st half  */
localparam OM_MC2   = 3;  /* Output Mode : Meta Command, 2nd half  */
localparam OM_FC    = 4;  /* Output Mode : Frame Counter           */

always @* begin
    case (fsm_state)
        FSM_XFER_PACKET:    output_mode = OM_FD;    // Frame-data
        FSM_OUTPUT_MC1:     output_mode = OM_MC1;   // 1st half of meta-command
        FSM_OUTPUT_MC2:     output_mode = OM_MC2;   // 2nd half of meta-command
        FSM_OUTPUT_FC:      output_mode = OM_FC;    // Frame counter
        default:            output_mode = OM_RESET;
    endcase
end
//-----------------------------------------------------------------------------


//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
// 
//     This next section manages the W-channel of the M_AXI output interface
//
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

//-----------------------------------------------------------------------------
// Drive M_AXI_WDATA
//-----------------------------------------------------------------------------
always @* begin
    case (output_mode)
        OM_RESET:   M_AXI_WDATA = 0;
        OM_FD   :   M_AXI_WDATA = axis_in_tdata_swapped;
        OM_MC1  :   M_AXI_WDATA = metacommand_le[ 0*8 +: DATA_WBITS];
        OM_MC2  :   M_AXI_WDATA = metacommand_le[64*8 +: DATA_WBITS];
        OM_FC   :   M_AXI_WDATA = frame_count;
    endcase
end
//-----------------------------------------------------------------------------


//-----------------------------------------------------------------------------
// Drive M_AXI_WLAST
//-----------------------------------------------------------------------------
always @* begin
    case (output_mode)
        OM_RESET:   M_AXI_WLAST = 0;
        OM_FD   :   M_AXI_WLAST = AXIS_IN_TLAST;
        OM_MC1  :   M_AXI_WLAST = 0;
        OM_MC2  :   M_AXI_WLAST = 1;
        OM_FC   :   M_AXI_WLAST = 1;
    endcase
end
//-----------------------------------------------------------------------------


//-----------------------------------------------------------------------------
// Drive M_AXI_WSTRB
//-----------------------------------------------------------------------------
always @* begin
    case (output_mode)
        OM_RESET:   M_AXI_WSTRB = 0;
        OM_FD   :   M_AXI_WSTRB = -1;
        OM_MC1  :   M_AXI_WSTRB = -1;
        OM_FC   :   M_AXI_WSTRB = 4'hF; /* We output lower 4 bytes of the FC */
    endcase
end
//-----------------------------------------------------------------------------


//-----------------------------------------------------------------------------
// Drive M_AXI_WVALID
//-----------------------------------------------------------------------------
always @* begin
    case (output_mode)
        OM_RESET:   M_AXI_WVALID = 0;
        OM_FD   :   M_AXI_WVALID = AXIS_IN_TVALID;
        OM_MC1  :   M_AXI_WVALID = 1;
        OM_MC2  :   M_AXI_WVALID = 1;
        OM_FC   :   M_AXI_WVALID = 1;
    endcase
end
//-----------------------------------------------------------------------------


//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//
//     This next section manages the AW-channel of the M_AXI output interface
// 
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

assign M_AXI_AWID    = 0;
assign M_AXI_AWSIZE  = $clog2(DATA_WBYTS);
assign M_AXI_AWBURST = 1;       /* Burst type = Increment */
assign M_AXI_AWLOCK  = 0;       /* Not locked             */
assign M_AXI_AWCACHE = 0;       /* No caching             */
assign M_AXI_AWPROT  = 1;       /* Privileged Access      */
assign M_AXI_AWQOS   = 0;       /* No QoS                 */


//-----------------------------------------------------------------------------
// Drive M_AXI_AWADDR
//-----------------------------------------------------------------------------
always @* begin
    case (output_mode)
        OM_RESET:   M_AXI_AWADDR = 0;
        OM_FD   :   M_AXI_AWADDR = FD_RING_ADDR + fd_ptr;
        OM_MC1  :   M_AXI_AWADDR = MC_RING_ADDR + mc_ptr;
        OM_MC2  :   M_AXI_AWADDR = MC_RING_ADDR + mc_ptr;
        OM_FC   :   M_AXI_AWADDR = FC_ADDR;
    endcase
end
//-----------------------------------------------------------------------------



//-----------------------------------------------------------------------------
// Drive M_AXI_AWLEN
//-----------------------------------------------------------------------------
always @* begin
    case (output_mode)
        OM_RESET:   M_AXI_AWLEN = 0;
        OM_FD   :   M_AXI_AWLEN = CYCLES_PER_PACKET - 1;
        OM_MC1  :   M_AXI_AWLEN = 1;
        OM_MC2  :   M_AXI_AWLEN = 1;
        OM_FC   :   M_AXI_AWLEN = 0;
    endcase
end
//-----------------------------------------------------------------------------


//-----------------------------------------------------------------------------
// Drive M_AXI_AWVALID - AWVALID goes active for 1 cycle when the first beat
//                       of a data burst has been accepted
//-----------------------------------------------------------------------------
always @* begin
    case (output_mode)
        OM_RESET:   M_AXI_AWVALID = 0;
        OM_FD   :   M_AXI_AWVALID = first_beat;
        OM_MC1  :   M_AXI_AWVALID = first_beat;
        OM_MC2  :   M_AXI_AWVALID = 0;
        OM_FC   :   M_AXI_AWVALID = first_beat;
    endcase
end
//-----------------------------------------------------------------------------



//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//
//                         End of AW-channel definitions
// 
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>
//<><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><><>

// We're always ready to receive AXI write-acknowledgments
assign M_AXI_BREADY = 1;

//-----------------------------------------------------------------------------
// Drive the TREADY line of the input stream.  We only allow input when
// we're in frame-data mode and the output is ready to receive the data-cycle.
//-----------------------------------------------------------------------------
always @* begin
    case (output_mode)
        OM_RESET:   AXIS_IN_TREADY = 0;
        OM_FD   :   AXIS_IN_TREADY = M_AXI_WREADY;
        OM_MC1  :   AXIS_IN_TREADY = 0;
        OM_MC2  :   AXIS_IN_TREADY = 0;
        OM_FC   :   AXIS_IN_TREADY = 0;
    endcase
end
//-----------------------------------------------------------------------------


//=============================================================================
// This state machine manages the "fd_ptr" that specifies the offset where
// the next packet of frame data should be stored
//=============================================================================
always @(posedge clk) begin
    
    if (new_job)
        fd_ptr <= 0;
    else case(fsm_state)

        FSM_START:
            fd_ptr <= 0;

        FSM_XFER_PACKET:
            if (M_AXI_WVALID & M_AXI_WREADY & M_AXI_WLAST) begin
                if (next_fd_ptr >= FD_RING_SIZE)
                  fd_ptr <= 0;
                else
                  fd_ptr <= next_fd_ptr;
            end

    endcase

end
//=============================================================================





//=============================================================================
// This state machine manages the "mc_ptr" that specifies the offset where
// the next meta-command should be stored
//=============================================================================
always @(posedge clk) begin
    
    if (new_job)
        mc_ptr <= 0;
    
    else case(fsm_state)

        FSM_START:
            mc_ptr <= 0;

        FSM_OUTPUT_MC2:
            if (M_AXI_WVALID & M_AXI_WREADY) begin
                if (next_mc_ptr >= MC_RING_SIZE)
                  mc_ptr <= 0;
                else
                  mc_ptr <= next_mc_ptr;
            end

    endcase

end
//=============================================================================



//=============================================================================
// This state machine is responsible for watching packets get copied from the
// input interface to the output interface and for injecting a meta-command
// packet and a frame-count packet after every frame.
//
// Drives:
//    fsm_state (and therefore, "output_mode")
//    beat
//    packet_count
//    frame_count
//=============================================================================
reg[15:0] packet_count;

always @(posedge clk) begin
    if (resetn == 0) begin
        fsm_state <= FSM_RESET;

    end else case(fsm_state)

        FSM_RESET:
            fsm_state <= FSM_START;

        FSM_START:
            begin
                beat         <= 0;
                frame_count  <= 1;
                packet_count <= 1;
                fsm_state    <= FSM_XFER_PACKET;
            end

        // Counts packets as they get output.  Once an entire frame has 
        // has been output, we move on to the next state
        FSM_XFER_PACKET:
            if (M_AXI_WVALID & M_AXI_WREADY) begin
                beat <= beat + 1;
                if (M_AXI_WLAST) begin
                    beat <= 0;
                    if (packet_count == packets_per_half_frame) begin
                        fsm_state <= FSM_OUTPUT_MC1;
                    end else
                        packet_count <= packet_count + 1;
                end
            end

        // Wait for the 1st half of the meta-command to be output
        FSM_OUTPUT_MC1:
            if (M_AXI_WVALID & M_AXI_WREADY) begin
                beat      <= 1;
                fsm_state <= FSM_OUTPUT_MC2;
            end
        
        // Wait for the 2nd half of the meta-command to be output
        FSM_OUTPUT_MC2:
            if (M_AXI_WVALID & M_AXI_WREADY) begin
                beat      <= 0;
                fsm_state <= FSM_OUTPUT_FC;
            end

        // Wait for the frame-counter to be output
        FSM_OUTPUT_FC:
            if (M_AXI_WVALID & M_AXI_WREADY) begin
                frame_count  <= frame_count + 1;
                packet_count <= 1;
                fsm_state    <= FSM_XFER_PACKET;
            end

    endcase

    // Whenever a new job starts, reset the frame counter
    if (new_job) frame_count <= 1;

end
//=============================================================================

endmodule
