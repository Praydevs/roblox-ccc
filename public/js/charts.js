import { esc, nf, money } from './ui.js';

const W = () => 760;
const H = 210;
const PAD = { top: 14, right: 10, bottom: 22, left: 34 };

const smooth = (pts) => {
  if (pts.length < 2) return '';
  let d = `M ${pts[0][0]} ${pts[0][1]}`;
  for (let i = 1; i < pts.length; i += 1) {
    const [x0, y0] = pts[i - 1];
    const [x1, y1] = pts[i];
    const mx = (x0 + x1) / 2;
    d += ` C ${mx} ${y0}, ${mx} ${y1}, ${x1} ${y1}`;
  }
  return d;
};

export function mountArea(host, series, { valueKey = 'hits' } = {}) {
  const draw = () => {
    const width = Math.max(320, host.clientWidth || W());
    const height = H;
    const max = Math.max(1, ...series.map((s) => s[valueKey]));
    const innerW = width - PAD.left - PAD.right;
    const innerH = height - PAD.top - PAD.bottom;
    const stepX = series.length > 1 ? innerW / (series.length - 1) : innerW;

    const pts = series.map((s, i) => [PAD.left + i * stepX, PAD.top + innerH - (s[valueKey] / max) * innerH]);
    const line = smooth(pts);
    const area = `${line} L ${PAD.left + (series.length - 1) * stepX} ${PAD.top + innerH} L ${PAD.left} ${PAD.top + innerH} Z`;

    const ticks = 4;
    const grid = Array.from({ length: ticks + 1 }, (_, i) => {
      const y = PAD.top + (innerH / ticks) * i;
      const val = Math.round(max - (max / ticks) * i);
      return `<line x1="${PAD.left}" y1="${y}" x2="${width - PAD.right}" y2="${y}"/>
        <text x="${PAD.left - 7}" y="${y + 3}" text-anchor="end">${nf(val)}</text>`;
    }).join('');

    const labelEvery = Math.max(1, Math.ceil(series.length / (width < 520 ? 5 : 9)));
    const labels = series.map((s, i) => (i % labelEvery === 0
      ? `<text x="${PAD.left + i * stepX}" y="${height - 6}" text-anchor="middle">${esc(s.label)}</text>`
      : '')).join('');

    host.innerHTML = `
      <div class="chart-wrap" style="height:${height}px">
        <svg class="chart-svg" viewBox="0 0 ${width} ${height}" preserveAspectRatio="none" role="img">
          <defs>
            <linearGradient id="areaFill" x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stop-color="#e63946" stop-opacity="0.34"/>
              <stop offset="100%" stop-color="#e63946" stop-opacity="0"/>
            </linearGradient>
          </defs>
          <g class="chart-grid">${grid}</g>
          <path d="${area}" fill="url(#areaFill)"/>
          <path class="chart-line" d="${line}"/>
          ${pts.map(([x, y], i) => `<circle class="chart-dot" cx="${x}" cy="${y}" r="${i === pts.length - 1 ? 3.2 : 0}" opacity="${i === pts.length - 1 ? 1 : 0}"/>`).join('')}
          <g class="chart-axis">${labels}</g>
        </svg>
        <div class="chart-tip"></div>
      </div>`;

    const wrap = host.querySelector('.chart-wrap');
    const tip = host.querySelector('.chart-tip');
    const svg = host.querySelector('svg');

    svg.addEventListener('pointermove', (e) => {
      const rect = svg.getBoundingClientRect();
      const x = e.clientX - rect.left;
      const i = Math.round((x - (PAD.left / width) * rect.width) / (stepX / width * rect.width));
      const item = series[Math.min(Math.max(0, i), series.length - 1)];
      if (!item) return;
      tip.textContent = `${item.label} · ${nf(item[valueKey])} hits`;
      tip.style.left = `${(PAD.left + Math.min(Math.max(0, i), series.length - 1) * stepX) / width * rect.width}px`;
      tip.style.top = `${(PAD.top + innerH - (item[valueKey] / max) * innerH) / height * rect.height}px`;
      tip.classList.add('on');
    });
    svg.addEventListener('pointerleave', () => tip.classList.remove('on'));
  };

  draw();
  const ro = new ResizeObserver(() => draw());
  ro.observe(host);
}

export function distBars(host, games, labels) {
  const max = Math.max(1, ...games.map((g) => g.hits));
  host.innerHTML = `<div class="dist">${games
    .slice()
    .sort((a, b) => b.hits - a.hits)
    .map((g) => `
      <div class="dist-row">
        <div class="dist-name">${esc(labels[g.game] ?? g.game)}</div>
        <div class="dist-track"><div class="dist-fill" style="width:${Math.max(2, (g.hits / max) * 100)}%"></div></div>
        <div class="dist-val">${nf(g.hits)}</div>
      </div>`).join('')}</div>`;
}

export function scene3d(host, games, labels) {
  const max = Math.max(1, ...games.map((g) => g.hits));
  host.innerHTML = `
    <div class="scene3d">
      <div class="plot">
        <div class="floor"></div>
        ${games.map((g) => `
          <div class="bar3d" style="height:${Math.max(4, (g.hits / max) * 150)}px" title="${esc(labels[g.game] ?? g.game)} · ${nf(g.hits)} hits">
            <span>${nf(g.hits)}</span>
          </div>`).join('')}
      </div>
    </div>
    <div class="legend">${games.map((g) => `<span><i></i>${esc(labels[g.game] ?? g.game)} · ${money(g.value)}</span>`).join('')}</div>`;
}
