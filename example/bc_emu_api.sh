#==============================================================================
#  Date      Vers  Who  Description
# -----------------------------------------------------------------------------
# 06-Dec-23  1.00  DWW  Initial Creation
#==============================================================================
BC_EMU_API_VERSION=1.00

#==============================================================================
# AXI register definitions
#==============================================================================
          REG_CTRL=0x1004
        REG_STATUS=0x1004
       REG_LOAD_F0=0x1008
        REG_COUNT0=0x1008
       REG_LOAD_F1=0x100C
        REG_COUNT1=0x100C
         REG_START=0x1010
REG_CYCLES_PER_PKT=0x1014
REG_PKTS_PER_FRAME=0x1018
         REG_VALUE=0x1040

 REG_FD_RING_ADDRH=0x2004
 REG_FD_RING_ADDRL=0x2008
 REG_FD_RING_SIZEH=0x200C
 REG_FD_RING_SIZEL=0x2010

 REG_MC_RING_ADDRH=0x2014
 REG_MC_RING_ADDRL=0x2018
 REG_MC_RING_SIZEH=0x201C
 REG_MC_RING_SIZEL=0x2020
      REG_FC_ADDRH=0x2024
      REG_FC_ADDRL=0x2028

REG_PKTS_PER_GROUP=0x202C
REG_BYTES_PER_USEC=0x2030
   REG_METACOMMAND=0x2040

# Ethernet configuration and status register offsets
          OFFS_ETH_RESET=0x0004
      OFFS_ETH_CONFIG_TX=0x000C
      OFFS_ETH_CONFIG_RX=0x0014
       OFFS_ETH_LOOPBACK=0x0090
        OFFS_ETH_STAT_RX=0x0204
OFFS_ETH_RSFEC_CONFIG_IC=0x1000
   OFFS_ETH_RSFEC_CONFIG=0x107C
#==============================================================================


#==============================================================================
# This strips underscores from a string and converts it to decimal
#==============================================================================
strip_underscores()
{
    local stripped=$(echo $1 | sed 's/_//g')
    echo $((stripped))
}
#==============================================================================


#==============================================================================
# This displays the upper 32 bits of an integer
#==============================================================================
upper32()
{
    local value=$(strip_underscores $1)
    echo $(((value >> 32) & 0xFFFFFFFF))
}
#==============================================================================


#==============================================================================
# This displays the lower 32 bits of an integer
#==============================================================================
lower32()
{
    local value=$(strip_underscores $1)
    echo $((value & 0xFFFFFFFF))
}
#==============================================================================


#==============================================================================
# This calls the local copy of pcireg
#==============================================================================
pcireg()
{
    axireg $1 $2 $3 $4 $5 $6
}
#==============================================================================


#==============================================================================
# This reads a PCI register and displays its value in decimal
#==============================================================================
read_reg()
{
    # Capture the value of the AXI register
    text=$(pcireg $1)

    # Extract just the first word of that text
    text=($text)

    # Convert the text into a number
    value=$((text))

    # Hand the value to the caller
    echo $value
}
#==============================================================================


#==============================================================================
# Displays 1 if bitstream is loaded, otherwise displays "0"
#==============================================================================
is_bitstream_loaded()
{
    reg=$(read_reg $REG_LOAD_F0)
    test $reg -ne $((0xFFFFFFFF)) && echo "1" || echo "0"
}
#==============================================================================


#==============================================================================
# Loads the bitstream into the FPGA
#
# Returns 0 on success, non-zero on failure
#==============================================================================
load_bitstream()
{
    sudo ./load_bitstream -hot_reset $1 1>&2
    return $?
}
#==============================================================================



#==============================================================================
# Define the geometry of a data frame
#
# $1 = Number of bytes per packet (must be a power of 2: 64 <= value <= 8192)
# $2 = Number of packets per frame
#==============================================================================
define_frame()
{
    # Define the number of data-cycles per packet
    pcireg $REG_CYCLES_PER_PKT $(($1 / 64))

    # Define the number of packets per data frame
    pcireg $REG_PKTS_PER_FRAME $2
}
#==============================================================================


#==============================================================================
# Define the number of packets in a single burst of the ping-ponger
#==============================================================================
set_ping_pong_group()
{
    pcireg $REG_PKTS_PER_GROUP $1
}
#==============================================================================


#==============================================================================
# Displays the number of packets in a ping-ponger burst
#==============================================================================
get_ping_pong_group()
{
    read_reg $REG_PKTS_PER_GROUP
}
#==============================================================================


#==============================================================================
# Set the maximum output bandwidth in bytes per microsecond
#
# The rate should be evenly divisible by 64
#==============================================================================
set_rate_limit()
{
    pcireg $REG_BYTES_PER_USEC $1
}
#==============================================================================


#==============================================================================
# Gets and displays the maximum output bandwidth in bytes per microsecond
#==============================================================================
get_rate_limit()
{
    read_reg $REG_BYTES_PER_USEC
}
#==============================================================================


