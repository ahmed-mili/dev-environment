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

// =================== PRE-SHAPING ARABE (terminaux sans BiDi) ===================
// Windows Terminal n'applique ni l'algorithme bidirectionnel Unicode ni le
// shaping contextuel (microsoft/terminal#538) : un chemin contenant de l'arabe
// (ex. C:\obsidian-vaults\<vault arabe>) sort inverse et deconnecte dans le
// banner. Meme parade que le sessionizer (ConvertTo-ArabicDisplay dans
// claude-code/windows-sessionizer/sessionizer.ps1, tests et justification
// la-bas) : convertir les runs arabes en formes de presentation U+FExx posees
// en ordre visuel. Applique au chemin AFFICHE uniquement -- compute_git()
// recoit toujours le chemin brut.

/// (isolated, final, initial, medial) ; 0 = forme absente (right-joining :
/// pas d'initial/medial ; hamza : isolated seule ; tatweel : inchange).
fn ar_forms(cp: u32) -> Option<[u32; 4]> {
    Some(match cp {
        0x0621 => [0xFE80, 0, 0, 0],
        0x0622 => [0xFE81, 0xFE82, 0, 0],
        0x0623 => [0xFE83, 0xFE84, 0, 0],
        0x0624 => [0xFE85, 0xFE86, 0, 0],
        0x0625 => [0xFE87, 0xFE88, 0, 0],
        0x0626 => [0xFE89, 0xFE8A, 0xFE8B, 0xFE8C],
        0x0627 => [0xFE8D, 0xFE8E, 0, 0],
        0x0628 => [0xFE8F, 0xFE90, 0xFE91, 0xFE92],
        0x0629 => [0xFE93, 0xFE94, 0, 0],
        0x062A => [0xFE95, 0xFE96, 0xFE97, 0xFE98],
        0x062B => [0xFE99, 0xFE9A, 0xFE9B, 0xFE9C],
        0x062C => [0xFE9D, 0xFE9E, 0xFE9F, 0xFEA0],
        0x062D => [0xFEA1, 0xFEA2, 0xFEA3, 0xFEA4],
        0x062E => [0xFEA5, 0xFEA6, 0xFEA7, 0xFEA8],
        0x062F => [0xFEA9, 0xFEAA, 0, 0],
        0x0630 => [0xFEAB, 0xFEAC, 0, 0],
        0x0631 => [0xFEAD, 0xFEAE, 0, 0],
        0x0632 => [0xFEAF, 0xFEB0, 0, 0],
        0x0633 => [0xFEB1, 0xFEB2, 0xFEB3, 0xFEB4],
        0x0634 => [0xFEB5, 0xFEB6, 0xFEB7, 0xFEB8],
        0x0635 => [0xFEB9, 0xFEBA, 0xFEBB, 0xFEBC],
        0x0636 => [0xFEBD, 0xFEBE, 0xFEBF, 0xFEC0],
        0x0637 => [0xFEC1, 0xFEC2, 0xFEC3, 0xFEC4],
        0x0638 => [0xFEC5, 0xFEC6, 0xFEC7, 0xFEC8],
        0x0639 => [0xFEC9, 0xFECA, 0xFECB, 0xFECC],
        0x063A => [0xFECD, 0xFECE, 0xFECF, 0xFED0],
        0x0640 => [0x0640, 0x0640, 0x0640, 0x0640],
        0x0641 => [0xFED1, 0xFED2, 0xFED3, 0xFED4],
        0x0642 => [0xFED5, 0xFED6, 0xFED7, 0xFED8],
        0x0643 => [0xFED9, 0xFEDA, 0xFEDB, 0xFEDC],
        0x0644 => [0xFEDD, 0xFEDE, 0xFEDF, 0xFEE0],
        0x0645 => [0xFEE1, 0xFEE2, 0xFEE3, 0xFEE4],
        0x0646 => [0xFEE5, 0xFEE6, 0xFEE7, 0xFEE8],
        0x0647 => [0xFEE9, 0xFEEA, 0xFEEB, 0xFEEC],
        0x0648 => [0xFEED, 0xFEEE, 0, 0],
        0x0649 => [0xFEEF, 0xFEF0, 0, 0],
        0x064A => [0xFEF1, 0xFEF2, 0xFEF3, 0xFEF4],
        _ => return None,
    })
}

