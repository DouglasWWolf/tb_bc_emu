for filename in *.v; do
   remotefn=/fpga/sidewinder_bc_emu/src/$filename
   if [ -f $remotefn ]; then
       echo Copying $filename
       cp $remotefn .
   fi
done
