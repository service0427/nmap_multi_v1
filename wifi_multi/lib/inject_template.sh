#!/bin/bash
# wifi_multi/lib/inject_template.sh: Surgical Golden Template Injection

DEV_ID=$1; PKG_NAME=$2; APP_UID=$3; NMAP_ORIG_SSAID=$4
[ -z "$DEV_ID" ] || [ -z "$PKG_NAME" ] && exit 1

NC="\e[0m"; GREEN="\e[1;32m"

# 기기별 격리된 tmp 폴더 경로 설정 및 생성
DEV_TMP_DIR="${WIFI_MULTI_LOGS}/${DEV_ID}/tmp"
mkdir -p "$DEV_TMP_DIR"

# Dynamic Date for Consent Realism
RAND_DAYS=$(shuf -i 1-90 -n 1)
TARGET_DATE=$(date -d "$RAND_DAYS days ago" +%Y-%m-%d)

# [ConsentInfo] - Full guest terms agreed
cat <<EOF > "${DEV_TMP_DIR}/tmp_consent.xml"
<?xml version="1.0" encoding="utf-8"?><map><string name="PREF_CONSENT_GUEST_MAP_TERMS_AGREEMENT_STATUS">$TARGET_DATE</string><string name="PREF_CONSENT_GUEST_LOCATION_TERMS_AGREEMENT_STATUS">$TARGET_DATE</string><string name="PREF_CONSENT_GUEST_MAP_LOCATION_TERMS_AGREEMENT_STATUS">$TARGET_DATE</string><boolean name="PREF_CONSENT_CLOVA_CHECKED" value="true" /><boolean name="PREF_CONSENT_CLOVA_AGREED" value="true" /><boolean name="PREF_CONSENT_NEW_MAP_LOCATION_TERMS_AGREED" value="true" /></map>
EOF
# [Preferences] - LAUNCHER_TAB_INDEX=1 (Navi Tab), PREF_ROUTE_TYPE=2 (Car Mode)
cat <<EOF > "${DEV_TMP_DIR}/tmp_prefs.xml"
<?xml version="1.0" encoding="utf-8"?><map><boolean name="PREF_NOT_FIRST_RUN" value="true"/><boolean name="THEME_CHANGE_POPUP_NEVER_SHOW_AGAIN" value="true" /><int name="LAUNCHER_TAB_INDEX" value="1" /><boolean name="HIPASS_POPUP_SHOWN" value="true" /><int name="PREF_ROUTE_TYPE" value="2" /><int name="LAST_USED_MODE" value="1" /><boolean name="INTERNAL_NAVI_UUID_PERSONAL_ROUTE_TERMS_AGREED" value="true" /></map>
EOF
# [NaviDefaults] - Car, Oil, and Auto-Route settings
cat <<EOF > "${DEV_TMP_DIR}/tmp_navi.xml"
<?xml version="1.0" encoding="utf-8"?><map><boolean name="NaviUseHipassKey" value="true" /><int name="NaviCarTypeKey" value="1" /><int name="NaviOilTypeKey" value="1" /><boolean name="NaviGuideTrafficCamKey" value="false" /><boolean name="NaviAutoChangeRoute" value="true" /></map>
EOF
# [NaviSettings] - Auto Quit, Night Theme, Volume 0
cat <<EOF > "${DEV_TMP_DIR}/tmp_navisettings.xml"
<?xml version='1.0' encoding='utf-8' standalone='yes' ?>
<map>
    <int name="PREF_SETTING_USE_NIGHT_THEME" value="2" />
    <boolean name="PREF_SETTING_AUTO_QUIT" value="true" />
    <boolean name="PREF_ENABLE_ROUTE_LAYER_TRAFFIC" value="true" />
    <int name="PREF_SETTING_GUIDE_TYPE" value="1" />
    <int name="PREF_NAVI_EFFECT_VOLUME" value="0" />
    <int name="PREF_SETTING_NAVI_SYMBOL_SCALE" value="0" />
    <int name="PREF_SETTING_NAVI_MAP_MODE" value="0" />
    <boolean name="PREF_ENABLE_SPOTIFY_PLAYER" value="false" />
    <int name="PREF_SETTING_NAVI_VIEW_MODE" value="2" />
    <int name="PREF_NAVI_VOLUME" value="0" />
</map>
EOF

adb -s "$DEV_ID" shell "su -c 'mkdir -p /data/data/$PKG_NAME/shared_prefs'"
adb -s "$DEV_ID" push "${DEV_TMP_DIR}/tmp_consent.xml" /data/local/tmp/ConsentInfo.xml >/dev/null 2>&1
adb -s "$DEV_ID" push "${DEV_TMP_DIR}/tmp_prefs.xml" /data/local/tmp/prefs.xml >/dev/null 2>&1
adb -s "$DEV_ID" push "${DEV_TMP_DIR}/tmp_navi.xml" /data/local/tmp/navi.xml >/dev/null 2>&1
adb -s "$DEV_ID" push "${DEV_TMP_DIR}/tmp_navisettings.xml" /data/local/tmp/navisettings.xml >/dev/null 2>&1

adb -s "$DEV_ID" shell "su -c 'cp /data/local/tmp/ConsentInfo.xml /data/data/$PKG_NAME/shared_prefs/ && cp /data/local/tmp/prefs.xml /data/data/$PKG_NAME/shared_prefs/com.nhn.android.nmap_preferences.xml && cp /data/local/tmp/navi.xml /data/data/$PKG_NAME/shared_prefs/NativeNaviDefaults.xml && cp /data/local/tmp/navisettings.xml /data/data/$PKG_NAME/shared_prefs/NaviSettingsInfo.xml && chown -R $APP_UID:$APP_UID /data/data/$PKG_NAME/shared_prefs && chmod -R 777 /data/data/$PKG_NAME/shared_prefs && restorecon -R /data/data/$PKG_NAME && setprop debug.nmap.ssaid $NMAP_ORIG_SSAID'"

rm -f "${DEV_TMP_DIR}/tmp_consent.xml" "${DEV_TMP_DIR}/tmp_prefs.xml" "${DEV_TMP_DIR}/tmp_navi.xml" "${DEV_TMP_DIR}/tmp_navisettings.xml"
echo -e "    > ${GREEN}[✓] Golden Template Injected.${NC}"
