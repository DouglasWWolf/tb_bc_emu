//====================================================================================
//                        ------->  Revision History  <------
//====================================================================================
//
//   Date     Who   Ver  Changes
//====================================================================================
// 04-Dec-23  DWW     1  Initial creation
//====================================================================================

/*
    Ensures that the number of data-transfers per microsecond doesn't exceed
    the configured limit
*/


module rate_limiter #
(
    parameter DW = 512, 
    parameter CLOCKS_PER_USEC = 250  
)
(
    input clk, resetn,

    //=========================   The input stream   ===========================
    input [DW-1:0]     AXIS_IN_TDATA,
    input [(DW/8)-1:0] AXIS_IN_TKEEP, 
    input              AXIS_IN_TLAST,
    input              AXIS_IN_TVALID,
    output             AXIS_IN_TREADY,
    //==========================================================================


    //=========================   The output stream   ==========================
    output [DW-1:0]     AXIS_OUT_TDATA,
    output [(DW/8)-1:0] AXIS_OUT_TKEEP, 
    output              AXIS_OUT_TLAST,
    output              AXIS_OUT_TVALID,
    input               AXIS_OUT_TREADY,
    //==========================================================================

    // Rate limit in bytes-per-microsecond.  Should be divisible by (DW/8)
    input [31:0]        BYTES_PER_USEC
);

// Define the number of data-cycle-transfers allowed per microsecond
wire[15:0] max_xfers_per_usec = BYTES_PER_USEC / (DW/8);

// Clock-cycle number, cycles continuously from 1 to CLOCKS_PER_USEC
reg [15:0] cycle_count;

// Incremented on every cycle in which a data-transfer handshake occurs
reg [15:0] xfer_count;

// We will pass data thru until we hit our limit in this microsecond
wire pass_thru = (xfer_count < max_xfers_per_usec);

always @(posedge clk) begin
    if (resetn == 0) begin
        cycle_count <= 1;
        xfer_count  <= 0;
    end else begin

        // Count the number of data-transfers during this microsecond
        if (AXIS_OUT_TVALID & AXIS_OUT_TREADY) xfer_count <= xfer_count + 1;

        // Have we reached the end of the current microsecond?
        if (cycle_count == CLOCKS_PER_USEC) begin
            cycle_count <= 1;
            xfer_count  <= 0;
        end        
        
        // If we haven't, then keep counting
        else cycle_count <= cycle_count + 1;

    end
end

assign AXIS_OUT_TDATA  = AXIS_IN_TDATA;
assign AXIS_OUT_TKEEP  = AXIS_IN_TKEEP;
assign AXIS_OUT_TLAST  = AXIS_IN_TLAST;
assign AXIS_OUT_TVALID = AXIS_IN_TVALID  & pass_thru & (resetn == 1);
assign AXIS_IN_TREADY  = AXIS_OUT_TREADY & pass_thru & (resetn == 1);

endmodule


