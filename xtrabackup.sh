#!/bin/bash

die () {
	echo -e 1>&2 "$@"
	exit 1
}

fail () {
	die "...FAILED! See ${1:-LOG_FILE} for details - aborting.\n"
}

INNOBACKUPEX=$(which innobackupex)
[ -f "$INNOBACKUPEX" ] || die "innobackupex script not found - please ensure xtrabackup is installed before proceeding."


##CONTAINER=$(export | sed -nr "/ENV_MYSQL_DATABASE/{s/^.+ -x (.+)_ENV.+/\1/p;q}")
##DB_PORT=$(export | sed -nr "/-x ${CONTAINER}_PORT_[[:digit:]]+_TCP_PORT/{s/^.+ -x (.+)=.+/\1/p}")
##DB_ADDR="${CONTAINER}_PORT_${!DB_PORT}_TCP_ADDR"
##DB_NAME="${CONTAINER}_ENV_MYSQL_DATABASE"
##DB_PASS="${CONTAINER}_ENV_MYSQL_ROOT_PASSWORD"

CONFIG_FILE=/backups/.xtrabackup.config

if [ -f $CONFIG_FILE ]; then
	echo -e "Loading configuration from $CONFIG_FILE."
	source $CONFIG_FILE
else
cat << EOF > $CONFIG_FILE
MYSQL_USER="$(whoami)"
MYSQL_PASS=
MYSQL_DATA_DIR=/var/lib/mysql/

##############################################################
## You can choose to use host:port or unix socket connection
## host:port is used by default
MYSQL_HOST=mysql-host
MYSQL_PORT=3306
################
## But you can uncomment the following variable and use unix socket connection instead
# MYSQL_SOCKET=/var/lib/mysql/mysql.sock
#################################################################

BACKUP_DIRECTORY=/backups/percona-backups
BACKUP_MAX_CHAINS=8
BACKUP_HISTORY_LABEL="$(whoami)"
BACKUP_THREADS=4

## Comment below string if you don't want to stream backup into one single archive file
## Possible values: xbstream/tar (all possible for innobackupex --stream=<option>)
BACKUP_STREAM_TYPE=xbstream

## Use pigz to gzip streamed backup in parallel (= ${BACKUP_THREADS}).
## Possible values: 
## piped - use pigz in pipe to gzip backup on the fly
## postponed - use pigz to gzip backup afterwards (extra disk space is needed)
## otherwise no gzipping
BACKUP_GZIP=piped

## Number of pigz threads:
BACKUP_GZIP_THREADS=4

## If BACKUP_TABLES_LIST_FILE provided then backup only tables listed
## see help for "innobackupex --tables=<file>" parameter to get the file format
## ATTENTION! Use container path below!
# BACKUP_TABLES_LIST_FILE=/backups/.tables_list

## Remove logs older than the specifier below
## see "man find" for mtime prameter for possible values 
LOGS_REMOVE_PERIOD=14d
EOF

	die "Configuration has been initialised in $CONFIG_FILE. \nPlease make sure all settings are correctly defined/customised - aborting."
fi

## Backward compatibility: read value from $BACKUPS_DIRECTORY if $BACKUP_DIRECTORY was not initialized
[ -z "${BACKUPS_DIRECTORY}" ] || BACKUP_DIRECTORY=${BACKUP_DIRECTORY:-${BACKUPS_DIRECTORY}}
## Backward compatibility: read value from $MAX_BACKUP_CHAINS if $BACKUP_MAX_CHAINS was not initialized
[ -z "${MAX_BACKUP_CHAINS}" ] || BACKUP_MAX_CHAINS=${BACKUP_MAX_CHAINS:-${MAX_BACKUP_CHAINS}}

## If no BACKUP_GZIP_THREADS defined then use BACKUP_THREADS or defaults to 4 threads
[ -z "${BACKUP_GZIP_THREADS}" ] && BACKUP_GZIP_THREADS=${BACKUP_THREADS:-4}

## If no LOGS_REMOVE_PERIOD define then use defaults 14d
LOGS_REMOVE_PERIOD=${LOGS_REMOVE_PERIOD:-14d}

[ -d $MYSQL_DATA_DIR ] || die "Please ensure the MYSQL_DATA_DIR setting in the configuration file points to the directory containing the MySQL databases."
[ -n "$MYSQL_USER" -a -n "$MYSQL_PASS" ] || die "Please ensure MySQL username and password are properly set in the configuration file."

