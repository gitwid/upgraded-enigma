/*
 * PDA — Non-invasive capture
 * ---------------------------
 * Passive DOM observation. This does NOT scrape, crawl, automate scrolling,
 * spoof requests, or touch anything you are not already looking at. It reads
 * the posts currently rendered in your own logged-in browser session and
 * transcribes them into the archive schema. You remain the human in the loop.
 *
 * Two ways to run it:
 *   1) Paste this whole file into the browser DevTools console on a page that
 *      is showing Instagram posts.
 *   2) Make a bookmarklet: minify and prefix with `javascript:` (see README).
 *
 * It exposes window.PDA:
 *   PDA.capture()  -> transcribe every post visible in the DOM right now
 *   PDA.count()    -> how many entries are held in local storage
 *   PDA.export()   -> download the archive as archive.json
 *   PDA.clear()    -> wipe local storage (the held archive), with confirm
 *
 * Selectors are deliberately defensive because platform markup drifts. If a
 * field stops populating, update SEL below — that is expected maintenance, not
 * a failure of the approach.
 */
(function () {
  "use strict";

  var STORE_KEY = "pda:archive";

  var SEL = {
    post: "article",
    time: "time",
    img: "img[srcset], img[src]",
    video: "video",
  };

  function loadStore() {
    try {
      return JSON.parse(localStorage.getItem(STORE_KEY)) || {};
    } catch (e) {
      return {};
    }
  }

  function saveStore(map) {
    localStorage.setItem(STORE_KEY, JSON.stringify(map));
  }

  function shortcodeFromHref(href) {
    if (!href) return null;
    var m = href.match(/\/(p|reel|tv)\/([^/?#]+)/);
    return m ? m[2] : null;
  }

  function extractHashtags(text) {
    if (!text) return [];
    var out = [];
    var re = /#([\p{L}\p{N}_]+)/gu;
    var m;
    while ((m = re.exec(text))) out.push(m[1].toLowerCase());
    return out;
  }

  function bestImageSrc(img) {
    // Prefer the largest candidate in srcset, else src.
    if (img.srcset) {
      var parts = img.srcset.split(",").map(function (s) {
        var bits = s.trim().split(/\s+/);
        return { url: bits[0], w: parseInt(bits[1], 10) || 0 };
      });
      parts.sort(function (a, b) { return b.w - a.w; });
      if (parts.length && parts[0].url) return parts[0].url;
    }
    return img.getAttribute("src") || "";
  }

  function transcribe(article) {
    var permalink = null;
    var posted_at = null;

    var timeEl = article.querySelector(SEL.time);
    if (timeEl) {
      posted_at = timeEl.getAttribute("datetime") || null;
      var a = timeEl.closest("a");
      if (a && a.href) permalink = a.href;
    }
    if (!permalink) {
      var anchors = article.querySelectorAll('a[href*="/p/"], a[href*="/reel/"], a[href*="/tv/"]');
      if (anchors.length) permalink = anchors[0].href;
    }

    var shortcode = shortcodeFromHref(permalink);

    var media = [];
    article.querySelectorAll(SEL.video).forEach(function (v) {
      media.push({
        type: "video",
        src: v.currentSrc || v.getAttribute("src") || "",
        poster: v.getAttribute("poster") || "",
        alt: v.getAttribute("aria-label") || "",
      });
    });
    article.querySelectorAll(SEL.img).forEach(function (img) {
      var alt = img.getAttribute("alt") || "";
      // Skip avatars / UI chrome: they carry no alt or trivial alt.
      var src = bestImageSrc(img);
      if (!src) return;
      // Heuristic: real content images tend to carry descriptive alt text.
      if (alt.length < 3 && img.width < 150) return;
      media.push({ type: "image", src: src, alt: alt });
    });

    // Caption: the richest alt text is often the platform's own description;
    // combine it with any visible caption node text as a fallback.
    var captionParts = [];
    var h1 = article.querySelector("h1");
    if (h1 && h1.textContent) captionParts.push(h1.textContent.trim());
    var firstAlt = media.map(function (m) { return m.alt; }).filter(Boolean)[0];
    if (firstAlt && captionParts.indexOf(firstAlt) === -1) captionParts.push(firstAlt);
    var caption = captionParts.join("\n").trim();

    var author = null;
    var authorLink = article.querySelector('header a[href^="/"]');
    if (authorLink) author = authorLink.getAttribute("href").replace(/\//g, "") || null;

    var id = shortcode || ("cap-" + Math.random().toString(36).slice(2, 10));

    return {
      id: id,
      source: "instagram",
      permalink: permalink || undefined,
      author: author || undefined,
      captured_at: new Date().toISOString(),
      posted_at: posted_at || undefined,
      media: media,
      caption: caption || undefined,
      hashtags: extractHashtags(caption),
      tags: [],
    };
  }

  var PDA = {
    capture: function () {
      var map = loadStore();
      var before = Object.keys(map).length;
      var articles = document.querySelectorAll(SEL.post);
      articles.forEach(function (article) {
        var entry = transcribe(article);
        if (!entry.media.length) return; // nothing worth keeping
        // Idempotent by id: re-capture refreshes volatile URLs but preserves tags/notes.
        var prev = map[entry.id];
        if (prev) {
          entry.tags = prev.tags && prev.tags.length ? prev.tags : entry.tags;
          entry.notes = prev.notes;
          entry.captured_at = prev.captured_at;
        }
        map[entry.id] = entry;
      });
      saveStore(map);
      var added = Object.keys(map).length - before;
      console.log("[PDA] captured " + articles.length + " article(s); +" + added + " new; " + Object.keys(map).length + " total held.");
      return added;
    },

    count: function () {
      return Object.keys(loadStore()).length;
    },

    export: function () {
      var map = loadStore();
      var arr = Object.keys(map).map(function (k) { return map[k]; });
      arr.sort(function (a, b) {
        return (b.posted_at || b.captured_at || "").localeCompare(a.posted_at || a.captured_at || "");
      });
      var blob = new Blob([JSON.stringify(arr, null, 2)], { type: "application/json" });
      var url = URL.createObjectURL(blob);
      var a = document.createElement("a");
      a.href = url;
      a.download = "archive.json";
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      console.log("[PDA] exported " + arr.length + " entries to archive.json");
      return arr.length;
    },

    clear: function () {
      if (typeof window !== "undefined" && window.confirm && !window.confirm("Wipe the held archive (" + PDA.count() + " entries)?")) return;
      localStorage.removeItem(STORE_KEY);
      console.log("[PDA] cleared.");
    },
  };

  if (typeof window !== "undefined") window.PDA = PDA;

  console.log("[PDA] ready. PDA.capture() to transcribe visible posts, PDA.export() to download, PDA.count() = " + PDA.count() + " held.");
})();
