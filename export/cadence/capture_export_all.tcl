# OrCAD Capture 16.6+ schematic-check data exporter.
#
# Launched by Export-CadenceCheckData.ps1. Paths are passed through process
# environment variables because Capture's command-line Tcl runner does not
# provide a stable cross-version argument convention.

package require Tcl 8.4

namespace eval ::capcheck {
    variable dsn ""
    variable out ""
    variable tclscripts ""
    variable objectsFile ""
    variable propertiesFile ""
    variable errorsFile ""
    variable logFile ""
    variable pages [list]
    variable objectCount 0
    variable propertyCount 0
    variable errorCount 0
    variable nativeIscfStatus "not-run"
    variable pspiceNetlistStatus "not-run"
    variable bundledDrcStatus "not-run"
}

proc ::capcheck::jsonEscape {value} {
    return [string map [list "\\" "\\\\" "\"" "\\\"" "\r" "\\r" "\n" "\\n" "\t" "\\t"] $value]
}

proc ::capcheck::jsonObject {pairs} {
    set fields [list]
    foreach {name value} $pairs {
        lappend fields "\"[::capcheck::jsonEscape $name]\":\"[::capcheck::jsonEscape $value]\""
    }
    return "\{[join $fields ,]\}"
}

proc ::capcheck::writeJson {channel pairs} {
    puts $channel [::capcheck::jsonObject $pairs]
}

proc ::capcheck::log {message} {
    variable logFile
    set channel [open $logFile a+]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel "[clock format [clock seconds] -format {%Y-%m-%d %H:%M:%S}] $message"
    close $channel
    catch {
        set text [DboTclHelper_sMakeCString $message]
        DboState_WriteToSessionLog $text
    }
}

proc ::capcheck::recordError {stage message} {
    variable errorsFile
    variable errorCount
    incr errorCount
    ::capcheck::writeJson $errorsFile [list record error stage $stage message $message]
    ::capcheck::log "ERROR ($stage): $message"
}

proc ::capcheck::fatal {stage message} {
    variable out
    catch {::capcheck::recordError $stage $message}
    set path [file join $out export.error.json]
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    ::capcheck::writeJson $channel [list status failed stage $stage message $message]
    close $channel
    exit 2
}

proc ::capcheck::cstringMethod {object method} {
    set value [DboTclHelper_sMakeCString]
    if {[catch {eval [list $object $method $value]}]} {
        return ""
    }
    if {[catch {set result [DboTclHelper_sGetConstCharPtr $value]}]} {
        return ""
    }
    return $result
}

proc ::capcheck::valueMethod {object method status {default ""}} {
    if {[catch {set value [eval [list $object $method $status]]}]} {
        return $default
    }
    return $value
}

proc ::capcheck::valueNoArg {object method {default ""}} {
    if {[catch {set value [eval [list $object $method]]}]} {
        return $default
    }
    return $value
}

proc ::capcheck::pointXY {point} {
    if {[catch {set x [DboTclHelper_sGetCPointX $point]}]} {
        return [list "" ""]
    }
    if {[catch {set y [DboTclHelper_sGetCPointY $point]}]} {
        return [list "" ""]
    }
    return [list $x $y]
}

proc ::capcheck::pointMethod {object method status} {
    if {[catch {set point [eval [list $object $method $status]]}]} {
        return [list "" ""]
    }
    return [::capcheck::pointXY $point]
}

proc ::capcheck::boundingBox {object status} {
    if {[catch {set box [$object GetBoundingBox]}]} {
        if {[catch {set box [$object GetBoundingBox $status]}]} {
            return [list "" "" "" ""]
        }
    }
    if {[catch {set topLeft [DboTclHelper_sGetCRectTopLeft $box]}]} {
        return [list "" "" "" ""]
    }
    if {[catch {set bottomRight [DboTclHelper_sGetCRectBottomRight $box]}]} {
        return [list "" "" "" ""]
    }
    set left [DboTclHelper_sGetCPointX $topLeft]
    set top [DboTclHelper_sGetCPointY $topLeft]
    set right [DboTclHelper_sGetCPointX $bottomRight]
    set bottom [DboTclHelper_sGetCPointY $bottomRight]
    return [list $left $top $right $bottom]
}

proc ::capcheck::emitObject {pairs} {
    variable objectsFile
    variable objectCount
    incr objectCount
    ::capcheck::writeJson $objectsFile $pairs
}

proc ::capcheck::emitProperty {pairs} {
    variable propertiesFile
    variable propertyCount
    incr propertyCount
    ::capcheck::writeJson $propertiesFile $pairs
}

