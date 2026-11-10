"use strict";
const $ = (id) => document.getElementById(id);
let startedAt = 0, startedPlaying = false, waitingSince = null, finishedSeen = false, sid = null, hls = null, statTimer = null, restartTimer = null, gen = 0;

function fill(sel, items) {
  sel.replaceChildren(...items.map(([v, t]) => new Option(t, v)));
}

async function api(path, body) {
  const r = await fetch(path, body === undefined ? {} : {
    method: "POST", headers: {"Content-Type": "application/json"},
    body: JSON.stringify(body)});
  let j = {};
  try { j = await r.json(); } catch (e) { /* keep empty */ }
  return {ok: r.ok, status: r.status, json: j};
}

function pct(id, v) {
  $(id).textContent = v == null ? "-" : v + "%";
  const bar = $(id + "bar");
  if (bar) bar.style.width = (v || 0) + "%";
}

function showStats(s) {
  $("streams").textContent = s.streams + " / " + s.max;
  const c = s.card || {};
  const enc = c.encoders || {}, dec = c.decoders || {};
  pct("enc", enc.load); pct("dec", dec.load);
  $("encinst").textContent = enc.inst != null ? enc.inst + " / " + enc.max_inst + " instances" : "";
  $("decinst").textContent = dec.inst != null ? dec.inst + " / " + dec.max_inst + " instances" : "";
  const sc = (c.scalers || c.uploaders || {});
  $("scl").textContent = sc.load != null ? sc.load + "%" : "-";
  $("ai").textContent = c.AIs ? "AI " + c.AIs.load + "%, " + c.AIs.inst + " inst" : "";
  $("temp").textContent = c.temp != null ? c.temp + " C" : "-";
  $("power").textContent = c.power_mw != null ? (c.power_mw / 1000).toFixed(1) + " W" : "";
  pct("cpu", s.cpu);
  pct("ram", s.ram && s.ram.used_pct);
  $("ramstreams").textContent = s.ram ? "streams: " + s.ram.streams_mb + " MB" : "";
  const ses = s.session;
  const n = s.net;
  $("nettx").textContent = n ? n.tx_mbps.toFixed(1) + " Mbit/s out" : "-";
  $("netrx").textContent = n ? n.rx_mbps.toFixed(1) + " Mbit/s in, link " + (n.link_mbps / 1000) + " Gbit/s" : "";
  $("nettxbar").style.width = n ? Math.min(100, 100 * n.tx_mbps / n.link_mbps) + "%" : "0";
  if (ses && ses.fps != null) {
    $("yours").textContent = ses.mbps.toFixed(1) + " Mbit/s";
    $("yours2").textContent = ses.fps.toFixed(0) + " fps, " + (ses.rate === "crf" ? "ceiling " : "target ") + (ses.target_kbps / 1000) + " Mbit/s, " + ses.remaining + " s left";
  }
  if (sid && ses && ses.state === "finished") {
    finishedSeen = true;
    $("yours2").textContent = "end of the video, playing the last seconds";
  } else if (sid && ses && ses.state === "ended") {
    setIdle(finishedSeen ? "The video is over. Press Start to watch it again."
      : "Session ended. Press Start to run it again." + (ses.error ? " (" + ses.error + ")" : ""));
  }
}

async function pollStats() {
  try {
    const r = await api("/api/stats" + (sid ? "?s=" + sid : ""));
    if (r.ok) showStats(r.json);
  } catch (e) { /* transient */ }
}

function setIdle(text) {
  teardownPlayer();
  sid = null; gen++; finishedSeen = false;
  $("toggle").textContent = "Start";
  $("msg").textContent = text || "";
  $("yours").textContent = "-"; $("yours2").textContent = "";
}

function teardownPlayer() {
  if (hls) { hls.destroy(); hls = null; }
  const v = $("player");
  v.removeAttribute("src"); v.load();
}

async function stop(quiet) {
  const old = sid;
  if (!old) return;
  setIdle(quiet ? "" : "Stopped.");
  await api("/api/stop", {id: old}).catch(() => {});
}

async function waitPlaylist(url, myGen) {
  const t0 = Date.now();
  for (let i = 0; i < 60; i++) {
    if (myGen !== gen) return false;
    $("msg").textContent = "Starting the encoder on the card... " + Math.round((Date.now() - t0) / 1000) + " s";
    const r = await fetch(url, {cache: "no-store"}).catch(() => null);
    if (r && r.ok) return true;
    await new Promise((res) => setTimeout(res, 500));
  }
  return false;
}

// What the player knows when it stalls: bandwidth estimate and how far it
// is behind the live edge (small = waiting for the card, big = download).
function hlsInfo() {
  // dropped = frames the browser could not decode/render in time: a high
  // count means the viewer's device is the bottleneck, not the network.
  const q = $("player").getVideoPlaybackQuality ? $("player").getVideoPlaybackQuality() : null;
  const dropped = q ? " dropped=" + q.droppedVideoFrames + "/" + q.totalVideoFrames : "";
  if (!hls) return dropped.trim();
  const bw = hls.bandwidthEstimate ? (hls.bandwidthEstimate / 1e6).toFixed(1) : "?";
  const lat = Number.isFinite(hls.latency) ? hls.latency.toFixed(1) : "?";
  return "bw=" + bw + "Mbps behind=" + lat + "s" + dropped;
}

