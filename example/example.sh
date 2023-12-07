#
# This is an example script that drives the bright-cycle emulator.   
# This script and "bc_emu_api.sh" was written by Doug Wolf
#

# Load our API into our current shell instance
source bc_emu_api.sh

# Make sure the system is idle
idle_system

# Set the output data rate in bytes-per-microsecond. 
set_rate_limit 12288

# Define packet size and packets-per-frame
define_frame 256 4 

# Set the number of packets in a packet-burst on each QSFP
set_ping_pong_group 1

# Define the location and size of the frame-data ring buffer
define_fd_ring 0x0000_0001_0000_0000 0x0000_0000_0400_0000

# Define the location and size of the meta-command ring buffer
define_mc_ring 0x0000_0002_0000_0000 4096

# Define the address where the frame counter is stored
set_frame_counter_addr 0x0000_0003_0000_0000

# Make sure both input FIFOs start out empty
clear_fifo both

# Load frame data into the first FIFO
load_fifo_imm 1 0x11111111
load_fifo_imm 1 0x22222222
load_fifo_imm 1 0x33333333
load_fifo_imm 1 0x44444444

# Start generating frames from the data we just loaded
start_fifo 1
echo "Generating bright cycle frames from FIFO #1"

# While frames are generating from FIFO #1, load FIFO #2 with frame data
load_fifo_imm 2 0xAAAAAAAA
load_fifo_imm 2 0xBBBBBBBB
load_fifo_imm 2 0xCCCCCCCC
load_fifo_imm 2 0xDDDDDDDD

# Let FIFO #1 generate bright cycle frames for a few seconds
sleep 5

# Switch to generating frames from FIFO 2
start_fifo 2

# Just for fun, lets wait for FIFO 2 to become active
echo "Waiting for FIFO #2 to start"
wait_active_fifo 2
echo "Generating bright cycle frames from FIFO #2"

# Let FIFO #2 generate bright cycle frames for a few seconds
sleep 5

# That's the end of our demo!
idle_system
echo "All done!"
