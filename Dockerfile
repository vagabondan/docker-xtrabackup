FROM centos:7

LABEL org.opencontainers.image.authors="strannix@vagabondan.ru"

RUN groupdel input && groupadd -g 999 mysql
RUN useradd -u 999 -r -g 999 -s /sbin/nologin \
		-c "Default Application User" mysql

# check repository package signature in secure way
RUN set -ex; \
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver ha.pool.sks-keyservers.net --recv-keys 430BDF5C56E7C94E848EE60C1C4CBDCDCD2EFD2A; \
    gpg --batch --export --armor 430BDF5C56E7C94E848EE60C1C4CBDCDCD2EFD2A > ${GNUPGHOME}/RPM-GPG-KEY-Percona; \
    rpmkeys --import ${GNUPGHOME}/RPM-GPG-KEY-Percona /etc/pki/rpm-gpg/RPM-GPG-KEY-CentOS-7; \
    curl -Lf -o /tmp/percona-release.rpm https://repo.percona.com/yum/percona-release-latest.noarch.rpm; \
    rpmkeys --checksig /tmp/percona-release.rpm; \
    yum install -y /tmp/percona-release.rpm; \
    rm -rf "$GNUPGHOME" /tmp/percona-release.rpm; \
    rpm --import /etc/pki/rpm-gpg/PERCONA-PACKAGING-KEY; \
    percona-release disable all; \
    percona-release enable original release

RUN yum install -y \
	pigz percona-xtrabackup-24 percona-toolkit qpress bash which \
	&& yum clean all \
	&& mkdir -p /backups && mkdir -p /var/lib/mysql

ENV SUPERCRONIC_URL=https://github.com/aptible/supercronic/releases/download/v0.1.9/supercronic-linux-amd64 \
    SUPERCRONIC=supercronic-linux-amd64 \
    SUPERCRONIC_SHA1SUM=5ddf8ea26b56d4a7ff6faecdd8966610d5cb9d85

RUN curl -fsSLO "$SUPERCRONIC_URL" \
 && echo "${SUPERCRONIC_SHA1SUM}  ${SUPERCRONIC}" | sha1sum -c - \
 && chmod +x "$SUPERCRONIC" \
 && mv "$SUPERCRONIC" "/usr/local/bin/${SUPERCRONIC}" \
 && ln -s "/usr/local/bin/${SUPERCRONIC}" /usr/local/bin/supercronic

USER mysql

# Allow mountable backup path
VOLUME ["/backups","/var/lib/mysql","/hooks","/etc/crontabs"]

# Copy the script to simplify backup command
COPY backup.sh /backup.sh
COPY xtrabackup.sh /xtrabackup.sh

ENTRYPOINT ["supercronic"]
CMD ["/etc/crontabs/crontab"]