//! 微密文件·经典版（weimi_legacy）——Win7/XP 旧机器客户端。
//! 无参数启动 GUI；带参数走 CLI（脚本化场景）。

mod cli;
mod discovery;
mod gui;
mod httpd;
mod proto;

use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        gui::run_gui();
        ExitCode::SUCCESS
    } else {
        cli::run(&args)
    }
}
