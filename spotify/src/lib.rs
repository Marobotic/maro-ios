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
//! {"cmd":"tracks","uris":["spotify:track:…"],"rid":5}.
//! Events: ready, loading, playing, paused, stopped, end, unavailable, track,
//! token, error - each with "ev" and the fields that apply.

mod library;
mod pool;
pub mod ffi;

use std::path::PathBuf;

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

fn uri(u: &SpotifyUri) -> String {
    u.to_uri().unwrap_or_default()
}

/// Play, taking commands one JSON line at a time from `lines`, until it
/// closes or a "quit" arrives. The desktop feeds it stdin; iOS, jb_send().
pub async fn serve(dir: PathBuf, mut lines: tokio::sync::mpsc::UnboundedReceiver<String>) {
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
    let session = Session::new(SessionConfig::default(), Some(c));
    if let Err(e) = session.connect(creds, true).await {
        emit(json!({"ev": "error", "code": "signed_out", "message": format!("Spotify would not sign in: {e}")}));
        return;
    }
    // "login": true when this start just turned a sign-in into a stored login.
    emit(json!({"ev": "ready", "user": session.username(), "login": fresh}));

    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<pool::Tagged>();
    let mut volume: u16 = u16::MAX;
    let mut generation: u64 = 0;
    let mut slots = pool::open(&session, None, volume, generation, &tx);
    let mut active: usize = 0;

    loop {
        tokio::select! {
            line = lines.recv() => {
                let Some(line) = line else { break };
                let Ok(cmd) = serde_json::from_str::<Value>(&line) else { continue };
                let pos = cmd["pos"].as_u64().unwrap_or(0) as u32;
                let want = cmd["uri"].as_str().unwrap_or("").to_string();
                match cmd["cmd"].as_str().unwrap_or("") {
                    "load" => {
                        let Ok(u) = SpotifyUri::from_uri(&want) else {
                            emit(json!({"ev": "error", "message": "not a Spotify track"}));
                            continue;
                        };
                        let play = cmd["play"].as_bool().unwrap_or(true);
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
                    "playlists" | "playlist" | "liked" | "search" | "tracks" => {
                        // In the background: a big library must not hold up play/pause.
                        let session = session.clone();
                        tokio::spawn(async move {
                            let rid = cmd["rid"].clone();
                            let result = match cmd["cmd"].as_str().unwrap_or("") {
                                "playlists" => library::playlists(&session).await,
                                "playlist" => library::playlist(&session, cmd["id"].as_str().unwrap_or("")).await,
                                "liked" => library::liked(&session).await,
                                "search" => library::search(&session, cmd["q"].as_str().unwrap_or("")).await,
                                _ => {
                                    let uris: Vec<String> = cmd["uris"].as_array().map(|a| a.iter().filter_map(|u| u.as_str().map(String::from)).collect()).unwrap_or_default();
                                    library::tracks(&session, &uris).await
                                }
                            };
                            match result {
                                Ok(data) => emit(json!({"ev": "reply", "rid": rid, "ok": true, "data": data})),
                                Err(e) => emit(json!({"ev": "reply", "rid": rid, "ok": false, "error": e.to_string()})),
                            }
                        });
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
                    PlayerEvent::Unavailable { track_id, .. } => emit(json!({"ev": "unavailable", "uri": uri(&track_id)})),
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
