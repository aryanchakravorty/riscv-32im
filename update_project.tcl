# Vivado project file-reference refresh script
# Expected layout:
#   src/opcode.vh
#   src/pipeline.v
#   src/top_fpga.v
#   src/modules/*.v
#   tb/*.v
#   tb/*.hex
#   sim/*.hex

if {[current_project -quiet] eq ""} {
    puts "ERROR: No project is currently open. Open riscv-32im.xpr first."
    return -code error
}

set project_dir [file normalize [get_property DIRECTORY [current_project]]]
set src_dir     [file normalize [file join $project_dir src]]
set mod_dir     [file normalize [file join $src_dir modules]]
set tb_dir      [file normalize [file join $project_dir tb]]
set sim_dir     [file normalize [file join $project_dir sim]]

# Remove all existing file references from sources_1 and sim_1
set src_existing [get_files -of_objects [get_filesets sources_1]]
if {[llength $src_existing] > 0} {
    remove_files -fileset sources_1 $src_existing
}

set sim_existing [get_files -of_objects [get_filesets sim_1]]
if {[llength $sim_existing] > 0} {
    remove_files -fileset sim_1 $sim_existing
}

# Build sources_1 file list
set src_files [list \
    [file join $src_dir opcode.vh] \
    [file join $src_dir pipeline.v] \
    [file join $src_dir top_fpga.v] \
]
set module_files [glob -nocomplain [file join $mod_dir *.v]]
set src_files [concat $src_files $module_files]

if {[llength $src_files] > 0} {
    add_files -fileset sources_1 $src_files
}

# Build sim_1 file list
set tb_v_files   [glob -nocomplain [file join $tb_dir *.v]]
set tb_hex_files [glob -nocomplain [file join $tb_dir *.hex]]
set sim_hex_files [glob -nocomplain [file join $sim_dir *.hex]]
set sim_files [concat $tb_v_files $tb_hex_files $sim_hex_files]

if {[llength $sim_files] > 0} {
    add_files -fileset sim_1 $sim_files
}

# Top module
set_property top top_fpga [get_filesets sources_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

puts "Project update complete: sources_1 and sim_1 refreshed from src/, tb/, and sim/."
