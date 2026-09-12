# Run this file from Capture's Tcl Command Window after opening a DSN.
package require Tcl 8.4
set ::CAPCHECK_LIBRARY_ONLY 1
set capcheckScriptDir [file dirname [info script]]
source [file join $capcheckScriptDir capture_export_all.tcl]
unset ::CAPCHECK_LIBRARY_ONLY
if {[catch {set capcheckOutput [::capcheck::mainActive]} capcheckMessage]} {
    puts "CapCheck export failed: $capcheckMessage"
} else {
    puts "CapCheck export completed: $capcheckOutput"
    set capcheckChecker [file normalize [file join $capcheckScriptDir .. Invoke-DSNCheck.ps1]]
    if {[catch {set capcheckReport [exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File $capcheckChecker -OutputDirectory $capcheckOutput]} capcheckCheckMessage]} {
        puts "DSN category check failed: $capcheckCheckMessage"
    } else {
        puts $capcheckReport
    }
}
