# Vivado auto-sync script:
# - Tracks src/, tb/, and sim/ recursively
# - Refreshes sources_1 and sim_1 when files are added/removed/modified
# - Starts automatically when sourced
#
# Usage in Vivado Tcl Console:
#   source auto_sync_project.tcl
#   auto_sync_stop
#   auto_sync_start 3000

if {[current_project -quiet] eq ""} {
    puts "ERROR: No project is currently open. Open riscv-32im.xpr first."
    return -code error
}

set auto_sync_running 0
set auto_sync_interval_ms 3000
set auto_sync_last_src_sig [list]
set auto_sync_last_sim_sig [list]

proc auto_sync_simulation_active {} {
    set sim_active 0

    if {![catch {set cur_sim [current_sim -quiet]}] && ($cur_sim ne "")} {
        set sim_active 1
    }

    if {!$sim_active} {
        if {![catch {set sim_run [get_runs -quiet sim_1]}] && ([llength $sim_run] > 0)} {
            set status ""
            if {![catch {set status [get_property STATUS $sim_run]}]} {
                if {[string match -nocase "*Running*" $status] ||
                    [string match -nocase "*Queued*"  $status] ||
                    [string match -nocase "*Launch*"  $status]} {
                    set sim_active 1
                }
            }
        }
    }

    return $sim_active
}

proc auto_sync_collect_files {root patterns} {
    set files [list]
    if {![file isdirectory $root]} {
        return $files
    }

    foreach p $patterns {
        set matches [glob -nocomplain -types f [file join $root $p]]
        if {[llength $matches] > 0} {
            set files [concat $files $matches]
        }
    }

    foreach d [glob -nocomplain -types d [file join $root *]] {
        set nested [auto_sync_collect_files $d $patterns]
        if {[llength $nested] > 0} {
            set files [concat $files $nested]
        }
    }

    return [lsort -unique $files]
}

proc auto_sync_signature {files} {
    set sig [list]
    foreach f [lsort -unique $files] {
        if {[file exists $f]} {
            lappend sig "$f|[file size $f]|[file mtime $f]"
        }
    }
    return $sig
}

proc auto_sync_refresh_project {} {
    global auto_sync_last_src_sig auto_sync_last_sim_sig

    if {[current_project -quiet] eq ""} {
        puts "WARN: No open project; sync skipped."
        return 0
    }

    if {[auto_sync_simulation_active]} {
        return 0
    }

    set project_dir [file normalize [get_property DIRECTORY [current_project]]]
    set src_dir     [file normalize [file join $project_dir src]]
    set tb_dir      [file normalize [file join $project_dir tb]]
    set sim_dir     [file normalize [file join $project_dir sim]]

    set src_patterns [list *.v *.sv *.vh *.vhd *.vhdl *.xci *.bd]
    set sim_patterns [list *.v *.sv *.vh *.vhd *.vhdl *.hex *.mem *.coe]

    set src_files [auto_sync_collect_files $src_dir $src_patterns]
    set tb_files  [auto_sync_collect_files $tb_dir $sim_patterns]
    set sim_only_files [auto_sync_collect_files $sim_dir $sim_patterns]
    set sim_files [lsort -unique [concat $tb_files $sim_only_files]]

    set src_sig [auto_sync_signature $src_files]
    set sim_sig [auto_sync_signature $sim_files]

    if {($src_sig eq $auto_sync_last_src_sig) && ($sim_sig eq $auto_sync_last_sim_sig)} {
        return 0
    }

    set src_top [get_property top [get_filesets sources_1]]
    set sim_top [get_property top [get_filesets sim_1]]

    set src_existing [get_files -quiet -of_objects [get_filesets sources_1]]
    if {[llength $src_existing] > 0} {
        remove_files -fileset sources_1 $src_existing
    }

    set sim_existing [get_files -quiet -of_objects [get_filesets sim_1]]
    if {[llength $sim_existing] > 0} {
        remove_files -fileset sim_1 $sim_existing
    }

    if {[llength $src_files] > 0} {
        add_files -fileset sources_1 $src_files
    }
    if {[llength $sim_files] > 0} {
        add_files -fileset sim_1 $sim_files
    }

    if {$src_top ne ""} {
        catch {set_property top $src_top [get_filesets sources_1]}
    } else {
        catch {set_property top top_fpga [get_filesets sources_1]}
    }

    if {$sim_top ne ""} {
        catch {set_property top $sim_top [get_filesets sim_1]}
    }

    update_compile_order -fileset sources_1
    update_compile_order -fileset sim_1

    set auto_sync_last_src_sig $src_sig
    set auto_sync_last_sim_sig $sim_sig

    puts "Auto-sync: refreshed sources_1 ([llength $src_files] files), sim_1 ([llength $sim_files] files)."
    return 1
}

proc auto_sync_tick {} {
    global auto_sync_running auto_sync_interval_ms
    if {!$auto_sync_running} {
        return
    }

    if {[catch {auto_sync_refresh_project} err]} {
        puts "WARN: auto-sync failed: $err"
    }

    after $auto_sync_interval_ms auto_sync_tick
}

proc auto_sync_start {{interval_ms 3000}} {
    global auto_sync_running auto_sync_interval_ms
    if {$auto_sync_running} {
        set auto_sync_interval_ms $interval_ms
        puts "Auto-sync already enabled (interval updated to $auto_sync_interval_ms ms)."
        return
    }
    set auto_sync_interval_ms $interval_ms
    set auto_sync_running 1
    puts "Auto-sync enabled (every $auto_sync_interval_ms ms)."
    auto_sync_tick
}

proc auto_sync_stop {} {
    global auto_sync_running
    set auto_sync_running 0
    puts "Auto-sync disabled."
}

auto_sync_start 3000
