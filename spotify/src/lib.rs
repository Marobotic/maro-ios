//! jukebox-spotify: Spotify playback for Jukebox - the desktop helper (main.rs)
//! and, built as a static library, the iPhone app's player (ffi.rs).
//!
//!     jukebox-spotify login <dir>   sign in on Spotify's page in the browser,
//!                                   keep the login in <dir>, print who it is
//!     jukebox-spotify serve <dir>   play: commands in on stdin, events out on
//!                                   stdout, one JSON object per line
//!
//! Commands: {"cmd":"load","uri":"spotify:track:…","play":true,"pos":0}
//! play, pause, stop, {"cmd":"seek","pos":ms}, {"cmd":"volume","value":0..1},
//! {"cmd":"device","name":"…"} (empty = the Windows default),
//! {"cmd":"stage","uri":"…","role":"hover"|"next"} (load a song paused on a
//! standby player, so a "load" of it starts at once; "preload" = role next),
//! {"cmd":"token"} (a Web API token for the library), quit.
//! Library, answered with {"ev":"reply","rid":…,"ok":…,"data"|"error":…}:
//! {"cmd":"playlists","rid":1}, {"cmd":"playlist","id":"…","rid":2},
//! {"cmd":"liked","rid":3}, {"cmd":"search","q":"…","rid":4},
//! {"cmd":"tracks","uris":["spotify:track:…"],"rid":5}, {"cmd":"radio","uri":…}
//! (a song's radio playlist), {"cmd":"home","hash":…,"tz":…} (Spotify's home
//! page: Discover Weekly, Daily Mixes, stations).
//! {"cmd":"reconnect"}: the phone changed networks (Wi-Fi to 4G), so the
//! connection made on the old one is dead though nothing says so: a new one,
//! answered with {"ev":"reconnected","ok":…}.
//! Events: ready, loading, playing, paused, stopped, end, unavailable, track,
//! token, error - each with "ev" and the fields that apply.

mod library;
mod pool;
pub mod ffi;

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use librespot_core::{
    SpotifyUri, authentication::Credentials, cache::Cache, config::SessionConfig, session::Session,
};
use librespot_oauth::OAuthClientBuilder;
use librespot_playback::{mixer::Mixer, player::PlayerEvent};
use serde_json::{Value, json};

// The Spotify app the login is for, and where Spotify's page sends the browser
// back to (this computer only). The engine passes Jukebox's own registered app
// in JUKEBOX_SPOTIFY_CLIENT / JUKEBOX_SPOTIFY_REDIRECT; without them, Spotify's
// desktop client.
const CLIENT_ID: &str = "65b708073fc0480ea92a077233ca87bd";
const REDIRECT: &str = "http://127.0.0.1:8898/login";

fn client() -> (String, String) {
    (
        std::env::var("JUKEBOX_SPOTIFY_CLIENT").unwrap_or_else(|_| CLIENT_ID.into()),
        std::env::var("JUKEBOX_SPOTIFY_REDIRECT").unwrap_or_else(|_| REDIRECT.into()),
    )
}
const SCOPES: &[&str] = &[
    "streaming",
    "user-read-private",
    "user-read-email",
    "user-library-read",
    "user-library-modify",
    "playlist-read-private",
    "playlist-read-collaborative",
    "user-follow-read",
];
const DONE_PAGE: &str = concat!(
    "<!doctype html><html><head><title>Jukebox</title></head>",
    "<body style=\"background:#101315;color:#cacccc;font-family:sans-serif;text-align:center;padding-top:20vh\">",
    "<h2>Signed in to Spotify</h2><p>You can close this tab and go back to Jukebox.</p></body></html>"
);

/// Where events go: stdout for the desktop helper, a callback in the iOS app.
static SINK: std::sync::OnceLock<Box<dyn Fn(&str) + Send + Sync>> = std::sync::OnceLock::new();

/// Send events to `sink` instead of stdout. Once, before anything is emitted.
pub fn set_sink(sink: Box<dyn Fn(&str) + Send + Sync>) {
    let _ = SINK.set(sink);
}

