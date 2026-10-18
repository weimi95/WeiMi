//! 微密文件·经典版（weimi_legacy）——Win7/XP 旧机器客户端。
//!
//! 加密内核直接复用 rust_crypto crate（与主程序同一份代码），
//! .wemi 格式兼容靠「同一个 crate」构造性保证，不存在重新实现漂移。
//!
//! 计划形态：CLI（M2）→ native-windows-gui 图形界面 + 飞传（M3）。
//! 当前进度：CLI 加解密。

use std::ffi::CString;
use std::io::Write;
use std::path::Path;
use std::process::ExitCode;

const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Windows 控制台切 UTF-8 输出，避免中文提示在 GBK 代码页下乱码。
/// XP 起支持 SetConsoleOutputCP(65001)。
fn set_utf8_console() {
    #[link(name = "kernel32")]
    extern "system" {
        fn SetConsoleOutputCP(codepage: u32) -> i32;
    }
    unsafe {
        SetConsoleOutputCP(65001);
    }
}

fn cpu_cores() -> usize {
    std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(4)
}

fn to_c(s: &str) -> Result<CString, String> {
    CString::new(s).map_err(|_| format!("路径含非法字符（NUL）: {s}"))
}

/// 终端读密码。Windows 无稳定的隐藏输入手段（getpass 不可用），
/// 先可见读入；GUI 阶段改用密码框。
fn prompt_password() -> Result<String, String> {
    print!("请输入密码: ");
    let _ = std::io::stdout().flush();
    let mut line = String::new();
    std::io::stdin()
        .read_line(&mut line)
        .map_err(|e| format!("读取输入失败: {e}"))?;
    Ok(line.trim_end_matches(['\r', '\n']).to_string())
}

/// 取密码：-p 优先，否则交互输入；空密码直接拒（加密没意义）。
fn resolve_password(opt: &Option<String>, confirm: bool) -> Result<Vec<u8>, String> {
    let pw = match opt {
        Some(p) => p.clone(),
        None => prompt_password()?,
    };
    if pw.is_empty() {
        return Err("密码不能为空".into());
    }
    if confirm {
        let again = match opt {
            Some(_) => pw.clone(), // -p 显式给出视为已确认
            None => {
                print!("请再输入一次: ");
                let _ = std::io::stdout().flush();
                let mut line = String::new();
                std::io::stdin()
                    .read_line(&mut line)
                    .map_err(|e| format!("读取输入失败: {e}"))?;
                line.trim_end_matches(['\r', '\n']).to_string()
            }
        };
        if pw != again {
            return Err("两次输入的密码不一致".into());
        }
    }
    Ok(pw.into_bytes())
}

fn ensure_input(path: &str) -> Result<(), String> {
    if !Path::new(path).is_file() {
        return Err(format!("输入文件不存在: {path}"));
    }
    Ok(())
}

fn encrypt_cmd(
    input: &str,
    output: &str,
    password: &[u8],
    hint: Option<&str>,
) -> Result<(), String> {
    ensure_input(input)?;
    if Path::new(output).exists() {
        return Err(format!("输出文件已存在: {output}"));
    }
    let inp = to_c(input)?;
    let out = to_c(output)?;
    let hint_c = match hint {
        Some(h) => Some(to_c(h)?),
        None => None,
    };
    let hint_ptr = match &hint_c {
        Some(c) => c.as_ptr(),
        None => std::ptr::null(),
    };
    let rc = rust_crypto::encrypt_file(
        inp.as_ptr(),
        out.as_ptr(),
        password.as_ptr(),
        password.len(),
        hint_ptr,
        false, // is_mobile
        cpu_cores(),
    );
    match rc {
        0 => {
            println!("已加密: {input} -> {output}");
            Ok(())
        }
        -1 => Err("参数错误（路径含非法字符？）".into()),
        _ => Err(format!("加密失败（错误码 {rc}）：请检查输入文件是否可读、磁盘空间是否足够")),
    }
}

