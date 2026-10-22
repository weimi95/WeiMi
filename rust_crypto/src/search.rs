//! 全盘搜索引擎 v2（v1.2.6，搜索升级方案 M1+M2）。
//!
//! M1 排序（docs/search-upgrade-plan.md §二）：
//!   全量命中 → 打分 → Top N。命中质量主导（精确 1000 / 前缀 800 / 词边界 600 /
//!   子串 400 / 仅路径 100），哈希乱码名 −300、临时文件扩展名 −300、超长名递减，
//!   命中密度微加分。多词 AND 每多命中一词加成。
//! M2 语法（§三，Everything 实用子集）：
//!   通配符 * ?（含通配符按整个文件名匹配）、"引号"字面量、空格=AND、|=OR（优先于 AND）、
//!   !=NOT、case:/wholeword:/path:/regex: 修饰符（全局生效）、ext:/size:/dm:/dc: 函数、
//!   audio:/video:/image:/doc:/zip:/exe: 宏（扩展名集与 Dart FileThumbs 同源）。
//!   拼音：查询词为纯 ASCII 时对含中文名实时转拼（全拼+首字母，带进程级缓存）。
//!   size:/dm:/dc: 需要 stat 文件元数据（命中集二次 stat，不动索引格式），
//!   由 flags.stat 门控（设置项默认关），stat 总量封顶防纯函数查询全盘扫盘。
//!
//! FFI：lib.rs 的 index_search（老签名兼容）与 index_search2（带 flags）都走 run()。

use std::collections::HashMap;
use std::sync::Mutex;

// ==================== flags ====================

#[derive(Clone, Copy, Debug)]
pub struct Flags {
    /// 区分大小写（case:）
    pub case: bool,
    /// 全字匹配（wholeword:）
    pub word: bool,
    /// 匹配路径（path:，文件名不含时查完整路径）
    pub path: bool,
    /// 全局正则模式（裸 regex:）
    pub regex: bool,
    /// 拼音实时转拼
    pub pinyin: bool,
    /// 允许 stat 类函数（size:/dm:/dc:；设置默认关）
    pub stat: bool,
}

pub const FLAG_PINYIN: u32 = 1;
pub const FLAG_STAT: u32 = 2;

// ==================== 查询语法树 ====================