pub fn emit(v: Value) {
    let line = v.to_string();
    match SINK.get() {
        Some(sink) => sink(&line),
        None => println!("{line}"),
    }
}

fn cache(dir: &PathBuf) -> Cache {
    Cache::new(Some(dir), None, None, None).expect("the login folder can be written")
}

pub async fn login(dir: PathBuf) {
    let (client_id, redirect) = client();
    let token = tokio::task::spawn_blocking(move || {
        OAuthClientBuilder::new(&client_id, &redirect, SCOPES.to_vec())
            .open_in_browser()
            .with_custom_message(DONE_PAGE)
            .build()
            .map_err(|e| e.to_string())?
            .get_access_token()
            .map_err(|e| e.to_string())
    })
    .await
    .unwrap_or_else(|e| Err(e.to_string()));
    let token = match token {
        Ok(t) => t,
        Err(e) => {
            emit(json!({"ev": "error", "message": format!("Spotify sign-in failed: {e}")}));
            std::process::exit(1);
        }
    };
    // The refresh token is the engine's way into the Web API (playlists,
    // library) under the same app; kept beside the player's own login.
    let (client_id, _) = client();
    let oauth = json!({"client_id": client_id, "refresh_token": token.refresh_token, "scopes": token.scopes});
    if let Err(e) = std::fs::create_dir_all(&dir).and_then(|_| std::fs::write(dir.join("oauth.json"), oauth.to_string())) {
        emit(json!({"ev": "error", "message": format!("could not keep the Spotify login: {e}")}));
        std::process::exit(1);
    }
    // Connecting once turns the access token into a saved login, so the next
    // start needs no browser.
    let session = Session::new(SessionConfig::default(), Some(cache(&dir)));
    match session.connect(Credentials::with_access_token(token.access_token), true).await {
        Ok(()) => emit(json!({"ev": "ready", "user": session.username()})),
        Err(e) => {
            emit(json!({"ev": "error", "message": format!("Spotify sign-in failed: {e}")}));
            std::process::exit(1);
        }
    }
}

/// A new session from the login stored in `dir`. Never waits more than 20 s:
/// a connect that hangs would hold up every command behind it.
async fn reconnect(dir: &PathBuf) -> Option<Session> {
    let creds = cache(dir).credentials()?;
    let session = Session::new(SessionConfig::default(), Some(cache(dir)));
    match tokio::time::timeout(Duration::from_secs(20), session.connect(creds, true)).await {
        Ok(Ok(())) => Some(session),
        Ok(Err(e)) => {
            log::warn!("Spotify would not connect again: {e}");
            None
        }
        Err(_) => {
            log::warn!("Spotify did not answer the new connection within 20 s");
            None
        }
    }
}

// One library answer may take this long (a 1,000-song playlist is three
// metadata batches); past it the connection is taken to be dead.
const LIBRARY_WAIT: Duration = Duration::from_secs(40);

/// The connection library calls use, and how many times it was replaced.
/// It starts as the player's; when a call hangs or fails it is replaced by a
/// connection of its own, so the music playing is never interrupted.
type Library = Arc<tokio::sync::Mutex<(Session, u64)>>;

async fn library_call(session: &Session, cmd: &Value) -> Result<Value, String> {
    let r = match cmd["cmd"].as_str().unwrap_or("") {
        "playlists" => library::playlists(session).await.map(Value::from),
        "playlist" => library::playlist(session, cmd["id"].as_str().unwrap_or("")).await.map(Value::from),
        "liked" => library::liked(session).await.map(Value::from),
        "search" => library::search(session, cmd["q"].as_str().unwrap_or("")).await.map(Value::from),
        "radio" => library::radio(session, cmd["uri"].as_str().unwrap_or("")).await,
        "home" => library::home(session, cmd["hash"].as_str().unwrap_or(""), cmd["tz"].as_str().unwrap_or("UTC")).await,
        "claim" => library::claim(session, cmd["id"].as_str().unwrap_or(""), cmd["token"].as_str().unwrap_or("")).await,
        "query" => library::query(session, cmd["op"].as_str().unwrap_or(""), &cmd["vars"], cmd["hash"].as_str().unwrap_or("")).await,
        _ => {
            let uris: Vec<String> = cmd["uris"].as_array().map(|a| a.iter().filter_map(|u| u.as_str().map(String::from)).collect()).unwrap_or_default();
            library::tracks(session, &uris).await.map(Value::from)
        }
    };
    r.map_err(|e| e.to_string())
}