FULLS_DIRECTORY=$BACKUP_DIRECTORY/full
INCREMENTALS_DIRECTORY=$BACKUP_DIRECTORY/incr
LOGS="/backups/logs"
CURRENT_DATE=`date +%Y-%m-%d_%H-%M-%S`
BACKUP_LOG=${LOGS}/innobackupex_${CURRENT_DATE}.log


mkdir -vp $FULLS_DIRECTORY
mkdir -vp $INCREMENTALS_DIRECTORY
mkdir -vp $LOGS

IONICE=$(which ionice)

if [ -n "$IONICE" ]; then
	IONICE_COMMAND="$IONICE -c2 -n7"
fi

INNOBACKUPEX_COMMAND="$(which nice) -n 15 $IONICE_COMMAND $INNOBACKUPEX"
RSYNC_COMMAND="$(which nice) -n 15 $IONICE_COMMAND  $(which rsync)"


full_backup () {
    
	echo "Starting full backup"
	
	OPTIONS="--slave-info --user=$MYSQL_USER --password=$MYSQL_PASS \
		--compress --compress-threads=$BACKUP_THREADS --parallel=$BACKUP_THREADS --history=$BACKUP_HISTORY_LABEL \
	"
	if [ -z "$MYSQL_SOCKET" ]; then # unset or empty
		OPTIONS="$OPTIONS \
			--host=$MYSQL_HOST --port=$MYSQL_PORT \
		"
	else	# use unix socket is set and not empty
		OPTIONS="$OPTIONS \
			--socket=$MYSQL_SOCKET \
		"
	fi

	## If BACKUP_TABLES_LIST_FILE provided then backup only tables listed
	[ -z "$BACKUP_TABLES_LIST_FILE" ] || OPTIONS="$OPTIONS --tables-file=$BACKUP_TABLES_LIST_FILE "

	if [ -z "$BACKUP_STREAM_TYPE" ]; then 	## no streamming
	 	echo "Running: $INNOBACKUPEX_COMMAND $OPTIONS $FULLS_DIRECTORY "
	 	$INNOBACKUPEX_COMMAND $OPTIONS "$FULLS_DIRECTORY" 2> $BACKUP_LOG
	else								## stream has been defined
	 	OPTIONS="$OPTIONS \
	 		--stream=$BACKUP_STREAM_TYPE \
	 	"
				
		FULLS_DIRECTORY_SUBDIR=${FULLS_DIRECTORY}/${CURRENT_DATE}
		BACKUP_FILENAME="${FULLS_DIRECTORY_SUBDIR}/full_${BACKUP_HISTORY_LABEL}_${CURRENT_DATE}.${BACKUP_STREAM_TYPE}"
		mkdir -vp ${FULLS_DIRECTORY_SUBDIR}
		
	 	if [ "$BACKUP_GZIP" = "piped" ]; then
	 		echo "Running: $INNOBACKUPEX_COMMAND $OPTIONS $FULLS_DIRECTORY_SUBDIR 2> $BACKUP_LOG | pigz -p ${BACKUP_THREADS:-5} > ${BACKUP_FILENAME}.gz"
	 		$INNOBACKUPEX_COMMAND $OPTIONS "$FULLS_DIRECTORY_SUBDIR" 2> $BACKUP_LOG | pigz -p ${BACKUP_GZIP_THREADS} > "${BACKUP_FILENAME}.gz"
	 	elif [ "$BACKUP_GZIP" = "postponed" ]; then
	 		echo "Running: $INNOBACKUPEX_COMMAND $OPTIONS $FULLS_DIRECTORY_SUBDIR 2> $BACKUP_LOG > ${BACKUP_FILENAME}"
	 		$INNOBACKUPEX_COMMAND $OPTIONS "$FULLS_DIRECTORY_SUBDIR" 2> $BACKUP_LOG > "${BACKUP_FILENAME}"
			echo "Gzipping ${BACKUP_FILENAME}"
	 		cat "${BACKUP_FILENAME}" | pigz -p ${BACKUP_GZIP_THREADS} > "${BACKUP_FILENAME}.gz" && rm "${BACKUP_FILENAME}"
	 	else
	 		echo "Running: $INNOBACKUPEX_COMMAND $OPTIONS $FULLS_DIRECTORY_SUBDIR 2> $BACKUP_LOG > ${BACKUP_FILENAME}"
	 		$INNOBACKUPEX_COMMAND $OPTIONS "$FULLS_DIRECTORY_SUBDIR" 2> $BACKUP_LOG > "${BACKUP_FILENAME}"
	 	fi
	fi

	if [[ $(tail -1 $BACKUP_LOG) == *"completed OK!"* ]]; then
  		NEW_BACKUP_DIR=$(find $FULLS_DIRECTORY -mindepth 1 -maxdepth 1 -type d -exec ls -dt {} \+ | head -1)
		echo $NEW_BACKUP_DIR > $NEW_BACKUP_DIR/backup.chain
		echo "Finished full backup"
	else
		fail $BACKUP_LOG
	fi
	 
}