/// Diacritique combinant : transparent pour la liaison, reste avec sa base.
fn ar_is_mark(cp: u32) -> bool {
    (0x064B..=0x065F).contains(&cp) || cp == 0x0670
}

/// Ligature lam-alef obligatoire : forme isolee (finale = isolee + 1).
fn ar_lam_alef(cp: u32) -> Option<u32> {
    Some(match cp {
        0x0622 => 0xFEF5,
        0x0623 => 0xFEF7,
        0x0625 => 0xFEF9,
        0x0627 => 0xFEFB,
        _ => return None,
    })
}

fn arabic_display(text: &str) -> String {
    // Fast path : rien a shaper (et idempotence, les U+FExx ne rematchent pas).
    if !text.chars().any(|c| (0x0621..=0x064A).contains(&(c as u32))) {
        return text.to_string();
    }
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut i = 0;
    while i < chars.len() {
        let cp = chars[i] as u32;
        if ar_forms(cp).is_none() && !ar_is_mark(cp) {
            out.push(chars[i]);
            i += 1;
            continue;
        }
        // Run arabe -> clusters (base, marks). Base 0 = diacritique orphelin.
        let mut clusters: Vec<(u32, Vec<u32>)> = Vec::new();
        while i < chars.len() {
            let cp = chars[i] as u32;
            if ar_forms(cp).is_some() {
                clusters.push((cp, Vec::new()));
            } else if ar_is_mark(cp) {
                match clusters.last_mut() {
                    Some(last) => last.1.push(cp),
                    None => clusters.push((0, vec![cp])),
                }
            } else {
                break;
            }
            i += 1;
        }
        // pair(P, L) = P a une forme initiale (dual) ET L une forme finale.
        let links_prev: Vec<bool> = (0..clusters.len())
            .map(|k| {
                k > 0
                    && clusters[k - 1].0 != 0
                    && clusters[k].0 != 0
                    && ar_forms(clusters[k - 1].0).is_some_and(|f| f[2] != 0)
                    && ar_forms(clusters[k].0).is_some_and(|f| f[1] != 0)
            })
            .collect();
        // Formes contextuelles + ligatures en ordre logique, puis inversion.
        let mut visual: Vec<String> = Vec::new();
        let mut k = 0;
        while k < clusters.len() {
            let b = clusters[k].0;
            let mut piece = String::new();
            let lam_alef = b == 0x0644
                && k + 1 < clusters.len()
                && ar_lam_alef(clusters[k + 1].0).is_some();
            if lam_alef {
                let mut lig = ar_lam_alef(clusters[k + 1].0).unwrap();
                if links_prev[k] {
                    lig += 1;
                }
                piece.push(char::from_u32(lig).unwrap());
                for &m in clusters[k].1.iter().chain(clusters[k + 1].1.iter()) {
                    piece.push(char::from_u32(m).unwrap());
                }
                k += 2;
            } else if b != 0 {
                let f = ar_forms(b).unwrap();
                let link_n = k + 1 < clusters.len()
                    && f[2] != 0
                    && clusters[k + 1].0 != 0
                    && ar_forms(clusters[k + 1].0).is_some_and(|nf| nf[1] != 0);
                let form = match (links_prev[k], link_n) {
                    (true, true) => f[3],
                    (true, false) => f[1],
                    (false, true) => f[2],
                    (false, false) => f[0],
                };
                piece.push(char::from_u32(form).unwrap());
                for &m in &clusters[k].1 {
                    piece.push(char::from_u32(m).unwrap());
                }
                k += 1;
            } else {
                for &m in &clusters[k].1 {
                    piece.push(char::from_u32(m).unwrap());
                }
                k += 1;
            }
            visual.push(piece);
        }
        for piece in visual.iter().rev() {
            out.push_str(piece);
        }
    }
    out
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
        // Sync arrows ↑/↓ en violet Copilot (#8534F3, https://brand.github.com/
        // foundations/color) -- couleur signature GitHub, saturee donc visible
        // sur le fond bleu clair du path, sans avoir l'air d'une alerte (sinon
        // ça crierait à chaque commit non poussé). Le jaune fetch_stale reste
        // en alerte distincte (le fetch background est planté = info perimee).
        let branch_sync_fg = if git.fetch_stale { rgb(200, 170, 100) } else { rgb(133, 52, 243) };

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

// =================== OLLAMA CLOUD USAGE ===================

// `ollama launch claude` ne modifie pas settings.json : il injecte des variables
// d'environnement dans le process claude (verifie en capturant l'env d'un faux
// claude lance via la commande). La statusline etant un enfant de claude, elle en
// herite. Signal le plus fiable : les modeles par defaut sont mappes sur des cibles
// ":cloud" ; en repli, ANTHROPIC_BASE_URL pointe sur le daemon ollama local
// (127.0.0.1:11434/11435, = OLLAMA_HOST).
fn detect_ollama_env() -> bool {
    let is_cloud = |k: &str| std::env::var(k).map(|v| v.contains(":cloud")).unwrap_or(false);
    if is_cloud("ANTHROPIC_DEFAULT_OPUS_MODEL")
        || is_cloud("ANTHROPIC_DEFAULT_SONNET_MODEL")
        || is_cloud("ANTHROPIC_DEFAULT_HAIKU_MODEL")
        || is_cloud("ANTHROPIC_MODEL")
    {
        return true;
    }
    if let Ok(base) = std::env::var("ANTHROPIC_BASE_URL") {
        let b = base.to_lowercase();
        if b.contains("ollama") || b.contains(":11434") || b.contains(":11435") {
            return true;
        }
        if let Ok(host) = std::env::var("OLLAMA_HOST") {
            if !base.is_empty() && base == host {
                return true;
            }
        }
    }
    false
}

// Detection robuste : claude SCRUBE les ANTHROPIC_* de l'env qu'il passe au
// sous-process statusline (verifie : BASE_URL=None cote statusline), et le model.id
// du stdin reste l'alias "claude-opus-4-8" (pas ":cloud"). MAIS l'environ PROPRE du
// process claude (et de ses ancetres) garde ANTHROPIC_BASE_URL=http://127.0.0.1:1143x
// et ANTHROPIC_DEFAULT_*_MODEL=...:cloud. On remonte donc la chaine des ppid en lisant
// /proc/<pid>/environ jusqu'a trouver le signal (Linux uniquement). Cousin de la
// technique borrow_win_env. Valide : meme avec `env -i`, l'enfant lit l'env du parent.
#[cfg(target_os = "linux")]
fn parent_pid(pid: i32) -> Option<i32> {
    let stat = fs::read_to_string(format!("/proc/{}/stat", pid)).ok()?;
    // comm (champ 2) peut contenir espaces/parentheses -> couper apres le dernier ')'
    let rest = &stat[stat.rfind(')')? + 2..];
    rest.split_whitespace().nth(1)?.parse().ok()
}

#[cfg(target_os = "linux")]
fn detect_ollama_proc() -> bool {
    let mut pid = std::process::id() as i32;
    for _ in 0..8 {
        if let Ok(env) = fs::read(format!("/proc/{}/environ", pid)) {
            for kv in env.split(|&b| b == 0) {
                if let Ok(s) = std::str::from_utf8(kv) {
                    if let Some(v) = s.strip_prefix("ANTHROPIC_BASE_URL=") {
                        let l = v.to_lowercase();
                        if l.contains("ollama") || l.contains(":11434") || l.contains(":11435") {
                            return true;
                        }
                    }
                    if s.starts_with("ANTHROPIC_DEFAULT_") && s.ends_with(":cloud") {
                        return true;
                    }
                    if let Some(v) = s.strip_prefix("ANTHROPIC_MODEL=") {
                        if v.contains(":cloud") {
                            return true;
                        }
                    }
                }
            }
        }
        match parent_pid(pid) {
            Some(p) if p > 1 => pid = p,
            _ => break,
        }
    }
    false
}

#[cfg(not(target_os = "linux"))]
fn detect_ollama_proc() -> bool {
    false
}

// Lit le cache d'usage Ollama (ecrit par ollama-usage.py). Si le cache a > 60 s,
// (re)lance le helper en arriere-plan detache -- meme pattern que le fetch git :
// un marqueur cooldown evite les rafales, et on rend immediatement avec la valeur
// en cache (la prochaine invocation affiche la valeur fraiche). Le scrape lui-meme
// (lecture du cookie Firefox + HTTP vers ollama.com/settings) reste donc hors du
// chemin chaud du binaire 10 Hz.
fn read_ollama_usage(claude_dir: &Path) -> Option<Value> {
    let cache = claude_dir.join("ollama-usage-cache.json");
    let stale = file_age_secs(&cache).map(|a| a >= 60.0).unwrap_or(true);
    if stale {
        let marker = claude_dir.join("ollama-usage-last-fetch");
        let needs = file_age_secs(&marker).map(|a| a >= 15.0).unwrap_or(true);
        if needs {
            touch(&marker);
            let helper = claude_dir.join("ollama-usage.py");
            if helper.exists() {
                let mut cmd = Command::new("python3");
                cmd.arg(&helper);
                cmd.stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
                #[cfg(windows)]
                cmd.creation_flags(CREATE_NO_WINDOW | 0x00000008 /* DETACHED_PROCESS */);
                let _ = cmd.spawn();
            }
        }
    }
    let raw = fs::read_to_string(&cache).ok()?;
    serde_json::from_str(&raw).ok()
}

// Construit la ligne 2 en mode Ollama : memes couleurs / barres / format que la
// version Anthropic (cf. build_usage_seg), mais alimentee par session/weekly d'Ollama
// Cloud. Labels "5h"/"7d" : la session Ollama se reinitialise toutes les 5 h et le
// quota hebdomadaire tous les 7 j -- meme semantique que les fenetres Anthropic.
fn build_line2_ollama(u: &Value) -> String {
    let sep = format!(" {}\u{00B7}{} ", rgb(220, 220, 220), RESET);
    let mut segments: Vec<String> = Vec::new();
    for (key, label) in [("session", "5h"), ("weekly", "7d")] {
        if let Some(w) = u.get(key) {
            if let Some(util) = w.get("utilization").and_then(|v| v.as_f64()) {
                let col = get_usage_color(util, false);
                let bar = format_bar(util, &col, 14);
                // pct = chaine exacte affichee par ollama.com (ex. "3.5"), repli sur
                // l'entier tronque si absente. La barre, elle, utilise le float.
                let pct = w
                    .get("pct")
                    .and_then(|v| v.as_str())
                    .map(String::from)
                    .unwrap_or_else(|| (util as i64).to_string());
                let mut seg = format!(
                    "{}{}{} {} {}{}%{}",
                    col, label, RESET, bar, col, pct, RESET
                );
                if let Some(rst) = w.get("reset").and_then(|v| v.as_str()) {
                    let reset_col = rgb(140, 145, 165);
                    seg.push_str(&format!(" {}({}){}", reset_col, rst, RESET));
                }
                segments.push(seg);
            }
        }
    }
    segments.join(&sep)
}

// =================== OLLAMA MODEL / CONTEXT WINDOW ===================

// Remonte la chaine des ppid pour extraire le VRAI nom du modele Ollama Cloud
// (ex. "deepseek-v4-pro:cloud") depuis l'environ du process claude parent.
// Claude scrubbe ANTHROPIC_* au spawn du statusline, mais ses ancetres
// conservent les variables (meme technique que detect_ollama_proc).
#[cfg(target_os = "linux")]
fn get_ollama_model() -> Option<String> {
    let mut pid = std::process::id() as i32;
    for _ in 0..8 {
        if let Ok(env) = fs::read(format!("/proc/{}/environ", pid)) {
            for kv in env.split(|&b| b == 0) {
                if let Ok(s) = std::str::from_utf8(kv) {
                    for prefix in [
                        "ANTHROPIC_DEFAULT_OPUS_MODEL=",
                        "ANTHROPIC_DEFAULT_SONNET_MODEL=",
                        "ANTHROPIC_DEFAULT_HAIKU_MODEL=",
                        "ANTHROPIC_MODEL=",
                    ] {
                        if let Some(v) = s.strip_prefix(prefix) {
                            if v.contains(":cloud") {
                                return Some(v.to_string());
                            }
                        }
                    }
                }
            }
        }
        match parent_pid(pid) {
            Some(p) if p > 1 => pid = p,
            _ => break,
        }
    }
    None
}

#[cfg(not(target_os = "linux"))]
fn get_ollama_model() -> Option<String> {
    None
}

// Context window (en tokens) des modeles Ollama Cloud courants.
// Source : docs Ollama Cloud / fiches modeles (DeepWiki, Collabnix, etc.).
fn ollama_context_window(model: &str) -> Option<i64> {
    match model {
        "deepseek-v4-pro:cloud" | "deepseek-v4-flash:cloud" => Some(1_000_000),
        "kimi-k2.6:cloud" | "kimi-k2.5:cloud" | "kimi-k2:1t:cloud" | "qwen3.5:cloud" => Some(262_144),
        "glm-5.1:cloud" => Some(131_072),
        "minimax-m3:cloud" | "minimax-m2:cloud" => Some(1_000_000),
        _ => None,
    }
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

    let home = std::env::var("USERPROFILE")
        .or_else(|_| std::env::var("HOME"))
        .unwrap_or_default();
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

    let mut model = data
        .pointer("/model/display_name")
        .and_then(|v| v.as_str())
        .or_else(|| data.pointer("/model/id").and_then(|v| v.as_str()))
        .map(String::from);

    // model.id brut (pour la detection Ollama : l'env ANTHROPIC_* peut etre scrube
    // par claude au spawn du statusline, mais l'id du modele est toujours dans le stdin).
    let model_id = data.pointer("/model/id").and_then(|v| v.as_str()).map(String::from);

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
    let mut ctx_size = data
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
    // Mode Ollama (`ollama launch claude`) : on ne consomme pas le quota Anthropic,
    // donc afficher ses rate_limits serait trompeur. On source l'usage depuis Ollama
    // Cloud (cache rempli par ollama-usage.py) et on n'interroge PAS api.anthropic.com.
    // Detection : env (si propage) OU id du modele stdin contient ":cloud"/"kimi"
    // (signal robuste, independant de la propagation d'env).
    let model_is_cloud = model_id
        .as_deref()
        .or(model.as_deref())
        .map(|m| {
            let l = m.to_lowercase();
            l.contains(":cloud") || l.contains("kimi")
        })
        .unwrap_or(false);
    // 3 signaux : env direct (si non scrube) | /proc des ancetres (claude garde
    // ANTHROPIC_BASE_URL malgre le scrub) | model.id du stdin contenant ":cloud".
    let ollama = detect_ollama_env() || detect_ollama_proc() || model_is_cloud;

    // Correction du contexte affiche : Claude Code envoie ctx_size=200k (sa valeur
    // par defaut interne) meme quand le modele Ollama sous-jacent supporte 1M.
    // On remplace par la vraie taille, et on affiche le vrai nom du modele.
    if ollama {
        if let Some(om) = get_ollama_model() {
            model = Some(om.clone());
            if let Some(sz) = ollama_context_window(&om) {
                ctx_size = Some(sz);
            }
        }
    }

    let mut usage_src = String::from("Ollama");
    let mut api_status_s = String::from("-");
    let mut api_attempts_v: u8 = 0;
    let mut api_ms_s = String::from("-");
    let line2 = if ollama {
        read_ollama_usage(&claude_dir)
            .map(|u| build_line2_ollama(&u))
            .unwrap_or_default()
    } else {
        let usage = read_usage(&claude_dir, stdin_rate_limits, stdin_version.as_deref());
        usage_src = format!("{:?}", usage.source);
        api_status_s = usage.api_status.map(|v| v.to_string()).unwrap_or_else(|| "-".to_string());
        api_attempts_v = usage.api_attempts;
        api_ms_s = usage.api_ms.map(|v| v.to_string()).unwrap_or_else(|| "-".to_string());
        build_line2(&usage)
    };
    let usage_ms = t_usage.elapsed().as_millis();

    // Chemin pour l'AFFICHAGE seulement : pre-shaping arabe (terminal sans
    // BiDi). compute_git() ci-dessus a recu le chemin brut.
    let dir_display = arabic_display(&dir);

    let line1 = build_line1(
        &dir_display,
        &git,
        mode.as_deref(),
        model.as_deref(),
        effort.as_deref(),
        ctx_pct,
        ctx_tokens,
        ctx_size,
    );

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
            "{} tick={} effort={} git_ms={} usage_ms={} usage_src={} api_status={} api_attempts={} api_ms={} total_ms={} pid={}\n",
            start_ms_unix,
            picker_tick(start_ms_unix),
            effort.as_deref().unwrap_or("none"),
            git_ms,
            usage_ms,
            usage_src,
            api_status_s,
            api_attempts_v,
            api_ms_s,
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

#[cfg(test)]
mod tests {
    use super::arabic_display;

    fn s(cps: &[u32]) -> String {
        cps.iter().map(|&c| char::from_u32(c).unwrap()).collect()
    }

    #[test]
    fn ascii_inchange() {
        assert_eq!(arabic_display(r"C:\dev\dev-environment"), r"C:\dev\dev-environment");
    }

    // al-islam (nom du vault) : memes vecteurs que test-arabic-display.ps1.
    #[test]
    fn al_islam_deux_ligatures() {
        let input = s(&[0x0627, 0x0644, 0x0625, 0x0633, 0x0644, 0x0627, 0x0645]);
        let want = s(&[0xFEE1, 0xFEFC, 0xFEB3, 0xFEF9, 0xFE8D]);
        assert_eq!(arabic_display(&input), want);
    }

    #[test]
    fn chemin_mixte_vault() {
        let input = format!(r"C:\obsidian-vaults\{}", s(&[0x0627, 0x0644, 0x0625, 0x0633, 0x0644, 0x0627, 0x0645]));
        let want = format!(r"C:\obsidian-vaults\{}", s(&[0xFEE1, 0xFEFC, 0xFEB3, 0xFEF9, 0xFE8D]));
        assert_eq!(arabic_display(&input), want);
    }

    #[test]
    fn marhaban_right_joiners() {
        let input = s(&[0x0645, 0x0631, 0x062D, 0x0628, 0x0627]);
        let want = s(&[0xFE8E, 0xFE92, 0xFEA3, 0xFEAE, 0xFEE3]);
        assert_eq!(arabic_display(&input), want);
    }

    #[test]
    fn idempotence() {
        let shaped = s(&[0xFEE1, 0xFEFC, 0xFEB3, 0xFEF9, 0xFE8D]);
        assert_eq!(arabic_display(&shaped), shaped);
    }
}
