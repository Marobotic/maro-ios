//! The players. Besides the one playing, two stand by with a song loaded and
//! paused at its start: the one under the pointer ("hover") and the queue's
//! next ("next"). A load of either swaps it in and it plays at once.
//! librespot keeps only one preload per player, and a cold start costs a
//! second or more (metadata, CDN, decryption key, decoder) that nothing else
//! can save.

use std::sync::Arc;

use librespot_core::session::Session;
use librespot_playback::{
    audio_backend,
    config::{AudioFormat, Bitrate, PlayerConfig},
    mixer::{Mixer, MixerConfig, softmixer::SoftMixer},
    player::{Player, PlayerEvent},
};
use tokio::sync::mpsc::UnboundedSender;

pub const SLOTS: usize = 3;

/// An event, the pool generation it came from, and which slot sent it.
pub type Tagged = (u64, usize, PlayerEvent);

pub struct Slot {
    pub player: Arc<Player>,
    pub mixer: Arc<SoftMixer>,
    /// The song loaded and paused on this standby player, if any.
    pub staged: Option<String>,
    /// What it was staged for last ("hover" or "next"), so each keeps its own.
    pub role: String,
}

pub fn open(
    session: &Session,
    device: Option<String>,
    volume: u16,
    generation: u64,
    tx: &UnboundedSender<Tagged>,
) -> Vec<Slot> {
    (0..SLOTS)
        .map(|i| {
            let mixer = Arc::new(SoftMixer::open(MixerConfig::default()).expect("software volume"));
            mixer.set_volume(volume);
            let backend = audio_backend::find(Some("rodio".into())).expect("the rodio backend is built in");
            let device = device.clone();
            // 320 kbps: librespot's default is 160. A song with no 320 file
            // gets the next best, and the "bitrate" event says which it got.
            let config = PlayerConfig { bitrate: Bitrate::Bitrate320, ..PlayerConfig::default() };
            let player = Player::new(config, session.clone(), mixer.get_soft_volume(), move || {
                backend(device, AudioFormat::default())
            });
            let mut events = player.get_player_event_channel();
            let tx = tx.clone();
            tokio::spawn(async move {
                while let Some(ev) = events.recv().await {
                    if tx.send((generation, i, ev)).is_err() {
                        break;
                    }
                }
            });
            Slot { player, mixer, staged: None, role: String::new() }
        })
        .collect()
}

/// The standby slot holding `uri`, if any.
pub fn staged(slots: &[Slot], active: usize, uri: &str) -> Option<usize> {
    (0..slots.len()).find(|&i| i != active && slots[i].staged.as_deref() == Some(uri))
}

/// Where to stage a song for `role`: the standby slot that role used last,
/// else an idle one, else the other.
pub fn slot_for(slots: &[Slot], active: usize, role: &str) -> usize {
    let standby: Vec<usize> = (0..slots.len()).filter(|&i| i != active).collect();
    standby
        .iter()
        .copied()
        .find(|&i| slots[i].role == role)
        .or_else(|| standby.iter().copied().find(|&i| slots[i].staged.is_none()))
        .unwrap_or(standby[0])
}