#[derive(Clone, Copy, PartialEq, Debug)]
enum Cmp {
    Lt,
    Le,
    Eq,
    Ge,
    Gt,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum DateKind {
    Modified,
    Created,
}

enum Node {
    And(Vec<Node>),
    Or(Vec<Node>),
    Not(Box<Node>),
    /// 文本词。wild=含通配符（按整个文件名匹配）
    Text { raw: String, lower: String, wild: bool },
    /// 正则词（regex:xxx 或全局 regex: 模式下的文本词）
    Regex(String),
    /// 扩展名集合（ext: 或宏），任一命中即过
    Ext(Vec<String>),
    /// size: 条件（字节），全部满足
    Size(Vec<(Cmp, u64)>),
    /// dm:/dc: 条件（纳秒时间戳），全部满足
    Date { kind: DateKind, conds: Vec<(Cmp, i64)> },
}

struct Parsed {
    root: Option<Node>,
    flags: Flags,
    /// 树里是否有 size/dm/dc 节点（决定要不要走 stat 过滤趟）
    needs_stat: bool,
}

impl Node {
    fn walk(&self, f: &mut impl FnMut(&Node)) {
        f(self);
        match self {
            Node::And(v) | Node::Or(v) => v.iter().for_each(|n| n.walk(f)),
            Node::Not(b) => b.walk(f),
            _ => {}
        }
    }
}

// ==================== 解析 ====================

/// 词法：按空白切词，双引号内字面量（含空格）；裸 | 为 OR 运算符，
/// 词中 |（如 *.jpg|*.png）也拆成 OR；词首 ! 为 NOT。
fn tokenize(input: &str) -> Vec<String> {
    let mut toks: Vec<String> = Vec::new();
    let mut cur = String::new();
    let mut in_quote = false;
    let mut flush = |cur: &mut String, toks: &mut Vec<String>| {
        if !cur.is_empty() {
            toks.push(std::mem::take(cur));
        }
    };
    for ch in input.chars() {
        if in_quote {
            if ch == '"' {
                in_quote = false;
                flush(&mut cur, &mut toks); // 引号闭合一律出词（空引号丢弃）
            } else {
                cur.push(ch);
            }
            continue;
        }
        match ch {
            '"' => in_quote = true,
            c if c.is_whitespace() => flush(&mut cur, &mut toks),
            '|' => {
                flush(&mut cur, &mut toks);
                toks.push("|".into());
            }
            '!' if cur.is_empty() => {
                flush(&mut cur, &mut toks);
                toks.push("!".into());
            }
            c => cur.push(c),
        }
    }
    flush(&mut cur, &mut toks);
    toks
}

fn split_list(s: &str) -> Vec<String> {
    s.split(';')
        .map(|x| x.trim().trim_start_matches('.').to_lowercase())
        .filter(|x| !x.is_empty())
        .collect()
}

fn parse_size_value(s: &str) -> Option<u64> {
    let s = s.trim().to_lowercase();
    if s.is_empty() {
        return None;
    }
    // 数字部分 + 单位部分（std 无 str::split_at_position，手写切分）
    let split = s
        .char_indices()
        .find(|(_, c)| !c.is_ascii_digit() && *c != '.')
        .map(|(i, _)| i)
        .unwrap_or(s.len());
    let (num, unit) = s.split_at(split);
    let n: f64 = num.parse().ok()?;
    let mult: u64 = match unit.trim() {
        "" | "b" => 1,
        "kb" | "k" => 1024,
        "mb" | "m" => 1024 * 1024,
        "gb" | "g" => 1024 * 1024 * 1024,
        "tb" | "t" => 1024_u64.pow(4),
        _ => return None,
    };
    Some((n * mult as f64) as u64)
}

/// size:>100mb / >=1gb / <500kb / <=.. / =5mb / 5mb / 1mb..2gb
fn parse_size_conds(s: &str) -> Vec<(Cmp, u64)> {
    let s = s.trim();
    if let Some((a, b)) = s.split_once("..") {
        let (Some(a), Some(b)) = (parse_size_value(a), parse_size_value(b)) else {
            return vec![];
        };
        return vec![(Cmp::Ge, a.min(b)), (Cmp::Le, a.max(b))];
    }
    let (cmp, rest) = if let Some(r) = s.strip_prefix(">=") {
        (Cmp::Ge, r)
    } else if let Some(r) = s.strip_prefix("<=") {
        (Cmp::Le, r)
    } else if let Some(r) = s.strip_prefix('>') {
        (Cmp::Gt, r)
    } else if let Some(r) = s.strip_prefix('<') {
        (Cmp::Lt, r)
    } else if let Some(r) = s.strip_prefix('=') {
        (Cmp::Eq, r)
    } else {
        (Cmp::Eq, s)
    };
    match parse_size_value(rest) {
        Some(v) => vec![(cmp, v)],
        None => vec![],
    }
}

/// dm:today / yesterday / thisweek / lastweek / thismonth / lastmonth /
/// thisyear / lastyear / 2024-01-01 / >2024-01-01 / <2024-01-01 / a..b
/// （解析实现见文件尾「日期解析」，需要 chrono 本地时区）

fn macro_exts(name: &str) -> Option<Vec<String>> {
    let v: &[&str] = match name {
        "audio" => &[
            "mp3", "wav", "flac", "aac", "m4a", "ogg", "wma", "ape", "opus",
        ],
        "video" => &[
            "mp4", "avi", "mkv", "mov", "wmv", "flv", "ts", "3gp", "webm",
            "m4v", "rmvb", "rm", "mpg", "mpeg", "vob",
        ],
        "image" => &[
            "jpg", "jpeg", "png", "gif", "bmp", "webp", "heic", "heif",
            "tiff", "tif", "svg", "ico",
        ],
        "doc" => &[
            "txt", "md", "json", "xml", "csv", "log", "pdf", "doc", "docx",
            "xls", "xlsx", "ppt", "pptx", "html", "htm", "epub", "mobi",
            "rtf", "wps", "et", "dps",
        ],
        "zip" => &["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "cab", "iso"],
        "exe" => &[
            "exe", "msi", "apk", "dmg", "pkg", "deb", "rpm", "appimage", "msix",
        ],
        _ => return None,
    };
    Some(v.iter().map(|s| s.to_string()).collect())
}

/// 单词 → 节点。返回 None 表示这是修饰符（case:/wholeword:/path:/裸 regex:），不产节点。
fn parse_term(tok: &str, flags: &mut Flags) -> Option<Node> {
    let (head, rest) = match tok.split_once(':') {
        Some((h, r)) => (h.to_lowercase(), r),
        None => (String::new(), ""),
    };
    let wild = tok.contains('*') || tok.contains('?');
    let node = match head.as_str() {
        "case" => {
            flags.case = true;
            if rest.is_empty() {
                return None;
            }
            Node::Text {
                raw: rest.to_string(),
                lower: rest.to_lowercase(),
                wild: rest.contains('*') || rest.contains('?'),
            }
        }
        "wholeword" | "wholefilename" | "ww" => {
            flags.word = true;
            if rest.is_empty() {
                return None;
            }
            Node::Text {
                raw: rest.to_string(),
                lower: rest.to_lowercase(),
                wild: rest.contains('*') || rest.contains('?'),
            }
        }
        "path" => {
            flags.path = true;
            if rest.is_empty() {
                return None;
            }
            Node::Text {
                raw: rest.to_string(),
                lower: rest.to_lowercase(),
                wild: rest.contains('*') || rest.contains('?'),
            }
        }
        "regex" => {
            if rest.is_empty() {
                flags.regex = true;
                return None;
            }
            Node::Regex(rest.to_string())
        }
        "ext" => Node::Ext(split_list(rest)),
        "size" => Node::Size(parse_size_conds(rest)),
        "dm" | "datemodified" => Node::Date {
            kind: DateKind::Modified,
            conds: parse_date_conds(rest),
        },
        "dc" | "datecreated" => Node::Date {
            kind: DateKind::Created,
            conds: parse_date_conds(rest),
        },
        "audio" | "video" | "image" | "doc" | "zip" | "exe" => {
            Node::Ext(macro_exts(&head).unwrap_or_default())
        }
        _ => {
            if flags.regex && !wild {
                // 全局正则模式下普通词按正则
                Node::Regex(tok.to_string())
            } else {
                Node::Text {
                    raw: tok.to_string(),
                    lower: tok.to_lowercase(),
                    wild,
                }
            }
        }
    };
    Some(node)
}

fn parse_query(input: &str, mut flags: Flags) -> Parsed {
    let toks = tokenize(input);
    if toks.is_empty() {
        return Parsed {
            root: None,
            flags,
            needs_stat: false,
        };
    }
    // 因子序列：OR（|）优先结合，整体 AND
    let mut factors: Vec<Node> = Vec::new();
    let mut or_group: Vec<Node> = Vec::new();
    let mut i = 0usize;
    let mut pending_or = false;
    while i < toks.len() {
        let tok = &toks[i];
        i += 1;
        if tok == "|" {
            pending_or = true;
            continue;
        }
        let neg = tok == "!";
        let term_tok = if neg {
            match toks.get(i) {
                Some(t) if t != "!" && t != "|" => {
                    i += 1;
                    t.as_str()
                }
                _ => continue, // 悬空 ! 忽略
            }
        } else {
            tok.as_str()
        };
        let node = match parse_term(term_tok, &mut flags) {
            Some(n) => n,
            None => continue, // 修饰符
        };
        let node = if neg { Node::Not(Box::new(node)) } else { node };
        if pending_or {
            if or_group.is_empty() && !factors.is_empty() {
                // a | b：把前一个因子拉进 OR 组
                if let Some(prev) = factors.pop() {
                    or_group.push(prev);
                }
            }
            or_group.push(node);
            pending_or = false;
        } else {
            if !or_group.is_empty() {
                or_group.push(node);
                factors.push(Node::Or(std::mem::take(&mut or_group)));
            } else {
                factors.push(node);
            }
        }
    }
    if !or_group.is_empty() {
        factors.push(Node::Or(or_group));
    }
    let root = match factors.len() {
        0 => None,
        1 => factors.pop(),
        _ => Some(Node::And(factors)),
    };
    let mut needs_stat = false;
    if let Some(r) = &root {
        r.walk(&mut |n| {
            if matches!(n, Node::Size(_) | Node::Date { .. }) {
                needs_stat = true;
            }
        });
    }
    Parsed {
        root,
        flags,
        needs_stat,
    }
}

// ==================== 拼音 ====================

/// 文件名(小写) → (全拼, 首字母)。非汉字字母数字原样保留（"我的report" → "wodereport"/"wdr"）。
/// 进程级缓存（按文件名），上限 15 万条防失控。
static PY_CACHE: Mutex<Option<HashMap<String, (String, String)>>> = Mutex::new(None);
const PY_CACHE_CAP: usize = 150_000;

/// 带 panic 兜底的互斥锁（防 poison 连环 panic，详见 lib.rs lock_or_recover）。
fn lock_or_recover<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn has_han(s: &str) -> bool {
    s.chars().any(|c| ('\u{4E00}'..='\u{9FFF}').contains(&c))
}

fn pinyin_uncached(name_lower: &str) -> (String, String) {
    use pinyin::ToPinyin;
    let mut full = String::with_capacity(name_lower.len() * 2);
    let mut initials = String::with_capacity(name_lower.len());
    for ch in name_lower.chars() {
        if ('\u{4E00}'..='\u{9FFF}').contains(&ch) {
            if let Some(py) = ch.to_pinyin() {
                let plain = py.plain();
                full.push_str(plain);
                if let Some(c) = plain.chars().next() {
                    initials.push(c);
                }
            }
            // 生僻字无拼音：跳过
            continue;
        }
        if ch.is_ascii_alphanumeric() {
            full.push(ch);
            initials.push(ch);
        }
    }
    (full, initials)
}

fn pinyin_of(name_lower: &str) -> (String, String) {
    {
        let g = lock_or_recover(&PY_CACHE);
        if let Some(m) = g.as_ref() {
            if let Some(hit) = m.get(name_lower) {
                return hit.clone();
            }
        }
    }
    let r = pinyin_uncached(name_lower);
    let mut g = lock_or_recover(&PY_CACHE);
    let m = g.get_or_insert_with(HashMap::new);
    if m.len() < PY_CACHE_CAP {
        m.insert(name_lower.to_string(), r.clone());
    }
    r
}

// ==================== 匹配与打分 ====================

/// 词边界字符：字母数字以外都算分隔
fn is_word_char(c: char) -> bool {
    c.is_alphanumeric()
}

/// 在 hay 中找 needle 的词边界命中位置（wholeword 模式）
fn find_wholeword(hay: &str, needle: &str) -> Option<usize> {
    let hb = hay.as_bytes();
    let nb = needle.as_bytes();
    if nb.is_empty() || nb.len() > hb.len() {
        return None;
    }
    let mut from = 0usize;
    while let Some(rel) = hay[from..].find(needle) {
        let pos = from + rel;
        let end = pos + nb.len();
        let before_ok = pos == 0 || !hay[..pos].chars().next_back().is_some_and(is_word_char);
        let after_ok = end == hay.len()
            || !hay[end..].chars().next().is_some_and(is_word_char);
        if before_ok && after_ok {
            return Some(pos);
        }
        from = pos + 1;
        // 防止切进多字节字符
        while from < hb.len() && (hb[from] & 0xC0) == 0x80 {
            from += 1;
        }
    }
    None
}

struct FileCtx<'a> {
    path: &'a str,
    name: &'a str,
    name_lower: &'a str,
    stem_lower: &'a str, // 去掉最后扩展名的文件名（小写）
    ext_lower: &'a str,
    path_lower: Option<String>, // 惰性（仅 path: 修饰符时）
    flags: Flags,
}

impl<'a> FileCtx<'a> {
    fn full_path_lower(&mut self) -> &str {
        if self.path_lower.is_none() {
            self.path_lower = Some(self.path.to_lowercase());
        }
        self.path_lower.as_deref().unwrap_or("")
    }
}

/// 文本词命中质量（方案 §二）：精确 1000 / 前缀 800 / 词边界 600 / 子串 400 /
/// 仅路径 100；拼音全拼 900/700/380，首字母 350。返回 (分数, 命中长度)。
fn score_text(ctx: &mut FileCtx, raw: &str, lower: &str, wild: bool) -> Option<(i32, usize)> {
    if wild {
        // 通配符：按整个文件名匹配（Everything 语义）
        let pat = if ctx.flags.case { raw } else { lower };
        let name_sub = if ctx.flags.case { ctx.name } else { ctx.name_lower };
        if crate::wildcard_match(pat.as_bytes(), name_sub.as_bytes()) {
            return Some((620, name_sub.len()));
        }
        if ctx.flags.path
            && crate::wildcard_match(pat.as_bytes(), ctx.full_path_lower().as_bytes())
        {
            return Some((110, 1));
        }
        return None;
    }
    if ctx.flags.case {
        // 区分大小写：原始串精确子串（全名精确 = 1000）
        if ctx.name == raw {
            return Some((1000, raw.len()));
        }
        if let Some(pos) = ctx.name.find(raw) {
            let boundary = pos == 0 || !ctx.name[..pos].chars().next_back().is_some_and(is_word_char);
            let q = if pos == 0 {
                800
            } else if boundary {
                600
            } else {
                400
            };
            return Some((q, raw.len()));
        }
        if ctx.flags.path && ctx.full_path_lower().contains(&raw.to_lowercase()) {
            return Some((100, 1));
        }
        return None;
    }
    // 默认：不区分大小写子串
    if ctx.name_lower == lower || ctx.stem_lower == lower {
        return Some((1000, lower.len()));
    }
    if let Some(pos) = ctx.name_lower.find(lower) {
        if ctx.flags.word {
            if find_wholeword(ctx.name_lower, lower).is_some() {
                return Some((600, lower.len()));
            }
        } else {
            let boundary =
                pos == 0 || !ctx.name_lower[..pos].chars().next_back().is_some_and(is_word_char);
            let q = if pos == 0 {
                800
            } else if boundary {
                600
            } else {
                400
            };
            return Some((q, lower.len()));
        }
    }
    if ctx.flags.path && ctx.full_path_lower().contains(lower) {
        return Some((100, 1));
    }
    // 拼音兜底：查询词为纯 ASCII 字母数字且文件名含汉字
    if ctx.flags.pinyin
        && !lower.is_empty()
        && lower.bytes().all(|b| b.is_ascii_alphanumeric())
        && has_han(ctx.name_lower)
    {
        let (full, initials) = pinyin_of(ctx.name_lower);
        let stem_py = pinyin_of(ctx.stem_lower);
        if full == lower || stem_py.0 == lower {
            return Some((900, lower.len()));
        }
        if full.starts_with(lower) || stem_py.0.starts_with(lower) {
            return Some((700, lower.len()));
        }
        if full.contains(lower) {
            return Some((380, lower.len()));
        }
        if !initials.is_empty()
            && (initials == lower
                || initials.starts_with(lower)
                || find_wholeword(&initials, lower).is_some())
        {
            return Some((350, lower.len()));
        }
    }
    None
}

fn cmp_ok(c: Cmp, v: i64, target: i64) -> bool {
    match c {
        Cmp::Lt => v < target,
        Cmp::Le => v <= target,
        Cmp::Eq => v == target,
        Cmp::Ge => v >= target,
        Cmp::Gt => v > target,
    }
}

fn eval_node(node: &Node, ctx: &mut FileCtx) -> Option<i32> {
    match node {
        Node::Text { raw, lower, wild } => {
            let (q, mlen) = score_text(ctx, raw, lower, *wild)?;
            // 密度加分：命中长度/文件名长度，短名精确命中 > 长名偶然命中（封顶 +60）
            let n = ctx.name_lower.chars().count().max(1);
            let d = (mlen as f64 / n as f64).min(1.0);
            Some(q + (60.0 * d) as i32)
        }
        Node::Regex(p) => {
            let re = regex::RegexBuilder::new(p)
                .case_insensitive(!ctx.flags.case)
                .size_limit(1 << 20)
                .build()
                .ok()?;
            if re.is_match(ctx.name) {
                Some(500)
            } else if ctx.flags.path && re.is_match(ctx.path) {
                Some(110)
            } else {
                None
            }
        }
        Node::Ext(list) => {
            if list.is_empty() {
                return None;
            }
            list.iter().any(|e| *e == ctx.ext_lower).then_some(500)
        }
        Node::Size(_) | Node::Date { .. } => Some(500), // 真过滤在 stat 趟
        Node::And(v) => {
            let mut sum = 0i32;
            let mut n = 0usize;
            for c in v {
                let s = eval_node(c, ctx)?;
                sum += s;
                n += 1;
            }
            Some(sum + 150 * (n as i32 - 1)) // 多词加成
        }
        Node::Or(v) => {
            let mut best = None;
            for c in v {
                if let Some(s) = eval_node(c, ctx) {
                    best = Some(best.map_or(s, |b: i32| b.max(s)));
                }
            }
            best
        }
        Node::Not(b) => {
            let saved_path = ctx.path_lower.take();
            let r = eval_node(b, ctx);
            ctx.path_lower = saved_path;
            r.is_none().then_some(0)
        }
    }
}

// ==================== stat 趟（size:/dm:/dc:） ====================

/// stat 上限：纯函数查询（如裸 size:>1gb）候选可能全量，封顶防扫盘
const STAT_CAP: usize = 100_000;

fn file_mtime_ns(meta: &std::fs::Metadata) -> Option<i64> {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as i64)
}

