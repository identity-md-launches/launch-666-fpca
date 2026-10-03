// Embedded verbatim into ViewerScript.sol; no external artwork, fonts or scripts.
// `initial` is immutable JSON-shaped data emitted by CatRenderer.html.
'use strict';
const canvas = document.getElementById('art');
const ctx = canvas.getContext('2d');
const cat = new Image();
let count = initial.count, observed = initial.observed, source = 'Onchain';
let cells = [], loading = false;

function jumble() {
    cells = [];
    if (!observed || !count) return;
    const cols = Math.ceil(Math.sqrt(count)), rows = Math.ceil(count / cols);
    const unit = Math.min(936 / cols, 726 / rows);
    const left = (1000 - cols * unit) / 2, top = 54 + (726 - rows * unit) / 2;
    for (let i = 0; i < count; i++) {
        const s = .45 + Math.random() * .35;
        const x = .05 + Math.random() * (.90 - s), y = .05 + Math.random() * (.90 - s);
        cells.push([left + (i % cols + x) * unit, top + (Math.floor(i / cols) + y) * unit, s * unit]);
    }
}

function draw() {
    ctx.fillStyle = '#342E2E';
    ctx.fillRect(0, 0, 1000, 1000);
    ctx.imageSmoothingEnabled = false;
    for (const [x, y, s] of cells) ctx.drawImage(cat, x, y, s, s * 21 / 23);
    ctx.fillStyle = '#DBFEE6';
    ctx.textAlign = 'center';
    ctx.font = '48px Inter,Arial,Helvetica,sans-serif'; // 36pt at 96 CSS dpi
    ctx.fillText(observed ? String(count) : '--', 500, 868);
    ctx.font = '40px Inter,Arial,Helvetica,sans-serif'; // 30pt
    ctx.fillText('Fren Pet Cats Still Alive', 500, 932);
    ctx.font = '18px Inter,Arial,Helvetica,sans-serif';
    ctx.textAlign = 'left';
    const status = !observed ? 'unreported' : (Date.now() / 1000 > observed + initial.maxAge ? 'stale' : 'fresh');
    ctx.fillText(source + ' ' + status + ' / observed Unix ' + observed, 32, 32);
    ctx.textAlign = 'right';
    ctx.fillText('#' + initial.mint, 968, 32);
}

const apiQuery = '{_meta{status} pets(where:{dna_starts_with:"6-"},limit:1000){totalCount items{id dna status owner} pageInfo{hasNextPage}}}';
const metaQuery = '{_meta{status}}';
async function request(query, signal) {
    const response = await fetch('https://api.pet.game/', {
        method: 'POST', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({query}), signal, credentials: 'omit'
    });
    if (!response.ok) throw new Error('API transport');
    const text = await response.text();
    if (text.length > 1000000) throw new Error('API size');
    const result = JSON.parse(text);
    if (result.errors || !result.data) throw new Error('API query');
    return result.data;
}

function block(data) {
    const base = data._meta.status.base, b = base.block;
    if (base.id !== 8453) throw new Error('API chain');
    if (!Number.isSafeInteger(b.number) || b.number <= 0 || !Number.isSafeInteger(b.timestamp)) {
        throw new Error('API index');
    }
    if (b.hash !== undefined && (typeof b.hash !== 'string' || !/^0x[0-9a-fA-F]{64}$/.test(b.hash))) {
        throw new Error('API block hash');
    }
    return b;
}

function validate(data, after) {
    const b = block(data), next = block(after), page = data.pets;
    const now = Date.now() / 1000;
    if (b.number !== next.number || b.timestamp !== next.timestamp || b.hash !== next.hash ||
        b.timestamp < initial.originalTimestamp || b.timestamp < observed || b.timestamp > now ||
        now - b.timestamp > initial.maxAge) throw new Error('API observation');
    if (!Number.isSafeInteger(page.totalCount) || page.totalCount < 0 || page.totalCount > 1000 ||
        !Array.isArray(page.items) || page.items.length !== page.totalCount ||
        page.pageInfo.hasNextPage !== false) throw new Error('API pagination');
    const seen = new Set();
    let alive = 0;
    for (const pet of page.items) {
        if (!Number.isSafeInteger(pet.id) || pet.id < 0 || seen.has(pet.id) || typeof pet.dna !== 'string' ||
            !/^6-[0-9]+-[0-9]+$/.test(pet.dna) || !Number.isInteger(pet.status) ||
            pet.status < 0 || pet.status > 6 || typeof pet.owner !== 'string' ||
            !/^0x[0-9a-fA-F]{40}$/.test(pet.owner)) throw new Error('API cat');
        seen.add(pet.id);
        const owner = pet.owner.toLowerCase();
        if (pet.status !== 4 && owner !== '0x0000000000000000000000000000000000000000' &&
            owner !== '0x000000000000000000000000000000000000dead') alive++;
    }
    if (alive > initial.original) throw new Error('API cohort');
    return {count: alive, observed: b.timestamp};
}

// A browser-capable viewer can obtain current indexed data. This never writes to the contract.
// Denied CORS/CSP, lag, incomplete responses or schema changes retain the last valid snapshot.
async function refresh() {
    if (loading) return;
    loading = true;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 8000);
    try {
        const data = await request(apiQuery, controller.signal);
        const after = await request(metaQuery, controller.signal);
        const fresh = validate(data, after);
        count = fresh.count;
        observed = fresh.observed;
        source = 'API';
        jumble();
    } catch (_) {
        // Preserve known data and let its timestamp visibly expire.
    } finally {
        clearTimeout(timeout);
        loading = false;
        draw();
    }
}

cat.onload = () => {
    jumble();
    draw();
    refresh();
    setInterval(draw, 1000);
    setInterval(refresh, 60000);
};
canvas.onclick = () => { jumble(); draw(); };
cat.src = initial.sprite;