proc ::capcheck::exportUserProperties {object ownerId status} {
    if {[catch {set iterator [$object NewUserPropsIter $status]}]} {
        return
    }
    if {$iterator == "NULL"} {
        return
    }
    if {[catch {set property [$iterator NextUserProp $status]}]} {
        catch {$iterator -delete}
        return
    }
    while {$property != "NULL"} {
        set name [::capcheck::cstringMethod $property GetName]
        set value [::capcheck::cstringMethod $property GetStringValue]
        ::capcheck::emitProperty [list record user_property owner_id $ownerId name $name value $value]
        if {[catch {set property [$iterator NextUserProp $status]}]} {
            break
        }
    }
    catch {$iterator -delete}
}

proc ::capcheck::exportDisplayProperties {object ownerId status} {
    if {[catch {set iterator [$object NewDisplayPropsIter $status]}]} {
        return
    }
    if {$iterator == "NULL"} {
        return
    }
    if {[catch {set property [$iterator NextProp $status]}]} {
        catch {$iterator -delete}
        return
    }
    set index 0
    while {$property != "NULL"} {
        incr index
        set id "$ownerId/display_property/$index"
        set name [::capcheck::cstringMethod $property GetName]
        set value [::capcheck::cstringMethod $property GetStringValue]
        set xy [::capcheck::pointMethod $property GetLocation $status]
        set bbox [::capcheck::boundingBox $property $status]
        ::capcheck::emitProperty [list record display_property id $id owner_id $ownerId name $name value $value x [lindex $xy 0] y [lindex $xy 1] left [lindex $bbox 0] top [lindex $bbox 1] right [lindex $bbox 2] bottom [lindex $bbox 3]]
        if {[catch {set property [$iterator NextProp $status]}]} {
            break
        }
    }
    catch {$iterator -delete}
}

proc ::capcheck::wireNetName {wire} {
    if {$wire == "NULL" || $wire == ""} {
        return ""
    }
    return [::capcheck::cstringMethod $wire GetNetName]
}

proc ::capcheck::objectsAtPointCount {page point status} {
    if {[catch {set iterator [$page NewObjectsAtPointIter $point $status]}]} {
        return ""
    }
    if {$iterator == "NULL"} {
        return 0
    }
    set count 0
    if {[catch {set object [$iterator NextObject $status]}]} {
        catch {$iterator -delete}
        return ""
    }
    while {$object != "NULL"} {
        if {![catch {set current [$object IsCurrent]}] && $current == 1} {
            incr count
        }
        if {[catch {set object [$iterator NextObject $status]}]} {
            break
        }
    }
    catch {$iterator -delete}
    return $count
}

proc ::capcheck::exportPin {pin ownerId pinIndex pageId status} {
    set id "$ownerId/pin/$pinIndex"
    set name [::capcheck::cstringMethod $pin GetPinName]
    set number [::capcheck::cstringMethod $pin GetPinNumber]
    set pinType [::capcheck::valueMethod $pin GetPinType $status]
    set noConnect [::capcheck::valueMethod $pin GetIsNoConnect $status]
    set visible [::capcheck::valueMethod $pin GetIsVisible $status]
    set hotspot [::capcheck::pointMethod $pin GetHotSpot $status]
    set offsetHotspot [::capcheck::pointMethod $pin GetOffsetHotSpot $status]
    set wire "NULL"
    catch {set wire [$pin GetWire $status]}
    set netName [::capcheck::wireNetName $wire]
    set connected [expr {$wire != "NULL" && $wire != ""}]
    ::capcheck::emitObject [list record pin id $id page_id $pageId owner_id $ownerId name $name number $number pin_type $pinType no_connect $noConnect visible $visible connected $connected net_name $netName hot_x [lindex $hotspot 0] hot_y [lindex $hotspot 1] offset_hot_x [lindex $offsetHotspot 0] offset_hot_y [lindex $offsetHotspot 1]]
    ::capcheck::exportUserProperties $pin $id $status
    ::capcheck::exportDisplayProperties $pin $id $status
}

