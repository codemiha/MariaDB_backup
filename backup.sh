#!/bin/sh
# Version 1.6 - Dec 19, 2024 - by miha
#
# Instructions:
# - Set the following variables: MYSQL_PASSWORD, BACKDIR, and THREADS.
# - Adjust `KEEP` to define how many full backups are retained.
# - Configure email notifications by setting Sender, Alarm_Subject, Alarm_Recipient, and smtp.
#   If email is not required, leave these variables as they are.
# - Prerequisite: `mailx` must be installed for email notifications (`yum install mailx`).
#
# Suggested cron job for this script:
# 15 3 * * * /root/backup.sh >/dev/null 2>&1
#
# Description:
# This script performs full and incremental backups for a Galera Cluster.

# Email configuration
Sender=""Galera1@customer.net""  # Note: double quotes are required
Alarm_Subject="ABC XYZ Backup Failed!"
Alarm_Recipient="some@email.net"
EmailBody=$(echo -e "The automated backup has failed. \nPlease check:\n- /backup/$(hostname -s)/backup.log\n- /backup/$(hostname -s)/debug_backup.log")
smtp="smtp://192.168.0.2"

# Backup configuration
MYSQL_USER="backup"
MYSQL_PASSWORD="CHANGE_ME"
THREADS=10  # Default: 10
MYSQL_HOST="localhost"
MYSQL_PORT=3306
BACKCMD="mariabackup"
BACKDIR="/var/lib/mysql/mariabackup/"
KEEP=2  # Number of full backups to keep

# Script constants
LOG="$BACKDIR/backup.log"
DLOG="$BACKDIR/debug_backup.log"
FULLBACKUPCYCLE=518400  # Full backup interval in seconds (6 days)
START=$(date +%s)
USEROPTIONS="--user=${MYSQL_USER} --password=${MYSQL_PASSWORD} --host=${MYSQL_HOST} --port=${MYSQL_PORT}"
BASEBACKDIR="$BACKDIR/base"
INCRBACKDIR="$BACKDIR/incr"

# Ensure log files exist
touch $LOG $DLOG
sed -i -e :a -e '$q;N;100000,$D;ba' $DLOG

echo "$(date) STARTED" >> $LOG

# Ensure backup directories exist and are writable
for DIR in $BASEBACKDIR $INCRBACKDIR; do
  mkdir -p $DIR
  if [ ! -d "$DIR" ] || [ ! -w "$DIR" ]; then
    echo "$(date) ERROR: Directory $DIR does not exist or is not writable" >> $LOG
    exit 1
  fi
done

# Check if MariaDB is running
if ! mysqladmin $USEROPTIONS status | grep -q 'Uptime'; then
  echo "$(date) ERROR: MySQL is not running." >> $LOG
  exit 1
fi

# Verify MariaDB credentials
if ! echo 'exit' | mysql -s $USEROPTIONS; then
  echo "$(date) ERROR: Invalid MySQL username or password." >> $LOG
  exit 1
fi

echo "$(date) Check completed OK" >> $LOG

# Record disk usage before backup
DUSAGEBEFORE=$(df -h $BACKDIR | tail -1 | awk '{print $5 ", Available free space: " $4}')

# Determine the latest full backup
LATEST=$(find $BASEBACKDIR -mindepth 1 -maxdepth 1 -type d -printf "%P\n" | sort -nr | head -1)
AGE=$(stat -c %Y "$BASEBACKDIR/$LATEST" 2>/dev/null || echo 0)

if [ "$LATEST" ] && [ $((AGE + FULLBACKUPCYCLE + 5)) -ge $START ]; then
  echo "$(date) START New incremental backup" >> $LOG

  # Prepare incremental backup directory
  INCRBASEDIR="$BASEBACKDIR/$LATEST"
  LATESTINCR=$(find "$INCRBACKDIR/$LATEST" -mindepth 1 -maxdepth 1 -type d | sort -nr | head -1)
  [ "$LATESTINCR" ] && INCRBASEDIR="$LATESTINCR"

  TARGETDIR="$INCRBACKDIR/$LATEST/$(date +%F_%H-%M-%S)"
  mkdir -p "$TARGETDIR"

  # Perform incremental backup
  $BACKCMD --backup $USEROPTIONS --galera-info --parallel=$THREADS --target-dir="$TARGETDIR" --incremental-basedir="$INCRBASEDIR" 2>>$DLOG
  if [ $? -ne 0 ]; then
    echo "$EmailBody" | mailx -s "$Alarm_Subject" -S smtp="$smtp" -S from="$Sender" "$Alarm_Recipient"
    exit 1
  fi
else
  echo "$(date) START New FULL backup" >> $LOG

  TARGETDIR="$BASEBACKDIR/$(date +%F_%H-%M-%S)"
  mkdir -p "$TARGETDIR"

  # Perform full backup
  $BACKCMD --backup $USEROPTIONS --galera-info --parallel=$THREADS --target-dir="$TARGETDIR" 2>>$DLOG
  if [ $? -ne 0 ]; then
    echo "$EmailBody" | mailx -s "$Alarm_Subject" -S smtp="$smtp" -S from="$Sender" "$Alarm_Recipient"
    exit 1
  fi
fi

# Cleanup old backups
MINS=$((FULLBACKUPCYCLE * (KEEP + 1) / 60))
echo "$(date) Cleaning backups older than $MINS minutes" >> $LOG
find $BASEBACKDIR $INCRBACKDIR -mindepth 1 -maxdepth 1 -type d -mmin +$MINS -exec rm -rf {} \; >> $LOG

# Record backup details
SPENT=$(( $(date +%s) - $START ))
BACKUP_SIZE=$(du -sh "$TARGETDIR" | awk '{print $1}')
BACKUP_LOCATION=$(du -sh "$TARGETDIR" | awk '{print $2}')
DUSAGEAFTER=$(df -h $BACKDIR | tail -1 | awk '{print $5 ", Available free space: " $4}')

echo "$(date) Backup duration: $SPENT seconds" >> $LOG
echo "$(date) Backup size: $BACKUP_SIZE" >> $LOG
echo "$(date) Backup location: $BACKUP_LOCATION" >> $LOG
echo "$(date) Disk usage BEFORE backup: $DUSAGEBEFORE" >> $LOG
echo "$(date) Disk usage AFTER backup: $DUSAGEAFTER" >> $LOG
echo "$(date) COMPLETED" >> $LOG
exit 0