#==============================================================================
# This configures the address and size of the frame-data ring buffer
#
# $1 = Address of the ring buffer
# $2 = Size of the ring buffer in bytes
#==============================================================================
define_fd_ring()
{
    # Store the address of the ring buffer
    pcireg $REG_FD_RING_ADDRH $(upper32 $1)
    pcireg $REG_FD_RING_ADDRL $(lower32 $1)

    # Store the size of the ring buffer
    pcireg $REG_FD_RING_SIZEH $(upper32 $2)
    pcireg $REG_FD_RING_SIZEL $(lower32 $2)
}
#==============================================================================


#==============================================================================
# This configures the address and size of the meta-command ring buffer
#
# $1 = Address of the ring buffer
# $2 = Size of the ring buffer in bytes
#==============================================================================
define_mc_ring()
{
    # Store the address of the ring buffer
    pcireg $REG_MC_RING_ADDRH $(upper32 $1)
    pcireg $REG_MC_RING_ADDRL $(lower32 $1)

    # Store the size of the ring buffer
    pcireg $REG_MC_RING_SIZEH $(upper32 $2)
    pcireg $REG_MC_RING_SIZEL $(lower32 $2)
}
#==============================================================================


#==============================================================================
# This configures the address where the frame counter is stored
#==============================================================================
set_frame_counter_addr()
{
    pcireg $REG_FC_ADDRH $(upper32 $1)
    pcireg $REG_FC_ADDRL $(lower32 $1)        
}
#==============================================================================


#==============================================================================
# This displays the number of the active FIFO, or "0" if neither is active
#==============================================================================
get_active_fifo()
{
    read_reg $REG_START
}
#==============================================================================


#==============================================================================
# This waits for the specified FIFO to become active
#
# $1 should be 0, 1, or 2
#==============================================================================
wait_active_fifo()
{
    local which_fifo=$1

    # Validate the input parameter    
    if [ -z $which_fifo ]; then
        echo "Missing parameter on wait_active_fifo()" 1>&2
        return 
    elif [ $which_fifo -lt 0 ] || [ $which_fifo -gt 2 ]; then
        echo "Bad parameter [$which_fifo] on wait_active_fifo()" 1>&2
        return 
    fi

    # Wait for the specified FIFO to become active
    while [ $(read_reg $REG_START) -ne $which_fifo ]; do
        sleep .1
    done
}
#==============================================================================




#==============================================================================
# This stops all data output and causes the system to go idle
#==============================================================================
idle_system()
{
    # Make the system go idle when the current bright-cycle has been emitted
    pcireg $REG_START 0

    # Wait for the current bright-cycle to finish being sent
    wait_active_fifo 0
}
#==============================================================================



#==============================================================================
# This clears one or both frame-data input FIFOs
#
# $1 should be 1, 2, or "both"
#==============================================================================
clear_fifo()
{
    local which_fifo=$1
    
    # A missing parameter or the word "both" means "clear them both"
    test "$which_fifo" == "both" && which_fifo=3
    test "$which_fifo" == ""     && which_fifo=3

 
    if [ $which_fifo -ge 1 ] && [ $which_fifo -le 3 ]; then
        pcireg $REG_CTRL $which_fifo
    else
        echo "Bad parameter [$1] on clear_fifo()" 1>&2
    fi
}
#==============================================================================


#==============================================================================
# This returns the number of entries in the specified FIFO
#==============================================================================
get_fifo_count()
{
    local which_fifo=$1
    
    if [ -z $which_fifo ]; then
        echo "Missing parameter on get_fifo_count()" 1>&2
        echo 0
    elif [ $which_fifo -eq 1 ]; then
        read_reg $REG_COUNT0
    elif [ $which_fifo -eq 2 ]; then
        read_reg $REG_COUNT1
    else
        echo "Bad parameter [$1] on get_fifo_count()" 1>&2
        echo 0
    fi
}
#==============================================================================


#==============================================================================
# This loads data info one of the FIFOS
#==============================================================================
load_fifo()
{
    local which_fifo=$1
    local filename=$2

    # Validate the fifo #
    if [ -z $which_fifo ]; then
        echo "Missing parameter on load_fifo()" 1>&2
        return 
    elif [ $which_fifo -lt 1 ] || [ $which_fifo -gt 2 ]; then
        echo "Bad parameter [$which_fifo] on load_fifo()" 1>&2
        return 
    fi

    # Make sure the caller gave us a filename
    if [ -z $filename ]; then
        echo "Missing filename on load_fifo()" 1>&2
        return
    fi

    # Make sure the file actually exists
    if [ ! -f $filename ]; then
        echo "not found: $filename" 1>&2
        return
    fi

    # And load the data
    ./load_bc_emu $which_fifo $filename 2>&1
}
#==============================================================================