proc ::capcheck::exportPart {instance id pageId status} {
    set objectType [::capcheck::valueNoArg $instance GetObjectType]
    set reference [::capcheck::cstringMethod $instance GetReference]
    set value [::capcheck::cstringMethod $instance GetPartValue]
    set footprint ""
    set sourceLibrary ""
    set sourcePart ""
    set placed "NULL"
    catch {set placed [DboPartInstToDboPlacedInst $instance]}
    if {$placed != "NULL" && $placed != ""} {
        set reference [::capcheck::cstringMethod $placed GetReferenceDesignator]
        set value [::capcheck::cstringMethod $placed GetPartValue]
        set footprint [::capcheck::cstringMethod $placed GetPCBFootprint]
        set sourceLibrary [::capcheck::cstringMethod $placed GetSourceLibName]
        set sourcePart [::capcheck::cstringMethod $placed GetSourcePartName]
    }
    set bbox [::capcheck::boundingBox $instance $status]
    ::capcheck::emitObject [list record part id $id page_id $pageId object_type $objectType reference $reference value $value pcb_footprint $footprint source_library $sourceLibrary source_part $sourcePart left [lindex $bbox 0] top [lindex $bbox 1] right [lindex $bbox 2] bottom [lindex $bbox 3]]
    ::capcheck::exportUserProperties $instance $id $status
    ::capcheck::exportDisplayProperties $instance $id $status

    if {[catch {set iterator [$instance NewPinsIter $status]}]} {
        return
    }
    if {$iterator == "NULL"} {
        return
    }
    set pinIndex 0
    if {[catch {set pin [$iterator NextPin $status]}]} {
        catch {$iterator -delete}
        return
    }
    while {$pin != "NULL"} {
        incr pinIndex
        ::capcheck::exportPin $pin $id $pinIndex $pageId $status
        if {[catch {set pin [$iterator NextPin $status]}]} {
            break
        }
    }
    catch {$iterator -delete}
}

proc ::capcheck::exportWire {wire id page pageId status} {
    set objectType [::capcheck::valueNoArg $wire GetObjectType]
    set netName [::capcheck::wireNetName $wire]
    set pointCount [::capcheck::valueMethod $wire GetPointCount $status 0]
    set startPoint [$wire GetStartPoint $status]
    set endPoint [$wire GetEndPoint $status]
    set start [::capcheck::pointXY $startPoint]
    set end [::capcheck::pointXY $endPoint]
    set bbox [::capcheck::boundingBox $wire $status]
    set startObjects [::capcheck::objectsAtPointCount $page $startPoint $status]
    set endObjects [::capcheck::objectsAtPointCount $page $endPoint $status]
    set isHorizontal [::capcheck::valueMethod $wire IsHorizontal $status]
    set isVertical [::capcheck::valueMethod $wire IsVertical $status]
    set isNonOrthogonal [::capcheck::valueMethod $wire IsNonOrthogonal $status]
    set isZeroLength [::capcheck::valueMethod $wire IsZeroLen $status]
    ::capcheck::emitObject [list record wire id $id page_id $pageId object_type $objectType net_name $netName point_count $pointCount start_x [lindex $start 0] start_y [lindex $start 1] end_x [lindex $end 0] end_y [lindex $end 1] start_object_count $startObjects end_object_count $endObjects horizontal $isHorizontal vertical $isVertical non_orthogonal $isNonOrthogonal zero_length $isZeroLength left [lindex $bbox 0] top [lindex $bbox 1] right [lindex $bbox 2] bottom [lindex $bbox 3]]
    ::capcheck::exportUserProperties $wire $id $status
    ::capcheck::exportDisplayProperties $wire $id $status

    for {set index 0} {$index < $pointCount} {incr index} {
        if {[catch {set point [$wire GetPoint $index $status]}]} {
            continue
        }
        set xy [::capcheck::pointXY $point]
        set isJunction ""
        catch {set isJunction [$wire PointIsJunction $point $status]}
        set junctionOnWire ""
        catch {set junctionOnWire [$wire JunctionOnWire $point]}
        ::capcheck::emitObject [list record wire_point id "$id/point/$index" page_id $pageId owner_id $id index $index x [lindex $xy 0] y [lindex $xy 1] is_junction $isJunction junction_on_wire $junctionOnWire]
    }

    if {![catch {set aliasIter [$wire NewAliasesIter $status]}] && $aliasIter != "NULL"} {
        set aliasIndex 0
        if {![catch {set alias [$aliasIter NextAlias $status]}]} {
            while {$alias != "NULL"} {
                incr aliasIndex
                set aliasId "$id/alias/$aliasIndex"
                set aliasName [::capcheck::cstringMethod $alias GetName]
                set aliasBox [::capcheck::boundingBox $alias $status]
                ::capcheck::emitObject [list record net_alias id $aliasId page_id $pageId owner_id $id name $aliasName left [lindex $aliasBox 0] top [lindex $aliasBox 1] right [lindex $aliasBox 2] bottom [lindex $aliasBox 3]]
                if {[catch {set alias [$aliasIter NextAlias $status]}]} {
                    break
                }
            }
        }
        catch {$aliasIter -delete}
    }
}

