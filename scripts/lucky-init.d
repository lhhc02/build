#!/bin/sh /etc/rc.common
# lucky 的 procd 服务脚本（OpenWrt 25.12）
# lucky 首次启动会在工作目录生成 lucky.conf，默认监听 0.0.0.0:16601

START=99
STOP=10
USE_PROCD=1

PROG=/usr/bin/lucky
DIR=/etc/lucky

start_service() {
	mkdir -p "$DIR" /var/log/lucky
	procd_open_instance
	procd_set_param command /bin/sh -c "cd $DIR && exec $PROG"
	procd_set_param respawn 3600 5 5
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param limits nofile="65535 65535"
	procd_close_instance
}

service_triggers() {
	procd_add_reload_trigger lucky
}
