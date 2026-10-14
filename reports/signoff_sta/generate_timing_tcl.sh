#!/bin/bash

# Set the base path prefix here
BASE_PATH="/homes/projects/digital-vlsi-cad-files/tsmc18"

# Resolve project path
PROJECT_PATH="../"
PROJECT_PATH=$(realpath "$PROJECT_PATH")

# Output file name
OUTPUT_FILE="timing.tcl"

# Create the run file
cat > "$OUTPUT_FILE" <<EOF
set_db design_process_node 180
set_multi_cpu_usage -local_cpu 8
read_mmmc ${PROJECT_PATH}/build/par-rundir/mmmc.tcl
read_physical -lef { /home/lab.apps/vlsiapps/kits/tsmc/N180RF/core_cell_library/7-track/tcb018gbwp7t_290a/TSMCHOME/digital/Back_End/lef/tcb018gbwp7t_270a/lef/tcb018gbwp7t_6lm.lef /homes/projects/digital-vlsi-cad-files/tsmc18/tsmc18/tpd018nv_6lm_modified.lef /homes/lab.apps/vlsiapps/kits/tsmc/N180RF/Standard_IO/tpd018nv_280a/TSMCHOME/digital/../../../tpb018v_190a/TSMCHOME/digital/Back_End/lef/tpb018v_190a/cup/6lm/lef/tpb018v_6lm.lef }
read_netlist { ${PROJECT_PATH}/build/par-rundir/chip_top.lvs.v } -top chip_top
read_power_intent -cpf ${PROJECT_PATH}/signoff_sta/power_spec.cpf
commit_power_intent
init_design
read_spef ${PROJECT_PATH}/rcx/chip_top_signoff_25C.spef -rc_corner NCCOM.extra_rc
read_spef ${PROJECT_PATH}/rcx/chip_top_signoff_25C.spef -rc_corner WCCOM.setup_rc
read_spef ${PROJECT_PATH}/rcx/chip_top_signoff_25C.spef -rc_corner BCCOM.hold_rc
set_db timing_analysis_cppr both
set_db timing_analysis_type ocv
set_db timing_analysis_graph_pba_mode true
set_db si_num_iteration 3
set_db si_delay_enable_report true
set_db si_delay_separate_on_data true
set_db si_delay_enable_logical_correlation true
set_db si_glitch_enable_report true
set_db si_enable_glitch_propagation true
set_db si_enable_glitch_overshoot_undershoot true
set_db delaycal_enable_si true
set_db timing_enable_timing_window_pessimism_removal true
check_noise
write_db -overwrite pre_run_sta
ln -sfn pre_run_sta latest
set_db timing_report_timing_header_detail_info extended
report_timing -retime path_slew_propagation -max_paths 100 > chip_top_timing_setup.rpt
report_timing -check_type hold -retime path_slew_propagation -max_paths 100 > chip_top_timing_hold.rpt
report_timing -unconstrained -debug unconstrained -max_paths 100 > chip_top_timing_unconstrained.rpt
report_noise -delay max -out_file max_si_delay
report_noise -delay min -out_file min_si_delay
report_noise -out_file glitch -threshold 0.05
report_noise -histogram
write_db -overwrite post_run_sta
ln -sfn post_run_sta latest
exit
EOF

echo "tempus tcl file generated as '$OUTPUT_FILE'"