/// Answer one library command: on the library connection, and once more on
/// a new one when that one hangs, has closed, or fails.
async fn answer(cmd: Value, lib: Library, dir: PathBuf) {
    let rid = cmd["rid"].clone();
    let what = cmd["cmd"].as_str().unwrap_or("").to_string();
    let mut result = Err(String::new());
    for attempt in 0..2 {
        let (session, epoch) = lib.lock().await.clone();
        result = if session.is_invalid() {
            Err("the connection was closed".into())
        } else {
            tokio::time::timeout(LIBRARY_WAIT, library_call(&session, &cmd)).await.unwrap_or_else(|_| Err("Spotify did not answer in time".into()))
        };
        let Err(e) = &result else { break };
        if attempt == 1 {
            break;
        }
        log::warn!("Spotify {what} failed ({e}); trying again on a new connection");
        let mut guard = lib.lock().await;
        // Another call may have replaced it while this one waited.
        if guard.1 == epoch {
            match reconnect(&dir).await {
                Some(s) => *guard = (s, epoch + 1),
                None => break,
            }
        }
    }
    match result {
        Ok(data) => emit(json!({"ev": "reply", "rid": rid, "ok": true, "data": data})),
        Err(e) => emit(json!({"ev": "reply", "rid": rid, "ok": false, "error": e})),
    }
}

fn uri(u: &SpotifyUri) -> String {
    u.to_uri().unwrap_or_default()
}

