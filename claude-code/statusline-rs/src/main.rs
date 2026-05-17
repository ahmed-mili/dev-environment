// Port Rust de statusline.ps1 — cible 10 Hz (refreshInterval=0.1 dans settings.json).
//
// L'enjeu : PowerShell met ~420 ms par spawn, donc refreshInterval < 0.5 s y kill
// le process avant qu'il produise sa sortie (cf. la fonction I() dans claude.exe qui
// appelle `_.current?.abort()` a chaque tick). Un binaire natif demarre en ~10 ms =
// largement sous le seuil = on tient 10 Hz sans abort.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use chrono::{DateTime, Datelike, Local, TimeZone, Utc, Weekday};
use serde::Deserialize;
use serde_json::Value;

#[cfg(windows)]
use std::os::windows::process::CommandExt;
#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x08000000;

const RESET: &str = "\x1b[0m";

fn rgb(r: u8, g: u8, b: u8) -> String {
    format!("\x1b[38;2;{};{};{}m", r, g, b)
}
fn bg(r: u8, g: u8, b: u8) -> String {
    format!("\x1b[48;2;{};{};{}m", r, g, b)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn file_age_secs(path: &Path) -> Option<f64> {
    let m = fs::metadata(path).ok()?;
    let mtime = m.modified().ok()?;
    Some(
        SystemTime::now()
            .duration_since(mtime)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0),
    )
}

fn file_mtime_utc(path: &Path) -> Option<DateTime<Utc>> {
    let m = fs::metadata(path).ok()?;
    let mtime = m.modified().ok()?;
    let d = mtime.duration_since(UNIX_EPOCH).ok()?;
    Utc.timestamp_opt(d.as_secs() as i64, d.subsec_nanos()).single()
}

fn touch(path: &Path) {
    if let Some(parent) = path.parent() {
        let _ = fs::create_dir_all(parent);
    }
    // Cree ou met a jour le mtime
    let _ = fs::File::create(path);
}

fn run_git(dir: &str, args: &[&str]) -> Option<String> {
    let mut cmd = Command::new("git");
    cmd.arg("-C").arg(dir).args(args);
    cmd.stdin(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);
    let out = cmd.output().ok()?;
    if !out.status.success() {
        return None;
    }
    String::from_utf8(out.stdout).ok().map(|s| s.trim_end().to_string())
}

// =================== USAGE / EFFORT / FORMATTING HELPERS ===================

fn get_usage_color(pct: f64, stale: bool) -> String {
    if stale {
        if pct < 50.0 { return rgb(130, 175, 145); }
        if pct < 70.0 { return rgb(195, 195, 165); }
        if pct < 85.0 { return rgb(200, 170, 145); }
        return rgb(195, 130, 130);
    }
    if pct < 50.0 { return rgb(80, 250, 123); }
    if pct < 70.0 { return rgb(241, 250, 140); }
    if pct < 85.0 { return rgb(255, 184, 108); }
    rgb(255, 85, 85)
}

fn format_tokens(n: i64) -> String {
    if n < 1000 { return n.to_string(); }
    if n < 1_000_000 {
        let v = (n as f64 / 1000.0).round() as i64;
        return format!("{}k", v);
    }
    let v = (n as f64 / 1_000_000.0 * 10.0).round() / 10.0;
    // Force '.' decimal (Rust default, donc OK).
    format!("{:.1}M", v)
}

fn format_bar(pct: f64, col: &str, width: usize) -> String {
    let mut filled = (pct / 100.0 * width as f64).round() as i64;
    if filled > width as i64 { filled = width as i64; }
    if filled < 0 { filled = 0; }
    let filled = filled as usize;
    let empty = width - filled;
    let rail = rgb(80, 80, 95);
    format!(
        "{}{}{}{}{}",
        col,
        "\u{25AC}".repeat(filled),
        rail,
        "\u{25AC}".repeat(empty),
        RESET
    )
}

