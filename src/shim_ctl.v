//====================================================================================
//                        ------->  Revision History  <------
//====================================================================================
//
//   Date     Who   Ver  Changes
//====================================================================================
// 01-Dec-23  DWW     1  Initial creation
//====================================================================================

/*
     This module provides AXI registers to configure simframe_shim
*/


module shim_ctl 
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
 
    // The number of packets in a single packet-group from the ping-ponger
    output reg[31:0] PACKETS_PER_GROUP, 

    // The geometry of the frame-data ring buffer
    output reg[63:0] FD_RING_ADDR,
    output reg[63:0] FD_RING_SIZE,

    // The geometry of the meta-command ring buffer
    output reg[63:0] MC_RING_ADDR,
    output reg[63:0] MC_RING_SIZE,

    // The remote-address where the frame-counter will be stored
    output reg[63:0] FC_ADDR,

    // The meta-command that gets output after every frame
    output reg[511:0] METACOMMAND,

    // The rate-limiter delay
    output reg[31:0] BYTES_PER_USEC
    //==========================================================================    
);  

    // Any time the register map of this module changes, this number should
    // be bumped
    localparam MODULE_VERSION = 1;

    // The indicies of the AXI registers
    localparam REG_MODULE_REV     =  0;

    localparam REG_FD_RING_ADDRH  =  1;
    localparam REG_FD_RING_ADDRL  =  2;
    localparam REG_FD_RING_SIZEH  =  3;
    localparam REG_FD_RING_SIZEL  =  4;

    localparam REG_MC_RING_ADDRH  =  5;
    localparam REG_MC_RING_ADDRL  =  6;
    localparam REG_MC_RING_SIZEH  =  7;
    localparam REG_MC_RING_SIZEL  =  8;

    localparam REG_FC_ADDRH       =  9;
    localparam REG_FC_ADDRL       = 10;

    localparam REG_PKT_PER_GROUP  = 11;
    localparam REG_BYTES_PER_USEC = 12;

    localparam REG_MCOMMAND_00    = 16;
    localparam REG_MCOMMAND_01    = 17;
    localparam REG_MCOMMAND_02    = 18;
    localparam REG_MCOMMAND_03    = 19;
    localparam REG_MCOMMAND_04    = 20;
    localparam REG_MCOMMAND_05    = 21;
    localparam REG_MCOMMAND_06    = 22;
    localparam REG_MCOMMAND_07    = 23;
    localparam REG_MCOMMAND_08    = 24;
    localparam REG_MCOMMAND_09    = 25;
    localparam REG_MCOMMAND_10    = 26;
    localparam REG_MCOMMAND_11    = 27;
    localparam REG_MCOMMAND_12    = 28;
    localparam REG_MCOMMAND_13    = 29;
    localparam REG_MCOMMAND_14    = 30;
    localparam REG_MCOMMAND_15    = 31;
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

    // Coming out of reset, these are default values
    localparam DEFAULT_FD_RING_ADDR      = 64'h0000_0001_0000_0000;
    localparam DEFAULT_FD_RING_SIZE      = 64'h0000_0000_0000_0800;
    localparam DEFAULT_MC_RING_ADDR      = 64'h0000_0002_0000_0000;
    localparam DEFAULT_MC_RING_SIZE      = 64'h0000_0000_0000_0100;
    localparam DEFAULT_FC_ADDR           = 64'h0000_F123_AABB_CC00;
    localparam DEFAULT_METACOMMAND       = 64'h0042_DEAD_BEEF_4200;
    localparam DEFAULT_PACKETS_PER_GROUP = 4;
    localparam DEFAULT_BYTES_PER_USEC    = 12288;

    //==========================================================================
    // This state machine handles AXI4-Lite write requests
    //
    // Drives:
    //==========================================================================
    always @(posedge clk) begin
    

        // If we're in reset, initialize important registers
        if (resetn == 0) begin
            axi4_write_state <= 0;
            FD_RING_ADDR      <= DEFAULT_FD_RING_ADDR;
            FD_RING_SIZE      <= DEFAULT_FD_RING_SIZE;
            MC_RING_ADDR      <= DEFAULT_MC_RING_ADDR;
            MC_RING_SIZE      <= DEFAULT_MC_RING_SIZE;
            FC_ADDR           <= DEFAULT_FC_ADDR;
            METACOMMAND       <= DEFAULT_METACOMMAND;
            PACKETS_PER_GROUP <= DEFAULT_PACKETS_PER_GROUP;
            BYTES_PER_USEC    <= DEFAULT_BYTES_PER_USEC;

        // If we're not in reset, and a write-request has occured...        
        end else case (axi4_write_state)
        
        0:  if (ashi_write) begin
       
                // Assume for the moment that the result will be OKAY
                ashi_wresp <= OKAY;              
            
                // Convert the byte address into a register index
                case ((ashi_waddr & ADDR_MASK) >> 2)

                    // Update the frame-data ring-buffer address
                    REG_FD_RING_ADDRH:  FD_RING_ADDR[63:32] <= ashi_wdata;
                    REG_FD_RING_ADDRL:  FD_RING_ADDR[31:00] <= ashi_wdata;                    
                
                    // Update the frame-data ring-buffer size
                    REG_FD_RING_SIZEH:  FD_RING_SIZE[63:32] <= ashi_wdata;
                    REG_FD_RING_SIZEL:  FD_RING_SIZE[31:00] <= ashi_wdata;                    
                    
                    // Update the meta-command ring-buffer address
                    REG_MC_RING_ADDRH:  MC_RING_ADDR[63:32] <= ashi_wdata;
                    REG_MC_RING_ADDRL:  MC_RING_ADDR[31:00] <= ashi_wdata;                    

                    // Update the meta-command ring-buffer size
                    REG_MC_RING_SIZEH:  MC_RING_SIZE[63:32] <= ashi_wdata;
                    REG_MC_RING_SIZEL:  MC_RING_SIZE[31:00] <= ashi_wdata;        

                    // Update the address where the frame-counter gets stored
                    REG_FC_ADDRH:       FC_ADDR[63:32] <= ashi_wdata;
                    REG_FC_ADDRL:       FC_ADDR[31:00] <= ashi_wdata;  

                    // Update the number of packets in a ping-ponger group
                    REG_PKT_PER_GROUP:  PACKETS_PER_GROUP <= ashi_wdata;     

                    // Update the rate-limiter's maximum throughput
                    REG_BYTES_PER_USEC: BYTES_PER_USEC <= ashi_wdata;             

                    // Allow the user to store values into the "METACOMMAND" field
                    REG_MCOMMAND_00:  METACOMMAND[ 0 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_01:  METACOMMAND[ 1 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_02:  METACOMMAND[ 2 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_03:  METACOMMAND[ 3 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_04:  METACOMMAND[ 4 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_05:  METACOMMAND[ 5 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_06:  METACOMMAND[ 6 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_07:  METACOMMAND[ 7 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_08:  METACOMMAND[ 8 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_09:  METACOMMAND[ 9 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_10:  METACOMMAND[10 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_11:  METACOMMAND[11 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_12:  METACOMMAND[12 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_13:  METACOMMAND[13 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_14:  METACOMMAND[14 * 32 +: 32] <= ashi_wdata;
                    REG_MCOMMAND_15:  METACOMMAND[15 * 32 +: 32] <= ashi_wdata;

                    // Writes to any other register are a decode-error
                    default: ashi_wresp <= DECERR;
                endcase
            end

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
                REG_FD_RING_ADDRH:  ashi_rdata <= FD_RING_ADDR[63:32];
                REG_FD_RING_ADDRL:  ashi_rdata <= FD_RING_ADDR[31:00];                    
                REG_FD_RING_SIZEH:  ashi_rdata <= FD_RING_SIZE[63:32];
                REG_FD_RING_SIZEL:  ashi_rdata <= FD_RING_SIZE[31:00];                    
                REG_MC_RING_ADDRH:  ashi_rdata <= MC_RING_ADDR[63:32];
                REG_MC_RING_ADDRL:  ashi_rdata <= MC_RING_ADDR[31:00];                    
                REG_MC_RING_SIZEH:  ashi_rdata <= MC_RING_SIZE[63:32];
                REG_MC_RING_SIZEL:  ashi_rdata <= MC_RING_SIZE[31:00];                    
                REG_FC_ADDRH:       ashi_rdata <= FC_ADDR[63:32];
                REG_FC_ADDRL:       ashi_rdata <= FC_ADDR[31:00];    
                REG_PKT_PER_GROUP:  ashi_rdata <= PACKETS_PER_GROUP;
                REG_BYTES_PER_USEC: ashi_rdata <= BYTES_PER_USEC;
                REG_MCOMMAND_00:    ashi_rdata <= METACOMMAND[ 0 * 32 +: 32];
                REG_MCOMMAND_01:    ashi_rdata <= METACOMMAND[ 1 * 32 +: 32];
                REG_MCOMMAND_02:    ashi_rdata <= METACOMMAND[ 2 * 32 +: 32];
                REG_MCOMMAND_03:    ashi_rdata <= METACOMMAND[ 3 * 32 +: 32];
                REG_MCOMMAND_04:    ashi_rdata <= METACOMMAND[ 4 * 32 +: 32];
                REG_MCOMMAND_05:    ashi_rdata <= METACOMMAND[ 5 * 32 +: 32];
                REG_MCOMMAND_06:    ashi_rdata <= METACOMMAND[ 6 * 32 +: 32];
                REG_MCOMMAND_07:    ashi_rdata <= METACOMMAND[ 7 * 32 +: 32];
                REG_MCOMMAND_08:    ashi_rdata <= METACOMMAND[ 8 * 32 +: 32];
                REG_MCOMMAND_09:    ashi_rdata <= METACOMMAND[ 9 * 32 +: 32];
                REG_MCOMMAND_10:    ashi_rdata <= METACOMMAND[10 * 32 +: 32];
                REG_MCOMMAND_11:    ashi_rdata <= METACOMMAND[11 * 32 +: 32];
                REG_MCOMMAND_12:    ashi_rdata <= METACOMMAND[12 * 32 +: 32];
                REG_MCOMMAND_13:    ashi_rdata <= METACOMMAND[13 * 32 +: 32];
                REG_MCOMMAND_14:    ashi_rdata <= METACOMMAND[14 * 32 +: 32];
                REG_MCOMMAND_15:    ashi_rdata <= METACOMMAND[15 * 32 +: 32];

                // Reads of any other register are a decode-error
                default: ashi_rresp <= DECERR;
            endcase
        end
    end
    //==========================================================================



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


endmodule
