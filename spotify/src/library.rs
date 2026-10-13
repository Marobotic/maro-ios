//! The library side of Spotify, through the same internal endpoints the
//! Spotify app itself uses (spclient). The public Web API is not used: with
//! Spotify's own client id it answers every call with 429.
//!
//! Tracks come out in the Web API's shape ({id, uri, name, artists, album,
//! duration_ms}) so the engine reads them exactly as it always has.

use std::collections::HashMap;

use librespot_core::{Error, SpotifyId, session::Session};
use librespot_protocol::{
    extended_metadata::{BatchedEntityRequest, EntityRequest, ExtensionQuery},
    extension_kind::ExtensionKind,
    metadata::Track,
    playlist4_external::SelectedListContent,
};
use protobuf::{EnumOrUnknown, Message};
use serde_json::{Value, json};

const TRACK: &str = "spotify:track:";
// Spotify's metadata service takes this many entities per request.
const BATCH: usize = 500;

fn image(file_id: &[u8]) -> String {
    let hex: String = file_id.iter().map(|b| format!("{b:02x}")).collect();
    format!("https://i.scdn.co/image/{hex}")
}

fn track_json(uri: &str, t: &Track) -> Value {
    let id = uri.strip_prefix(TRACK).unwrap_or(uri);
    let album = t.album.as_ref();
    // The largest cover: sizes go DEFAULT, SMALL, LARGE, XLARGE.
    let cover = album
        .and_then(|a| a.cover_group.as_ref().map(|g| g.image.clone()).filter(|i| !i.is_empty()).or_else(|| Some(a.cover.clone())))
        .unwrap_or_default()
        .into_iter()
        .max_by_key(|i| i.width.unwrap_or(0).max(i.size.map(|s| s.value()).unwrap_or(0)))
        .map(|i| image(i.file_id()));
    json!({
        "id": id,
        "uri": uri,
        "name": t.name(),
        "artists": t.artist.iter().map(|a| json!({"name": a.name()})).collect::<Vec<_>>(),
        "album": {
            "name": album.map(|a| a.name()).unwrap_or(""),
            "images": cover.map(|u| vec![json!({"url": u})]).unwrap_or_default(),
        },
        "duration_ms": t.duration(),
        "explicit": t.explicit(),
    })
}