fn decrypt_cmd(input: &str, output: &str, password: &[u8]) -> Result<(), String> {
    ensure_input(input)?;
    if Path::new(output).exists() {
        return Err(format!("输出文件已存在: {output}"));
    }
    let inp = to_c(input)?;
    let out = to_c(output)?;
    let run = |inp: &CString, out: &CString| rust_crypto::decrypt_file(
        inp.as_ptr(),
        out.as_ptr(),
        password.as_ptr(),
        password.len(),
        false,
        cpu_cores(),
    );
    let mut rc = run(&inp, &out);
    // -4：输出目录缺失。先建目录再重试一次（缓存被清理/首次使用的常见场景）。
    if rc == -4 {
        if let Some(parent) = Path::new(output).parent() {
            if !parent.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(parent);
            }
        }
        rc = run(&inp, &out);
    }
    match rc {
        0 => {
            println!("已解密: {input} -> {output}");
            Ok(())
        }
        -1 => Err("参数错误（路径含非法字符？）".into()),
        -2 => Err("密码不正确，或文件已损坏".into()),
        -4 => Err(format!("输出目录不可写: {}", Path::new(output).parent().unwrap_or(Path::new("")).display())),
        _ => Err(format!("解密失败（错误码 {rc}）")),
    }
}

fn usage() {
    println!(
        "微密文件·经典版 v{VERSION}（Win7/XP 旧机器客户端）\n\
         \n\
         用法:\n\
         \x20 weimi_legacy encrypt <输入文件> <输出文件> [-p 密码] [-h 密码提示]\n\
         \x20 weimi_legacy decrypt <输入文件> <输出文件> [-p 密码]\n\
         \x20 weimi_legacy --version\n\
         \n\
         说明:\n\
         \x20 - 加解密格式与微密文件主程序完全一致（.wemi）\n\
         \x20 - 不带 -p 时交互输入密码；加密需输入两遍\n\
         \x20 - 保险箱导出的 .wemi（v3）同样支持解密"
    );
}

fn main() -> ExitCode {
    set_utf8_console();
    let args: Vec<String> = std::env::args().skip(1).collect();

    let mut password: Option<String> = None;
    let mut hint: Option<String> = None;
    let mut positional: Vec<String> = Vec::new();
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "-p" | "--password" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("错误: -p 缺少参数");
                    return ExitCode::from(2);
                }
                password = Some(args[i].clone());
            }
            "-h" | "--hint" => {
                i += 1;
                if i >= args.len() {
                    eprintln!("错误: -h 缺少参数");
                    return ExitCode::from(2);
                }
                hint = Some(args[i].clone());
            }
            "--version" | "-V" => {
                println!("weimi_legacy v{VERSION}");
                return ExitCode::SUCCESS;
            }
            "--help" | "-?" => {
                usage();
                return ExitCode::SUCCESS;
            }
            other => positional.push(other.to_string()),
        }
        i += 1;
    }

    if positional.is_empty() {
        usage();
        return ExitCode::from(2);
    }

    let cmd = positional[0].as_str();
    let rest = &positional[1..];
    let result = match cmd {
        "encrypt" | "decrypt" => {
            if rest.len() != 2 {
                Err(format!("用法: weimi_legacy {cmd} <输入文件> <输出文件> [-p 密码]"))
            } else {
                match resolve_password(&password, cmd == "encrypt") {
                    Err(e) => Err(e),
                    Ok(pw) => {
                        if cmd == "encrypt" {
                            encrypt_cmd(&rest[0], &rest[1], &pw, hint.as_deref())
                        } else {
                            decrypt_cmd(&rest[0], &rest[1], &pw)
                        }
                    }
                }
            }
        }
        _ => Err(format!("未知命令: {cmd}")),
    };

    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(e) => {
            eprintln!("错误: {e}");
            ExitCode::FAILURE
        }
    }
}