/// Play, taking commands one JSON line at a time from `lines`, until it
/// closes or a "quit" arrives. The desktop feeds it stdin; iOS, jb_send().
pub async fn serve(dir: PathBuf, mut lines: tokio::sync::mpsc::UnboundedReceiver<String>) {
    emit(json!({"ev": "log", "message": format!("serving from {}", dir.display())}));
    let c = cache(&dir);
    // No login yet: wait for one. {"cmd":"login","token":"<access token>"}
    // is a sign-in the app did on Spotify's own page (the phone's web view);
    // connecting once with it stores a reusable login in `dir`, which the
    // app then keeps on the account.
    let mut fresh = false;
    let creds = match c.credentials() {
        Some(creds) => creds,
        None => {
            emit(json!({"ev": "error", "code": "signed_out", "message": "Not signed in to Spotify."}));
            loop {
                let Some(line) = lines.recv().await else { return };
                let Ok(cmd) = serde_json::from_str::<Value>(&line) else { continue };
                match cmd["cmd"].as_str().unwrap_or("") {
                    "login" => {
                        let token = cmd["token"].as_str().unwrap_or("").to_string();
                        if !token.is_empty() {
                            fresh = true;
                            break Credentials::with_access_token(token);
                        }
                    }
                    "quit" => return,
                    _ => {}
                }
            }
        }
    };
    emit(json!({"ev": "log", "message": format!("connecting as {}", creds.username.clone().unwrap_or_default())}));
    let mut session = Session::new(SessionConfig::default(), Some(c));
    match tokio::time::timeout(Duration::from_secs(30), session.connect(creds, true)).await {
        Ok(Ok(())) => {}
        Ok(Err(e)) => {
            emit(json!({"ev": "error", "code": "signed_out", "message": format!("Spotify would not sign in: {e}")}));
            return;
        }
        Err(_) => {
            // Offline or Spotify not answering: the app starts it again on the next use.
            emit(json!({"ev": "error", "code": "signed_out", "message": "Spotify did not answer. Check the connection."}));
            return;
        }
    }
    // "login": true when this start just turned a sign-in into a stored login.
    emit(json!({"ev": "ready", "user": session.username(), "login": fresh}));

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<pool::Tagged>();
    let mut volume: u16 = u16::MAX;
    let mut generation: u64 = 0;
    let mut slots = pool::open(&session, None, volume, generation, &tx);
    let mut active: usize = 0;
    // The last song loaded on the playing player, so a load that failed on a
    // worn-out connection can be tried again on a new one, once.
    let mut last_load: Option<(String, u32, bool)> = None;
    let mut retried: Option<String> = None;
    let mut connected_at = std::time::Instant::now();
    let lib: Library = Arc::new(tokio::sync::Mutex::new((session.clone(), 0)));

    // Spotify drops the connection after some hours and librespot does not
    // reconnect: every song then fails as "unavailable" until a restart. A
    // new session (from the stored login) and new players replace the old.
    macro_rules! renew {
        () => {{
            match reconnect(&dir).await {
                Some(s) => {
                    for old in &slots {
                        old.player.stop();
                        if let Some(u) = &old.staged {
                            emit(json!({"ev": "stage_failed", "uri": u}));
                        }
                    }
                    generation += 1;
                    session = s;
                    slots = pool::open(&session, None, volume, generation, &tx);
                    active = 0;
                    connected_at = std::time::Instant::now();
                    // A library connection that died with the old one moves to the new.
                    if let Ok(mut l) = lib.try_lock() {
                        if l.0.is_invalid() {
                            *l = (session.clone(), l.1 + 1);
                        }
                    }
                    true
                }
                None => false,
            }
        }};
    }

    loop {
        tokio::select! {
            line = lines.recv() => {
                let Some(line) = line else { break };
                let Ok(cmd) = serde_json::from_str::<Value>(&line) else { continue };
                let pos = cmd["pos"].as_u64().unwrap_or(0) as u32;
                let want = cmd["uri"].as_str().unwrap_or("").to_string();
                let what = cmd["cmd"].as_str().unwrap_or("");
                if session.is_invalid() && !matches!(what, "pause" | "stop" | "volume" | "quit" | "reconnect") {
                    log::warn!("Spotify's connection was closed; connecting again");
                    renew!();
                }
                match what {
                    "load" => {
                        let Ok(u) = SpotifyUri::from_uri(&want) else {
                            emit(json!({"ev": "error", "message": "not a Spotify track"}));
                            continue;
                        };
                        let play = cmd["play"].as_bool().unwrap_or(true);
                        if retried.as_deref() != Some(want.as_str()) {
                            retried = None;
                        }
                        last_load = Some((want.clone(), pos, play));
                        if let Some(i) = pool::staged(&slots, active, &want) {
                            // Staged: already loaded and paused at its start.
                            slots[active].player.stop();
                            active = i;
                            slots[i].staged = None;
                            if pos > 0 {
                                slots[i].player.seek(pos);
                            }
                            if play {
                                slots[i].player.play();
                            }
                            emit(json!({"ev": "swapped", "uri": want}));
                        } else {
                            slots[active].player.load(u, play, pos);
                        }
                    }
                    "stage" | "preload" => {
                        let Ok(u) = SpotifyUri::from_uri(&want) else { continue };
                        if pool::staged(&slots, active, &want).is_some() {
                            continue;
                        }
                        let role = cmd["role"].as_str().unwrap_or("next").to_string();
                        let i = pool::slot_for(&slots, active, &role);
                        slots[i].staged = Some(want.clone());
                        slots[i].role = role;
                        slots[i].player.load(u, false, 0);
                    }
                    "play" => slots[active].player.play(),
                    "pause" => slots[active].player.pause(),
                    "stop" => slots[active].player.stop(),
                    "seek" => slots[active].player.seek(pos),
                    "volume" => {
                        volume = (cmd["value"].as_f64().unwrap_or(1.0).clamp(0.0, 1.0) * u16::MAX as f64) as u16;
                        for s in &slots {
                            s.mixer.set_volume(volume);
                        }
                    }
                    "device" => {
                        // The output is fixed when a player opens, so a new
                        // device means new players; the engine reloads the
                        // track at its position afterwards.
                        for s in &slots {
                            s.player.stop();
                        }
                        let name = cmd["name"].as_str().filter(|n| !n.is_empty()).map(String::from);
                        generation += 1;
                        slots = pool::open(&session, name, volume, generation, &tx);
                        active = 0;
                        emit(json!({"ev": "device"}));
                    }
                    "token" => match session.login5().auth_token().await {
                        Ok(t) => emit(json!({"ev": "token", "access_token": t.access_token, "expires_in": t.expires_in.as_secs()})),
                        Err(e) => emit(json!({"ev": "error", "message": format!("no Spotify token: {e}")})),
                    },
                    "reconnect" => {
                        // Not again when the connection is seconds old.
                        let ok = connected_at.elapsed().as_secs() < 3 || renew!();
                        if ok {
                            let mut l = lib.lock().await;
                            *l = (session.clone(), l.1 + 1);
                        }
                        emit(json!({"ev": "reconnected", "ok": ok}));
                    }
                    "playlists" | "playlist" | "liked" | "search" | "tracks" | "radio" | "home" | "query" | "claim" => {
                        // In the background: a big library must not hold up play/pause.
                        tokio::spawn(answer(cmd, lib.clone(), dir.clone()));
                    }
                    "quit" => break,
                    _ => {}
                }
            }
            got = rx.recv() => {
                let Some((g, i, ev)) = got else { break };
                if g != generation {
                    continue;       // a pool replaced by a device change
                }
                if i != active {
                    // A standby player: only whether its song could be staged.
                    match ev {
                        PlayerEvent::Paused { track_id, .. } => emit(json!({"ev": "staged", "uri": uri(&track_id)})),
                        PlayerEvent::Unavailable { track_id, .. } => {
                            if slots[i].staged.as_deref() == Some(uri(&track_id).as_str()) {
                                slots[i].staged = None;
                            }
                            emit(json!({"ev": "stage_failed", "uri": uri(&track_id)}));
                        }
                        _ => {}
                    }
                    continue;
                }
                match ev {
                    PlayerEvent::Loading { track_id, position_ms, .. } => emit(json!({"ev": "loading", "uri": uri(&track_id), "pos": position_ms})),
                    PlayerEvent::Playing { track_id, position_ms, .. } => emit(json!({"ev": "playing", "uri": uri(&track_id), "pos": position_ms})),
                    PlayerEvent::PositionCorrection { track_id, position_ms, .. } => emit(json!({"ev": "playing", "uri": uri(&track_id), "pos": position_ms})),
                    PlayerEvent::Paused { track_id, position_ms, .. } => emit(json!({"ev": "paused", "uri": uri(&track_id), "pos": position_ms})),
                    PlayerEvent::Stopped { track_id, .. } => emit(json!({"ev": "stopped", "uri": uri(&track_id)})),
                    PlayerEvent::EndOfTrack { track_id, .. } => emit(json!({"ev": "end", "uri": uri(&track_id)})),
                    PlayerEvent::Unavailable { track_id, .. } => {
                        // Once per song, on a connection older than a minute:
                        // a new one, and the song again. A song Spotify
                        // really will not play fails the same way twice.
                        let u = uri(&track_id);
                        let again = match &last_load {
                            Some((l, pos, play)) if *l == u && retried.as_deref() != Some(u.as_str()) && connected_at.elapsed().as_secs() > 60 => Some((*pos, *play)),
                            _ => None,
                        };
                        if let Some((pos, play)) = again {
                            retried = Some(u.clone());
                            log::warn!("Spotify could not load {u}; connecting again and trying once more");
                            if renew!() {
                                if let Ok(su) = SpotifyUri::from_uri(&u) {
                                    slots[active].player.load(su, play, pos);
                                    continue;
                                }
                            }
                        }
                        emit(json!({"ev": "unavailable", "uri": u}));
                    }
                    PlayerEvent::Bitrate { track_id, position_ms, kbps, nominal_kbps } => emit(json!({"ev": "bitrate", "uri": uri(&track_id), "pos": position_ms, "kbps": kbps, "nominal": nominal_kbps})),
                    PlayerEvent::TrackChanged { audio_item } => emit(json!({"ev": "track", "uri": audio_item.uri, "name": audio_item.name, "duration": audio_item.duration_ms})),
                    _ => {}
                }
            }
        }
    }
    for s in &slots {
        s.player.stop();
    }
}
