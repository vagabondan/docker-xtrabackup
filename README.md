# Percona Xtrabackup

Derived from the official Docker CentOS 7 image. The image contains [supercronic](https://github.com/aptible/supercronic) (enhanced cron), Percona Xtrabackup installed and a simple bash script to run the backup command.

# How to use this image?

To run the backup, link it to the running MySQL container and ensure to map the following volumes correctly:

- MySQL datadir of the running MySQL container: /var/lib/mysql
- Backup destination: /backups

## Example with manual usage

Sometimes, it is handy to execute backup/restore procedures manually.
First of all, you should check, that you have right docker image to run. You can build it by yourself, typing in shell:
```bash
./build.sh
```

After that you can continue with editting [run.sh](https://github.com/vagabondan/docker-xtrabackup/blob/master/run.sh) script or run docker with approximately the following parameters (in the latter case delete  ```$*``` in the last line):
```bash
#!/bin/bash

docker run -it \
-v `pwd`/backups:/backups \
-v `pwd`/../percona/zbx_env/var/lib/mysql:/var/lib/mysql \
-v `pwd`/../percona1/zbx_env/var/lib/mysql:/restore/mysql \
--rm=true \
--entrypoint="" \
vagabondan/xtrabackup \
sh -c "exec /xtrabackup.sh $*"
```

Just edit volume mappings keeping in mind that:
*/backups* - the path where all backups, their logs and all additional files are stored
*/var/lib/mysql* - the path to MySQL DB data directory inside container that has to be backuped
*/restore/mysql* - the path to MySQL DB data directory inside container where backup should be restored to (only needs when you are restoring the data)
Two last pathes can be redefined in the configuration file which is in the */backups* directory inside container: **/backups/.xtrabackup.config**

...and run:
```bash
$ ./run.sh 

Configuration has been initialised in /backups/.xtrabackup.config. 
Please make sure all settings are correctly defined/customised - aborting.
```

If configuration file doesn't exist then it will be created with some defaults settings at first run: run.sh tells you about it and exist.
You should check all settings and undoubtly edit at least:
* MYSQL_USER="$(whoami)"
* MYSQL_PASS=

...try once again:
```bash
$ ./run.sh 

Loading configuration from /backups/.xtrabackup.config.
Backup type not specified. Please run: as /xtrabackup.sh [incr|full|list|restore]
```

If settings are fine, you get the help about possible commandline options:
* *incr* - create incremental backup
* *full* - create full backup
* *list* - list all backups made
* *restore* - restore from backup, you need provide here additional parameter: ```<backup timestamp>``` - one of the backup ids got from ```./run.sh list``` output


## Example with docker compose and scheduler

Suppose you have a MySQL container running named "mysql-server", started with this command:

```bash
$ docker run -d \
--name=mysql-server \
-v /storage/mysql-server/datadir:/var/lib/mysql \
-e MySQL_ROOT_PASSWORD=mypassword \
mysql
```

Check volume mapping inside docker-compose.yaml, crontab settings for supercronic

```docker-compose
version: "3.3"

services:
  percona-backup:
    build: .
    image: vagabondan/xtrabackup
    restart: unless-stopped
    volumes:
        # set date and timezone equals to host
      - /etc/localtime:/etc/localtime:ro
        # mysql data dir
      - /storage/mysql-server/datadir:/var/lib/mysql:rw
        # /backups - folder inside container where backup files and logs are written to
      - ./backups:/backups:rw
        # map your crontab to /etc/crontabs/crontab inside container
      - ./backups/crontab:/etc/crontabs/crontab:ro
    networks:
      - percona
  
networks:
  # define external network with DB host if you want to interact with DB through <service>:<port> rather than unix socket
  percona:
```

and then run:
```bash
docker-compose up -d --build
```

You should see [Supercronic](https://github.com/aptible/supercronic) output on the screen: it tells us that it reads configuration from ```/etc/crontabs/crontab``` file inside container:

```bash
percona-backup_1  | time="2020-02-17T10:37:07Z" level=info msg="read crontab: /etc/crontabs/crontab"
```

The container will then continue to work with [supercronic](https://github.com/aptible/supercronic) launching scripts according to the ```/etc/crontabs/crontab``` schedule. On the machine host, we can see the backups are there:

```bash
$ ls -1 ./backups/percona-backups/*/
./backups/percona-backups/full/:
2020-02-15_04-38-59
2020-02-15_04-39-59
...

./backups/percona-backups/incr/:
2020-02-15_04-40-59
2020-02-15_04-41-59
...
```

Crontab file example:
```cron
# Run every friday at 21:00
0 21 5 * * /xtrabackup.sh full

# Run every day at 07:00
0 7 * * * /xtrabackup.sh incr
```

# Configuration file parameters
Configuration file is self descriptive. All possible options are listed below:
```
######## BACKUP SECTION ######################################
MYSQL_USER="$(whoami)"
MYSQL_PASS=
MYSQL_DATA_DIR=/var/lib/mysql/

###
## You can choose to use unix socket connection or host:port
## Unix socket connection is preferable
MYSQL_SOCKET=/var/lib/mysql/mysql.sock
# MYSQL_HOST=mysql-host
# MYSQL_PORT=3306
###

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

## If you want to save metadata for schemas then define them here:
## you can use ,:;|/ - as separator symbols
# BACKUP_DDL_SCHEMAS=schema1,schema2,schema3

## Remove logs older than the specifier below
## see "man find" for mtime prameter for possible values 
LOGS_REMOVE_PERIOD=14

###############################################################
##
######## RESTORE SECTION ######################################
## Restore mode
## Possible values: 
## full - restore data in a new data base, you should then define RESTORE_* variables
## any other value - only prepares files from backup for further manual restoration
RESTORE_MODE=full

RESTORE_MYSQL_DATA_DIR=/restore/mysql/

RESTORE_MYSQL_USER="$(whoami)"
RESTORE_MYSQL_PASS=

###
## You can choose to use unix socket connection or host:port
## Unix socket connection is preferable
RESTORE_MYSQL_SOCKET=/restore/mysql/mysql.sock
# RESTORE_MYSQL_HOST=mysql-host-restore
# RESTORE_MYSQL_PORT=3306
###
```