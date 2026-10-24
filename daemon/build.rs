use embed_manifest::{embed_manifest, new_manifest};

fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        // 默认模板即含 Microsoft.Windows.Common-Controls v6 依赖 + DPI 感知
        match embed_manifest(new_manifest("Weimi.Daemon")) {
            Ok(_) => println!("cargo:warning=manifest embedded OK"),
            Err(e) => println!("cargo:warning=manifest embed FAILED: {}", e),
        }
        println!("cargo:rerun-if-changed=build.rs");
    }
}
