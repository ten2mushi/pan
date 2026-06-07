// examples/animation/layouts.js — standalone, importable visualization modes.
//
// Each "mode" is a self-contained recipe for turning a stream of analysed audio
// points into a 3-D scene: WHERE each point sits (`place`), HOW the constellation
// edges are drawn (`knn`), and HOW the camera moves to frame it (`camera`). The
// viewer (viewer.html) owns the feature decoding, spectral-peak extraction, edge
// meshing and GLSL drawing; it imports this module and dispatches on the chosen
// mode. Adding a mode is adding one entry to MODES — nothing else changes.
//
// This split exists so the *aesthetic/mathematical* design lives in one small,
// reusable file, decoupled from the WebGL plumbing. Import it anywhere:
//     import { MODES, modeNames, mergedCam } from "./layouts.js";
//
// ---------------------------------------------------------------------------
// The per-point context `p` the viewer passes to place():
//   p.lf      log-frequency of this point, normalised to [0,1] over the track's
//             detected [f_lo, f_hi]   (PITCH)
//   p.pAmp    this point's power, normalised to [0,1]            (LOUDNESS)
//   p.cen     frame spectral centroid, normalised [0,1]          (BRIGHTNESS)
//   p.flux    frame spectral flux, normalised [0,1]              (ONSET/NOVELTY)
//   p.rol     frame spectral rolloff, normalised [0,1]
//   p.az      cumulative golden-angle azimuth + centroid drift   (SPIRAL ANGLE)
//   p.t       emission time of this point (seconds)
//   p.i       frame index
//   p.peakHz  this point's actual frequency in Hz
//
// The whole-track context `ctx`:
//   ctx.octLo/octHi   log2(f_lo)/log2(f_hi)  (octave bounds)
//   ctx.octMid        midpoint octave
//   ctx.octSpan       octHi-octLo (≥ 1e-3)
//   ctx.totalT, ctx.fps, ctx.nFrames
//   ctx.cam           merged camera params {speed,radius,polar1,polar2}
//   ctx.center,ctx.diag   bounding-box centre [x,y,z] and diagonal length,
//                          filled by the viewer AFTER placement (for auto-fit)
//
// place(p, ctx) -> [x, y, z]
// camera(tt, ctx) -> { pos:[x,y,z], look:[x,y,z] }
// ---------------------------------------------------------------------------

export const PHI = (1 + Math.sqrt(5)) / 2; // golden ratio ≈ 1.618
const TAU = Math.PI * 2;

// --- shared cameras --------------------------------------------------------

// A quasi-periodic spherical Lissajous orbit: azimuth advances linearly while the
// polar angle wobbles on two golden-ratio-incommensurate frequencies, so the
// camera visits equatorial, near-overhead and near-underside views and never
// exactly repeats. polar1/2 = 0 collapses to a flat equatorial orbit.
function sphericalLissajous(tt, ctx, lookAt = [0, 0, 0]) {
  const c = ctx.cam;
  const theta = tt * c.speed;
  const phi = Math.PI / 2 +
    c.polar1 * Math.sin(tt * c.speed / PHI) +
    c.polar2 * Math.sin(tt * c.speed * PHI);
  const sp = Math.sin(phi);
  return {
    pos: [
      lookAt[0] + c.radius * sp * Math.cos(theta),
      lookAt[1] + c.radius * Math.cos(phi),
      lookAt[2] + c.radius * sp * Math.sin(theta),
    ],
    look: lookAt,
  };
}

// Auto-fitting orbit: frames the WHOLE cloud by deriving the orbital radius from
// the bounding-box diagonal and looking at its centre. Fixes the "pure feature
// space scenes get clipped / never seen in full" problem — the entire feature
// cube is always in frame, and a slow polar sweep reveals every face over time.
function autoFitOrbit(tt, ctx) {
  const c = ctx.cam;
  const center = ctx.center || [0, 0, 0];
  const R = Math.max(ctx.diag || 16, 1) * 0.62 * (c.radius_scale || 1);
  const theta = tt * c.speed;
  // Slow polar sweep between near-top and near-bottom (never poles → no gimbal).
  const phi = Math.PI / 2 + 0.85 * Math.sin(tt * c.speed / PHI);
  const sp = Math.sin(phi);
  return {
    pos: [
      center[0] + R * sp * Math.cos(theta),
      center[1] + R * Math.cos(phi),
      center[2] + R * sp * Math.sin(theta),
    ],
    look: center,
  };
}