fn get_effort_display(level: Option<&str>) -> String {
    let Some(level) = level else { return String::new(); };
    if level.is_empty() { return String::new(); }
    let bold = "\x1b[1m";
    let nobold = "\x1b[22m";
    let rst = "\x1b[0m";
    let label = level;

    // Frame avance toutes les 200 ms (~5 Hz) -- vitesse perceptuelle qui matche
    // le picker /effort. Le refreshInterval reste a 0.1 (10 Hz) pour avoir un
    // statusline qui reagit instantanement aux state changes (model, ctx tokens,
    // git status), mais l'animation effort ne progresse que d'une frame toutes
    // les 200 ms (= 2 refreshes successifs montrent la meme frame).
    let now = now_ms();

    match level {
        "low" => format!("\x1b[93m{}{}{}", bold, label, rst),
        "medium" => format!("\x1b[92m{}{}{}", bold, label, rst),
        "high" => format!("\x1b[94m{}{}{}", bold, label, rst),
        "xhigh" => {
            let chars: Vec<char> = label.chars().collect();
            let period = (chars.len() as i64) + 4;
            let mut frame = (now / 200) % period;
            if frame < 0 { frame += period; }
            let mut s = String::new();
            for (i, c) in chars.iter().enumerate() {
                let i = i as i64;
                if i == frame {
                    s.push_str(&rgb(208, 180, 255));
                    s.push_str(bold);
                } else if i == frame - 1 || i == frame + 1 {
                    s.push_str("\x1b[95m");
                    s.push_str(bold);
                } else {
                    s.push_str("\x1b[95m");
                    s.push_str(nobold);
                }
                s.push(*c);
            }
            s.push_str(rst);
            s
        }
        "max" => {
            let palette = [
                "\x1b[31m", "\x1b[91m", "\x1b[33m", "\x1b[32m", "\x1b[36m", "\x1b[34m",
                "\x1b[35m",
            ];
            let chars: Vec<char> = label.chars().collect();
            let frame = now / 200;
            let palette_len = palette.len() as i64;
            let mut s = String::new();
            for (i, c) in chars.iter().enumerate() {
                let i = i as i64;
                let mut idx = (i + frame) % palette_len;
                if idx < 0 { idx += palette_len; }
                s.push_str(palette[idx as usize]);
                s.push_str(bold);
                s.push(*c);
            }
            s.push_str(rst);
            s
        }
        _ => String::new(),
    }
}

fn format_reset(reset_at: &Value, reference: Option<DateTime<Utc>>) -> Option<String> {
    let s = reset_at.as_str()?;
    let reset_utc = DateTime::parse_from_rfc3339(s).ok()?.with_timezone(&Utc);
    let now = reference.unwrap_or_else(Utc::now);
    let delta = reset_utc.signed_duration_since(now);
    if delta.num_seconds() <= 0 {
        return Some("now".to_string());
    }
    let total_minutes = delta.num_seconds() as f64 / 60.0;
    if total_minutes < 60.0 {
        return Some(format!("{}m", total_minutes.floor() as i64));
    }
    let total_hours = delta.num_seconds() as f64 / 3600.0;
    if total_hours < 24.0 {
        let h = total_hours.floor() as i64;
        let m = (delta.num_seconds() - h * 3600) / 60;
        return Some(format!("{}h{:02}m", h, m));
    }
    let local = reset_utc.with_timezone(&Local);
    let day_abbr = match local.weekday() {
        Weekday::Sun => "dim",
        Weekday::Mon => "lun",
        Weekday::Tue => "mar",
        Weekday::Wed => "mer",
        Weekday::Thu => "jeu",
        Weekday::Fri => "ven",
        Weekday::Sat => "sam",
    };
    Some(format!("{}. {}", day_abbr, local.format("%H:%M")))
}

// =================== GIT ===================

#[derive(Default)]
struct GitInfo {
    branch: Option<String>,
    sha: Option<String>,
    ahead: i32,
    behind: i32,
    dirty: i32,
    fetch_stale: bool,
}

fn find_git_root(start: &str) -> Option<PathBuf> {
    let mut probe = PathBuf::from(start);
    loop {
        if probe.join(".git").exists() {
            return Some(probe);
        }
        if !probe.pop() {
            return None;
        }
    }
}

