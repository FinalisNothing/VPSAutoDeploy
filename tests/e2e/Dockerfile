# Debian 13 with systemd, in the state phase1 leaves behind (minus the BBR
# kernel, which a container cannot have): curl wget jq sudo nano, sshd on a
# custom port with password login closed, and a UID-1000 sudo user.
FROM debian:trixie

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus openssh-server sudo curl wget jq nano ca-certificates \
      iproute2 procps cron openssl kmod iptables \
      python3 \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash -G sudo -u 1000 tester \
 && printf 'Port 2222\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/10-e2e.conf \
 && systemctl enable ssh cron

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