fn file_ctime_ns(meta: &std::fs::Metadata) -> Option<i64> {
    meta.created()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_nanos() as i64)
        .or_else(|| file_mtime_ns(meta))
}

fn stat_pass(node: &Node, meta: &std::fs::Metadata) -> bool {
    match node {
        Node::Size(conds) => {
            let sz = meta.len();
            conds.iter().all(|&(c, t)| cmp_ok(c, sz as i64, t as i64))
        }
        Node::Date { kind, conds } => {
            let ts = match kind {
                DateKind::Modified => file_mtime_ns(meta),
                DateKind::Created => file_ctime_ns(meta),
            };
            match ts {
                Some(t) => conds.iter().all(|&(c, target)| cmp_ok(c, t, target)),
                None => false,
            }
        }
        Node::And(v) => v.iter().all(|c| stat_pass(c, meta)),
        Node::Or(v) => v.iter().any(|c| stat_pass(c, meta)),
        Node::Not(b) => !stat_pass(b, meta),
        _ => true,
    }
}

// ==================== 名称质量惩罚（§二.2） ====================

const TEMP_EXTS: &[&str] = &["tmp", "temp", "part", "crdownload", "partial"];

fn penalties(name_lower: &str, ext_lower: &str, name_chars: usize) -> i32 {
    let mut p = 0i32;
    // 哈希特征：≥16 位连续十六进制
    let mut run = 0usize;
    for c in name_lower.chars() {
        if c.is_ascii_hexdigit() {
            run += 1;
            if run >= 16 {
                p -= 300;
                break;
            }
        } else {
            run = 0;
        }
    }
    if TEMP_EXTS.contains(&ext_lower) || name_lower.ends_with(".meta.json") || name_lower.ends_with(".meta") {
        p -= 300;
    }
    if name_chars > 64 {
        p -= ((name_chars - 64) / 32 * 50) as i32;
    }
    p
}

