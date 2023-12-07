base=tb_bc_emu
dest=bitstream

mkdir $dest 2>/dev/null


cp axi_uart_a7.runs/impl_1/design_1_wrapper.bit ${dest}/${base}.bit
cp axi_uart_a7.runs/impl_1/design_1_wrapper.ltx ${dest}/${base}.ltx

