#!/system/bin/sh
LOG=/data/initd.log
echo "[init.d] Boot start" > $LOG
if [ -d /system/etc/init.d ]; then
  run-parts /system/etc/init.d >> $LOG 2>&1
fi
