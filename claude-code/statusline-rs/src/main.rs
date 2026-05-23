// Port Rust de statusline.ps1 — cible 10 Hz (refreshInterval=0.1 dans settings.json).
//
// L'enjeu : PowerShell met ~420 ms par spawn, donc refreshInterval < 0.5 s y kill
// le process avant qu'il produise sa sortie (cf. la fonction I() dans claude.exe qui
// appelle `_.current?.abort()` a chaque tick). Un binaire natif demarre en ~10 ms =
// largement sous le seuil = on tient 10 Hz sans abort.

use std::fs;
use std::fs::OpenOptions;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

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

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

fn bg(r: u8, g: u8, b: u8) -> String {
    format!("\x1b[48;2;{};{};{}m", r, g, b)
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

// Cadence interne du picker /effort de claude.exe : M=112ms (~9 Hz). Le rendu
// des effort levels cote statusline est desormais statique (cf.
// get_effort_display), donc picker_tick ne sert plus qu'au log
// d'instrumentation (statusline-tick-log.txt) comme identifiant deterministe
// d'un tick -- utile pour correler des ticks rapproches sans coller un
// timestamp ms qui change a chaque invocation.
const PICKER_ZC: i64 = 16;
const PICKER_H: i64 = 100;
const PICKER_M: i64 = ((PICKER_H + PICKER_ZC - 1) / PICKER_ZC) * PICKER_ZC; // = 112

fn picker_tick(now_ms: i64) -> i64 {
    let k = (now_ms / PICKER_M) * PICKER_M;
    k / PICKER_H
}

fn get_effort_display(level: Option<&str>) -> String {
    let Some(level) = level else { return String::new(); };
    if level.is_empty() { return String::new(); }
    let bold = "\x1b[1m";
    let rst = "\x1b[0m";
    let label = level;

    // Rendu statique. Les couleurs sont des codes ANSI de slots de palette du
    // terminal, PAS des RGB figes : on emet exactement le meme SGR que
    // claude.exe pour chaque cible -> rendu strictement identique quel que soit
    // le theme du terminal (ici Catppuccin Mocha : slot 9 = #F38BA8, slot 13 =
    // #F5C2E7) et le reglage intenseTextStyle.
    //   low/medium/high -> ANSI bright 93/92/94 + bold (design statusline, pas
    //                      de cible externe a matcher).
    //   xhigh -> ANSI 95 (magentaBright), SANS gras = couleur EXACTE de
    //            l'indicateur "⏵⏵ accept edits on". Verifie dans le binaire :
    //            acceptEdits -> color:"autoAccept" ; dark-ansi mappe autoAccept
    //            -> ansi:magentaBright -> chalk.magentaBright -> \x1b[95m. C'est
    //            aussi la couleur de base des lettres de l'ancien xhigh anime
    //            (le halo balayant #D0B4FF n'est PAS voulu) -- cf. git 5c3b0c3.
    //   max   -> ANSI 91 (bright red), SANS gras = couleur EXACTE de
    //            l'indicateur "⏵⏵ bypass permissions on". Verifie :
    //            bypassPermissions -> color:"error" ; dark-ansi mappe error ->
    //            ansi:redBright -> chalk.redBright -> \x1b[91m.
    // Les indicateurs de claude.exe sont rendus color-only -- createElement(
    // Text, {color}, glyph, " ", label), AUCUN bold ni dim. On reproduit donc
    // uniquement le code couleur (sans \x1b[1m) : match au pixel pres, robuste
    // au theme, a la police (JetBrainsMono Nerd Font) et a intenseTextStyle.
    match level {
        "low" => format!("\x1b[93m{}{}{}", bold, label, rst),
        "medium" => format!("\x1b[92m{}{}{}", bold, label, rst),
        "high" => format!("\x1b[94m{}{}{}", bold, label, rst),
        "xhigh" => format!("\x1b[95m{}{}", label, rst),
        "max" => format!("\x1b[91m{}{}", label, rst),
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

    // Single git call: status --porcelain=v2 --branch returns branch, oid, ab, AND dirty.
    // Saves ~30-50ms vs an extra `git rev-parse --abbrev-ref HEAD` spawn on Windows,
    // which used to push total time over CC's ~100ms abort threshold in git repos.
    let Some(out) = run_git(dir, &["status", "--porcelain=v2", "--branch"]) else {
        return info;
    };

    for line in out.lines() {
        if let Some(rest) = line.strip_prefix("# branch.head ") {
            let head = rest.trim();
            if !head.is_empty() {
                // Detached HEAD -> "(detached)" ; aligne sur ce que `rev-parse --abbrev-ref HEAD` renvoyait ("HEAD")
                info.branch = Some(if head == "(detached)" { "HEAD".to_string() } else { head.to_string() });
            }
        } else if let Some(rest) = line.strip_prefix("# branch.oid ") {
            let oid = rest.trim();
            if oid.len() >= 7 && oid != "(initial)" {
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

    if info.branch.is_none() {
        return info;
    }

    // Background fetch cooldown 30s
    let marker = root.join(".git").join("statusline-last-fetch");
    let needs_fetch = match file_age_secs(&marker) {
        Some(age) => age >= 30.0,
        None => true,
    };
    if needs_fetch {
        // Touch d'abord pour empecher d'autres ticks de re-spawn pendant que celui-ci demarre.
        touch(&marker);
        // Le spawn lui-meme coute ~300 ms sur Windows quand Defender realtime est actif :
        // chaque creation de process git est scannee. DETACHED_PROCESS ne sauve pas ce cout,
        // il rend juste le process enfant detache une fois cree. On detache donc aussi LA CREATION
        // elle-meme dans un thread daemon, pour que la main thread retourne immediatement.
        let dir_owned = dir.to_string();
        std::thread::spawn(move || {
            let mut cmd = Command::new("git");
            cmd.args(["-C", &dir_owned, "fetch", "--quiet"]);
            cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
            #[cfg(windows)]
            cmd.creation_flags(CREATE_NO_WINDOW | 0x00000008 /* DETACHED_PROCESS */);
            let _ = cmd.spawn();
        });
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
}

fn read_credentials(claude_dir: &Path) -> Option<CredsRoot> {
    let path = claude_dir.join(".credentials.json");
    let raw = fs::read_to_string(path).ok()?;
    serde_json::from_str(&raw).ok()
}

// Cache 1h de la version de claude.exe pour le User-Agent. Si l'API Anthropic
// commence un jour a verifier strictement le UA, hard-coder "2.0.32" devient
// une bombe a retardement. On extrait la version via `claude --version`
// (sortie : "2.1.148 (Claude Code)\n"), cachee dans claude-version.txt.
// Fallback "2.0.32" si claude introuvable -- valeur historique connue pour
// fonctionner avec l'endpoint /api/oauth/usage.
fn detect_claude_version(claude_dir: &Path) -> String {
    let cache_path = claude_dir.join("claude-version.txt");
    if let Some(age) = file_age_secs(&cache_path) {
        if age < 3600.0 {
            if let Ok(s) = fs::read_to_string(&cache_path) {
                let v = s.trim().to_string();
                if !v.is_empty() {
                    return v;
                }
            }
        }
    }
    let mut cmd = Command::new("claude");
    cmd.arg("--version");
    cmd.stdin(Stdio::null()).stderr(Stdio::null());
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);
    let version = cmd
        .output()
        .ok()
        .filter(|out| out.status.success())
        .and_then(|out| String::from_utf8(out.stdout).ok())
        .and_then(|s| s.split_whitespace().next().map(String::from))
        .filter(|s| !s.is_empty() && s.chars().next().map_or(false, |c| c.is_ascii_digit()))
        .unwrap_or_else(|| "2.0.32".to_string());
    let _ = fs::write(&cache_path, &version);
    version
}

#[derive(Debug, Clone, Copy)]
enum UsageSource {
    Stdin,              // rate_limits.* directement dans le stdin JSON (Pro/Max
                        // apres 1er API call). Source la plus fiable -- pas
                        // d'appel HTTP, pas de token, pas de cache.
    CacheFresh,
    ApiSuccess,
    ApiSuccessRetry,    // succes au 2e essai apres retry 500ms
    ApiTimeoutOrIo,     // echec apres 1 essai (+1 retry) -- reseau down ou DNS
    Api429,
    Api401,             // token expire -- claude refresh au prochain api call
    ApiBadStatus,       // autre code 4xx/5xx
    Cooldown,
    StaleCacheFallback,
    NoCredsOrNoCache,
}

struct UsageResult {
    json: Option<Value>,
    stale: bool,
    reference: Option<DateTime<Utc>>,
    source: UsageSource,
    api_ms: Option<u128>,
    api_status: Option<u16>,
    api_attempts: u8,
}

// Resultat d'un essai HTTP unique. Distingue les classes d'erreurs pour decider
// quoi faire :
//   - Io/Timeout -> RETRY (peut etre transitoire : DNS hiccup, packet loss)
//   - Status(code) -> PAS de retry (server-side decision : 429, 401, 5xx ne se
//     resolvent pas en 500ms)
//   - BodyParse -> PAS de retry (le serveur a renvoye 200 OK mais avec un corps
//     non-JSON : probablement une page d'erreur HTML, structurelle)
enum FetchOutcome {
    Ok(Value),
    Io,
    Status(u16),
    BodyParse,
}

fn fetch_usage_once(agent: &ureq::Agent, token: &str, user_agent: &str) -> FetchOutcome {
    match agent
        .get("https://api.anthropic.com/api/oauth/usage")
        .set("Authorization", &format!("Bearer {}", token))
        .set("anthropic-beta", "oauth-2025-04-20")
        .set("User-Agent", user_agent)
        .set("Accept", "application/json, text/plain, */*")
        .set("Content-Type", "application/json")
        .call()
    {
        Ok(resp) => match resp.into_string() {
            Ok(body) => match serde_json::from_str::<Value>(&body) {
                Ok(v) => FetchOutcome::Ok(v),
                Err(_) => FetchOutcome::BodyParse,
            },
            Err(_) => FetchOutcome::Io,
        },
        Err(ureq::Error::Status(code, _)) => FetchOutcome::Status(code),
        Err(ureq::Error::Transport(_)) => FetchOutcome::Io,
    }
}

// Convertit le bloc rate_limits du stdin Claude Code en JSON format usage-cache
// (utilization + resets_at ISO). Documente :
//   https://code.claude.com/docs/en/statusline#full-json-schema
//   rate_limits = { five_hour: { used_percentage, resets_at }, seven_day: {...} }
//   resets_at est un Unix epoch en SECONDES dans le stdin (vs ISO 8601 dans
//   l'API endpoint /api/oauth/usage). On normalise vers ISO 8601 pour que
//   `format_reset` n'ait qu'une seule branche.
// Absent pour : (a) sessions early avant 1er API call, (b) users API direct
// (non Pro/Max). Dans ces cas le caller fallback sur l'API HTTP.
fn build_usage_from_stdin_rate_limits(data: &Value) -> Option<Value> {
    let rl = data.get("rate_limits")?;
    let mut result = serde_json::Map::new();

    for key in ["five_hour", "seven_day"] {
        if let Some(window) = rl.get(key) {
            let pct = window.get("used_percentage").and_then(|v| v.as_f64());
            if let Some(p) = pct {
                let mut obj = serde_json::Map::new();
                obj.insert("utilization".to_string(), Value::from(p));
                if let Some(epoch) = window.get("resets_at").and_then(|v| v.as_i64()) {
                    if let Some(dt) = Utc.timestamp_opt(epoch, 0).single() {
                        obj.insert("resets_at".to_string(), Value::from(dt.to_rfc3339()));
                    }
                }
                result.insert(key.to_string(), Value::Object(obj));
            }
        }
    }

    if result.is_empty() {
        None
    } else {
        Some(Value::Object(result))
    }
}

fn read_usage(
    claude_dir: &Path,
    stdin_rate_limits: Option<Value>,
    stdin_version: Option<&str>,
) -> UsageResult {
    let cache_path = claude_dir.join("usage-cache.json");
    let ratelimit_path = claude_dir.join("usage-ratelimit.txt");

    // STDIN PATH (toujours prefere : zero overhead, zero token, zero
    // dependance reseau). On enrichit avec seven_day_opus depuis le cache si
    // disponible (rate_limits du stdin ne contient pas opus -- limitation
    // documentee Anthropic, opus_usage change peu sur une window 7j donc
    // staleness moderee acceptable).
    if let Some(stdin_data) = stdin_rate_limits {
        let mut merged = stdin_data;
        if let Ok(raw) = fs::read_to_string(&cache_path) {
            if let Ok(cached) = serde_json::from_str::<Value>(&raw) {
                if let Some(sdo) = cached.get("seven_day_opus") {
                    if let Some(merged_obj) = merged.as_object_mut() {
                        merged_obj.insert("seven_day_opus".to_string(), sdo.clone());
                    }
                }
            }
        }
        // Update cache avec donnees fraiches stdin pour futur fallback API
        if let Ok(body) = serde_json::to_string(&merged) {
            let _ = fs::write(&cache_path, body.as_bytes());
        }
        // Si on avait un ratelimit arme avant, le retirer maintenant qu'on a
        // une donnee valide (le 429 etait peut-etre transitoire).
        let _ = fs::remove_file(&ratelimit_path);

        return UsageResult {
            json: Some(merged),
            stale: false,
            reference: None,
            source: UsageSource::Stdin,
            api_ms: None,
            api_status: None,
            api_attempts: 0,
        };
    }

    let mut usage: Option<Value> = None;
    let mut source = UsageSource::NoCredsOrNoCache;
    let mut api_ms: Option<u128> = None;
    let mut api_status: Option<u16> = None;
    let mut api_attempts: u8 = 0;

    // Cache 60s
    if let Some(age) = file_age_secs(&cache_path) {
        if age < 60.0 {
            if let Ok(raw) = fs::read_to_string(&cache_path) {
                if let Ok(v) = serde_json::from_str::<Value>(&raw) {
                    usage = Some(v);
                    source = UsageSource::CacheFresh;
                }
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
                    source = UsageSource::Cooldown;
                }
            }
        }
    }

    if usage.is_none() && !in_cooldown {
        if let Some(creds) = read_credentials(claude_dir) {
            if let Some(token) = creds.claude_ai_oauth.as_ref().and_then(|o| o.access_token.clone())
            {
                // User-Agent : version depuis stdin (gratuit), sinon spawn
                // `claude --version` cache 1h, sinon fallback hardcode "2.0.32".
                let version = stdin_version
                    .map(String::from)
                    .unwrap_or_else(|| detect_claude_version(claude_dir));
                let user_agent = format!("claude-code/{}", version);
                let agent = ureq::AgentBuilder::new()
                    .timeout(Duration::from_secs(4))
                    .build();
                let t_api = Instant::now();
                api_attempts = 1;
                let mut outcome = fetch_usage_once(&agent, &token, &user_agent);

                // Retry une seule fois apres 500ms si erreur IO/timeout. Pas de
                // retry sur 4xx/5xx (le serveur a deja decide), pas sur BodyParse
                // (changement structurel cote serveur).
                if matches!(outcome, FetchOutcome::Io) {
                    std::thread::sleep(Duration::from_millis(500));
                    api_attempts = 2;
                    outcome = fetch_usage_once(&agent, &token, &user_agent);
                }
                api_ms = Some(t_api.elapsed().as_millis());

                match outcome {
                    FetchOutcome::Ok(v) => {
                        if let Ok(body) = serde_json::to_string(&v) {
                            let _ = fs::write(&cache_path, body.as_bytes());
                        }
                        let _ = fs::remove_file(&ratelimit_path);
                        usage = Some(v);
                        source = if api_attempts == 2 {
                            UsageSource::ApiSuccessRetry
                        } else {
                            UsageSource::ApiSuccess
                        };
                        api_status = Some(200);
                    }
                    FetchOutcome::Status(429) => {
                        let _ = fs::write(&ratelimit_path, Utc::now().to_rfc3339().as_bytes());
                        source = UsageSource::Api429;
                        api_status = Some(429);
                    }
                    FetchOutcome::Status(401) => {
                        // Token expire -- claude.exe le refresh au prochain api
                        // call principal. Pas la peine d'armer le cooldown 429.
                        source = UsageSource::Api401;
                        api_status = Some(401);
                    }
                    FetchOutcome::Status(code) => {
                        source = UsageSource::ApiBadStatus;
                        api_status = Some(code);
                    }
                    FetchOutcome::Io | FetchOutcome::BodyParse => {
                        source = UsageSource::ApiTimeoutOrIo;
                    }
                }
            }
        }
    }

    // Fallback stale : reutiliser le cache meme vieux
    let mut stale = false;
    let mut reference: Option<DateTime<Utc>> = None;
    if usage.is_none() && cache_path.exists() {
        if let Ok(raw) = fs::read_to_string(&cache_path) {
            if let Ok(v) = serde_json::from_str::<Value>(&raw) {
                usage = Some(v);
                stale = true;
                reference = file_mtime_utc(&cache_path);
                source = UsageSource::StaleCacheFallback;
            }
        }
    }

    UsageResult {
        json: usage,
        stale,
        reference,
        source,
        api_ms,
        api_status,
        api_attempts,
    }
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
        // Texte git unifie avec celui du path : meme couleur sombre sur le fond
        // bleu degrade -- les parentheses suffisent a delimiter le bloc git, pas
        // besoin d'un gris distinct qui creait une 2e teinte sur la meme banniere.
        let branch_fg = path_text_fg.clone();
        // Sync arrows en jaune si fetch_stale : alerte utile, on garde la couleur
        // distincte uniquement pour ce cas.
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

    // Transition path -> banner 2 (model + ctx). Section cout ($) retiree :
    // total_cost_usd est un estimatif au tarif API, sans signification en
    // abonnement Pro/Max (forfait fixe, pas de facturation au token). Les vraies
    // jauges de budget sont les barres 5h/7d/opus de la ligne 2.
    line1.push_str(&path_fg);
    line1.push_str(&s2_bg);
    line1.push(chevron);

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
    // INSTRUMENTATION (2026-05-20) : freeze ~3s constant signalé par user.
    // On mesure : durée totale, durée git, durée usage (avec breakdown source / api_ms).
    // Log append-only dans `~/.claude/statusline-tick-log.txt`. À retirer après
    // identification de la cause.
    let t_main_start = Instant::now();
    let start_ms_unix = now_ms();

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

    // Pre-extract version + rate_limits du stdin pour read_usage (cf. doc
    // officielle https://code.claude.com/docs/en/statusline -- ces champs sont
    // fournis par Claude Code lui-meme, plus fiables que tout appel HTTP).
    let stdin_version = data.get("version").and_then(|v| v.as_str()).map(String::from);
    let stdin_rate_limits = build_usage_from_stdin_rate_limits(&data);

    let t_git = Instant::now();
    let git = compute_git(&dir);
    let git_ms = t_git.elapsed().as_millis();

    let t_usage = Instant::now();
    let usage = read_usage(&claude_dir, stdin_rate_limits, stdin_version.as_deref());
    let usage_ms = t_usage.elapsed().as_millis();

    let line1 = build_line1(
        &dir,
        &git,
        mode.as_deref(),
        model.as_deref(),
        effort.as_deref(),
        ctx_pct,
        ctx_tokens,
        ctx_size,
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
    drop(h);

    // INSTRUMENTATION (2026-05-20) : log append-only, best-effort. Le total_ms
    // est mesuré AVANT cette écriture pour ne pas se compter soi-même.
    let total_ms = t_main_start.elapsed().as_millis();
    let _ = (|| -> std::io::Result<()> {
        let log_path = claude_dir.join("statusline-tick-log.txt");
        let line = format!(
            "{} tick={} effort={} git_ms={} usage_ms={} usage_src={:?} api_status={} api_attempts={} api_ms={} total_ms={} pid={}\n",
            start_ms_unix,
            picker_tick(start_ms_unix),
            effort.as_deref().unwrap_or("none"),
            git_ms,
            usage_ms,
            usage.source,
            usage.api_status.map(|v| v.to_string()).unwrap_or_else(|| "-".to_string()),
            usage.api_attempts,
            usage.api_ms.map(|v| v.to_string()).unwrap_or_else(|| "-".to_string()),
            total_ms,
            std::process::id(),
        );
        let mut f = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&log_path)?;
        // Write all bytes en un seul appel : OS append est atomic-by-write
        // sur Windows quand le buffer < PIPE_BUF (~4KB) — pas d'interleaving
        // entre processes parallèles.
        f.write_all(line.as_bytes())?;
        Ok(())
    })();
}
