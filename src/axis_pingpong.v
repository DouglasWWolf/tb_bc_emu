
//====================================================================================
//                        ------->  Revision History  <------
//====================================================================================
//
//   Date     Who   Ver  Changes
//====================================================================================
// 30-Nov-23  DWW     1  Initial creation
//====================================================================================

/*
    This modules reads packets from an input stream, and writes a group of packets
    to output stream #1, then writes a group to output stream #2, then another
    group to output stream #1, etc.
*/

module axis_pingpong #
(
    parameter STREAM_WBITS = 512
)
(
    input clk, resetn,

    //=========================   The input stream   ===========================
    input [STREAM_WBITS-1:0] AXIS_IN_TDATA,
    input                    AXIS_IN_TVALID,
    input                    AXIS_IN_TLAST,
    output                   AXIS_IN_TREADY,
    //==========================================================================


    //=========================   Output Stream #1   ===========================
    output [STREAM_WBITS-1:0] AXIS_OUT0_TDATA,
    output                    AXIS_OUT0_TLAST,
    output                    AXIS_OUT0_TVALID,
    input                     AXIS_OUT0_TREADY,
    //==========================================================================


    //=========================   Output Stream #2   ===========================
    output [STREAM_WBITS-1:0] AXIS_OUT1_TDATA,
    output                    AXIS_OUT1_TLAST,
    output                    AXIS_OUT1_TVALID,
    input                     AXIS_OUT1_TREADY,
    //==========================================================================

    input[31:0] PACKETS_PER_GROUP
);

// This selects which output stream we're writing to
reg output_select;

// The output TDATA and TLAST are driven directly from the input stream
assign AXIS_OUT0_TDATA = (output_select == 0) ? AXIS_IN_TDATA : 0;
assign AXIS_OUT1_TDATA = (output_select == 1) ? AXIS_IN_TDATA : 0;
assign AXIS_OUT0_TLAST = (output_select == 0) ? AXIS_IN_TLAST : 0;
assign AXIS_OUT1_TLAST = (output_select == 1) ? AXIS_IN_TLAST : 0;

// The output TVALID is driven by the input TVALID, gated by "output_select"
assign AXIS_OUT0_TVALID = AXIS_IN_TVALID & (output_select == 0);
assign AXIS_OUT1_TVALID = AXIS_IN_TVALID & (output_select == 1);

// The TREADY signal on the input stream is driven by one of the output streams
assign AXIS_IN_TREADY = (output_select == 0) ? AXIS_OUT0_TREADY : AXIS_OUT1_TREADY;

// Create some convenient shortcuts to the output TVALID, TLAST, and TREADY
wire axis_out_tvalid = (output_select == 0) ? AXIS_OUT0_TVALID : AXIS_OUT1_TVALID;
wire axis_out_tlast  = (output_select == 0) ? AXIS_OUT0_TLAST  : AXIS_OUT1_TLAST;
wire axis_out_tready = (output_select == 0) ? AXIS_OUT0_TREADY : AXIS_OUT1_TREADY;

//--------------------------------------------------------------------------
// This state machine watches for the handshake on the last data-cycle of
// outgoing packets.  Every PACKETS_PER_GROUP packets, it switches the
// "output_select" register from 0 to 1 (or vice-versa)
//--------------------------------------------------------------------------
reg[15:0] counter;

always @(posedge clk) begin

    // If we're in reset, clear the counter and output_select to known values
    if (resetn == 0) begin
        counter       <= 1;
        output_select <= 0;
    
    // Otherwise, we're not in reset, so...
    end else begin

        // If this is the end-of-packet handshake on the output....
        if (axis_out_tvalid & axis_out_tready & axis_out_tlast) begin
            
            // If this is the last packet in this group, start outputtting
            // on the other output stream.
            if (counter < PACKETS_PER_GROUP)
                counter       <= counter + 1;
            else begin
                counter       <= 1;
                output_select <= ~output_select;
            end
        end
    end
end
//--------------------------------------------------------------------------

endmodule
