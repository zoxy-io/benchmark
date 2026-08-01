// crosshair + tooltip on every chart (hover layer, dataviz interaction spec)
function fmt(v, kind) {
  if (kind === 'bytes') { const u=[['GiB',2**30],['MiB',2**20],['KiB',1024]];
    for (const [n,d] of u) if (v>=d) return (v/d).toFixed(1)+n; return v.toFixed(0)+'B'; }
  if (kind === 'pct') return (v*100).toFixed(2)+'%';
  // latency series carry SECONDS; render the tooltip in ms (or s past 1000ms)
  if (kind === 'ms') { const m=v*1000; return m>=1000 ? (m/1000).toFixed(2)+'s'
    : m>=10 ? m.toFixed(0)+'ms' : m.toFixed(1)+'ms'; }
  if (v>=1e6) return (v/1e6).toFixed(2)+'M';
  if (v>=1e3) return (v/1e3).toFixed(1)+'k';
  return v>=10 ? v.toFixed(0) : v.toFixed(2);
}
document.querySelectorAll('.hover-capture[data-chart]').forEach(cap => {
  const id = cap.dataset.chart;
  const data = JSON.parse(document.getElementById('data-'+id).textContent);
  const wrap = document.getElementById('wrap-'+id);
  const tip = document.getElementById('tip-'+id);
  const svg = cap.ownerSVGElement;
  const [W,H,ML,MR,MT,MB] = data.geom;
  const cross = document.createElementNS('http://www.w3.org/2000/svg','line');
  cross.setAttribute('class','axis'); cross.setAttribute('y1',MT); cross.setAttribute('y2',H-MB);
  cross.setAttribute('hidden',''); svg.insertBefore(cross, cap);
  cap.addEventListener('mousemove', e => {
    const r = svg.getBoundingClientRect();
    const px = (e.clientX - r.left) * (W / r.width);
    const x = (px - ML) / (W - ML - MR) * data.xmax;
    cross.removeAttribute('hidden');
    cross.setAttribute('x1', px); cross.setAttribute('x2', px);
    let rows = '';
    for (const s of data.series) {
      let best = null, bd = Infinity;
      for (const [sx, sy] of s.pts) { const d = Math.abs(sx-x); if (d<bd) { bd=d; best=sy; } }
      if (best === null) continue;
      rows += `<div class="trow"><span class="tname"><span class="swatch s-${s.name}"></span>${s.name}</span>` +
              `<span class="tval">${fmt(best, data.yfmt)}</span></div>`;
    }
    // What x IS depends on the chart, so the blob says rather than the script
    // assuming: offered load on the run report, a run on the nightly trend.
    // `labels` means x is an ordinal position — show the label (the run id),
    // not a formatted number with a unit that chart has no axis for.
    const xa = data.x || {name: 'offered', unit: 'req/s', labels: []};
    const head = (xa.labels && xa.labels.length)
      ? (xa.labels[Math.min(Math.max(Math.round(x), 0), xa.labels.length - 1)] || '')
      : `${fmt(x)} ${xa.unit}`.trim();
    tip.innerHTML = `<div class="trow"><span class="tname">${xa.name}</span><span class="tval">${head}</span></div>` + rows;
    tip.hidden = false;
    const wr = wrap.getBoundingClientRect();
    let lx = e.clientX - wr.left + 14;
    if (lx + tip.offsetWidth > wr.width - 8) lx = e.clientX - wr.left - tip.offsetWidth - 14;
    tip.style.left = lx + 'px';
    tip.style.top = Math.min(e.clientY - wr.top + 12, wr.height - tip.offsetHeight - 8) + 'px';
  });
  cap.addEventListener('mouseleave', () => { tip.hidden = true; cross.setAttribute('hidden',''); });
});

// Distribution-chart tooltip: same crosshair/tip mechanics as above, but a
// LOG x-scale (percentile, n = 1/(1-p)) and one series instead of several
// named ones, so it is not the same data shape or scale function — kept as
// its own small block rather than folded into the handler above.
document.querySelectorAll('.hover-capture[data-hist]').forEach(cap => {
  const id = cap.dataset.hist;
  const data = JSON.parse(document.getElementById('data-hist-'+id).textContent);
  const wrap = document.getElementById('wrap-hist-'+id);
  const tip = document.getElementById('tip-hist-'+id);
  const svg = cap.ownerSVGElement;
  const [W,H,ML,MR,MT,MB] = data.geom;
  // Mirrors svg.zig's histChart X.f(n, decades) exactly — n=1 sits at ML.
  const xOf = n => ML + (W-ML-MR) * Math.min(Math.max(Math.log10(Math.max(n,1)),0), data.decades) / data.decades;
  const cross = document.createElementNS('http://www.w3.org/2000/svg','line');
  cross.setAttribute('class','axis'); cross.setAttribute('y1',MT); cross.setAttribute('y2',H-MB);
  cross.setAttribute('hidden',''); svg.insertBefore(cross, cap);
  cap.addEventListener('mousemove', e => {
    const r = svg.getBoundingClientRect();
    const mx = (e.clientX - r.left) * (W / r.width);
    let best = null, bd = Infinity, bx = 0;
    for (const [n, ms] of data.pts) {
      const px = xOf(n);
      const d = Math.abs(px - mx);
      if (d < bd) { bd = d; best = [n, ms]; bx = px; }
    }
    if (!best) return;
    const [n, ms] = best;
    cross.removeAttribute('hidden');
    cross.setAttribute('x1', bx); cross.setAttribute('x2', bx);
    const pct = 100 * (1 - 1/n);
    const digits = pct < 99 ? 0 : pct < 99.9 ? 1 : pct < 99.99 ? 2 : 3;
    tip.innerHTML = `<div class="trow"><span class="tname">1 in ${n.toFixed(0)} (p${pct.toFixed(digits)})</span>` +
                     `<span class="tval">${fmt(ms/1000, 'ms')}</span></div>`;
    tip.hidden = false;
    const wr = wrap.getBoundingClientRect();
    let lx = e.clientX - wr.left + 14;
    if (lx + tip.offsetWidth > wr.width - 8) lx = e.clientX - wr.left - tip.offsetWidth - 14;
    tip.style.left = lx + 'px';
    tip.style.top = Math.min(e.clientY - wr.top + 12, wr.height - tip.offsetHeight - 8) + 'px';
  });
  cap.addEventListener('mouseleave', () => { tip.hidden = true; cross.setAttribute('hidden',''); });
});
