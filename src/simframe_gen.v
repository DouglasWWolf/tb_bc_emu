//====================================================================================
//                        ------->  Revision History  <------
//====================================================================================
//
//   Date     Who   Ver  Changes
//====================================================================================
// 25-Oct-23  DWW     1  Initial creation
//====================================================================================

/*
    The purpose of this module is to stream in bit patterns that are of fixed at 8,
    16, 32, 64, 128, 256, or 512 bits wide, and replicate that pattern across the 
    width of an output stream, writing sufficient data cycles to comprise an entire
    4 million cell frame.
*/


module simframe_gen #
(
    parameter PATTERN_WIDTH = 32,
    parameter OUTPUT_WIDTH  = 512   
)
(
    input clk, resetn,

    input[15:0] CYCLES_PER_PKT, PKTS_PER_FRAME,

    //=========================   The input stream   ===========================
    input [PATTERN_WIDTH-1:0] AXIS_IN_TDATA,
    input                     AXIS_IN_TVALID,
    output                    AXIS_IN_TREADY,
    //==========================================================================


    //=========================   The output stream   ==========================
    output [OUTPUT_WIDTH-1:0] AXIS_OUT_TDATA,
    output reg                AXIS_OUT_TVALID,
    output                    AXIS_OUT_TLAST,
    input                     AXIS_OUT_TREADY
    //==========================================================================

);
    // This is the number of times that the input pattern can fit across the output bus
    localparam PATTERN_REPEATS = OUTPUT_WIDTH / PATTERN_WIDTH;

    // This is the pattern that we'll be outputting
    reg[PATTERN_WIDTH-1:0] pattern;

    // The input pattern repeats across the width of the output stream
    genvar i;
    for (i=0; i<PATTERN_REPEATS; i=i+1) begin
        assign AXIS_OUT_TDATA[i*PATTERN_WIDTH +: PATTERN_WIDTH] = pattern;
    end 

    //====================================================================================
    // Output state machine - Drives packets of frame data out to the output stream
    //====================================================================================
    reg       osm_state;
    reg[31:0] cycles_remaining;  // Number of cycles left in this packet
    reg[31:0] pkts_remaining;    // Number of packets left in this frame

    // This signal will be high during the handshake of the last data-cycle of a frame
    wire last_cycle_in_frame =  (
                                    AXIS_OUT_TVALID  == 1 &&
                                    AXIS_OUT_TREADY  == 1 &&
                                    cycles_remaining == 0 &&
                                    pkts_remaining   == 0
                                );

    // Define when we're ready to accept a new pattern on the input stream    
    assign AXIS_IN_TREADY  = (resetn == 1 && osm_state == 0) ? 1 :
                             (resetn == 1 && osm_state == 1 && last_cycle_in_frame) ? 1 : 0;
    
    // The TLAST signal on the output stream should be high on the last cycle of a packet
    assign AXIS_OUT_TLAST  = (cycles_remaining == 0);

    //------------------------------------------------------------------------------------

    always @(posedge clk) begin

        // If we're being held in reset...
        if (resetn == 0) begin
            osm_state       <= 0;
            AXIS_OUT_TVALID <= 0;
          
        // Otherwise, run the state machine
        end else case(osm_state)

            // Here we wait for a valid-data cycle to arrive on the input stream.
            // When it does, we repeat that input data across AXIS_OUT_TDATA, then
            // output as many packets of data as it takes to fill a frame
            0:  if (AXIS_IN_TVALID & AXIS_IN_TREADY) begin
                    pattern          <= AXIS_IN_TDATA;
                    cycles_remaining <= CYCLES_PER_PKT - 1;
                    pkts_remaining   <= PKTS_PER_FRAME - 1;
                    AXIS_OUT_TVALID  <= 1;
                    osm_state        <= 1;
                end

            // Every time we output a data-cycle...
            1:  if (AXIS_OUT_TVALID & AXIS_OUT_TREADY) begin
                    
                    // If this was the last data-cycle of this packet...
                    if (cycles_remaining == 0) begin

                        // Reload the counter for the next packet
                        cycles_remaining <= CYCLES_PER_PKT - 1;

                        // If this was the last packet of this frame
                        if (pkts_remaining == 0) begin
                            
                            // Reload the counter for the next frame
                            pkts_remaining <= PKTS_PER_FRAME - 1;

                            // If there's a new pattern available on the input stream...
                            if (AXIS_IN_TVALID & AXIS_IN_TREADY) begin
                                pattern <= AXIS_IN_TDATA;
                            end
                            
                            // Otherwise, if there's not a new input pattern, go wait for one
                            else begin
                                osm_state <= 0;
                                AXIS_OUT_TVALID <= 0;
                            end

                        // If this wasn't the last packet of the frame, just count down packets
                        end else begin
                            pkts_remaining <= pkts_remaining - 1;
                        end
                    
                    // If this wasn't the last cycle of the packet, just count down cycles
                    end else begin
                        cycles_remaining <= cycles_remaining - 1;
                    end
                end

        endcase
    end
    //====================================================================================


endmodule


