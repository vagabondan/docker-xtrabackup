#!/bin/bash

docker run -it \
-v `pwd`/backups:/backups \
-v `pwd`/../percona/zbx_env/var/lib/mysql:/var/lib/mysql \
-v `pwd`/../percona1/zbx_env/var/lib/mysql:/restore/mysql \
--rm=true \
--entrypoint="" \
vagabondan/xtrabackup \
sh -c "exec /xtrabackup.sh $*"