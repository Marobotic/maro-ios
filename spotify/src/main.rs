//! The desktop helper: `jukebox-spotify login|serve <dir>`, commands on stdin
//! and events on stdout, one JSON object per line. Everything else is in lib.rs.

use std::path::PathBuf;

use tokio::io::{AsyncBufReadExt, BufReader};

#[tokio::main]
async fn main() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("warn"))
        .target(env_logger::Target::Stderr)
        .init();
    let args: Vec<String> = std::env::args().collect();
    if args.len() != 3 || !matches!(args[1].as_str(), "login" | "serve") {
        eprintln!("usage: jukebox-spotify login|serve <dir>");
        std::process::exit(2);
    }
    let dir = PathBuf::from(&args[2]);
    if args[1] == "login" {
        return jukebox_spotify::login(dir).await;
    }
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut lines = BufReader::new(tokio::io::stdin()).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    jukebox_spotify::serve(dir, rx).await;
    // Signed out (the engine reads the "signed_out" event), or stdin closed.
    std::process::exit(0);
}
