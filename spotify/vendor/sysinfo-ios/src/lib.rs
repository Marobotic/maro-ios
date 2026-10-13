//! What librespot-core asks sysinfo for (its client info sent to Spotify),
//! answered for iOS. The real sysinfo 0.36 does not compile for iOS.

pub struct System;

impl System {
    pub fn os_version() -> Option<String> {
        Some("17.0".into())
    }

    pub fn kernel_version() -> Option<String> {
        Some("23.0.0".into())
    }

    pub fn name() -> Option<String> {
        Some("iOS".into())
    }
}
