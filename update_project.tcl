if {[current_project -quiet] eq ""} {
    puts "ERROR: No project is currently open. Open riscv-32im.xpr first."
    return -code error
}

set project_dir [file normalize [get_property DIRECTORY [current_project]]]
set project_name [get_property NAME [current_project]]
set src_dir     [file normalize [file join $project_dir src]]
set mod_dir     [file normalize [file join $src_dir modules]]
set tb_dir      [file normalize [file join $project_dir tb]]
set sim_dir     [file normalize [file join $project_dir sim]]

set src_existing [get_files -of_objects [get_filesets sources_1]]
if {[llength $src_existing] > 0} {
    if {[catch {remove_files -fileset sources_1 $src_existing} err]} {
        puts "WARN: sources_1 refresh skipped (busy): $err"
    }
}

set sim_existing [get_files -of_objects [get_filesets sim_1]]
if {[llength $sim_existing] > 0} {
    if {[catch {remove_files -fileset sim_1 $sim_existing} err]} {
        puts "WARN: sim_1 refresh skipped (busy): $err"
    }
}

set src_files [list \
    [file join $src_dir opcode.vh] \
    [file join $src_dir pipeline.v] \
    [file join $src_dir top_fpga.v] \
]
set module_files [glob -nocomplain [file join $mod_dir *.v]]
set src_files [concat $src_files $module_files]

if {[llength $src_files] > 0} {
    if {[catch {add_files -fileset sources_1 $src_files} err]} {
        puts "WARN: add_files sources_1 failed: $err"
    }
}

set tb_v_files   [glob -nocomplain [file join $tb_dir *.v]]
set tb_hex_files [glob -nocomplain [file join $tb_dir *.hex]]
set sim_hex_files [glob -nocomplain [file join $sim_dir *.hex]]
set root_hex_files [glob -nocomplain [file join $project_dir *.hex]]
set sim_files [lsort -unique [concat $tb_v_files $tb_hex_files $sim_hex_files $root_hex_files]]

if {[llength $sim_files] > 0} {
    if {[catch {add_files -fileset sim_1 $sim_files} err]} {
        puts "WARN: add_files sim_1 failed: $err"
    }

    catch {set_property used_in_synthesis false $sim_files}
    catch {set_property used_in_implementation false $sim_files}
    catch {set_property used_in_simulation true $sim_files}
}

set_property top top_fpga [get_filesets sources_1]

set_property INCREMENTAL 0 [get_filesets sim_1]

if {[catch {update_compile_order -fileset sources_1} err]} {
    puts "WARN: update_compile_order(sources_1) failed: $err"
}
if {[catch {update_compile_order -fileset sim_1} err]} {
    puts "WARN: update_compile_order(sim_1) skipped: $err"
}

set xsim_dir [file join $project_dir "${project_name}.sim" sim_1 behav xsim]
if {[file isdirectory $xsim_dir]} {
    foreach f {xvlog.pb xelab.pb xvhdl.pb xvlog.log compile.log} {
        set p [file join $xsim_dir $f]
        if {[file exists $p]} {
            catch {file delete -force $p}
        }
    }
}

puts "Project update complete: sources_1 and sim_1 refreshed from src/, tb/, and sim/."