#==============================================================================
# This stores an immediate value into one of the FIFOS
#==============================================================================
load_fifo_imm()
{
    local which_fifo=$1
    local value=$2

    # Make sure the caller gave us a value
    if [ -z $value ]; then
        echo "Missing value on load_fifo()" 1>&2
        return
    fi

    # Validate the fifo #
    if [ "$which_fifo" == "1" ]; then
        pcireg $REG_LOAD_F0 $value
    elif [ "$which_fifo" == "2" ]; then
        pcireg $REG_LOAD_F1 $value
    else
        echo "Bad parameter [$which_fifo] on load_fifo_imm()" 1>&2
    fi

}
#==============================================================================





#==============================================================================
# This will start generating data-frames from the specified FIFO
#==============================================================================
start_fifo()
{
    local which_fifo=$1

    # Validate the fifo #
    if [ -z $which_fifo ]; then
        echo "Missing parameter on start_fifo()" 1>&2
        return 
    elif [ $which_fifo -lt 1 ] || [ $which_fifo -gt 2 ]; then
        echo "Bad parameter [$which_fifo] on start_fifo()" 1>&2
        return 
    fi

    # And tell the FPGA to start generating frames from this FIFO
    pcireg $REG_START $which_fifo
}
#==============================================================================



#==============================================================================
# Displays the PCS-lock status of an Ethernet port
#
# $1 = 0, 1 or blank (blank = both)
#
# Displays "1" if the selected Ethernet port has PCS-lock, else displays 0
#==============================================================================
get_pcs_status()
{
    local eth0_pcs_lock=0
    local eth1_pcs_lock=0

    # Fetch the status of Ethernet port 0
    local eth0_status=$(read_reg $((0x10000 + $OFFS_ETH_STAT_RX)))
    
    # Fetch the status of Ethernet port 1
    local eth1_status=$(read_reg $((0x20000 + $OFFS_ETH_STAT_RX)))

    # Check the STAT_RX register to see if we have PCS lock
    test $eth0_status -eq 3 && eth0_pcs_lock=1
    test $eth1_status -eq 3 && eth1_pcs_lock=1

    # Display the requested status
    if [ "$1" == "0" ]; then
        echo $eth0_pcs_lock
    elif [ "$1" == "1" ]; then
        echo $eth1_pcs_lock
    else
        echo $((eth0_pcs_lock & eth1_pcs_lock))
    fi
}
#==============================================================================


#==============================================================================
# Get PCS-lock with the Ethernet-partner
#
# $1 = 0 or 1
#
# Returns 0 on success
#==============================================================================
align_pcs()
{
    local port=$1
    local base_addr

    # Validate the port number and determine the base address of the registers
    if [ "$port" = "0" ]; then
        base_addr=0x10000
    elif [ "$port" = "1" ]; then
        base_addr=0x20000
    else
        echo "Bad port number [$port] passed to align_pcs()" 2>&1
        return 1
    fi

    # If we already have PCS lock on this port, just enable the 
    # transmitter and receiver
    if [ $(get_pcs_status $port) -eq 1 ]; then
        pcireg $((base_addr + OFFS_ETH_CONFIG_TX)) 1
        pcireg $((base_addr + OFFS_ETH_CONFIG_RX)) 1        
        return 0
    fi

    # Disable the Ethernet transmitter
    pcireg $((base_addr + OFFS_ETH_CONFIG_TX)) 1

    # Enable RS-FEC indication and correction
    pcireg $((base_addr + OFFS_ETH_RSFEC_CONFIG_IC)) 3

    # Enable RS-FEC on both TX and RX
    pcireg $((base_addr + OFFS_ETH_RSFEC_CONFIG)) 3

    # Reset the Ethernet core to make the RS-FEC settings take effect
    pcireg $((base_addr + OFFS_ETH_RESET)) 0xC0000000
    pcireg $((base_addr + OFFS_ETH_RESET)) 0x00000000

    # Enable the Ethernet receiver
    pcireg $((base_addr + OFFS_ETH_CONFIG_RX)) 1

    # Enable the transmission of RFI (Remote Fault Indicator)
    pcireg $((base_addr + OFFS_ETH_CONFIG_TX)) 2

    # Wait for PCS lock negotiation with the peer
    for n in {1..150}; do
        test $(get_pcs_status $port) -eq 1 && break;
        sleep .1
    done

    # Enable the Ethernet transmitter
    pcireg $((base_addr + OFFS_ETH_CONFIG_TX)) 1

    # Tell the caller if we have PCS lock
    test $(get_pcs_status $port) -eq 1 && return 0

    # If we get here, we do NOT have PCS lock
    return 1
}
#==============================================================================


#==============================================================================
# This ensures PCS-lock on both QSFP ports
#==============================================================================
init_ethernet()
{
    align_pcs 0
    if [ $? -ne 0 ]; then
        echo "Alignment failed on QSFP port 0.  Stopping." 1>&2
        exit 1
    fi
    
    align_pcs 1
    if [ $? -ne 0 ]; then
        echo "Alignment failed on QSFP port 1.  Stopping." 1>&2
        exit 1
    fi
}
#==============================================================================


