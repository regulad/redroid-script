# Adds rote66/redroid_libhoudini_hack's two init.rc lines to a redroid init.rc,
# where the hack's own 16.0.0 init.rc has them: right after the
# perform_apex_config that runs once the APEXes are active, which is when
# linkerconfig has written the ld.config.txt files the two lines patch.
{ print }
$0 == "    perform_apex_config" {
    found++
    print ""
    print "    # Patch ld.config.txt after apex_config (rote66/redroid_libhoudini_hack)"
    print "    exec -- /system/bin/sh -c \"/system/bin/patch /linkerconfig/ld.config.txt < /system/etc/ld_config.patch\""
    print "    exec -- /system/bin/sh -c \"/system/bin/patch /linkerconfig/com.android.media.swcodec/ld.config.txt < /system/etc/ld_config_swcodec.patch\""
}
END {
    if (found != 1) {
        printf "patch-linkerconfig.awk: expected one bare perform_apex_config line, found %d\n", found > "/dev/stderr"
        exit 1
    }
}
