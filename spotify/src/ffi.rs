//! The iPhone app's way in: the same player and library as the desktop
//! helper, with jb_spotify_send() for stdin and a callback for stdout.
//!
//!     jb_spotify_start("/path/to/login/dir", on_event)  -> true once serving
//!     jb_spotify_send("{\"cmd\":\"load\",\"uri\":\"spotify:track:...\"}")
//!
//! `on_event` gets one JSON event per call, on one of the player's own
//! threads; the app hops to its main thread itself. Starting again (another
//! account, a login that just arrived) ends the previous session first.

use std::ffi::{CStr, CString, c_char};
use std::sync::{Mutex, OnceLock};

use tokio::sync::mpsc::UnboundedSender;

pub type Callback = extern "C" fn(*const c_char);

static INPUT: Mutex<Option<UnboundedSender<String>>> = Mutex::new(None);
static RUNTIME: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
static CALLBACK: OnceLock<Callback> = OnceLock::new();

/// # Safety
/// `dir` must be a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jb_spotify_start(dir: *const c_char, on_event: Callback) -> bool {
    if dir.is_null() {
        return false;
    }
    let dir = unsafe { CStr::from_ptr(dir) }.to_string_lossy().into_owned();
    if CALLBACK.set(on_event).is_ok() {
        crate::set_sink(Box::new(|line| {
            if let (Some(cb), Ok(c)) = (CALLBACK.get(), CString::new(line)) {
                cb(c.as_ptr());
            }
        }));
    }
    let rt = RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .expect("the Spotify player's runtime")
    });
    let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
    // Dropping the old sender ends the previous serve loop.
    *INPUT.lock().unwrap_or_else(|e| e.into_inner()) = Some(tx);
    rt.spawn(crate::serve(dir.into(), rx));
    true
}

/// # Safety
/// `line` must be a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jb_spotify_send(line: *const c_char) -> bool {
    if line.is_null() {
        return false;
    }
    let line = unsafe { CStr::from_ptr(line) }.to_string_lossy().into_owned();
    match INPUT.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
        Some(tx) => tx.send(line).is_ok(),
        None => false,
    }
}
