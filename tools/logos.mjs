// Makes the iOS app's brand images, as exact-scale PNGs (@1x, @2x, @3x) in the asset catalog:
//   Logo-<service>-<pt>.imageset  the official Spotify, YouTube Music, YouTube and SoundCloud
//                                 logos (the desktop's BRAND paths, ui/main.ts), rasterised
//                                 smooth by librsvg at 16 pt (menus) and 28 pt (Accounts);
//   Logo-jukebox-<pt>.imageset    the Jukebox app icon (the #121212 tile and the gold pixel
//                                 note) at 16 pt and 32 pt, the note on whole pixels.
//   node tools/logos.mjs      (needs rsvg-convert; the same art as the Android app's tools/logos.mjs)
import { writeFileSync, mkdirSync, mkdtempSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { tmpdir } from "node:os";
import { join } from "node:path";

const assets = new URL("../Maro/Resources/Assets.xcassets/", import.meta.url).pathname;
const SCALES = [1, 2, 3];
const BRAND = {
  spotify: { fill: "#1DB954", d: "M12 0C5.4 0 0 5.4 0 12s5.4 12 12 12 12-5.4 12-12S18.66 0 12 0zm5.521 17.34c-.24.359-.66.48-1.021.24-2.82-1.74-6.36-2.101-10.561-1.141-.418.122-.779-.179-.899-.539-.12-.421.18-.78.54-.9 4.56-1.021 8.52-.6 11.64 1.32.42.18.479.659.301 1.02zm1.44-3.3c-.301.42-.841.6-1.262.3-3.239-1.98-8.159-2.58-11.939-1.38-.479.12-1.02-.12-1.14-.6-.12-.48.12-1.021.6-1.141C9.6 9.9 15 10.561 18.72 12.84c.361.181.54.78.241 1.2zm.12-3.36C15.24 8.4 8.82 8.16 5.16 9.301c-.6.179-1.2-.181-1.38-.721-.18-.601.18-1.2.72-1.381 4.26-1.26 11.28-1.02 15.721 1.621.539.3.719 1.02.419 1.56-.299.421-1.02.599-1.559.3z" },
  ytm: { fill: "#FF0033", under: '<circle cx="12" cy="12" r="8" fill="#fff"/>', d: "M12 0C5.376 0 0 5.376 0 12s5.376 12 12 12 12-5.376 12-12S18.624 0 12 0zm0 19.104c-3.924 0-7.104-3.18-7.104-7.104S8.076 4.896 12 4.896s7.104 3.18 7.104 7.104-3.18 7.104-7.104 7.104zm0-13.332c-3.432 0-6.228 2.796-6.228 6.228S8.568 18.228 12 18.228s6.228-2.796 6.228-6.228S15.432 5.772 12 5.772zM9.684 15.54V8.46L15.816 12l-6.132 3.54z" },
  youtube: { fill: "#FF0033", under: '<path d="M9 8h7v8H9z" fill="#fff"/>', d: "M23.498 6.186a3.016 3.016 0 0 0-2.122-2.136C19.505 3.545 12 3.545 12 3.545s-7.505 0-9.377.505A3.017 3.017 0 0 0 .502 6.186C0 8.07 0 12 0 12s0 3.93.502 5.814a3.016 3.016 0 0 0 2.122 2.136c1.871.505 9.376.505 9.376.505s7.505 0 9.377-.505a3.015 3.015 0 0 0 2.122-2.136C24 15.93 24 12 24 12s0-3.93-.502-5.814zM9.545 15.568V8.432L15.818 12l-6.273 3.568z" },
  sc: { fill: "#FF5500", d: "M23.999 14.165c-.052 1.796-1.612 3.169-3.4 3.169h-8.18a.68.68 0 0 1-.675-.683V7.862a.747.747 0 0 1 .452-.724s.75-.513 2.333-.513a5.364 5.364 0 0 1 2.763.755 5.433 5.433 0 0 1 2.57 3.54c.282-.08.574-.121.868-.12.884 0 1.73.358 2.347.992s.948 1.49.922 2.373ZM10.721 8.421c.247 2.98.427 5.697 0 8.672a.264.264 0 0 1-.53 0c-.395-2.946-.22-5.718 0-8.672a.264.264 0 0 1 .53 0ZM9.072 9.448c.285 2.659.37 4.986-.006 7.655a.277.277 0 0 1-.55 0c-.331-2.63-.256-5.02 0-7.655a.277.277 0 0 1 .556 0Zm-1.663-.257c.27 2.726.39 5.171 0 7.904a.266.266 0 0 1-.532 0c-.38-2.69-.257-5.21 0-7.904a.266.266 0 0 1 .532 0Zm-1.647.77a26.108 26.108 0 0 1-.008 7.147.272.272 0 0 1-.542 0 27.955 27.955 0 0 1 0-7.147.275.275 0 0 1 .55 0Zm-1.67 1.769c.421 1.865.228 3.5-.029 5.388a.257.257 0 0 1-.514 0c-.21-1.858-.398-3.549 0-5.389a.272.272 0 0 1 .543 0Zm-1.655-.273c.388 1.897.26 3.508-.01 5.412-.026.28-.514.283-.54 0-.244-1.878-.347-3.54-.01-5.412a.283.283 0 0 1 .56 0Zm-1.668.911c.4 1.268.257 2.292-.026 3.572a.257.257 0 0 1-.514 0c-.241-1.262-.354-2.312-.023-3.572a.283.283 0 0 1 .563 0Z" },
};
// The app icon's note, one string per row, "o" a pixel (the desktop's JB_MARK).
const NOTE = ["....ooooooo", "....ooooooo", "....o.....o", "....o.....o", "....o.....o", "....o.....o", "..ooo...ooo", ".oooo..oooo", "oooo..oooo.", ".oo....oo.."];

const dir = mkdtempSync(join(tmpdir(), "jblogos-"));
function render(svg, px, out) {
  const file = join(dir, "x.svg");
  writeFileSync(file, svg);
  execFileSync("rsvg-convert", ["-w", String(px), "-h", String(px), file, "-o", out]);
}
function jukebox(px) {
  // The note as big as whole pixels allow, about 69 % of the tile like the desktop's icon-16/32/64.
  const k = Math.max(1, Math.floor((px * 0.69) / 11));
  const x0 = Math.floor((px - 11 * k) / 2), y0 = Math.floor((px - 10 * k) / 2);
  const d = NOTE.flatMap((row, y) => [...row].map((c, x) => (c === "o" ? `M${x0 + x * k} ${y0 + y * k}h${k}v${k}h-${k}z` : ""))).join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${px} ${px}"><rect width="${px}" height="${px}" rx="${px * 0.16}" fill="#121212"/>` +
    `<path fill="#F0BE66" shape-rendering="crispEdges" d="${d}"/></svg>`;
}
function imageset(name, pt, svgOf) {
  const out = join(assets, name + ".imageset");
  mkdirSync(out, { recursive: true });
  const images = [];
  for (const s of SCALES) {
    const file = `${name}@${s}x.png`;
    render(svgOf(pt * s), pt * s, join(out, file));
    images.push({ idiom: "universal", filename: file, scale: `${s}x` });
  }
  // Drawn at the size it was made for: never scaled, never re-tinted.
  writeFileSync(join(out, "Contents.json"), JSON.stringify({ images, info: { author: "xcode", version: 1 }, properties: { "preserves-vector-representation": false } }, null, 2) + "\n");
}
for (const [key, b] of Object.entries(BRAND))
  for (const pt of [16, 28])
    imageset(`Logo-${key}-${pt}`, pt, () => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">${b.under || ""}<path fill="${b.fill}" d="${b.d}"/></svg>`);
for (const pt of [16, 32]) imageset(`Logo-jukebox-${pt}`, pt, (px) => jukebox(px));
console.log("Assets.xcassets/Logo-*.imageset made");
