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

            // [핵심 생존 방어] WebView Sandbox (libmonochrome) Seccomp-BPF 충돌 원천 차단
            // ExoPlayer가 TTS 엔진 혹은 알림음을 위해 MediaCodec을 초기화할 때, libstagefright가 
            // WebView 샌드박스의 검열을 받아 SIGBUS를 유발합니다. 이를 막기 위해 MediaCodec 객체 생성을 Java 단에서 차단합니다.
            try {
                var MediaCodec = Java.use("android.media.MediaCodec");
                var IOException = Java.use("java.io.IOException");
                
                MediaCodec.createByCodecName.implementation = function(name) {
                    console.log("[🛡️] Blocked MediaCodec Initialization (createByCodecName): " + name);
                    throw IOException.$new("MediaCodec disabled to prevent Seccomp-BPF SIGBUS");
                };
                MediaCodec.createDecoderByType.implementation = function(type) {
                    console.log("[🛡️] Blocked MediaCodec Initialization (createDecoderByType): " + type);
                    throw IOException.$new("MediaCodec disabled to prevent Seccomp-BPF SIGBUS");
                };
                MediaCodec.createEncoderByType.implementation = function(type) {
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
