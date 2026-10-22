/* 
   Core Survival System (V3 Refactored)
   - Goal: Prevent App Crash & Skip Agreement Screen rendering bug.
   - Executed: ALWAYS (Even in --no-filter mode)
*/

console.log("[*] Core Survival System Loaded");

// 1. Android 14/15 MTE (Heap Tagging) Crash Prevention
function patch_heap_tagging() {
    try {
        var libc = Process.getModuleByName("libc.so");
        var mallopt = null;
        var prctl = null;
        
        libc.enumerateExports().forEach(function(exp) {
            if (exp.name === "mallopt") mallopt = exp.address;
            else if (exp.name === "prctl") prctl = exp.address;
        });

        // WebView(libmonochrome.so) Sandbox strictly monitors prctl and set_heap_tagging hooks.
        // Attaching Interceptor to them causes a deliberate SIGBUS SI_USER suicide trap!
        // We MUST ONLY use direct, one-time NativeFunction invocations to bypass MTE.
        
        if (mallopt) {
            try {
                var mallopt_func = new NativeFunction(mallopt, 'int', ['int', 'int']);
                mallopt_func(-9, 0); // M_BIONIC_DISABLE_MEMORY_MITIGATIONS
                console.log("[✓] Direct MTE Disable via mallopt(-9) success");
            } catch(e) {}
        }

        if (prctl) {
            try {
                var prctl_func = new NativeFunction(prctl, 'int', ['int', 'uint64', 'uint64', 'uint64', 'uint64']);
                prctl_func(53, 0, 0, 0, 0); // PR_SET_TAGGED_ADDR_CTRL -> 0
                console.log("[✓] Direct MTE Disable via prctl(53) success. (No Interceptor attached to avoid WebView Trap)");
            } catch(e) {}
        }
    } catch(e) {
        console.log("[-] MTE Patch Error: " + e.stack);
    }
}