// ==================== 入口 ====================

/// 搜索主流程：全量命中 →（可选 stat 过滤）→ 打分排序 → Top limit。
/// 返回 \n 连接路径（与老协议一致）。
pub fn run(paths: &[String], query: &str, limit: usize, flags: Flags) -> String {
    let query = query.trim();
    if query.is_empty() {
        return String::new();
    }
    let parsed = parse_query(query, flags);
    let Some(root) = parsed.root else {
        return String::new();
    };
    let fl = parsed.flags;
    let mut scored: Vec<(i32, usize, usize)> = Vec::new(); // (score, name_chars, idx)
    for (idx, p) in paths.iter().enumerate() {
        let name_start = p
            .as_bytes()
            .iter()
            .rposition(|&b| b == b'/' || b == b'\\')
            .map(|i| i + 1)
            .unwrap_or(0);
        let name = &p[name_start..];
        let name_lower = name.to_lowercase();
        let (stem_lower, ext_lower) = match name.rfind('.') {
            Some(d) if d > 0 => (&name_lower[..d], &name_lower[d + 1..]),
            _ => (&name_lower[..], ""),
        };
        let name_chars = name_lower.chars().count();
        let mut ctx = FileCtx {
            path: p,
            name,
            name_lower: &name_lower,
            stem_lower,
            ext_lower,
            path_lower: None,
            flags: fl,
        };
        let Some(mut score) = eval_node(&root, &mut ctx) else {
            continue;
        };
        if parsed.needs_stat && fl.stat {
            let Ok(meta) = std::fs::metadata(p) else {
                continue;
            };
            if !stat_pass(&root, &meta) {
                continue;
            }
        }
        score = (score + penalties(&name_lower, ext_lower, name_chars)).max(1);
        scored.push((score, name_chars, idx));
        if scored.len() > STAT_CAP * 4 {
            // 异常防护：命中集离谱大（如裸 ext: 无限流），保底截断防止内存爆
            break;
        }
    }
    scored.sort_by(|a, b| {
        b.0.cmp(&a.0)
            .then(a.1.cmp(&b.1))
            .then(paths[a.2].cmp(&paths[b.2]))
    });
    let take = scored.len().min(limit.max(1));
    let mut out = String::new();
    for &(s, _, idx) in scored.iter().take(take) {
        let _ = s;
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&paths[idx]);
    }
    out
}

