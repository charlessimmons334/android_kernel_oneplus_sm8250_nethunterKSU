#!/system/bin/sh

TOGGLE=/data/disable_bypass
LOG=/data/spoof.log

if [ -f $TOGGLE ]; then
  echo "[!] Spoofing disabled by toggle" > $LOG
  exit 0
fi

echo "[+] Starting KernelSU spoofing" > $LOG

# Spoof dangerous props
setprop persist.ksu.spoof.debuggable 0
setprop persist.ksu.spoof.secure 1
setprop persist.ksu.spoof.boot.vbmeta.device_state locked
setprop persist.ksu.spoof.boot.verifiedbootstate green

# Block dangerous paths
setprop persist.ksu.block.paths "/system/xbin/su:/data/adb:/proc/self/mountinfo"

# Load kernel modules
/system/bin/sh /data/adb/ksu/kpm/chatgptksu/common/ko-loader.sh >> $LOG 2>&1