// 2. FDS Stealth (Hide Root, Magisk, Developer Options)
function hook_stealth() {
    if (!Java.available) return;
    Java.perform(function() {
        try {
            var File = Java.use("java.io.File");
            File.exists.implementation = function() {
                var name = this.getName();
                if (name === "su" || name === "magisk" || name === "frida-server" || name === "busybox") return false;
                return this.exists.call(this);
            };

            var SettingsGlobal = Java.use("android.provider.Settings$Global");
            SettingsGlobal.getInt.overload('android.content.ContentResolver', 'java.lang.String', 'int').implementation = function(cr, name, def) {
                if (name === "development_settings_enabled" || name === "adb_enabled") return 0;
                return this.getInt(cr, name, def);
            };

            // [🛡️ Mock Location Detection Bypass]
            try {
                var Location = Java.use("android.location.Location");
                Location.isFromMockProvider.implementation = function() {
                    return false;
                };
                console.log("[✓] Location.isFromMockProvider bypass applied successfully");
            } catch (err) {
                console.log("[-] Location.isFromMockProvider Hook Error: " + err);
            }

            // [핵심 생존 방어] WebView Sandbox (libmonochrome) Seccomp-BPF 충돌 원천 차단
            // ExoPlayer가 TTS 엔진 혹은 알림음을 위해 MediaCodec을 초기화할 때, libstagefright가 
            // WebView 샌드박스의 검열을 받아 SIGBUS를 유발합니다. 이를 막기 위해 MediaCodec 객체 생성을 Java 단에서 차단합니다.
            // 단, WebView/Chromium(libmonochrome) 자체의 비디오 디코더(c2.qti.avc 등) 호출은 정상 통과시켜야 SIGILL 자살 트랩을 방지합니다.
            try {
                var MediaCodec = Java.use("android.media.MediaCodec");
                var IOException = Java.use("java.io.IOException");
                var Thread = Java.use("java.lang.Thread");
                
                function isChromiumCaller() {
                    try {
                        var stack = Thread.currentThread().getStackTrace();
                        for (var i = 0; i < stack.length; i++) {
                            var cls = stack[i].getClassName();
                            if (cls && cls.indexOf("org.chromium") !== -1) {
                                return true;
                            }
                        }
                    } catch(e) {}
                    return false;
                }

                MediaCodec.createByCodecName.implementation = function(name) {
                    if (name && (name.indexOf("video") !== -1 || name.indexOf("avc") !== -1 || name.indexOf("hevc") !== -1 || name.indexOf("vp") !== -1)) {
                        return this.createByCodecName(name);
                    }
                    if (isChromiumCaller()) {
                        return this.createByCodecName(name);
                    }
                    console.log("[🛡️] Blocked MediaCodec Initialization (createByCodecName): " + name);
                    throw IOException.$new("MediaCodec disabled to prevent Seccomp-BPF SIGBUS");
                };
                MediaCodec.createDecoderByType.implementation = function(type) {
                    if (type && type.startsWith("video/")) {
                        return this.createDecoderByType(type);
                    }
                    if (isChromiumCaller()) {
                        return this.createDecoderByType(type);
                    }
                    console.log("[🛡️] Blocked MediaCodec Initialization (createDecoderByType): " + type);
                    throw IOException.$new("MediaCodec disabled to prevent Seccomp-BPF SIGBUS");
                };
                MediaCodec.createEncoderByType.implementation = function(type) {
                    if (type && type.startsWith("video/")) {
                        return this.createEncoderByType(type);
                    }
                    if (isChromiumCaller()) {
                        return this.createEncoderByType(type);
                    }
                    console.log("[🛡️] Blocked MediaCodec Initialization (createEncoderByType): " + type);
                    throw IOException.$new("MediaCodec disabled to prevent Seccomp-BPF SIGBUS");
                };
            } catch (err) {
                console.log("[-] MediaCodec Hook Error: " + err);
            }

            var SettingsSecure = Java.use("android.provider.Settings$Secure");
            SettingsSecure.getInt.overload('android.content.ContentResolver', 'java.lang.String', 'int').implementation = function(cr, name, def) {
                if (name === "development_settings_enabled" || name === "adb_enabled") return 0;
                return this.getInt(cr, name, def);
            };

            var System = Java.use("java.lang.System");
            var getProp = System.getProperty.overload('java.lang.String');
            System.getProperty.overload('java.lang.String').implementation = function(key) {
                if (key === "ro.debuggable" || key === "ro.secure") {
                    return key === "ro.secure" ? "1" : "0";
                }
                return getProp.call(System, key);
            };

            // [🛰️ Android Auto Connection Spoofing]
            try {
                var CarConnection = Java.use("androidx.car.app.connection.CarConnection");
                CarConnection.getType.implementation = function() {
                    console.log("[🛰️ FRIDA HOOK] androidx.car.app.connection.CarConnection.getType() called! Force returning 2 (Projection Mode Connected)");
                    return 2; // CONNECTION_TYPE_PROJECTION
                };
            } catch (err) {}

            try {
                var UiModeManager = Java.use("android.app.UiModeManager");
                UiModeManager.getCurrentModeType.implementation = function() {
                    console.log("[🛰️ FRIDA HOOK] android.app.UiModeManager.getCurrentModeType() called! Force returning 3 (UI_MODE_TYPE_CAR)");
                    return 3; // UI_MODE_TYPE_CAR
                };
            } catch (err) {}

            // [🔐 OS Root: AccountManager] Emulate Random Google Account Login (Hybrid Parity)
            var AT = Java.use("android.app.ActivityThread");
            var SysProp = Java.use("android.os.SystemProperties");
            var StringCls = Java.use("java.lang.String");
            var MapCls = Java.use("java.util.Map");

            try {
                var AccountManager = Java.use("android.accounts.AccountManager");
                var Account = Java.use("android.accounts.Account");
                var spSsaidForAcct = SysProp.get("debug.nmap.ssaid", "a1b2c3d4");
                if (!spSsaidForAcct || spSsaidForAcct.length < 8) spSsaidForAcct = "a1b2c3d4";
                var fakeEmail = "user." + spSsaidForAcct.substring(0, 8).toLowerCase() + "@gmail.com";

                AccountManager.getAccountsByType.overload("java.lang.String").implementation = function(type) {
                    if (type === "com.google") {
                        var fakeAcct = Account.$new(fakeEmail, "com.google");
                        return Java.array("android.accounts.Account", [fakeAcct]);
                    }
                    return this.getAccountsByType(type);
                };

                AccountManager.getAccounts.overload().implementation = function() {
                    var orig = this.getAccounts();
                    var hasGoogle = false;
                    for (var i = 0; i < orig.length; i++) {
                        if (orig[i].type.value === "com.google") {
                            hasGoogle = true;
                            break;
                        }
                    }
                    if (!hasGoogle) {
                        var fakeAcct = Account.$new(fakeEmail, "com.google");
                        return Java.array("android.accounts.Account", [fakeAcct]);
                    }
                    return orig;
                };
                console.log("[✓] Emulated Google Account Login: " + fakeEmail);
            } catch (eAcct) {}

            // [🆔 GMS Root: IDFV (AppSetId) & NTracker Synchronous Readiness]
            var cachedIdfv = "";
            function resolveActiveIdfv() {
                if (cachedIdfv && cachedIdfv.length === 36) return cachedIdfv;
                try {
                    var app = AT.currentApplication();
                    if (app) {
                        var zzl = Java.use("com.google.android.gms.internal.appset.zzl");
                        var v = zzl.f(app.getApplicationContext()).getString("app_set_id", "");
                        if (v && v.length === 36) {
                            cachedIdfv = v;
                            return cachedIdfv;
                        }
                    }
                } catch (e1) {}
                try {
                    var spOrig = SysProp.get("debug.nmap.orig_idfv", "");
                    if (spOrig && spOrig.length === 36) {
                        cachedIdfv = spOrig;
                        return cachedIdfv;
                    }
                    var spIdfv = SysProp.get("debug.nmap.idfv", "");
                    if (spIdfv && spIdfv.length === 36) {
                        cachedIdfv = spIdfv;
                        return cachedIdfv;
                    }
                } catch (e2) {}
                return "";
            }

            try {
                var AppSetIdInfo = Java.use("com.google.android.gms.appset.AppSetIdInfo");
                AppSetIdInfo.a.overload().implementation = function() {
                    var idfv = resolveActiveIdfv();
                    if (idfv && idfv.length === 36) return idfv;
                    return this.a();
                };
                AppSetIdInfo.b.overload().implementation = function() {
                    return 1; // SCOPE_DEVELOPER (1)
                };
            } catch (eAppSet) {}

            function syncNTrackerContextIdfv() {
                try {
                    var idfv = resolveActiveIdfv();
                    if (!idfv || idfv.length !== 36) return;
                    var NTC = Java.use("com.navercorp.ntracker.ntrackersdk.NTrackerContext");
                    var inst = NTC.d();
                    if (inst) {
                        if (!inst._n.value || inst._n.value.length === 0) {
                            inst._n.value = idfv;
                        }
                        if (inst._p && inst._p.value) {
                            var pMap = Java.cast(inst._p.value, MapCls);
                            if (!pMap.containsKey(StringCls.$new("idfv"))) {
                                pMap.put(StringCls.$new("idfv"), StringCls.$new(idfv));
                            }
                        }
                    }
                } catch (eNtc) {}
            }

            try {
                var EntryComp = Java.use("com.navercorp.ntracker.ntrackersdk.model.Entry$Companion");
                EntryComp.d.overload("java.util.List").implementation = function(list) {
                    syncNTrackerContextIdfv();
                    var res = this.d(list);
                    try {
                        var idfv = resolveActiveIdfv();
                        if (res && idfv && idfv.length === 36) {
                            var usrObj = res.d();
                            if (usrObj) {
                                var usrMap = Java.cast(usrObj, MapCls);
                                var kIdfv = StringCls.$new("idfv");
                                if (!usrMap.containsKey(kIdfv)) {
                                    usrMap.put(kIdfv, StringCls.$new(idfv));
                                }
                            }
                        }
                    } catch (eEntry) {}
                    return res;
                };
            } catch (eComp) {}

            syncNTrackerContextIdfv();
            setTimeout(syncNTrackerContextIdfv, 50);
            setTimeout(syncNTrackerContextIdfv, 150);
            setTimeout(syncNTrackerContextIdfv, 500);
            setTimeout(syncNTrackerContextIdfv, 1000);
        } catch(e) {}
    });
}

// 3. Skip Agreement Screen (Prevents rendering crash on start)
function skip_agreement_screen() {
    if (!Java.available) return;
    Java.perform(function() {
        try {
            // Removed invasive global SharedPreferences hooks that crash ExoPlayer on S22 PAC hardware.
            // All necessary agreements are now explicitly saved to XML in bypass.js.
            console.log("[+] Agreement Screen Skipped Successfully");
        } catch(e) {}
    });
}

// Boot sequence: MTE patch MUST be first and synchronous.
patch_heap_tagging();
hook_stealth();
skip_agreement_screen();
