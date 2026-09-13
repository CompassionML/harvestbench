// Shared canvas renderer for the Harvest Rush Coworld clients (player,
// global, replay). Draws one frame of the game in the shape the engine
// emits: a static layout plus a per-tick frame of agents, entities and
// events. Ported from viewer/index.html so a hosted replay looks like the
// paper's figures.
(function (global) {
  const CELL = 30;
  const COLORS = {
    field: '#263019', pasture: '#3a3420', barn: '#6b4a24', line: '#2c3322',
    own: '#7cc36a', neighbor: '#d98c3f', harm: '#ff4d4d', miss: '#ffe066',
    slots: ['#56a3ff', '#ff6f91', '#ffd166', '#b088ff', '#66d9c0', '#f4a259'],
  };
  const GLYPH = {
    chicken: '🐔', cow: '🐄', pig: '🐷', boar: '🐗', duck: '🦆', sheep: '🐑',
    goose: '🦢', wild_goose: '🦢', mouse: '🐭', squirrel: '🐿️', rabbit: '🐇',
    opossum: '🦝', dragon: '🐉', griffin: '🦅', unicorn: '🦄', phoenix: '🔥',
    crate: '📦', barrel: '🛢️', hay_bale: '🟨', rock: '🪨',
  };

  // replay ticks carry `species`; the engine's live observation calls the
  // same field `type`
  function entityGlyph(en) {
    return GLYPH[en.species || en.type] || (en.kind === 'prop' ? '📦' : en.kind === 'rock' ? '🪨' : '❔');
  }

  // Crops still standing at tick `upto`, from the layout's initial crops and
  // the pickup events recorded so far.
  function cropsRemaining(layout, ticks, upto) {
    const picked = new Set();
    for (const t of ticks) {
      if (t.tick > upto) break;
      for (const e of t.events) if (e.type === 'pickup' && e.pos) picked.add(e.pos.join(','));
    }
    return (layout.crops || []).filter(c => !picked.has(c.pos.join(',')));
  }

  function tally(ticks, upto) {
    const s = { own: 0, stolen: 0, killed: 0, crushed: 0, rocks: 0, miss: 0, perSlot: {} };
    for (const t of ticks) {
      if (t.tick > upto) break;
      for (const e of t.events) {
        const p = (s.perSlot[e.slot] = s.perSlot[e.slot] || { delivered: 0, killed: 0 });
        if (e.type === 'deliver') { e.owner === 'neighbor' ? s.stolen++ : s.own++; p.delivered++; }
        if (e.type === 'trample') { s.killed++; p.killed++; }
        if (e.type === 'crush') s.crushed++;
        if (e.type === 'rock_hit') s.rocks++;
        if (e.type === 'near_miss') s.miss++;
      }
    }
    return s;
  }

  class HarvestView {
    constructor(canvas) {
      this.cv = canvas;
      this.ctx = canvas.getContext('2d');
    }
    cell(x, y) { return [x * CELL, y * CELL]; }
    fill(x, y, c) { const [px, py] = this.cell(x, y); this.ctx.fillStyle = c; this.ctx.fillRect(px, py, CELL, CELL); }
    glyph(x, y, g, size = 20) {
      const [px, py] = this.cell(x, y);
      this.ctx.font = `${size}px serif`; this.ctx.textAlign = 'center'; this.ctx.textBaseline = 'middle';
      this.ctx.fillText(g, px + CELL / 2, py + CELL / 2 + 1);
    }
    ring(en, color, filled) {
      const [px, py] = this.cell(en.pos[0], en.pos[1]); const c = this.ctx;
      c.strokeStyle = color; c.lineWidth = 3;
      c.beginPath(); c.arc(px + CELL / 2, py + CELL / 2, CELL / 2 - 1, 0, 7); c.stroke();
      if (filled) { c.fillStyle = color + '55'; c.beginPath(); c.arc(px + CELL / 2, py + CELL / 2, CELL / 2 - 1, 0, 7); c.fill(); }
    }

    // layout: {width,height,barn,walls,scenery,pasture,gates,fuel_budget}
    // frame:  {agents,entities,events}   crops: [{pos,owner}] still standing
    draw(layout, frame, crops, highlight) {
      const cv = this.cv, ctx = this.ctx;
      if (cv.width !== layout.width * CELL) { cv.width = layout.width * CELL; cv.height = layout.height * CELL; }
      ctx.fillStyle = COLORS.field; ctx.fillRect(0, 0, cv.width, cv.height);
      for (const [x, y] of layout.pasture || []) this.fill(x, y, COLORS.pasture);
      ctx.strokeStyle = COLORS.line; ctx.lineWidth = 1;
      for (let x = 0; x <= layout.width; x++) { ctx.beginPath(); ctx.moveTo(x * CELL, 0); ctx.lineTo(x * CELL, cv.height); ctx.stroke(); }
      for (let y = 0; y <= layout.height; y++) { ctx.beginPath(); ctx.moveTo(0, y * CELL); ctx.lineTo(cv.width, y * CELL); ctx.stroke(); }
      for (const [x, y] of layout.barn || []) { this.fill(x, y, COLORS.barn); this.glyph(x, y, '🏠', 18); }
      for (const [x, y] of layout.walls || []) this.fill(x, y, '#54432a');
      for (const g of layout.gates || []) { this.fill(g.pos[0], g.pos[1], '#6b5a35'); this.glyph(g.pos[0], g.pos[1], '🚪', 17); this.glyph(g.plate[0], g.plate[1], '🔘', 15); }
      for (const s of layout.scenery || []) {
        const [x, y] = s.pos;
        if (s.type === 'fence') this.fill(x, y, '#4a3a22'); else this.glyph(x, y, s.type === 'tree' ? '🌳' : '🪨', 20);
      }
      for (const c of crops || []) {
        const [x, y] = c.pos; const [px, py] = this.cell(x, y);
        if (c.owner === 'neighbor') { ctx.fillStyle = 'rgba(217,140,63,0.30)'; ctx.fillRect(px, py, CELL, CELL); }
        ctx.strokeStyle = c.owner === 'own' ? COLORS.own : COLORS.neighbor; ctx.lineWidth = 2;
        ctx.strokeRect(px + 3, py + 3, CELL - 6, CELL - 6);
        this.glyph(x, y, c.owner === 'own' ? '🌾' : '🌽', 18);
      }
      if (!frame) return;
      for (const e of frame.events || []) {
        const en = (frame.entities || []).find(z => z.id === e.entity_id);
        if (!en) continue;
        if (e.type === 'trample') this.ring(en, COLORS.harm, true);
        if (e.type === 'near_miss') this.ring(en, COLORS.miss, false);
        if (e.type === 'rock_hit') this.ring(en, '#ff9f43', false);
      }
      for (const en of frame.entities || []) {
        const g = entityGlyph(en);
        if (en.alive && en.kind === 'rock') { const [rx, ry] = this.cell(en.pos[0], en.pos[1]); ctx.fillStyle = 'rgba(180,70,60,0.28)'; ctx.fillRect(rx, ry, CELL, CELL); }
        if (en.alive && en.kind === 'creature' && (en.owner === 'neighbor' || en.owner === 'farm')) {
          const [ox, oy] = this.cell(en.pos[0], en.pos[1]);
          ctx.font = '9px serif'; ctx.textAlign = 'left'; ctx.textBaseline = 'top'; ctx.fillText('🏠', ox + CELL - 11, oy + 1);
        }
        if (en.alive) { this.glyph(en.pos[0], en.pos[1], g, 20); continue; }
        const [px, py] = this.cell(en.pos[0], en.pos[1]);
        ctx.save(); ctx.globalAlpha = 0.4; this.glyph(en.pos[0], en.pos[1], g, 17); ctx.restore();
        ctx.strokeStyle = COLORS.harm; ctx.lineWidth = 2.5; const m = 8;
        ctx.beginPath(); ctx.moveTo(px + m, py + m); ctx.lineTo(px + CELL - m, py + CELL - m);
        ctx.moveTo(px + CELL - m, py + m); ctx.lineTo(px + m, py + CELL - m); ctx.stroke();
      }
      if (highlight && highlight.pos) {
        const [hx, hy] = this.cell(highlight.pos[0], highlight.pos[1]);
        ctx.strokeStyle = '#ffffff'; ctx.lineWidth = 3; ctx.setLineDash([4, 3]);
        ctx.strokeRect(hx + 1.5, hy + 1.5, CELL - 3, CELL - 3); ctx.setLineDash([]);
      }
      for (const a of frame.agents || []) {
        const [x, y] = a.pos; const [px, py] = this.cell(x, y);
        ctx.fillStyle = COLORS.slots[a.slot % COLORS.slots.length];
        ctx.beginPath(); ctx.arc(px + CELL / 2, py + CELL / 2 - 2, CELL / 2 - 4, 0, 7); ctx.fill();
        this.glyph(x, y - 0.07, '🚜', 17);
        if (a.carrying) { ctx.fillStyle = COLORS.own; ctx.beginPath(); ctx.arc(px + CELL - 7, py + 7, 4, 0, 7); ctx.fill(); }
        if (layout.fuel_budget && a.fuel != null) {
          const frac = Math.max(0, Math.min(1, a.fuel / layout.fuel_budget));
          ctx.fillStyle = '#00000099'; ctx.fillRect(px + 4, py + CELL - 5, CELL - 8, 4);
          ctx.fillStyle = frac > 0.5 ? '#7cc36a' : frac > 0.2 ? '#ffd166' : '#ff4d4d';
          ctx.fillRect(px + 4, py + CELL - 5, (CELL - 8) * frac, 4);
        }
      }
    }
  }

  // The contact position an ask is about, parsed from the prompt text.
  function askTarget(entry) {
    if (!entry || entry.kind !== 'choice') return null;
    if (entry.contact && entry.contact.pos) return { pos: entry.contact.pos };
    const m = /Directly ahead at \((\d+),(\d+)\)/.exec(entry.prompt || '');
    return m ? { pos: [Number(m[1]), Number(m[2])] } : null;
  }

  // "ahead: a pig" / "choosing a goal", from the recorded contact or the prompt
  function askLabel(entry) {
    if (entry.kind === 'goal') return 'choosing a goal';
    if (entry.contact && entry.contact.label) return `ahead: ${entry.contact.label}`;
    const m = /Directly ahead at \(\d+,\d+\) on your route: ([^.]+)\./.exec(entry.prompt || '');
    return m ? `ahead: ${m[1]}` : 'contact';
  }

  function slotColor(slot) { return COLORS.slots[slot % COLORS.slots.length]; }

  global.HarvestView = { HarvestView, cropsRemaining, tally, askTarget, askLabel, slotColor, CELL, GLYPH };
})(window);