// Report player events to the server log: it cannot see buffering itself.
function report(type, ms, detail) {
  if (!sid) return;
  api("/api/event", {id: sid, type: type, ms: ms || 0, detail: detail || ""}).catch(() => {});
}

async function start() {
  if (sid) await stop(true);
  startedAt = Date.now(); startedPlaying = false; waitingSince = null;
  const myGen = ++gen;
  $("toggle").disabled = true;
  $("msg").textContent = "Starting the encoder on the card...";
  const r = await api("/api/start", {video: $("video").value,
    resolution: $("resolution").value, filter: $("filter").value,
    codec: $("codec").value, rate: $("rate").value,
    bitrate: $("bitrate").value === "auto" ? "auto" : parseInt($("bitrate").value, 10)});
  $("toggle").disabled = false;
  if (!r.ok) { setIdle(r.json.error || "Error " + r.status); return; }
  sid = r.json.id;
  $("toggle").textContent = "Stop";
  const url = "/hls/" + sid + "/index.m3u8";
  if (!(await waitPlaylist(url, myGen))) {
    if (myGen === gen) setIdle("The stream did not start.");
    return;
  }
  $("msg").textContent = "Loading the video, playback starts in a few seconds...";
  const v = $("player");
  if (window.Hls && Hls.isSupported()) {
    hls = new Hls({liveSyncDurationCount: 2});
    hls.on(Hls.Events.ERROR, (ev, data) => report("error", 0, data.details + (data.fatal ? " fatal" : "")));
    hls.loadSource(url);
    hls.attachMedia(v);
  } else {
    v.src = url;
  }
  v.play().catch(() => {});
}

function scheduleRestart() {
  if (!sid) return;
  clearTimeout(restartTimer);
  restartTimer = setTimeout(start, 400);
}

// Codec strings used only to ask the browser whether it can play the codec.
const MIME = {h264: 'avc1.64001f', h265: 'hvc1.1.6.L120.90', av1: 'av01.0.08M.08'};
function canPlay(codec) {
  const type = 'video/mp4; codecs="' + MIME[codec] + '"';
  if (window.Hls && Hls.isSupported()) return MediaSource.isTypeSupported(type);
  return $("player").canPlayType(type) !== "";
}

async function init() {
  const o = (await api("/api/videos")).json;
  fill($("video"), o.videos.map((v) => [v, v]));
  fill($("resolution"), o.resolutions.map((q) => [q, q]));
  $("resolution").value = o.resolutions.includes("720p") ? "720p" : o.resolutions[0];
  fill($("bitrate"), [["auto", "Auto"], ...o.bitrates.map((k) => [String(k), (k / 1000) + " Mbit/s"])]);
  const autoLabel = () => { $("bitrate").options[0].text = "Auto (" + (o.auto_kbps[$("resolution").value] / 1000) + " Mbit/s)"; };
  $("resolution").addEventListener("change", autoLabel);
  autoLabel();
  fill($("rate"), Object.entries(o.rates).map(([k, r]) => [k, r.label]));
  const showRate = () => { $("rdesc").firstChild.textContent = o.rates[$("rate").value].desc; };
  $("rate").addEventListener("change", showRate);
  showRate();
  fill($("filter"), Object.entries(o.filters).map(([k, f]) => [k, f.label]));
  const showDesc = () => { $("fdesc").firstChild.textContent = o.filters[$("filter").value].desc; };
  $("filter").addEventListener("change", showDesc);
  // HDR10 videos take only "No filter" and the tonemaps; SDR videos the rest.
  const fitFilters = () => {
    const kind = (o.hdr || []).includes($("video").value) ? "hdr" : "sdr";
    for (const opt of $("filter").options) opt.disabled = !o.filters[opt.value][kind];
    if ($("filter").selectedOptions[0].disabled) $("filter").value = "none";
    showDesc();
  };
  $("video").addEventListener("change", fitFilters);
  fitFilters();
  fill($("codec"), Object.entries(o.codecs));
  for (const opt of $("codec").options) {
    if (!canPlay(opt.value)) { opt.disabled = true; opt.text += " (not playable in this browser)"; }
  }
  for (const id of ["video", "resolution", "bitrate", "rate", "filter", "codec"]) $(id).addEventListener("change", scheduleRestart);
  $("toggle").addEventListener("click", () => (sid ? stop(false) : start()));
  window.addEventListener("pagehide", () => {
    if (sid) navigator.sendBeacon("/api/stop", new Blob([JSON.stringify({id: sid})], {type: "application/json"}));
  });
  const v = $("player");
  v.addEventListener("ended", () => { if (sid) stop(true).then(() => { $("msg").textContent = "The video is over. Press Start to watch it again."; }); });
  const host = o.host || {};
  const hostText = [host.system, host.cpu].filter(Boolean).join(" - ");
  if (hostText) $("host").firstChild.textContent = "Host: " + hostText;
  v.addEventListener("playing", () => {
    if (!sid) return;
    $("msg").textContent = "";
    if (!startedPlaying) { startedPlaying = true; report("startup", Date.now() - startedAt); }
    else if (waitingSince !== null) { report("stall", Date.now() - waitingSince, hlsInfo()); }
    waitingSince = null;
  });
  v.addEventListener("waiting", () => {
    if (!sid) return;
    $("msg").textContent = "Buffering...";
    if (startedPlaying && waitingSince === null) waitingSince = Date.now();
  });
  pollStats();
  statTimer = setInterval(pollStats, 2000);
}
init();