proc ::capcheck::exportNetSymbol {object kind id pageId status} {
    set name [::capcheck::cstringMethod $object GetName]
    set netName [::capcheck::cstringMethod $object GetNetName]
    set hotspot [::capcheck::pointMethod $object GetHotSpot $status]
    set bbox [::capcheck::boundingBox $object $status]
    set objectType [::capcheck::valueNoArg $object GetObjectType]
    set pinType [::capcheck::valueMethod $object GetPinType $status]
    ::capcheck::emitObject [list record $kind id $id page_id $pageId object_type $objectType name $name net_name $netName pin_type $pinType hot_x [lindex $hotspot 0] hot_y [lindex $hotspot 1] left [lindex $bbox 0] top [lindex $bbox 1] right [lindex $bbox 2] bottom [lindex $bbox 3]]
    ::capcheck::exportUserProperties $object $id $status
    ::capcheck::exportDisplayProperties $object $id $status
}

proc ::capcheck::exportBusEntry {entry id pageId status} {
    set entryPoint [::capcheck::pointMethod $entry GetEntryPoint $status]
    set endPoint [::capcheck::pointMethod $entry GetEndPoint $status]
    set isBus [::capcheck::valueMethod $entry IsBus $status]
    set isBundle [::capcheck::valueMethod $entry IsBundle $status]
    set entryWire "NULL"
    set endWire "NULL"
    catch {set entryWire [$entry GetEntryWire $status]}
    catch {set endWire [$entry GetEndWire $status]}
    set bbox [::capcheck::boundingBox $entry $status]
    ::capcheck::emitObject [list record bus_entry id $id page_id $pageId entry_x [lindex $entryPoint 0] entry_y [lindex $entryPoint 1] end_x [lindex $endPoint 0] end_y [lindex $endPoint 1] entry_net [::capcheck::wireNetName $entryWire] end_net [::capcheck::wireNetName $endWire] is_bus $isBus is_bundle $isBundle left [lindex $bbox 0] top [lindex $bbox 1] right [lindex $bbox 2] bottom [lindex $bbox 3]]
    ::capcheck::exportUserProperties $entry $id $status
}

proc ::capcheck::exportGraphic {graphic id pageId status} {
    set objectType [::capcheck::valueNoArg $graphic GetObjectType]
    set name [::capcheck::cstringMethod $graphic GetName]
    set bbox [::capcheck::boundingBox $graphic $status]
    ::capcheck::emitObject [list record graphic id $id page_id $pageId object_type $objectType name $name left [lindex $bbox 0] top [lindex $bbox 1] right [lindex $bbox 2] bottom [lindex $bbox 3]]
    ::capcheck::exportUserProperties $graphic $id $status
    ::capcheck::exportDisplayProperties $graphic $id $status
}