/// Track details for any number of track uris, in their order; unknown ones
/// are left out.
pub async fn tracks(session: &Session, uris: &[String]) -> Result<Vec<Value>, Error> {
    let wanted: Vec<&String> = uris.iter().filter(|u| u.starts_with(TRACK)).collect();
    let mut known: HashMap<String, Value> = HashMap::new();
    for chunk in wanted.chunks(BATCH) {
        let request = BatchedEntityRequest {
            entity_request: chunk
                .iter()
                .map(|uri| EntityRequest {
                    entity_uri: (*uri).clone(),
                    query: vec![ExtensionQuery {
                        extension_kind: EnumOrUnknown::new(ExtensionKind::TRACK_V4),
                        ..Default::default()
                    }],
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        };
        let response = session.spclient().get_extended_metadata(request).await?;
        for array in response.extended_metadata {
            for data in array.extension_data {
                let Some(any) = data.extension_data.as_ref() else { continue };
                if let Ok(t) = Track::parse_from_bytes(&any.value) {
                    known.insert(data.entity_uri.clone(), track_json(&data.entity_uri, &t));
                }
            }
        }
    }
    Ok(wanted.into_iter().filter_map(|u| known.remove(u)).collect())
}

/// Your playlists, in the order Spotify shows them (folders flattened).
pub async fn playlists(session: &Session) -> Result<Vec<Value>, Error> {
    let mut out = Vec::new();
    let mut from = 0;
    loop {
        let bytes = session.spclient().get_rootlist(from, Some(200)).await?;
        let list = SelectedListContent::parse_from_bytes(&bytes)?;
        let contents = list.contents.as_ref();
        let items = contents.map(|c| c.items.clone()).unwrap_or_default();
        let metas = contents.map(|c| c.meta_items.clone()).unwrap_or_default();
        let n = items.len();
        for (i, item) in items.iter().enumerate() {
            let Some(id) = item.uri().strip_prefix("spotify:playlist:") else { continue };
            let meta = metas.get(i);
            let attrs = meta.and_then(|m| m.attributes.as_ref());
            out.push(json!({
                "id": id,
                "name": attrs.map(|a| a.name()).unwrap_or(""),
                "count": meta.map(|m| m.length()).unwrap_or(0),
                "owner": meta.map(|m| m.owner_username()).unwrap_or(""),
                "art": attrs.filter(|a| a.has_picture()).map(|a| image(a.picture())).unwrap_or_default(),
            }));
        }
        let truncated = contents.map(|c| c.truncated()).unwrap_or(false);
        if !truncated || n == 0 {
            break;
        }
        from += n;
    }
    Ok(out)
}

/// One playlist's tracks.
pub async fn playlist(session: &Session, id: &str) -> Result<Vec<Value>, Error> {
    let pid = SpotifyId::from_base62(id)?;
    let bytes = session.spclient().get_playlist(&pid).await?;
    let list = SelectedListContent::parse_from_bytes(&bytes)?;
    let uris: Vec<String> = list
        .contents
        .as_ref()
        .map(|c| c.items.iter().map(|i| i.uri().to_string()).collect())
        .unwrap_or_default();
    tracks(session, &uris).await
}

/// Search: the same "search context" the Spotify app plays results from.
pub async fn search(session: &Session, q: &str) -> Result<Vec<Value>, Error> {
    let q = q.trim();
    if q.is_empty() {
        return Ok(vec![]);
    }
    let escaped: String = q
        .split_whitespace()
        .map(|w| url_escape(w))
        .collect::<Vec<_>>()
        .join("+");
    let ctx = session.spclient().get_context(&format!("spotify:search:{escaped}")).await?;
    let uris: Vec<String> = ctx
        .pages
        .iter()
        .flat_map(|p| p.tracks.iter())
        .filter_map(|t| t.uri.clone())
        .filter(|u| u.starts_with(TRACK))
        .take(30)
        .collect();
    tracks(session, &uris).await
}

fn url_escape(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

// --- Liked Songs: the "collection" set, newest first -------------------------
//
// The collection service speaks a small protobuf that librespot does not
// compile in, so its two messages are written and read by hand here:
//   PageRequest  { 1 username, 2 set, 3 pagination_token, 4 limit }
//   PageResponse { 1 repeated item {1 uri, 2 added_at, 3 is_removed}, 2 next_page_token }

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let b = (v & 0x7f) as u8;
        v >>= 7;
        if v == 0 {
            out.push(b);
            return;
        }
        out.push(b | 0x80);
    }
}

fn put_str(out: &mut Vec<u8>, field: u64, s: &str) {
    if s.is_empty() {
        return;
    }
    put_varint(out, field << 3 | 2);
    put_varint(out, s.len() as u64);
    out.extend_from_slice(s.as_bytes());
}

fn get_varint(b: &[u8], i: &mut usize) -> Option<u64> {
    let mut v = 0u64;
    let mut shift = 0;
    loop {
        let byte = *b.get(*i)?;
        *i += 1;
        v |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 {
            return Some(v);
        }
        shift += 7;
        if shift > 63 {
            return None;
        }
    }
}

/// (field, wire type, payload) for each field of one message.
fn fields(b: &[u8]) -> Vec<(u64, u64, Vec<u8>, u64)> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < b.len() {
        let Some(key) = get_varint(b, &mut i) else { break };
        let (field, wire) = (key >> 3, key & 7);
        match wire {
            0 => {
                let Some(v) = get_varint(b, &mut i) else { break };
                out.push((field, wire, vec![], v));
            }
            2 => {
                let Some(len) = get_varint(b, &mut i) else { break };
                let end = i + len as usize;
                if end > b.len() {
                    break;
                }
                out.push((field, wire, b[i..end].to_vec(), 0));
                i = end;
            }
            5 => i += 4,
            1 => i += 8,
            _ => break,
        }
    }
    out
}

pub async fn liked(session: &Session) -> Result<Vec<Value>, Error> {
    let user = session.username();
    let mut uris: Vec<String> = Vec::new();
    let mut token = String::new();
    loop {
        let mut req = Vec::new();
        put_str(&mut req, 1, &user);
        put_str(&mut req, 2, "collection");
        put_str(&mut req, 3, &token);
        put_varint(&mut req, 4 << 3);
        put_varint(&mut req, 300);
        let mut headers = http::HeaderMap::new();
        headers.insert("Content-Type", "application/vnd.collection-v2.spotify.proto".parse().unwrap());
        headers.insert("Accept", "application/vnd.collection-v2.spotify.proto".parse().unwrap());
        let res = session
            .spclient()
            .request(&http::Method::POST, "/collection/v2/paging", Some(headers), Some(&req))
            .await?;
        token.clear();
        for (field, _, payload, _) in fields(&res) {
            if field == 1 {
                let mut uri = String::new();
                let mut removed = false;
                for (f, _, p, v) in fields(&payload) {
                    if f == 1 {
                        uri = String::from_utf8_lossy(&p).into_owned();
                    } else if f == 3 {
                        removed = v != 0;
                    }
                }
                if !removed && uri.starts_with(TRACK) {
                    uris.push(uri);
                }
            } else if field == 2 {
                token = String::from_utf8_lossy(&payload).into_owned();
            }
        }
        if token.is_empty() {
            break;
        }
    }
    tracks(session, &uris).await
}
