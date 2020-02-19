#!/bin/bash

docker run -it \
-v `pwd`/../percona/zbx_env/var/lib/mysql:/var/lib/mysql \
-v `pwd`/../percona1/zbx_env/var/lib/mysql:/restore/mysql \
-v `pwd`/backups:/backups \
--rm=true \
--network=zbx_net_frontend \
--entrypoint="" \
vagabondan/xtrabackup \
sh -c "exec /xtrabackup.sh $*"