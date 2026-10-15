/* ==========================================================================
   Acme Corp demo site -- client-side availability probe.

   Every 2 seconds this page re-fetches a cache-busted copy of itself and times
   how long Apache took to answer. That is a genuine end-to-end request through
   the exact code path Slowloris starves, so the chart below drops off a cliff
   at the same moment the Grafana board does.

   No dependencies, no CDN: it works on a box with no internet access.
   ========================================================================== */
(function () {
  "use strict";

  var PROBE_INTERVAL_MS = 2000;
  var PROBE_TIMEOUT_MS  = 8000;
  var SLOW_MS           = 1000;
  var MAX_SAMPLES       = 90;

  var samples   = [];   // { ms: Number, state: "ok" | "slow" | "timeout" }
  var totalRuns = 0;
  var okRuns    = 0;
  var timeouts  = 0;

  var elBadge    = document.getElementById("badge");
  var elAvail    = document.getElementById("m-avail");
  var elLast     = document.getElementById("m-last");
  var elP95      = document.getElementById("m-p95");
  var elTimeouts = document.getElementById("m-timeouts");
  var elChart    = document.getElementById("chart");

  /* --- helpers ---------------------------------------------------------- */

  function classify(ms, ok) {
    if (!ok) { return "timeout"; }
    return ms > SLOW_MS ? "slow" : "ok";
  }

  function colourFor(state) {
    if (state === "timeout") { return "#f85149"; }
    if (state === "slow")    { return "#d29922"; }
    return "#3fb950";
  }

  function niceCeil(value) {
    if (value <= 0) { return 1; }
    var magnitude = Math.pow(10, Math.floor(Math.log(value) / Math.LN10));
    var scaled = value / magnitude;
    var nice;
    if (scaled <= 1)      { nice = 1; }
    else if (scaled <= 2) { nice = 2; }
    else if (scaled <= 5) { nice = 5; }
    else                  { nice = 10; }
    return nice * magnitude;
  }

  function formatMs(ms) {
    if (ms === null || ms === undefined) { return "\u2013"; }
    if (ms >= 1000) { return (ms / 1000).toFixed(1) + "s"; }
    return Math.round(ms) + "ms";
  }

  /* --- statistics ------------------------------------------------------- */

  function updateStats() {
    var last = samples[samples.length - 1];

    elAvail.textContent = totalRuns === 0
      ? "\u2013"
      : (100 * okRuns / totalRuns).toFixed(1) + "%";

    elLast.textContent = last ? formatMs(last.ms) : "\u2013";
    elTimeouts.textContent = String(timeouts);

    var good = [];
    for (var i = 0; i < samples.length; i++) {
      if (samples[i].state !== "timeout") { good.push(samples[i].ms); }
    }
    if (good.length) {
      good.sort(function (a, b) { return a - b; });
      var idx = Math.min(good.length - 1, Math.floor(good.length * 0.95));
      elP95.textContent = formatMs(good[idx]);
    } else {
      elP95.textContent = "\u2013";
    }

    if (!last) { return; }

    if (last.state === "timeout") {
      setBadge("badge-bad", "NO RESPONSE");
    } else if (last.state === "slow") {
      setBadge("badge-warn", "SLOW \u00b7 " + formatMs(last.ms));
    } else {
      setBadge("badge-ok", "HEALTHY \u00b7 " + formatMs(last.ms));
    }
  }

  function setBadge(cls, text) {
    elBadge.className = "badge " + cls;
    elBadge.textContent = text;
  }

  /* --- probe ------------------------------------------------------------ */

  function record(ms, ok) {
    var state = classify(ms, ok);

    totalRuns++;
    if (ok) { okRuns++; } else { timeouts++; }

    samples.push({ ms: ms, state: state });
    while (samples.length > MAX_SAMPLES) { samples.shift(); }

    updateStats();
    drawChart();
  }

  function probe() {
    var started = window.performance ? performance.now() : Date.now();
    var controller = typeof AbortController === "function" ? new AbortController() : null;
    var timer = null;

    if (controller) {
      timer = setTimeout(function () { controller.abort(); }, PROBE_TIMEOUT_MS);
    }

    var url = "/index.html?probe=" + Date.now();

    function finish(ok) {
      if (timer) { clearTimeout(timer); }
      var now = window.performance ? performance.now() : Date.now();
      record(Math.round(now - started), ok);
    }

    fetch(url, {
      cache: "no-store",
      signal: controller ? controller.signal : undefined
    }).then(function (response) {
      return response.text().then(function (body) {
        finish(response.ok && body.length > 0);
      });
    }).catch(function () {
      finish(false);
    });
  }

  /* --- chart ------------------------------------------------------------ */

  function drawChart() {
    if (!elChart) { return; }

    var dpr  = window.devicePixelRatio || 1;
    var cssW = elChart.clientWidth || 480;
    var cssH = elChart.clientHeight || 170;
    var pxW  = Math.round(cssW * dpr);
    var pxH  = Math.round(cssH * dpr);

    if (elChart.width !== pxW || elChart.height !== pxH) {
      elChart.width  = pxW;
      elChart.height = pxH;
    }

    var ctx = elChart.getContext("2d");
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, cssW, cssH);

    var padL = 46, padR = 8, padT = 10, padB = 16;
    var plotW = Math.max(1, cssW - padL - padR);
    var plotH = Math.max(1, cssH - padT - padB);

    var peak = 0;
    for (var i = 0; i < samples.length; i++) {
      if (samples[i].ms > peak) { peak = samples[i].ms; }
    }
    var maxMs = niceCeil(Math.max(500, peak));

    function xFor(index) {
      var n = Math.max(1, MAX_SAMPLES - 1);
      return padL + (index / n) * plotW;
    }
    function yFor(ms) {
      return padT + plotH - (Math.min(ms, maxMs) / maxMs) * plotH;
    }

    /* grid + y labels */
    ctx.font = "10px ui-monospace, Menlo, Consolas, monospace";
    ctx.textAlign = "right";
    ctx.textBaseline = "middle";

    for (var g = 0; g <= 4; g++) {
      var value = (maxMs / 4) * g;
      var y = yFor(value);
      ctx.strokeStyle = "rgba(139,148,158,0.16)";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(padL, y + 0.5);
      ctx.lineTo(padL + plotW, y + 0.5);
      ctx.stroke();

      ctx.fillStyle = "rgba(139,148,158,0.85)";
      ctx.fillText(formatMs(value), padL - 6, y);
    }

    /* the 1 second "this is slow" reference line */
    if (maxMs > SLOW_MS) {
      ctx.save();
      ctx.setLineDash([4, 4]);
      ctx.strokeStyle = "rgba(210,153,34,0.5)";
      ctx.beginPath();
      ctx.moveTo(padL, yFor(SLOW_MS));
      ctx.lineTo(padL + plotW, yFor(SLOW_MS));
      ctx.stroke();
      ctx.restore();
    }

    if (samples.length === 0) {
      ctx.fillStyle = "rgba(139,148,158,0.7)";
      ctx.textAlign = "center";
      ctx.fillText("waiting for the first probe\u2026", padL + plotW / 2, padT + plotH / 2);
      return;
    }

    /* offset so the newest sample sits at the right edge */
    var offset = MAX_SAMPLES - samples.length;

    /* area fill */
    var gradient = ctx.createLinearGradient(0, padT, 0, padT + plotH);
    gradient.addColorStop(0, "rgba(88,166,255,0.28)");
    gradient.addColorStop(1, "rgba(88,166,255,0.02)");

    ctx.beginPath();
    ctx.moveTo(xFor(offset), padT + plotH);
    for (var k = 0; k < samples.length; k++) {
      ctx.lineTo(xFor(offset + k), yFor(samples[k].ms));
    }
    ctx.lineTo(xFor(offset + samples.length - 1), padT + plotH);
    ctx.closePath();
    ctx.fillStyle = gradient;
    ctx.fill();

    /* line */
    ctx.beginPath();
    for (var j = 0; j < samples.length; j++) {
      var px = xFor(offset + j);
      var py = yFor(samples[j].ms);
      if (j === 0) { ctx.moveTo(px, py); } else { ctx.lineTo(px, py); }
    }
    ctx.strokeStyle = "#58a6ff";
    ctx.lineWidth = 1.75;
    ctx.lineJoin = "round";
    ctx.stroke();

    /* sample dots */
    for (var d = 0; d < samples.length; d++) {
      var dotX = xFor(offset + d);
      var dotY = yFor(samples[d].ms);
      ctx.beginPath();
      ctx.arc(dotX, dotY, samples[d].state === "ok" ? 1.8 : 3.2, 0, Math.PI * 2);
      ctx.fillStyle = colourFor(samples[d].state);
      ctx.fill();
    }
  }

  /* --- boot ------------------------------------------------------------- */

  window.addEventListener("resize", drawChart);

  probe();
  setInterval(probe, PROBE_INTERVAL_MS);
  drawChart();
})();
