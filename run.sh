#!/bin/bash

docker run -it \
-v /Users/Strannix/Structure/projects/docker/percona/zbx_env/var/lib/mysql:/var/lib/mysql \
-v /Users/Strannix/Structure/projects/docker/docker-xtrabackup/backup:/backups \
--rm=true \
--network=zbx_net_frontend \
vagabondan/xtrabackup \
sh -c "exec /xtrabackup.sh $1"