fn compute_git(dir: &str) -> GitInfo {
    let mut info = GitInfo::default();
    let Some(root) = find_git_root(dir) else { return info; };

    let Some(branch) = run_git(dir, &["rev-parse", "--abbrev-ref", "HEAD"]) else {
        return info;
    };
    if branch.is_empty() {
        return info;
    }
    info.branch = Some(branch);

    // Background fetch cooldown 30s
    let marker = root.join(".git").join("statusline-last-fetch");
    let needs_fetch = match file_age_secs(&marker) {
        Some(age) => age >= 30.0,
        None => true,
    };
    if needs_fetch {
        touch(&marker);
        let mut cmd = Command::new("git");
        cmd.args(["-C", dir, "fetch", "--quiet"]);
        cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        #[cfg(windows)]
        cmd.creation_flags(CREATE_NO_WINDOW | 0x00000008 /* DETACHED_PROCESS */);
        let _ = cmd.spawn();
    }

    // Status porcelain v2
    if let Some(out) = run_git(dir, &["status", "--porcelain=v2", "--branch"]) {
        for line in out.lines() {
            if let Some(rest) = line.strip_prefix("# branch.oid ") {
                let oid = rest.trim();
                if oid.len() >= 7 {
                    info.sha = Some(oid[..7].to_string());
                }
            } else if let Some(rest) = line.strip_prefix("# branch.ab ") {
                // format: +N -M
                let parts: Vec<&str> = rest.split_whitespace().collect();
                if parts.len() == 2 {
                    if let Some(a) = parts[0].strip_prefix('+') {
                        info.ahead = a.parse().unwrap_or(0);
                    }
                    if let Some(b) = parts[1].strip_prefix('-') {
                        info.behind = b.parse().unwrap_or(0);
                    }
                }
            } else if let Some(first) = line.chars().next() {
                // Premier char : 1=change, 2=renomme, ?=untracked, u=unmerged
                if matches!(first, '1' | '2' | '?' | 'u') && line.chars().nth(1) == Some(' ') {
                    info.dirty += 1;
                }
            }
        }
    }

    // FETCH_HEAD staleness check
    let fetch_head = root.join(".git").join("FETCH_HEAD");
    if let Some(age) = file_age_secs(&fetch_head) {
        if age > 150.0 {
            info.fetch_stale = true;
        }
    }

    info
}

// =================== USAGE / AUTH ===================

#[derive(Deserialize)]
struct CredsRoot {
    #[serde(rename = "claudeAiOauth")]
    claude_ai_oauth: Option<CredsOauth>,
}
#[derive(Deserialize)]
struct CredsOauth {
    #[serde(rename = "accessToken")]
    access_token: Option<String>,
    #[serde(rename = "subscriptionType")]
    subscription_type: Option<String>,
}

