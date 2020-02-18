# Percona Xtrabackup

Derived from the official Docker CentOS 7 image. The image contains [supercronic](https://github.com/aptible/supercronic) (enhanced cron), Percona Xtrabackup installed and a simple bash script to run the backup command.

# How to use this image?

To run the backup, link it to the running MySQL container and ensure to map the following volumes correctly:

- MySQL datadir of the running MySQL container: /var/lib/mysql
- Backup destination: /backups

## Example with docker compose

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