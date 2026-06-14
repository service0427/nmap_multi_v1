/* 
   Core Survival System (Lightweight for A-Series)
   - Goal: Prevent App Crash with minimal performance overhead.
*/

console.log("[*] Core Survival System Light Loaded");

function patch_mte_light() {
    try {
        var libc = Process.getModuleByName("libc.so");
        var prctl = null;
        libc.enumerateExports().forEach(function(exp) { if (exp.name === "prctl") prctl = exp.address; });
        if (prctl) {
            // Proactively disable MTE
            var prctl_func = new NativeFunction(prctl, 'int', ['int', 'uint64', 'uint64', 'uint64', 'uint64']);
            prctl_func(53, 0, 0, 0, 0); // PR_SET_TAGGED_ADDR_CTRL

            // Also intercept to block future enabling
            Interceptor.attach(prctl, {
                onEnter: function(args) {
                    if (args[0].toInt32() === 53) { args[1] = ptr(0); }
                }
            });
            console.log("[✓] MTE Patch Active (Light)");
        }
    } catch(e) {}
}

function skip_agreement_light() {
    if (!Java.available) return;
    Java.perform(function() {
        try {
            var SharedPreferencesImpl = Java.use("android.app.SharedPreferencesImpl");
            SharedPreferencesImpl.getBoolean.implementation = function(k, d) {
                if (k === "NaviTtsTurnGuide" || k === "NaviSafetyGuide") {
                    return false;
                }
                return this.getBoolean(k, d);
            };
            console.log("[*] TTS Crash Prevention Applied (Agreements left to Native/XML)");
        } catch(e) {}
    });
}

// Execute MTE patch synchronously before anything else
patch_mte_light();
// Execute Java hooks safely
skip_agreement_light();
