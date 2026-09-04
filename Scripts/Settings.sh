#!/bin/bash

#移除luci-app-attendedsysupgrade
sed -i "/attendedsysupgrade/d" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改默认主题
sed -i "s/luci-theme-bootstrap/luci-theme-$WRT_THEME/g" $(find ./feeds/luci/collections/ -type f -name "Makefile")
#修改immortalwrt.lan关联IP
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $(find ./feeds/luci/modules/luci-mod-system/ -type f -name "flash.js")
#添加编译日期标识
sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ $WRT_MARK-$WRT_DATE')/g" $(find ./feeds/luci/modules/luci-mod-status/ -type f -name "10_system.js")

WIFI_SH=$(find ./target/linux/{mediatek/filogic,qualcommax}/base-files/etc/uci-defaults/ -type f -name "*set-wireless.sh" 2>/dev/null)
WIFI_UC="./package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"
if [ -f "$WIFI_SH" ]; then
	#修改WIFI名称
	sed -i "s/BASE_SSID='.*'/BASE_SSID='$WRT_SSID'/g" $WIFI_SH
	#修改WIFI密码
	sed -i "s/BASE_WORD='.*'/BASE_WORD='$WRT_WORD'/g" $WIFI_SH
elif [ -f "$WIFI_UC" ]; then
	#修改WIFI名称
	sed -i "s/ssid='.*'/ssid='$WRT_SSID'/g" $WIFI_UC
	#修改WIFI密码
	sed -i "s/key='.*'/key='$WRT_WORD'/g" $WIFI_UC
	#修改WIFI地区
	sed -i "s/country='.*'/country='CN'/g" $WIFI_UC
	#修改WIFI加密
	sed -i "s/encryption='.*'/encryption='psk2+ccmp'/g" $WIFI_UC
fi

CFG_FILE="./package/base-files/files/bin/config_generate"
#修改默认IP地址
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" $CFG_FILE
#修改默认主机名
sed -i "s/hostname='.*'/hostname='$WRT_NAME'/g" $CFG_FILE

#配置文件修改
echo "CONFIG_PACKAGE_luci=y" >> ./.config
echo "CONFIG_LUCI_LANG_zh_Hans=y" >> ./.config
echo "CONFIG_PACKAGE_luci-theme-$WRT_THEME=y" >> ./.config
echo "CONFIG_PACKAGE_luci-app-$WRT_THEME-config=y" >> ./.config

#手动调整的插件
if [ -n "$WRT_PACKAGE" ]; then
	echo -e "$WRT_PACKAGE" >> ./.config
fi

#高通平台调整
DTS_PATH="./target/linux/qualcommax/files/arch/arm64/boot/dts/qcom/"
if [[ "${WRT_TARGET^^}" == *"QUALCOMMAX"* ]]; then
	#取消nss相关feed
	echo "CONFIG_FEED_nss_packages=n" >> ./.config
	echo "CONFIG_FEED_sqm_scripts_nss=n" >> ./.config
	#开启sqm-nss插件
	echo "CONFIG_PACKAGE_luci-app-sqm=y" >> ./.config
	echo "CONFIG_PACKAGE_sqm-scripts-nss=y" >> ./.config
	#设置NSS版本
	echo "CONFIG_NSS_FIRMWARE_VERSION_11_4=n" >> ./.config
	if [[ "${WRT_CONFIG,,}" == *"ipq50"* ]]; then
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_2=y" >> ./.config
	else
		echo "CONFIG_NSS_FIRMWARE_VERSION_12_5=y" >> ./.config
	fi
	#无WIFI配置调整Q6大小
	if [[ "${WRT_CONFIG,,}" == *"wifi"* && "${WRT_CONFIG,,}" == *"no"* ]]; then
		find $DTS_PATH -type f ! -iname '*nowifi*' -exec sed -i 's/ipq\(6018\|8074\).dtsi/ipq\1-nowifi.dtsi/g' {} +
		echo "qualcommax set up nowifi successfully!"
	fi
	#其他调整
	echo "CONFIG_PACKAGE_kmod-usb-serial-qualcomm=y" >> ./.config
fi
# ============ USB 网卡：每次开机自动显示到首页"端口状态" ============

# 1) 启动脚本：打进固件，每次开机执行
mkdir -p ./package/base-files/files/etc/init.d ./package/base-files/files/etc/rc.d
cat > ./package/base-files/files/etc/init.d/usbnet <<'EOF'
#!/bin/sh /etc/rc.common
START=99

boot() { start; }

start() {
	# 最多等 30 秒，让 USB 网卡完成枚举
	local i=0
	while [ $i -lt 30 ]; do
		ls /sys/class/net/*/device/idVendor >/dev/null 2>&1 && break
		sleep 1
		i=$((i + 1))
	done

	local changed=0 devpath iface sec

	# 遍历所有"挂在 USB 总线上的网卡"
	for devpath in /sys/class/net/*/device/idVendor; do
		[ -f "$devpath" ] || continue
		iface="${devpath%/device/idVendor}"
		iface="${iface##*/}"

		# ① 写入 /etc/board.json（首页端口状态的数据来源）
		if ! grep -q "\"$iface\"" /etc/board.json; then
			. /usr/share/libubox/jshn.sh
			json_load "$(cat /etc/board.json)"
			json_select network
			json_select lan
			json_select ports 2>/dev/null || json_add_array "ports"
			json_add_string "" "$iface"
			json_dump > /tmp/board.json.new
			mv /tmp/board.json.new /etc/board.json
			changed=1
		fi

		# ② 加入 br-lan（让卡片带上 lan 区域颜色、正常转发）
		sec=$(uci show network 2>/dev/null | sed -n "s/^network\.\([^.]*\)\.name='br-lan'$/\1/p" | head -1)
		if [ -n "$sec" ]; then
			uci -q get "network.$sec.ports" | tr ' ' '\n' | grep -qx "$iface" || {
				uci -q add_list "network.$sec.ports=$iface"
				changed=1
			}
		fi
	done

	# 只有改动过才提交并重载网络，避免每次开机多余操作
	if [ "$changed" = "1" ]; then
		uci commit network
		/etc/init.d/network reload
	fi
	return 0
}
EOF
chmod +x ./package/base-files/files/etc/init.d/usbnet

# 2) 建立开机自启软链接（否则脚本打进固件也不会自动运行）
ln -sf ../init.d/usbnet ./package/base-files/files/etc/rc.d/S99usbnet
## =========================================================================================
