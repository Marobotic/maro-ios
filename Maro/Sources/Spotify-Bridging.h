// The Spotify player compiled from spotify/ (Rust, librespot) - see
// spotify/src/ffi.rs and Spotify.swift.
#include <stdbool.h>

bool jb_spotify_start(const char *dir, void (*on_event)(const char *line));
bool jb_spotify_send(const char *line);