// ==================== 日期解析（chrono） ====================

use chrono::{Days, Datelike, Duration as ChronoDuration, Local, NaiveDate, TimeZone};

fn day_start_ns(d: NaiveDate) -> Option<i64> {
    let naive = d.and_hms_opt(0, 0, 0)?;
    Local
        .from_local_datetime(&naive)
        .single()
        .map(|dt| dt.timestamp() * 1_000_000_000)
}

fn parse_date_conds(s: &str) -> Vec<(Cmp, i64)> {
    let s = s.trim().to_lowercase();
    if s.is_empty() {
        return vec![];
    }
    let today = Local::now().date_naive();
    let day_start = |d: NaiveDate| day_start_ns(d);
    // 范围 a..b
    if let Some((a, b)) = s.split_once("..") {
        let (Ok(a), Ok(b)) = (
            NaiveDate::parse_from_str(a.trim(), "%Y-%m-%d"),
            NaiveDate::parse_from_str(b.trim(), "%Y-%m-%d"),
        ) else {
            return vec![];
        };
        let (Some(sa), Some(sb)) = (day_start(a), day_start(b)) else {
            return vec![];
        };
        return if sa <= sb {
            vec![(Cmp::Ge, sa), (Cmp::Lt, sb)]
        } else {
            vec![(Cmp::Ge, sb), (Cmp::Lt, sa)]
        };
    }
    let (cmp, rest) = if let Some(r) = s.strip_prefix('>') {
        (Cmp::Gt, r.to_string())
    } else if let Some(r) = s.strip_prefix('<') {
        (Cmp::Lt, r.to_string())
    } else {
        (Cmp::Eq, s.clone())
    };
    // 相对词
    let monday = today - Days::new(today.weekday().num_days_from_monday() as u64);
    let month_first = |y: i32, m: u32| NaiveDate::from_ymd_opt(y, m, 1);
    let next_month_first = |d: NaiveDate| {
        if d.month() == 12 {
            month_first(d.year() + 1, 1)
        } else {
            month_first(d.year(), d.month() + 1)
        }
    };
    let span = |from: Option<NaiveDate>, to: Option<NaiveDate>| -> Option<Vec<(Cmp, i64)>> {
        let (Some(a), Some(b)) = (day_start(from?), day_start(to?)) else {
            return None;
        };
        Some(vec![(Cmp::Ge, a), (Cmp::Lt, b)])
    };
    let rel = match rest.as_str() {
        "today" => span(Some(today), today.checked_add_days(Days::new(1))),
        "yesterday" => span(Some(today - Days::new(1)), Some(today)),
        "thisweek" => span(Some(monday), monday.checked_add_days(Days::new(7))),
        "lastweek" => span(monday.checked_sub_days(Days::new(7)), Some(monday)),
        "thismonth" => {
            let first = today.with_day(1);
            let next = first.and_then(next_month_first);
            span(first, next)
        }
        "lastmonth" => match today.with_day(1) {
            Some(first) => match first.checked_sub_days(Days::new(1)).and_then(|e| e.with_day(1)) {
                Some(prev) => span(Some(prev), Some(first)),
                None => None,
            },
            None => None,
        },
        "thisyear" => span(
            month_first(today.year(), 1),
            month_first(today.year() + 1, 1),
        ),
        "lastyear" => span(
            month_first(today.year() - 1, 1),
            month_first(today.year(), 1),
        ),
        _ => None,
    };
    if let Some(v) = rel {
        return v;
    }
    // 绝对日期
    let Ok(d) = NaiveDate::parse_from_str(&rest, "%Y-%m-%d") else {
        return vec![];
    };
    match cmp {
        Cmp::Gt => day_start(d + ChronoDuration::days(1)).map(|t| vec![(Cmp::Gt, t)]),
        Cmp::Lt => day_start(d).map(|t| vec![(Cmp::Lt, t)]),
        _ => span(Some(d), d.checked_add_days(Days::new(1))),
    }
    .unwrap_or_default()
}