proc ::capcheck::exportPage {page schematicName pageIndex status} {
    variable pages
    set pageName [::capcheck::cstringMethod $page GetName]
    set pageId "$schematicName/$pageName"
    set granularity [::capcheck::valueNoArg $page GetPhysicalGranularity]
    lappend pages $page
    ::capcheck::emitObject [list record page id $pageId schematic $schematicName page $pageName index $pageIndex physical_granularity $granularity]

    if {![catch {set iterator [$page NewPartInstsIter $status]}] && $iterator != "NULL"} {
        set index 0
        if {![catch {set object [$iterator NextPartInst $status]}]} {
            while {$object != "NULL"} {
                incr index
                ::capcheck::exportPart $object "$pageId/part/$index" $pageId $status
                if {[catch {set object [$iterator NextPartInst $status]}]} {break}
            }
        }
        catch {$iterator -delete}
    }

    if {![catch {set iterator [$page NewWiresIter $status]}] && $iterator != "NULL"} {
        set index 0
        if {![catch {set object [$iterator NextWire $status]}]} {
            while {$object != "NULL"} {
                incr index
                ::capcheck::exportWire $object "$pageId/wire/$index" $page $pageId $status
                if {[catch {set object [$iterator NextWire $status]}]} {break}
            }
        }
        catch {$iterator -delete}
    }

    foreach spec [list \
        [list global NewGlobalsIter NextGlobal] \
        [list port NewPortsIter NextPort]] {
        set kind [lindex $spec 0]
        set newMethod [lindex $spec 1]
        set nextMethod [lindex $spec 2]
        if {![catch {set iterator [eval [list $page $newMethod $status]]}] && $iterator != "NULL"} {
            set index 0
            if {![catch {set object [eval [list $iterator $nextMethod $status]]}]} {
                while {$object != "NULL"} {
                    incr index
                    ::capcheck::exportNetSymbol $object $kind "$pageId/$kind/$index" $pageId $status
                    if {[catch {set object [eval [list $iterator $nextMethod $status]]}]} {break}
                }
            }
            catch {$iterator -delete}
        }
    }

    if {![catch {set iterator [$page NewOffPageConnectorsIter $status $::IterDefs_ALL]}] && $iterator != "NULL"} {
        set index 0
        if {![catch {set object [$iterator NextOffPageConnector $status]}]} {
            while {$object != "NULL"} {
                incr index
                ::capcheck::exportNetSymbol $object offpage_connector "$pageId/offpage_connector/$index" $pageId $status
                if {[catch {set object [$iterator NextOffPageConnector $status]}]} {break}
            }
        }
        catch {$iterator -delete}
    }

    if {![catch {set iterator [$page NewBusEntriesIter $status]}] && $iterator != "NULL"} {
        set index 0
        if {![catch {set object [$iterator NextBusEntry $status]}]} {
            while {$object != "NULL"} {
                incr index
                ::capcheck::exportBusEntry $object "$pageId/bus_entry/$index" $pageId $status
                if {[catch {set object [$iterator NextBusEntry $status]}]} {break}
            }
        }
        catch {$iterator -delete}
    }

    if {![catch {set iterator [$page NewCommentGraphicsIter $status]}] && $iterator != "NULL"} {
        set index 0
        if {![catch {set object [$iterator NextCommentGraphic $status]}]} {
            while {$object != "NULL"} {
                incr index
                ::capcheck::exportGraphic $object "$pageId/graphic/$index" $pageId $status
                if {[catch {set object [$iterator NextCommentGraphic $status]}]} {break}
            }
        }
        catch {$iterator -delete}
    }

    if {![catch {set iterator [$page NewTitleBlocksIter $status]}] && $iterator != "NULL"} {
        set index 0
        if {![catch {set object [$iterator NextTitleBlock $status]}]} {
            while {$object != "NULL"} {
                incr index
                ::capcheck::exportGraphic $object "$pageId/title_block/$index" $pageId $status
                if {[catch {set object [$iterator NextTitleBlock $status]}]} {break}
            }
        }
        catch {$iterator -delete}
    }
}

proc ::capcheck::runBundledDrc {} {
    variable tclscripts
    variable out
    variable pages
    variable bundledDrcStatus

    if {[info exists ::env(CAPCHECK_SKIP_BUNDLED_DRC)] && $::env(CAPCHECK_SKIP_BUNDLED_DRC) == "1"} {
        set bundledDrcStatus skipped
        return
    }

    lappend ::auto_path [file join $tclscripts capDRCFramework tcl]
    lappend ::auto_path [file join $tclscripts capDRC]
    if {[catch {
        package require capCustomDRC
        package require capProcessDRC
    } message]} {
        set bundledDrcStatus failed
        ::capcheck::recordError bundled_drc_framework $message
        return
    }

    set drcDir [file join $out native_drc]
    file mkdir $drcDir
    set failures 0
    foreach rule [list \
        [list capHangingWires capHangingWires hanging_wires.drc.log] \
        [list capOverlapWires capOverlapWires overlapping_wires.drc.log] \
        [list capInvalidPinNumber capInvalidPinNumber invalid_pin_number.drc.log] \
        [list capPartReferencePrefixMismatch capPartReferencePrefixMismatch reference_prefix.drc.log]] {
        set packageName [lindex $rule 0]
        set namespaceName [lindex $rule 1]
        set logPath [file join $drcDir [lindex $rule 2]]
        set channel [open $logPath w]
        fconfigure $channel -encoding utf-8 -translation lf
        puts $channel "Cadence bundled Custom DRC: $packageName"
        close $channel
        if {[catch {package require $packageName} message]} {
            incr failures
            ::capcheck::recordError "bundled_drc:$packageName" $message
            continue
        }
        capCustomDRC::capSetCreateMarker 0
        capCustomDRC::capSetLogFilePath $logPath
        if {$namespaceName == "capHangingWires"} {
            set ::capHangingWires::WireList [list]
        }
        if {$namespaceName == "capOverlapWires"} {
            set ::capOverlapWires::wireList [list]
        }
        foreach page $pages {
            if {[catch {capProcessDRC::capProcessPageObjects $namespaceName $page} message]} {
                incr failures
                ::capcheck::recordError "bundled_drc:$packageName" $message
            }
        }
    }
    if {$failures == 0} {
        set bundledDrcStatus success
    } else {
        set bundledDrcStatus partial
    }
}

