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
## ===================== USB网卡热插拔重命名脚本 + LuCI条件显示端口卡片 =====================
# 1、创建hotplug脚本：匹配MAC，把内核生成的ethX重命名为eth_usb
HOTPLUG_SCRIPT="./package/base-files/files/etc/hotplug.d/iface/99-rename-usbnic"
mkdir -p $(dirname $HOTPLUG_SCRIPT)
cat > $HOTPLUG_SCRIPT <<'EOF'
#!/bin/sh
[ "$ACTION" != "add" ] && exit 0
# 匹配你的USB网卡MAC
TARGET_MAC="00:e0:4c:68:11:9b"
CURR_MAC=$(cat /sys/class/net/$INTERFACE/address 2>/dev/null)
if [ "$CURR_MAC" = "$TARGET_MAC" ]; then
    # 把当前内核分配的名字重命名为 eth_usb
    ip link set dev "$INTERFACE" down
    ip link set dev "$INTERFACE" name eth_usb
    ip link set dev eth_usb up
fi
EOF
chmod +x $HOTPLUG_SCRIPT
echo "hotplug rename script installed"

# 2、修改LuCI首页模板：eth_usb存在才渲染USB‑LAN卡片，不存在完全不显示
LUCI_INDEX_HTM=$(find ./feeds/luci/modules/luci-mod-admin-full/luasrc/view/admin_status/ -name "index.htm")
if [ -f "$LUCI_INDEX_HTM" ]; then
sed -i '/<div class="port-card">wan<\/div>/a\
<% if luci.sys.net.devices["eth_usb"] then %>\
<div class="port-card">USB‑LAN<br>1GbE">\
    <div class="port-green"></div>\
    <div>▲ <%=luci.sys.net.devices["eth_usb"].tx_bytes%></div>\
    <div>▼ <%=luci.sys.net.devices["eth_usb"].rx_bytes%></div>\
</div>\
<% end %>' $LUCI_INDEX_HTM
echo "patch luci index.htm conditional USB‑LAN done!"
fi

# 3、编译阶段预置br‑lan网桥包含eth_usb（允许不存在的接口，不会报错）
CFG_GENERATE="./package/base-files/files/bin/config_generate"
if [ -f "$CFG_GENERATE" ]; then
# 在br‑lan ports列表追加 eth_usb
sed -i '/list ports/s/$/ eth_usb/' $CFG_GENERATE
echo "add eth_usb to br‑lan ports in config_generate"
fi
## =========================================================================================