// --- mode table ------------------------------------------------------------

export const MODES = {
  // ---------------------------------------------------------------------
  // PURE FEATURE SPACE (information). Axes ARE the features: X brightness,
  // Y pitch, Z loudness. No time folding — a static scatter the camera tours.
  // ---------------------------------------------------------------------
  "feature-space": {
    label: "pure feature space",
    knn: "spatial",
    defaults: { cam: { speed: 0.10, radius: 11, polar1: 0.9, polar2: 0.25, radius_scale: 1.05 }, edge_life: 0, hue_shift: 0 },
    place(p) {
      return [(p.cen - 0.5) * 13.0, (p.lf - 0.5) * 13.0, (p.pAmp - 0.5) * 13.0];
    },
    camera: autoFitOrbit,
  },

  // ---------------------------------------------------------------------
  // CYLINDER (aesthetic) — audio-driven phyllotaxis where the azimuth advances by
  // the golden angle PER FRAME (+ cumulative centroid-drift twist), radius is pushed
  // out by loudness + onset flux, and height = pitch. Because the angle is driven by
  // the frame index (time), the cloud grows as an emergent CYLINDER/coil over time:
  // the geometry reads as a clear column. The global spatial kNN weaves a crystalline
  // web over it. (Distinct from `constellation`, which embeds by feature into an
  // organic star cloud with no dominant central form.)
  // ---------------------------------------------------------------------
  "cylinder": {
    label: "cylinder (phyllotaxis coil + global kNN)",
    knn: "spatial",
    defaults: { cam: { speed: 0.09, radius: 11, polar1: 0.9, polar2: 0.25 }, edge_life: 30, hue_shift: 0 },
    place(p) {
      const r = 1 + 4.6 * p.pAmp + 2.2 * p.flux;
      return [r * Math.cos(p.az), (p.lf - 0.5) * 8 + 0.5 * Math.sin(p.az * 0.5), r * Math.sin(p.az)];
    },
    camera: (tt, ctx) => sphericalLissajous(tt, ctx),
  },

  // ---------------------------------------------------------------------
  // CONSTELLATION (aesthetic) — an acoustic SIMILARITY MAP, not a timeline. Every
  // point is embedded purely by what it SOUNDS like (pitch, brightness, loudness,
  // onset, rolloff) and NEVER by when it happens, so a loud high note at 0:10 and
  // a loud high note at 4:00 land in the same region of space and the global
  // spatial kNN weaves them together — an organic crystalline star cloud.
  //
  // Geometry (why it is a rounded volumetric scatter and not a primitive):
  //  • DIRECTION on the unit sphere comes from two timbral features, mapped so
  //    similar timbres point the same way. We use an equal-area sphere param:
  //    u = brightness drives cos(polar) ∈[-1,1] (equal-area in latitude → no
  //    pole crowding), and the azimuth is the pitch CLASS (fractional octave),
  //    so octave-related pitches share a longitude (harmonic clustering) while
  //    spanning latitudes by brightness. Direction is a pure feature embedding —
  //    no time, no frame index, no p.az.
  //  • RADIUS is driven by loudness+onset (energy), so along every direction the
  //    points SPREAD radially and FILL a ball instead of sitting on a hollow
  //    shell. Quiet ambience sits near the core; loud transients fly to the rim.
  //  • A small rolloff term nudges points along Y so the embedding is not cleanly
  //    separable into (direction × radius), which would otherwise read as radial
  //    fans; this curves the cloud organically.
  //  • DETERMINISTIC jitter (a hash of the frame index, reproducible, no RNG) of
  //    amplitude ~0.5 breaks any residual lattice/banding from quantised features
  //    into natural-looking scatter. It is small relative to the feature spread
  //    (radius ~3..12), so acoustically-similar points stay clustered.
  // The result has NO dominant central form: it is a fuzzy, clustered ball of
  // stars whose lobes ARE the recurring sounds of the track.
  // ---------------------------------------------------------------------
  "constellation": {
    label: "constellation (acoustic similarity star cloud)",
    knn: "spatial",
    defaults: { cam: { speed: 0.06, radius: 13, polar1: 0.85, polar2: 0.22, radius_scale: 1.08 }, edge_life: 30, hue_shift: 0 },
    place(p, ctx) {
      // --- direction on the sphere from TIMBRE (no time) ---------------
      // Equal-area latitude: brightness → cos(polar) ∈ [-1, 1]. Bright points
      // gather toward one pole, dark toward the other, mids around the equator,
      // and equal-area mapping keeps the angular density uniform (no pole pinch).
      const cphi = (p.cen - 0.5) * 2.0;            // cos(polar) ∈ [-1,1]
      const sphi = Math.sqrt(Math.max(0, 1 - cphi * cphi));
      // Azimuth = pitch class (fractional octave): octave-related pitches share a
      // longitude so harmonics/recurrences fall on the same meridian and cluster.
      const lg = Math.log2(Math.max(p.peakHz, 1));
      const pc = lg - Math.floor(lg);             // pitch class ∈ [0,1)
      const az = pc * TAU;
      const dir = [sphi * Math.cos(az), cphi, sphi * Math.sin(az)];
      // --- radius from ENERGY: fills the ball, no hollow shell --------
      // Energy = loudness with onset boost. Quiet → near core, loud → rim.
      const energy = 0.55 * p.pAmp + 0.45 * p.flux;
      const r = 3.0 + 9.0 * energy;
      // --- deterministic per-point jitter (reproducible, no Math.random) ---
      // A cheap integer hash of the frame index gives three uncorrelated values
      // in [-0.5,0.5]; scaled small so clusters survive but lattice/banding from
      // quantised features dissolves into organic scatter.
      const h = (n) => {
        let x = (p.i * 2654435761 + n * 40503) >>> 0;
        x ^= x >>> 15; x = (x * 2246822519) >>> 0;
        x ^= x >>> 13; x = (x * 3266489917) >>> 0;
        x ^= x >>> 16;
        return (x / 4294967296) - 0.5;             // [-0.5, 0.5)
      };
      const J = 0.9;                               // jitter amplitude (< feature spread)
      // --- non-separable rolloff nudge so it isn't clean radial fans ---
      const yNudge = (p.rol - 0.5) * 2.6;
      return [
        r * dir[0] + J * h(1),
        r * dir[1] + yNudge + J * h(2),
        r * dir[2] + J * h(3),
      ];
    },
    camera: autoFitOrbit,
  },

  // ---------------------------------------------------------------------
  // TIMELINE (information) — unroll time along −Z into a Cartesian timbre space:
  // X centroid (texture), Y pitch, Z time. The camera flies down the timeline
  // alongside the current clusters. Edges are spatial within a short time window
  // (spectro-temporal) so the mesh threads local moments, not the whole song.
  // ---------------------------------------------------------------------
  "timeline": {
    label: "timeline (Cartesian timbre space)",
    knn: "spectro-temporal",
    knn_window: 5,
    defaults: { cam: { speed: 0.5, radius: 11, polar1: 0, polar2: 0 }, edge_life: 12, hue_shift: 0 },
    place(p) {
      return [(p.cen - 0.5) * 16.0, (p.lf - 0.5) * 8, -p.t * 2.0];
    },
    camera(tt, ctx) {
      const z = -tt * 2.0;
      const r = ctx.cam.radius;
      return {
        pos: [r * 0.3 * Math.sin(tt * 0.5), r * 0.3 * Math.cos(tt * 0.3), z + r],
        look: [0, 0, z],
      };
    },
  },

  // ---------------------------------------------------------------------
  // HELIX (aesthetic, NEW) — the Shepard pitch helix. The angle around the
  // vertical axis is the PITCH CLASS (the fractional part of log2 f, i.e. position
  // within the octave), so one full turn = one octave; the height is the (signed)
  // octave number. Octave-related partials therefore stack in a vertical column,
  // and a harmonic series (f, 2f, 3f, 4f, …) traces a logarithmic climb that
  // re-aligns every octave — ideal for overtone / polyphonic singing where the
  // harmonics are the whole point. Radius grows with loudness.
  // ---------------------------------------------------------------------
  "helix": {
    label: "pitch helix (Shepard)",
    knn: "spatial",
    defaults: { cam: { speed: 0.08, radius: 13, polar1: 0, polar2: 0 }, edge_life: 22, hue_shift: 0 },
    place(p, ctx) {
      const lg = Math.log2(Math.max(p.peakHz, 1));
      const pc = lg - Math.floor(lg);            // pitch class ∈ [0,1)
      const ang = pc * TAU;
      const r = 3.0 + 3.0 * p.pAmp;
      const y = (lg - ctx.octMid) * 2.2;         // octave height, centred
      return [r * Math.cos(ang), y, r * Math.sin(ang)];
    },
    camera(tt, ctx) {
      const c = ctx.cam;
      const theta = tt * c.speed;
      // Gentle vertical bob to reveal the full column top-to-bottom over time.
      const y = (ctx.octSpan) * 1.1 * Math.sin(tt * c.speed / PHI);
      return {
        pos: [c.radius * Math.cos(theta), y, c.radius * Math.sin(theta)],
        look: [0, 0, 0],
      };
    },
  },

  // ---------------------------------------------------------------------
  // TORUS (aesthetic, NEW) — the chroma torus. Pitch class wraps the TUBE (minor
  // circle) and the octave wraps the RING (major circle), so the full pitch
  // surface is a torus and a rising glissando winds around it like thread on a
  // spool. Integer harmonics, being log-spaced, lay down an elegant interleaved
  // winding. Radius of the tube breathes with loudness.
  // ---------------------------------------------------------------------
  "torus": {
    label: "chroma torus",
    knn: "spatial",
    defaults: { cam: { speed: 0.10, radius: 20, polar1: 0.7, polar2: 0.2 }, edge_life: 26, hue_shift: 0 },
    place(p, ctx) {
      const lg = Math.log2(Math.max(p.peakHz, 1));
      const pc = lg - Math.floor(lg);
      const minor = pc * TAU;
      const major = ((lg - ctx.octLo) / ctx.octSpan) * TAU;
      const R = 7.5;                              // major (ring) radius
      const r = 2.0 + 1.6 * p.pAmp;              // minor (tube) radius
      const rr = R + r * Math.cos(minor);
      return [rr * Math.cos(major), r * Math.sin(minor), rr * Math.sin(major)];
    },
    camera: (tt, ctx) => sphericalLissajous(tt, ctx),
  },

  // ---------------------------------------------------------------------
  // STEREO FIELD (information, stereo-only) — a literal moving image of the
  // stereo spectrum. X is each peak's PAN ((√L−√R)/(√L+√R), so left ↔ right), Y is
  // pitch, Z is time. Every harmonic is drawn where it actually sits in the stereo
  // field, so for a real stereo recording (e.g. overtone singing in a room) you
  // watch the partials spread and move across the image over time. Falls back to a
  // centred ribbon on mono input (pan ≡ 0). Edges thread local moments in time.
  // ---------------------------------------------------------------------
  "stereo-field": {
    label: "stereo field (per-peak panning)",
    knn: "spectro-temporal",
    knn_window: 4,
    defaults: { cam: { speed: 0.4, radius: 14, polar1: 0, polar2: 0 }, edge_life: 10, hue_shift: 0 },
    place(p) {
      return [(p.pan || 0) * 11.0, (p.lf - 0.5) * 8, -p.t * 2.0];
    },
    camera(tt, ctx) {
      const z = -tt * 2.0, r = ctx.cam.radius;
      return { pos: [r * 0.18 * Math.sin(tt * 0.5), r * 0.22 * Math.cos(tt * 0.31), z + r], look: [0, 0, z] };
    },
  },

  // ---------------------------------------------------------------------
  // HARMONIC COMB / overtone-detachment (information, NEW). Makes the harmonic
  // series visible. For each frame the viewer estimates the fundamental f0 (its
  // harmonic-comb branch — see viewer.html), then places every detected partial on
  // a vertical LADDER by harmonic number n (Y = (n−1)·spacing), slides the whole
  // ladder horizontally by the sung pitch (X = (log2 f0 − octMid)·k), and unrolls
  // time into depth (Z = −t·v). Ladder rungs (consecutive n within a frame) are the
  // comb teeth. When a reinforced overtone's power exceeds the fundamental's it
  // "detaches" — nudged up/out, larger and brighter — so you literally watch the
  // overtone ignite. The geometry is computed in the viewer's harmonic branch; this
  // place()/camera/knn entry carries the mode's defaults and a sane fallback.
  // ---------------------------------------------------------------------
  "harmonic": {
    label: "harmonic comb (overtone detachment)",
    knn: "harmonic",
    defaults: { cam: { speed: 0.05, radius: 16, polar1: 0.35, polar2: 0.12, radius_scale: 1.1 }, edge_life: 24, hue_shift: 0 },
    // Fallback only (used if no full_spectrum is present so the viewer's dedicated
    // harmonic branch can't run): a plain pitch×time ribbon.
    place(p) {
      return [(p.lf - 0.5) * 10, (p.pAmp) * 6, -p.t * 2.0];
    },
    // Flythrough: glide along the −Z time axis a fixed distance ahead of the current
    // ladder, looking side-on so the vertical comb (harmonic rungs) and the pitch
    // slide (X) stay legible. autoFitOrbit can't be used — the time axis is far longer
    // than the ladder, so it would shrink each frame's comb to a speck.
    camera(tt, ctx) {
      const v = ctx.harmTimev || 2;
      const z = -tt * v;
      const midY = ctx.harmLadderMidY || 6;
      const r = ctx.cam.radius;
      return {
        pos: [r * 0.85 + r * 0.12 * Math.sin(tt * (ctx.cam.speed || 0.05)),
              midY + r * 0.28, z + r * 0.8],
        look: [0, midY, z],
      };
    },
  },

  // ---------------------------------------------------------------------
  // PCA TIMBRAL FINGERPRINT (information, NEW). The cloud's SHAPE is this track's
  // own principal timbral variation: render.py builds a per-frame timbre vector
  // (centroid/rolloff/flux/rms + flatness + spectral contrast + MFCCs), z-scores it,
  // runs PCA (SVD) and projects to the top-3 components (`<base>.pca.f32`). Each
  // frame becomes one point in that 3-D principal-timbre space; all peaks of a frame
  // share the frame's timbral coordinate (intended clustering) and only fan slightly
  // by pitch so they don't perfectly coincide. Acoustically similar moments — even
  // far apart in time — land together, so the silhouette is a fingerprint unique to
  // the track. Needs `ctx.pca` (loaded by the viewer when mode==="pca").
  // ---------------------------------------------------------------------
  "pca": {
    label: "PCA timbral fingerprint",
    knn: "spatial",
    defaults: { cam: { speed: 0.07, radius: 13, polar1: 0.85, polar2: 0.22, radius_scale: 1.1 }, edge_life: 30, hue_shift: 0 },
    place(p, ctx) {
      const a = ctx.pca;
      if (!a) return [(p.cen - 0.5) * 13.0, (p.lf - 0.5) * 13.0, (p.pAmp - 0.5) * 13.0];
      const i = p.i, s = (ctx.pcaSpread ?? 0.6);
      // PCA coordinate is per-FRAME; fan a frame's peaks slightly by pitch/energy so
      // simultaneous partials are visible instead of stacking on one point.
      return [
        a[i * 3]     + (p.lf - 0.5) * s,
        a[i * 3 + 1] + (p.pAmp - 0.5) * s * 0.5,
        a[i * 3 + 2] + (p.flux - 0.5) * s * 0.5,
      ];
    },
    camera: autoFitOrbit,
  },
};

export function modeNames() {
  return Object.keys(MODES);
}

// Merge user-supplied (URL) camera params over a mode's defaults. `urlCam` values
// are numbers or null/undefined (absent → fall back to the mode default).
export function mergedCam(mode, urlCam) {
  const base = (MODES[mode] && MODES[mode].defaults && MODES[mode].defaults.cam) || {};
  const out = { ...base };
  for (const k of Object.keys(urlCam || {})) {
    if (urlCam[k] !== null && urlCam[k] !== undefined && !Number.isNaN(urlCam[k])) out[k] = urlCam[k];
  }
  // sane fallbacks
  out.speed = out.speed ?? 0.10;
  out.radius = out.radius ?? 11;
  out.polar1 = out.polar1 ?? 0;
  out.polar2 = out.polar2 ?? 0;
  return out;
}