proc ::capcheck::runNativeIscf {} {
    variable dsn
    variable out
    variable tclscripts
    variable nativeIscfStatus

    if {[info exists ::env(CAPCHECK_SKIP_ISCF)] && $::env(CAPCHECK_SKIP_ISCF) == "1"} {
        set nativeIscfStatus skipped
        return
    }

    lappend ::auto_path [file join $tclscripts capISCFExport tcl]
    if {[catch {package require capISCFExport 1.0} message]} {
        set nativeIscfStatus failed
        ::capcheck::recordError native_iscf_package $message
        return
    }
    set nativeDir [file join $out native]
    file mkdir $nativeDir
    set iscfPath [file join $nativeDir design.iscf]
    set logPath [file join $nativeDir design.iscf.log]
    if {[catch {::capISCFExport::ExportDesignInBatch $dsn $iscfPath $logPath} message]} {
        set nativeIscfStatus failed
        ::capcheck::recordError native_iscf_export $message
        return
    }
    if {[file exists $iscfPath] && [file size $iscfPath] > 0} {
        set nativeIscfStatus success
    } else {
        set nativeIscfStatus failed
        ::capcheck::recordError native_iscf_export "ISCF exporter returned without a non-empty design.iscf"
    }
}

# Export ISCF from a design which is already open in the current Capture
# process.  Unlike ExportDesignInBatch, this does not create a DboSession,
# reopen the DSN, or remove the design from Capture afterwards.
proc ::capcheck::runNativeIscfForDesign {design} {
    variable out
    variable tclscripts
    variable nativeIscfStatus

    if {[info exists ::env(CAPCHECK_SKIP_ISCF)] && $::env(CAPCHECK_SKIP_ISCF) == "1"} {
        set nativeIscfStatus skipped
        return
    }

    lappend ::auto_path [file join $tclscripts capISCFExport tcl]
    if {[catch {package require capISCFExport 1.0} message]} {
        set nativeIscfStatus failed
        ::capcheck::recordError native_iscf_package $message
        return
    }
    set nativeDir [file join $out native]
    file mkdir $nativeDir
    set iscfPath [file join $nativeDir design.iscf]
    set logPath [file join $nativeDir design.iscf.log]
    if {[catch {
        ::capISCFExport::ExportDesign $design $iscfPath $logPath
        ::capISCFExport::DumpLogs $logPath
        ::capISCFExport::ClearErrorLog
        ::capDesignPhysicalViewReader::CleanAllocatedMemory
    } message]} {
        set nativeIscfStatus failed
        catch {::capISCFExport::DumpLogs $logPath}
        catch {::capISCFExport::ClearErrorLog}
        ::capcheck::recordError native_iscf_export $message
        return
    }
    if {[file exists $iscfPath] && [file size $iscfPath] > 0} {
        set nativeIscfStatus success
    } else {
        set nativeIscfStatus failed
        ::capcheck::recordError native_iscf_export "ISCF exporter returned without a non-empty design.iscf"
    }
}

proc ::capcheck::runPspiceNetlist { } {
    variable dsn
    variable out
    variable pspiceNetlistStatus

    if {[info exists ::env(CAPCHECK_SKIP_PSPICE_NETLIST)] && $::env(CAPCHECK_SKIP_PSPICE_NETLIST) == "1"} {
        set pspiceNetlistStatus skipped
        return
    }
    set netlistDir [file join $out netlist]
    file mkdir $netlistDir
    set cirPath [file join $netlistDir design.cir]
    set logPath [file join $netlistDir design.pspice_netlist.log]
    set logChannel [open $logPath w]
    fconfigure $logChannel -encoding utf-8 -translation lf
    if {[catch {
        load [file join [file dirname [info nameofexecutable]] orTclNetlist.dll]
        set result [OrTclNetlist_sCreatePSpiceNetList $dsn $cirPath 1 0 0 0 0 1]
        if {$result == 0} {
            set vector [DboTclHelper_sMakeStdVector 0]
            OrTclNetlist_sGetErrorLog $vector
            set vectorSize [DboTclHelper_sGetVectorSize $vector]
            for {set index 0} {$index < $vectorSize} {incr index} {
                puts $logChannel [DboTclHelper_sGetConstCharPtrFromVector $vector $index]
            }
            error "OrTclNetlist_sCreatePSpiceNetList returned failure"
        }
    } message]} {
        puts $logChannel $message
        close $logChannel
        set pspiceNetlistStatus failed
        ::capcheck::recordError pspice_netlist $message
        return
    }
    puts $logChannel "PSpice netlist export completed"
    close $logChannel
    if {[file exists $cirPath] && [file size $cirPath] > 0} {
        set pspiceNetlistStatus success
    } else {
        set pspiceNetlistStatus failed
        ::capcheck::recordError pspice_netlist "PSpice netlist exporter returned without a non-empty design.cir"
    }
}

