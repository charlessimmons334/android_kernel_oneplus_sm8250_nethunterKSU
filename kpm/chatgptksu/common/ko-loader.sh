#!/system/bin/sh

# Load all .ko modules from kernel module path
MODULE_PATH=/system/lib/modules
LOGFILE=/data/ko_loader.log

echo "[+] Loading .ko modules..." > $LOGFILE
for module in $(find $MODULE_PATH -name "*.ko"); do
  echo "[*] Loading $module" >> $LOGFILE
  insmod $module >> $LOGFILE 2>&1
done