// ==================== 单元测试 ====================

#[cfg(test)]
mod tests {
    use super::*;

    fn f() -> Flags {
        Flags {
            case: false,
            word: false,
            path: false,
            regex: false,
            pinyin: true,
            stat: false,
        }
    }

    fn paths() -> Vec<String> {
        vec![
            r"C:\work\项目\抖音视频剪辑教程.mp4".into(),
            r"C:\work\4176a3b8f9e2d1c0a5b6c7d8e9f0a1b2.meta.json".into(),
            r"C:\work\douyin_setup_v1.2.3.exe".into(),
            r"C:\photos\海边度假照片.jpg".into(),
            r"C:\work\report_2024_final.docx".into(),
            r"C:\tmp\notes.txt".into(),
        ]
    }

    #[test]
    fn test_rank_exact_and_prefix_over_noise() {
        let out = run(&paths(), "douyin", 10, f());
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines.len(), 2);
        // 前缀命中 > 子串命中
        assert!(lines[0].ends_with("douyin_setup_v1.2.3.exe"), "{lines:?}");
    }

    #[test]
    fn test_hash_noise_sinks() {
        let ps = vec![
            r"C:\a\4176a3b8f9e2d1c0a5b6c7d8e9f0a1b2.meta.json".into(),
            r"C:\a\4176 备份说明.txt".into(),
        ];
        let out = run(&ps, "4176", 10, f());
        assert!(out.lines().next().unwrap().ends_with("备份说明.txt"));
    }

    #[test]
    fn test_multi_word_and() {
        let out = run(&paths(), "report final", 10, f());
        assert_eq!(out.lines().count(), 1);
        assert!(out.contains("report_2024_final.docx"));
    }

    #[test]
    fn test_or_not_quotes() {
        // OR
        let out = run(&paths(), "*.jpg | *.mp4", 10, f());
        assert_eq!(out.lines().count(), 2);
        // NOT
        let out = run(&paths(), "*.txt !notes", 10, f());
        assert_eq!(out.lines().count(), 0);
        // 引号字面量（原样匹配，不做词切分）
        let out = run(&paths(), "\"2024_final\"", 10, f());
        assert_eq!(out.lines().count(), 1);
        // 同词不加引号被切成多词 AND（两词分别子串命中 → 同样命中）
        let out = run(&paths(), "2024 final", 10, f());
        assert_eq!(out.lines().count(), 1);
        // 但词序敏感的字面量只有引号能表达（"final 2024" 两词 AND 仍命中，引号则不命中）
        let out = run(&paths(), "\"final 2024\"", 10, f());
        assert_eq!(out.lines().count(), 0);
    }

    #[test]
    fn test_ext_and_macros() {
        let out = run(&paths(), "ext:jpg;mp4", 10, f());
        assert_eq!(out.lines().count(), 2);
        let out = run(&paths(), "image:", 10, f());
        assert!(out.contains("海边度假照片.jpg"));
        let out = run(&paths(), "audio:", 10, f());
        assert!(out.is_empty());
    }

    #[test]
    fn test_pinyin_full_and_initials() {
        let out = run(&paths(), "douyin", 10, f());
        assert!(out.contains("抖音视频剪辑教程.mp4"));
        let out = run(&paths(), "dy", 10, f());
        assert!(out.contains("抖音视频剪辑教程.mp4"));
    }

    #[test]
    fn test_wholeword_and_case() {
        let out = run(&paths(), "wholeword:2024", 10, f());
        assert!(out.contains("report_2024_final.docx"));
        // wholeword:notes 应命中（notes.txt 词边界）
        let out = run(&paths(), "wholeword:notes", 10, f());
        assert!(out.contains("notes.txt"));
    }

    #[test]
    fn test_size_gate() {
        // stat 关：size: 条件不过滤（占位 500 分照常命中）
        let out = run(&paths(), "size:>1kb", 10, f());
        assert!(!out.is_empty());
    }

    #[test]
    fn test_regex() {
        let out = run(&paths(), "regex:^report_\\d{4}", 10, f());
        assert!(out.contains("report_2024_final.docx"));
    }

    #[test]
    fn test_limit_and_empty() {
        assert!(run(&paths(), "", 10, f()).is_empty());
        let out = run(&paths(), "*", 2, f());
        assert_eq!(out.lines().count(), 2);
    }

    #[test]
    fn test_malformed_queries_never_panic() {
        // v1.2.11 防闪退回归：畸形/边界查询串必须安全走完（曾因 unwrap panic
        // 跨 FFI abort 宿主进程，表现为输入搜索词 UI 即闪退）。
        for q in [
            "|", "||", "a|", "|a", "a|b|", "!", "!!", "! ", "a !", "!|",
            "\"", "\"\"", "\"abc", "a\"b", "<", ">", "<>", "()", "(", ")",
            "regex:", "regex:[", "regex:(", "ext:", "ext:;", "ext:;;",
            "size:", "size:>", "size:>abc", "size:>1", "size:1..2..3",
            "dm:", "dm:>", "dm:2026", "dm:2026-13-45", "dc:a..b",
            "case:", "wholeword:", "path:", "\\", "\\\\", "*", "?", "**",
            "a b c d e f g", "   ", "\t\n", "!", "!!a", "!a!", "a!b",
            "中文|拼音", "🎉", "\u{0}\u{1}", "a\u{FFFF}b",
        ] {
            let _ = run(&paths(), q, 10, f());
            let _ = parse_query(q, f());
        }
    }
}