proc ::capcheck::exportDesign {design status} {
    variable dsn

    set designName [::capcheck::cstringMethod $design GetName]
    ::capcheck::emitObject [list record design id $designName path $dsn]
    ::capcheck::exportUserProperties $design $designName $status

    if {[catch {set schematicIterator [$design NewViewsIter $status $::IterDefs_SCHEMATICS]} message]} {
        error "Cannot iterate design schematics: $message"
    }
    set schematicIndex 0
    if {[catch {set view [$schematicIterator NextView $status]} message]} {
        catch {$schematicIterator -delete}
        error "Cannot read first schematic: $message"
    }
    while {$view != "NULL"} {
        incr schematicIndex
        set schematic [DboViewToDboSchematic $view]
        if {$schematic != "NULL"} {
            set schematicName [::capcheck::cstringMethod $schematic GetName]
            ::capcheck::emitObject [list record schematic id $schematicName design_id $designName index $schematicIndex]
            set pageIterator [$schematic NewPagesIter $status]
            set pageIndex 0
            set page [$pageIterator NextPage $status]
            while {$page != "NULL"} {
                incr pageIndex
                if {[catch {::capcheck::exportPage $page $schematicName $pageIndex $status} message]} {
                    ::capcheck::recordError "page:$schematicName:$pageIndex" $message
                }
                set page [$pageIterator NextPage $status]
            }
            catch {$pageIterator -delete}
        }
        set view [$schematicIterator NextView $status]
    }
    catch {$schematicIterator -delete}
}

proc ::capcheck::initializeOutput {} {
    variable out
    variable objectsFile
    variable propertiesFile
    variable errorsFile
    variable logFile
    variable pages
    variable objectCount
    variable propertyCount
    variable errorCount
    variable nativeIscfStatus
    variable bundledDrcStatus

    set pages [list]
    set objectCount 0
    set propertyCount 0
    set errorCount 0
    set nativeIscfStatus not-run
    set bundledDrcStatus not-run

    file mkdir $out
    file mkdir [file join $out dbo]
    file mkdir [file join $out netlist]
    foreach staleName [list export.ok export.error.json] {
        set stalePath [file join $out $staleName]
        if {[file exists $stalePath] && [file isfile $stalePath]} {
            file delete -force $stalePath
        }
    }
    set logFile [file join $out capture_export.log]
    set channel [open $logFile w]
    fconfigure $channel -encoding utf-8 -translation lf
    puts $channel "Cadence Capture schematic-check export"
    close $channel

    set objectsFile [open [file join $out dbo objects.jsonl] w]
    set propertiesFile [open [file join $out dbo properties.jsonl] w]
    set errorsFile [open [file join $out dbo errors.jsonl] w]
    foreach channel [list $objectsFile $propertiesFile $errorsFile] {
        fconfigure $channel -encoding utf-8 -translation lf
    }
}

proc ::capcheck::closeOutput {} {
    variable objectsFile
    variable propertiesFile
    variable errorsFile
    foreach name [list objectsFile propertiesFile errorsFile] {
        if {[set $name] != ""} {
            catch {close [set $name]}
            set $name ""
        }
    }
}

proc ::capcheck::writeManifest {} {
    variable dsn
    variable out
    variable objectCount
    variable propertyCount
    variable errorCount
    variable nativeIscfStatus
    variable pspiceNetlistStatus
    variable bundledDrcStatus
    set path [file join $out manifest.json]
    set channel [open $path w]
    fconfigure $channel -encoding utf-8 -translation lf
    ::capcheck::writeJson $channel [list schema_version 1.0 status success source_dsn $dsn generated_at [clock format [clock seconds] -format {%Y-%m-%dT%H:%M:%S}] native_iscf $nativeIscfStatus pspice_netlist $pspiceNetlistStatus bundled_custom_drc $bundledDrcStatus dbo_object_records $objectCount dbo_property_records $propertyCount nonfatal_errors $errorCount]
    close $channel
}

