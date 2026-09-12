# Convenience wrapper: export the active DSN, then check the exported files.
# For strict separation, use capture_export_active.tcl followed by Run-DSNCheck.ps1.
package require Tcl 8.4
set ::CAPCHECK_LIBRARY_ONLY 1
set capcheckScriptDir [file dirname [info script]]
source [file join $capcheckScriptDir capture_export_all.tcl]
unset ::CAPCHECK_LIBRARY_ONLY
if {[catch {set capcheckOutput [::capcheck::mainActive]} capcheckMessage]} {
    puts "CapCheck export failed: $capcheckMessage"
} else {
    puts "CapCheck export completed: $capcheckOutput"
    set capcheckChecker [file normalize [file join $capcheckScriptDir .. .. check Run-DSNCheck.ps1]]
    if {[catch {set capcheckReport [exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File $capcheckChecker -InputDirectory $capcheckOutput]} capcheckCheckMessage]} {
        puts "DSN category check failed: $capcheckCheckMessage"
    } else {
        puts $capcheckReport
    }
}