incremental_backup () {
	LAST_BACKUP=${LAST_CHECKPOINTS%/xtrabackup_checkpoints}

	$INNOBACKUPEX_COMMAND --slave-info --host="$MYSQL_HOST" --port=$MYSQL_PORT --user="$MYSQL_USER" --password="$MYSQL_PASS" --incremental --incremental-basedir="$LAST_BACKUP" "$INCREMENTALS_DIRECTORY"

	NEW_BACKUP_DIR=$(find $INCREMENTALS_DIRECTORY -mindepth 1 -maxdepth 1 -type d -exec ls -dt {} \+ | head -1)
	cp $LAST_BACKUP/backup.chain $NEW_BACKUP_DIR/
	echo $NEW_BACKUP_DIR >> $NEW_BACKUP_DIR/backup.chain
}


#
# Call before hooks
#
if [ -d "/hooks" ] && ls /hooks/*.before 1> /dev/null 2>&1; then
  for hookfile in /hooks/*.before; do
    eval $hookfile
    echo "Called hook $hookfile"
  done
fi


if [ "$1" = "full" ]; then
	full_backup
elif [ "$1" = "incr" ]; then
	LAST_CHECKPOINTS=$(find $BACKUP_DIRECTORY -mindepth 3 -maxdepth 3 -type f -name xtrabackup_checkpoints -exec ls -dt {} \+ | head -1)
	
	if [[ -f $LAST_CHECKPOINTS ]]; then
		incremental_backup
	else
		full_backup
	fi
elif [ "$1" = "list" ]; then
	if [[ -d $FULLS_DIRECTORY ]]; then
		BACKUP_CHAINS=$(ls $FULLS_DIRECTORY | wc -l)
	else
		BACKUP_CHAINS=0
	fi
		
	if [[ $BACKUP_CHAINS -gt 0 ]]; then
		echo -e "Available backup chains (from oldest to latest):\n"

		for FULL_BACKUP in `ls $FULLS_DIRECTORY -tr`; do
			let COUNTER=COUNTER+1

			echo "Backup chain $COUNTER:"
			echo -e "\tFull:        $FULL_BACKUP"

			if [[ $(ls $INCREMENTALS_DIRECTORY | wc -l) -gt 0 ]]; then
				grep -l $FULL_BACKUP $INCREMENTALS_DIRECTORY/**/backup.chain | \
				while read INCREMENTAL; 
				do 
					BACKUP_DATE=${INCREMENTAL%/backup.chain}
					echo -e "\tIncremental: ${BACKUP_DATE##*/}"
				done
			fi
		done
		
		LATEST_BACKUP=$(find $BACKUP_DIRECTORY -mindepth 2 -maxdepth 2 -type d -exec ls -dt {} \+ | head -1)
		
		[[ "$LATEST_BACKUP" == *full* ]] && IS_FULL=1 || IS_FULL=0

		BACKUP_DATE=${LATEST_BACKUP##*/}

		if [[ "$LATEST_BACKUP" == *full* ]]
		then
		  echo -e "\nLatest backup available:\n\tFull: $BACKUP_DATE"
		else
		  echo -e "\nLatest backup available:\n\tIncremental: $BACKUP_DATE"
		fi
		
		exit 1
	else
		die "No backup chains available in the backup directory specified in the configuration ($BACKUP_DIRECTORY)"
	fi
elif [ "$1" = "restore" ]; then
	([ -n "$2" ] && [ -n "$3" ]) || die "Missing arguments. Please run as: \n\t$0 restore <timestamp> <destination folder>\nTo see the list of the available backups, run:\n\t$0 list"
		
	BACKUP_TIMESTAMP="$2"
	DESTINATION="$3"
	BACKUP=`find $BACKUP_DIRECTORY -mindepth 2 -maxdepth 2 -type d -name $BACKUP_TIMESTAMP -exec ls -dt {} \+ | head -1`
	LOG_FILE="$LOGS/restore-$BACKUP_TIMESTAMP.log"
	
	echo "" > $LOG_FILE
	
	(mkdir -vp $DESTINATION) || die "Could not access destination folder $3 - aborting"
	
	if [[ -d "$BACKUP" ]]; then
		echo -e "!! About to restore MySQL backup taken on $BACKUP_TIMESTAMP to $DESTINATION !!\n"
		
		if [[ "$BACKUP" == *full* ]]; then
			echo "- Restore of full backup taken on $BACKUP_TIMESTAMP"

			echo "Copying data files to destination..."
			$RSYNC_COMMAND --quiet -ah --delete $BACKUP/ $DESTINATION &>> $LOG_FILE || fail
			echo -e "...done.\n"
		
			echo "Preparing the destination for use with MySQL..."
			$INNOBACKUPEX_COMMAND --apply-log --ibbackup=xtrabackup_51 $DESTINATION  &>> $LOG_FILE || fail
			echo -e "...done.\n"
		else
			XTRABACKUP=$(which xtrabackup)
			
      [ -f "$XTRABACKUP" ] || die "xtrabackup executable not found - this is required in order to restore from incrementals. Ensure xtrabackup is installed properly - aborting."

      XTRABACKUP_COMMAND="$(which nice) -n 15 $IONICE_COMMAND $XTRABACKUP"
		
			FULL_BACKUP=$(cat $BACKUP/backup.chain | head -1)
		
			echo "- Restore of base backup from $FULL_BACKUP"

			echo "Copying data files to destination..."
			$RSYNC_COMMAND --quiet -ah --delete $FULL_BACKUP/ $DESTINATION  &>> $LOG_FILE || fail
			echo -e "...done.\n"

			echo "Preparing the base backup in the destination..."
			#$XTRABACKUP_COMMAND --prepare --apply-log-only --target-dir=$DESTINATION &>> $LOG_FILE || fail
      $INNOBACKUPEX_COMMAND --apply-log --redo-only $DESTINATION &>> $LOG_FILE || fail
			echo -e "...done.\n"
		
			for INCREMENTAL in $(cat $BACKUP/backup.chain | tail -n +2); do
				echo -e "Applying incremental from $INCREMENTAL...\n"
				#$XTRABACKUP_COMMAND  --prepare --apply-log-only --target-dir=$DESTINATION --incremental-dir=$INCREMENTAL  &>> $LOG_FILE || fail
        $INNOBACKUPEX_COMMAND --apply-log --redo-only $DESTINATION --incremental-dir=$INCREMENTAL &>> $LOG_FILE || fail
				echo -e "...done.\n"
			done

			echo "Finalising the destination..."
			#$XTRABACKUP_COMMAND --prepare --target-dir=$DESTINATION  &>> $LOG_FILE || fail
      $INNOBACKUPEX_COMMAND --apply-log  $DESTINATION &>> $LOG_FILE || fail
			echo -e "...done.\n"
		fi
		
		rm $LOG_FILE # no errors, no need to keep it
		
		echo -e "The destination is ready. All you need to do now is:
	- ensure the MySQL user owns the destination directory, e.g.: chown -R mysql:mysql $DESTINATION
	- stop MySQL server
	- replace the content of the MySQL datadir (usually /var/lib/mysql) with the content of $DESTINATION
	- start MySQL server again"
	else
		die "Backup not found. To see the list of the available backups, run: $0 list"
	fi
else
  die "Backup type not specified. Please run: as $0 [incr|full|list|restore]"
fi

BACKUP_CHAINS=`ls $FULLS_DIRECTORY | wc -l`

if [[ $BACKUP_CHAINS -gt $BACKUP_MAX_CHAINS ]]; then
	CHAINS_TO_DELETE=$(expr $BACKUP_CHAINS - $BACKUP_MAX_CHAINS)
	
	for FULL_BACKUP in `ls $FULLS_DIRECTORY -t |  tail -n $CHAINS_TO_DELETE`; do
		grep -l $FULLS_DIRECTORY/$FULL_BACKUP $INCREMENTALS_DIRECTORY/**/backup.chain | while read incremental; do rm -rf "${incremental%/backup.chain}"; done
		$IONICE_COMMAND rm -rf $FULLS_DIRECTORY/$FULL_BACKUP
	done
fi

## Remove old logs
find ${LOGS} -mtime +${LOGS_REMOVE_PERIOD} -exec rm -f {} \+

unset MYSQL_USER
unset MYSQL_PASS

#
# Call after hooks
#
if [ -d "/hooks" ] && ls /hooks/*.after 1> /dev/null 2>&1; then
  for hookfile in /hooks/*.after; do
    echo "===> Calling hook ${hookfile}... "
    eval $hookfile
    echo "===> Calling hook ${hookfile}... DONE"
  done

  echo "===> All hooks processed, finished."
else
  echo "===> No hooks found, finished."
fi