proc ::capcheck::main {} {
    variable dsn
    variable out
    variable tclscripts
    variable objectsFile
    variable propertiesFile
    variable errorsFile
    variable logFile

    foreach name [list CAPCHECK_DSN CAPCHECK_OUT CAPCHECK_TCLSCRIPTS] {
        if {![info exists ::env($name)] || $::env($name) == ""} {
            puts "Missing required environment variable: $name"
            exit 2
        }
    }
    set dsn [file normalize $::env(CAPCHECK_DSN)]
    set out [file normalize $::env(CAPCHECK_OUT)]
    set tclscripts [file normalize $::env(CAPCHECK_TCLSCRIPTS)]
    ::capcheck::initializeOutput

    ::capcheck::log "Source DSN: $dsn"
    ::capcheck::runNativeIscf
    ::capcheck::runPspiceNetlist

    set status [DboState]
    set session [DboTclHelper_sCreateSession]
    set designPath [DboTclHelper_sMakeCString $dsn]
    if {[catch {set design [$session GetDesignAndSchematics $designPath $status]} message]} {
        ::capcheck::fatal open_design $message
    }
    if {$design == "NULL"} {
        ::capcheck::fatal open_design "DboSession could not open the DSN"
    }

    if {[catch {::capcheck::exportDesign $design $status} message]} {
        ::capcheck::fatal schematics $message
    }

    ::capcheck::runBundledDrc

    catch {$session RemoveDesign $design}
    catch {$session -delete}
    catch {$status -delete}

    ::capcheck::closeOutput
    ::capcheck::writeManifest
    set ok [open [file join $out export.ok] w]
    puts $ok "ok"
    close $ok
    ::capcheck::log "Export completed"
    exit 0
}

proc ::capcheck::mainActive {} {
    variable dsn
    variable out
    variable tclscripts

    if {[catch {set design [GetActivePMDesign]} message]} {
        error "Cannot get the active Capture design: $message"
    }
    if {$design == "NULL" || $design == ""} {
        error "No active DSN design. Open and activate a schematic design first."
    }

    set dsn [::capcheck::cstringMethod $design GetName]
    if {$dsn == ""} {
        error "The active design did not return a DSN file name"
    }
    set dsn [file normalize $dsn]

    if {[info exists ::CAPCHECK_OUTPUT_DIR] && $::CAPCHECK_OUTPUT_DIR != ""} {
        set out [file normalize $::CAPCHECK_OUTPUT_DIR]
    } else {
        set parent [file dirname $dsn]
        set stem [file rootname [file tail $dsn]]
        set out [file normalize [file join $parent "${stem}_checkdata"]]
    }

    if {[info exists ::CAPCHECK_TCLSCRIPTS] && $::CAPCHECK_TCLSCRIPTS != ""} {
        set tclscripts [file normalize $::CAPCHECK_TCLSCRIPTS]
    } elseif {[info exists ::env(CAPCHECK_TCLSCRIPTS)] && $::env(CAPCHECK_TCLSCRIPTS) != ""} {
        set tclscripts [file normalize $::env(CAPCHECK_TCLSCRIPTS)]
    } elseif {[info exists ::env(CDSROOT)] && $::env(CDSROOT) != ""} {
        set tclscripts [file normalize [file join $::env(CDSROOT) tools capture tclscripts]]
    } else {
        set tclscripts [file normalize [file join [file dirname [info nameofexecutable]] tclscripts]]
    }
    if {![file isdirectory $tclscripts]} {
        error "Cadence tclscripts directory was not found: $tclscripts"
    }

    ::capcheck::initializeOutput
    ::capcheck::log "Source DSN (active Capture design): $dsn"
    ::capcheck::log "Output directory: $out"

    set status [DboState]
    set resultCode [catch {
        ::capcheck::runNativeIscfForDesign $design
        ::capcheck::runPspiceNetlist
        ::capcheck::exportDesign $design $status
        ::capcheck::runBundledDrc
    } resultMessage]
    catch {$status -delete}
    ::capcheck::closeOutput

    if {$resultCode != 0} {
        catch {::capcheck::log "ERROR (active_export): $resultMessage"}
        set errorPath [file join $out export.error.json]
        if {![catch {set errorChannel [open $errorPath w]}]} {
            fconfigure $errorChannel -encoding utf-8 -translation lf
            ::capcheck::writeJson $errorChannel [list status failed stage active_export message $resultMessage]
            close $errorChannel
        }
        error $resultMessage
    }

    ::capcheck::writeManifest
    set ok [open [file join $out export.ok] w]
    puts $ok "ok"
    close $ok
    ::capcheck::log "Export completed; current Capture design was left open"
    return $out
}

if {![info exists ::CAPCHECK_LIBRARY_ONLY] || !$::CAPCHECK_LIBRARY_ONLY} {
    if {[catch {::capcheck::main} message]} {
        catch {::capcheck::fatal unhandled $message}
        puts $message
        exit 2
    }
}