fn read_credentials(claude_dir: &Path) -> Option<CredsRoot> {
    let path = claude_dir.join(".credentials.json");
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

struct UsageResult {
    json: Option<Value>,
    stale: bool,
    reference: Option<DateTime<Utc>>,
}

fn read_usage(claude_dir: &Path) -> UsageResult {
    let cache_path = claude_dir.join("usage-cache.json");
    let ratelimit_path = claude_dir.join("usage-ratelimit.txt");

    let mut usage: Option<Value> = None;

    // Cache 60s
    if let Some(age) = file_age_secs(&cache_path) {
        if age < 60.0 {
            if let Ok(raw) = fs::read_to_string(&cache_path) {
                usage = serde_json::from_str(&raw).ok();
            }
        }
    }

    // Cooldown 5 min apres 429
    let mut in_cooldown = false;
    if usage.is_none() {
        if let Ok(raw) = fs::read_to_string(&ratelimit_path) {
            if let Ok(ts) = DateTime::parse_from_rfc3339(raw.trim()) {
                let elapsed = Utc::now().signed_duration_since(ts.with_timezone(&Utc));
                if elapsed.num_seconds() < 300 {
                    in_cooldown = true;
                }
            }
        }
    }

    if usage.is_none() && !in_cooldown {
        if let Some(creds) = read_credentials(claude_dir) {
            if let Some(token) = creds.claude_ai_oauth.as_ref().and_then(|o| o.access_token.clone()) {
                let agent = ureq::AgentBuilder::new()
                    .timeout(Duration::from_secs(4))
                    .build();
                match agent
                    .get("https://api.anthropic.com/api/oauth/usage")
                    .set("Authorization", &format!("Bearer {}", token))
                    .set("anthropic-beta", "oauth-2025-04-20")
                    .set("User-Agent", "claude-code/2.0.32")
                    .set("Accept", "application/json, text/plain, */*")
                    .set("Content-Type", "application/json")
                    .call()
                {
                    Ok(resp) => {
                        if let Ok(body) = resp.into_string() {
                            if let Ok(v) = serde_json::from_str::<Value>(&body) {
                                let _ = fs::write(&cache_path, body.as_bytes());
                                let _ = fs::remove_file(&ratelimit_path);
                                usage = Some(v);
                            }
                        }
                    }
                    Err(ureq::Error::Status(429, _)) => {
                        let _ = fs::write(&ratelimit_path, Utc::now().to_rfc3339().as_bytes());
                    }
                    Err(_) => {}
                }
            }
        }
    }

    // Fallback stale : reutiliser le cache meme vieux
    let mut stale = false;
    let mut reference: Option<DateTime<Utc>> = None;
    if usage.is_none() && cache_path.exists() {
        if let Ok(raw) = fs::read_to_string(&cache_path) {
            usage = serde_json::from_str(&raw).ok();
            if usage.is_some() {
                stale = true;
                reference = file_mtime_utc(&cache_path);
            }
        }
    }

    UsageResult { json: usage, stale, reference }
}

// =================== BUILD LINE 1 (banner) ===================

struct GradStop(u8, u8, u8);

struct BannerSeg {
    text: String,
    fg: String,
}

#[allow(clippy::too_many_arguments)]
fn build_line1(
    dir: &str,
    git: &GitInfo,
    mode: Option<&str>,
    model: Option<&str>,
    effort: Option<&str>,
    ctx_pct: Option<f64>,
    ctx_tokens: Option<i64>,
    ctx_size: Option<i64>,
    cost: Option<f64>,
) -> String {
    // Couleur de fin de banner (chevron + dernier stop ou fond uni)
    let (p_r, p_g, p_b, grad_stops): (u8, u8, u8, Option<Vec<GradStop>>) = match mode {
        Some("bypassPermissions") => (255, 121, 198, None),
        Some("plan") => (139, 233, 253, None),
        Some("acceptEdits") => (80, 250, 123, None),
        Some("dontAsk") => (189, 147, 249, None),
        Some("auto") => (255, 184, 108, None),
        _ => {
            let stops = vec![
                GradStop(180, 190, 254),
                GradStop(137, 180, 250),
                GradStop(116, 199, 236),
            ];
            let last = stops.last().unwrap();
            (last.0, last.1, last.2, Some(stops))
        }
    };
    let path_fg = rgb(p_r, p_g, p_b);
    let path_bg = bg(p_r, p_g, p_b);

    // Section cost (banner intermediaire)
    let s_cost = (45u8, 55u8, 45u8);
    let s_cost_bg = bg(s_cost.0, s_cost.1, s_cost.2);
    let s_cost_fg = rgb(166, 227, 161);

    // Section 2 (model + ctx)
    let s2 = (60u8, 64u8, 80u8);
    let s2_bg = bg(s2.0, s2.1, s2.2);
    let s2_fg = rgb(220, 220, 220);

    let path_text_fg = rgb(25, 28, 42);
    let chevron = '\u{E0B0}';

    // Construction segments du banner path
    let mut segs: Vec<BannerSeg> = vec![BannerSeg {
        text: format!(" {}", dir),
        fg: path_text_fg.clone(),
    }];

    if let Some(branch) = &git.branch {
        let branch_fg = rgb(60, 65, 80);
        let branch_sync_fg = if git.fetch_stale { rgb(200, 170, 100) } else { branch_fg.clone() };

        let mut prefix = format!(" ({}", branch);
        if let Some(sha) = &git.sha {
            prefix.push_str(&format!(" {}", sha));
        }
        segs.push(BannerSeg { text: prefix, fg: branch_fg.clone() });
        if git.ahead > 0 {
            segs.push(BannerSeg { text: format!(" \u{2191}{}", git.ahead), fg: branch_sync_fg.clone() });
        }
        if git.behind > 0 {
            segs.push(BannerSeg { text: format!(" \u{2193}{}", git.behind), fg: branch_sync_fg.clone() });
        }
        if git.dirty > 0 {
            segs.push(BannerSeg { text: format!(" *{}", git.dirty), fg: branch_fg.clone() });
        }
        segs.push(BannerSeg { text: ")".to_string(), fg: branch_fg.clone() });
    }
    segs.push(BannerSeg { text: " ".to_string(), fg: path_text_fg.clone() });

    let mut line1 = String::new();

    if let Some(stops) = &grad_stops {
        // Degrade per-character entre stops, interpolation lineaire
        let total_len: usize = segs.iter().map(|s| s.text.chars().count()).sum();
        let seg_count = (stops.len() - 1) as f64;
        let mut idx = 0usize;
        for s in &segs {
            for c in s.text.chars() {
                let u = if total_len > 1 {
                    (idx as f64 / (total_len - 1) as f64) * seg_count
                } else {
                    0.0
                };
                let mut seg = u.floor() as usize;
                if seg >= stops.len() - 1 {
                    seg = stops.len() - 2;
                }
                let t = u - seg as f64;
                let a = &stops[seg];
                let b = &stops[seg + 1];
                let r = (a.0 as f64 + (b.0 as f64 - a.0 as f64) * t).round() as u8;
                let g = (a.1 as f64 + (b.1 as f64 - a.1 as f64) * t).round() as u8;
                let bb = (a.2 as f64 + (b.2 as f64 - a.2 as f64) * t).round() as u8;
                line1.push_str(&bg(r, g, bb));
                line1.push_str(&s.fg);
                line1.push(c);
                idx += 1;
            }
        }
        line1.push_str(RESET);
    } else {
        // Fond uni
        for s in &segs {
            line1.push_str(&path_bg);
            line1.push_str(&s.fg);
            line1.push_str(&s.text);
        }
        line1.push_str(RESET);
    }

    // Banner cost
    let cost_str = cost.map(|c| format!("\u{2248}${:.2}", c));
    if let Some(cs) = &cost_str {
        line1.push_str(&path_fg);
        line1.push_str(&s_cost_bg);
        line1.push(chevron);
        line1.push_str(&s_cost_fg);
        line1.push_str(&format!(" {} ", cs));
        line1.push_str(&rgb(s_cost.0, s_cost.1, s_cost.2));
        line1.push_str(&s2_bg);
        line1.push(chevron);
    } else {
        line1.push_str(&path_fg);
        line1.push_str(&s2_bg);
        line1.push(chevron);
    }

    // Banner 2 : modele + effort + ctx
    line1.push_str(&s2_fg);
    line1.push(' ');
    if let Some(m) = model {
        line1.push_str(m);
        line1.push_str("  ");
    }

    let effort_str = get_effort_display(effort);
    if !effort_str.is_empty() {
        line1.push_str(&effort_str);
        line1.push_str(RESET);
        line1.push_str(&s2_bg);
        line1.push_str(&s2_fg);
        line1.push_str("  ");
    }

    let ctx_pct_safe = ctx_pct.unwrap_or(0.0);
    let col = get_usage_color(ctx_pct_safe, false);
    match (ctx_tokens, ctx_size) {
        (Some(t), Some(sz)) => {
            line1.push_str(&format!("{}{}/{}{} tok", col, format_tokens(t), format_tokens(sz), s2_fg));
        }
        _ => {
            line1.push_str(&format!("ctx {}{}%{}", col, ctx_pct_safe as i64, s2_fg));
        }
    }
    line1.push(' ');

    // Chevron final
    line1.push_str(RESET);
    line1.push_str(&rgb(s2.0, s2.1, s2.2));
    line1.push(chevron);
    line1.push_str(RESET);

    line1
}

// =================== BUILD LINE 2 (usage) ===================

fn build_usage_seg(label: &str, util: f64, resets_at: &Value, stale: bool, reference: Option<DateTime<Utc>>) -> String {
    let col = get_usage_color(util, stale);
    let bar = format_bar(util, &col, 14);
    let mut seg = format!("{}{}{} {} {}{}%{}", col, label, RESET, bar, col, util as i64, RESET);
    if let Some(rst) = format_reset(resets_at, reference) {
        let reset_col = rgb(140, 145, 165);
        seg.push_str(&format!(" {}({}){}", reset_col, rst, RESET));
    }
    seg
}

fn build_line2(usage: &UsageResult) -> String {
    let Some(u) = &usage.json else { return String::new(); };
    let stale = usage.stale;
    let reference = usage.reference;
    let sep = format!(" {}\u{00B7}{} ", rgb(220, 220, 220), RESET);

    let mut segments: Vec<String> = Vec::new();

    if let Some(fh) = u.get("five_hour") {
        if let Some(util) = fh.get("utilization").and_then(|v| v.as_f64()) {
            let resets = fh.get("resets_at").cloned().unwrap_or(Value::Null);
            segments.push(build_usage_seg("5h", util, &resets, stale, reference));
        }
    }
    if let Some(sd) = u.get("seven_day") {
        if let Some(util) = sd.get("utilization").and_then(|v| v.as_f64()) {
            let resets = sd.get("resets_at").cloned().unwrap_or(Value::Null);
            segments.push(build_usage_seg("7d", util, &resets, stale, reference));
        }
    }
    if let Some(sdo) = u.get("seven_day_opus") {
        let util = sdo.get("utilization").and_then(|v| v.as_f64()).unwrap_or(0.0);
        let has_reset = sdo.get("resets_at").and_then(|v| v.as_str()).is_some();
        if util > 0.0 && has_reset {
            let resets = sdo.get("resets_at").cloned().unwrap_or(Value::Null);
            segments.push(build_usage_seg("opus", util, &resets, stale, reference));
        }
    }

    segments.join(&sep)
}

// =================== MAIN ===================

fn main() {
    let mut raw = String::new();
    std::io::stdin().read_to_string(&mut raw).ok();

    let home = std::env::var("USERPROFILE").unwrap_or_default();
    let claude_dir = PathBuf::from(&home).join(".claude");

    let _ = fs::write(claude_dir.join("statusline-last-input.json"), &raw);

    let data: Value = serde_json::from_str(&raw).unwrap_or(Value::Null);

    let dir = data
        .pointer("/workspace/current_dir")
        .and_then(|v| v.as_str())
        .or_else(|| data.pointer("/cwd").and_then(|v| v.as_str()))
        .map(String::from)
        .unwrap_or_else(|| {
            std::env::current_dir()
                .map(|p| p.display().to_string())
                .unwrap_or_default()
        });

    let mode = data
        .get("permission_mode")
        .or_else(|| data.get("permissionMode"))
        .and_then(|v| v.as_str())
        .or_else(|| data.pointer("/session/permission_mode").and_then(|v| v.as_str()))
        .map(String::from);

    let model = data
        .pointer("/model/display_name")
        .and_then(|v| v.as_str())
        .or_else(|| data.pointer("/model/id").and_then(|v| v.as_str()))
        .map(String::from);

    let effort = data
        .pointer("/effort/level")
        .and_then(|v| v.as_str())
        .map(String::from);

    let ctx_pct = data
        .pointer("/context_window/used_percentage")
        .and_then(|v| v.as_f64());
    let ctx_tokens = data
        .pointer("/context_window/total_input_tokens")
        .and_then(|v| v.as_i64());
    let ctx_size = data
        .pointer("/context_window/context_window_size")
        .and_then(|v| v.as_i64());
    let cost = data
        .pointer("/cost/total_cost_usd")
        .and_then(|v| v.as_f64());

    let git = compute_git(&dir);
    let usage = read_usage(&claude_dir);

    let line1 = build_line1(
        &dir,
        &git,
        mode.as_deref(),
        model.as_deref(),
        effort.as_deref(),
        ctx_pct,
        ctx_tokens,
        ctx_size,
        cost,
    );
    let line2 = build_line2(&usage);

    let mut out = line1;
    if !line2.is_empty() {
        out.push_str("\n\n");
        out.push_str(&line2);
    }

    // Print sans newline (comme Write-Host -NoNewline en PowerShell)
    use std::io::Write;
    let stdout = std::io::stdout();
    let mut h = stdout.lock();
    let _ = h.write_all(out.as_bytes());
}
