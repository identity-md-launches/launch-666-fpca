// Offline behavior checks for the exact JavaScript embedded in the deployed contract.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const test = require('node:test');
const root = path.resolve(__dirname, '..');
const source = fs.readFileSync(path.join(root, 'assets/viewer.js'), 'utf8');
const generated = fs.readFileSync(path.join(root, 'src/ViewerScript.sol'), 'utf8');

function viewer(overrides = {}) {
    let now = 1200, randomSeed = 12345;
    const texts = [], images = [], responses = [];
    const context = {
        fillRect() { texts.length = 0; images.length = 0; },
        drawImage(...args) { images.push(args.slice(1)); },
        fillText(...args) { texts.push(args); }
    };
    const canvas = {getContext: () => context};
    const math = Object.create(Math);
    math.random = () => { randomSeed = (randomSeed * 16807) % 2147483647; return randomSeed / 2147483647; };
    const sandbox = vm.createContext({
        initial: {count: 34, observed: 1000, maxAge: 3600, mint: 1, original: 100,
            originalTimestamp: 1, sprite: 'data:image/png;base64,abc', ...overrides},
        document: {getElementById: () => canvas},
        Image: class {}, Math: math, Date: {now: () => now * 1000}, AbortController,
        setTimeout: () => 1, clearTimeout() {}, setInterval() {},
        fetch: async (url, options) => {
            assert.equal(url, 'https://api.pet.game/');
            assert.equal(options.credentials, 'omit');
            const next = responses.shift();
            if (next instanceof Error) throw next;
            if (!next) throw new Error('No response');
            return {ok: true, text: async () => JSON.stringify(next)};
        }
    });
    vm.runInContext(source, sandbox);
    return {run: code => vm.runInContext(code, sandbox), texts, images, responses,
        now: n => { now = n; }, canvas, sandbox};
}

function snapshot(rows, timestamp = 1100, number = 10) {
    return {data: {_meta: {status: {base: {id: 8453, block: {number, timestamp}}}},
        pets: {totalCount: rows.length, items: rows, pageInfo: {hasNextPage: false}}}};
}
function row(id, status = 0, owner = '0x1111111111111111111111111111111111111111') {
    return {id, status, owner, dna: '6-6-6'};
}

test('committed Solidity string and image exactly match the reviewed source assets', () => {
    const literal = generated.match(/SOURCE\s*=\s*("(?:\\.|[^"\\])*")\s*;/s)[1];
    assert.equal(JSON.parse(literal), source);
    const renderer = fs.readFileSync(path.join(root, 'src/CatRenderer.sol'), 'utf8');
    const png = fs.readFileSync(path.join(root, 'assets/cat.png')).toString('base64');
    assert.ok(renderer.includes('data:image/png;base64,' + png));
});

test('zero and unreported states render no sprites and distinguish zero from unknown', () => {
    for (const observed of [0, 1000]) {
        const v = viewer({count: 0, observed});
        v.run('jumble();draw()');
        assert.equal(v.images.length, 0);
        assert.equal(v.texts[0][0], observed ? '0' : '--');
    }
});

test('every drawn cat is inside its distinct grid cell with positive gaps, through the maximum', () => {
    for (const count of [1, 2, 3, 16, 17, 34, 37, 1000, 100000]) {
        const v = viewer({count, original: 100000});
        v.run('jumble();draw()');
        assert.equal(v.images.length, count);
        const cols = Math.ceil(Math.sqrt(count)), rows = Math.ceil(count / cols);
        const unit = Math.min(936 / cols, 726 / rows);
        const left = (1000 - cols * unit) / 2, top = 54 + (726 - rows * unit) / 2;
        v.images.forEach(([x, y, w, h], i) => {
            const cellX = left + (i % cols) * unit, cellY = top + Math.floor(i / cols) * unit;
            assert.ok(x > cellX && x + w < cellX + unit);
            assert.ok(y > cellY && y + h < cellY + unit);
            assert.ok(y + h < 780);
            assert.ok(Math.abs(h / w - 21 / 23) < 1e-12);
        });
        assert.equal(v.texts[0][0], String(count));
    }
});

test('opening/clicking reshuffles without changing population', () => {
    const v = viewer();
    v.run('jumble();draw()');
    const first = JSON.stringify(v.images);
    v.canvas.onclick();
    assert.notEqual(JSON.stringify(v.images), first);
    assert.equal(v.images.length, 34);
});

test('mint numbers retain their decimal digits beyond JavaScript integer precision', () => {
    const mint = '9007199254740993';
    const v = viewer({mint});
    v.run('draw()');
    assert.ok(v.texts.some(t => t[0] === '#' + mint));
    const renderer = fs.readFileSync(path.join(root, 'src/CatRenderer.sol'), 'utf8');
    assert.ok(renderer.includes("',mint:\"'"));
});

test('validated API result counts all living statuses and excludes dead and burned owners', async () => {
    const v = viewer();
    const data = snapshot([row(1, 0), row(2, 5), row(3, 6), row(4, 4),
        row(5, 1, '0x0000000000000000000000000000000000000000'),
        row(6, 2, '0x000000000000000000000000000000000000dEaD')]);
    v.responses.push(data, data);
    await v.run('refresh()');
    assert.equal(v.run('count'), 3);
    assert.equal(v.run('observed'), 1100);
    assert.equal(v.images.length, 3);
    assert.ok(v.texts.some(t => t[0].startsWith('API fresh')));
});

test('malformed, incomplete, stale, future, wrong-chain and inconsistent data fail closed', async () => {
    const mutations = [
        data => { data.errors = [{message: 'error'}]; },
        data => { data.data.pets.pageInfo.hasNextPage = true; },
        data => { data.data.pets.totalCount++; },
        data => { data.data.pets.items[0].status = 7; },
        data => { data.data.pets.items[0].dna = '1-1-1'; },
        data => { data.data.pets.items[0].owner = 'invalid'; },
        data => { data.data.pets.items[0].id = '1'; },
        data => { data.data.pets.items[1].id = 1; },
        data => { data.data._meta.status.base.id = 1; },
        data => { data.data._meta.status.base.block.timestamp = 1201; },
        data => { data.data._meta.status.base.block.timestamp = 999; },
        data => { data.data._meta.status.base.block.hash = 'not a hash'; },
    ];
    for (const mutate of mutations) {
        const v = viewer();
        v.run('jumble()');
        const data = snapshot([row(1), row(2)]);
        mutate(data);
        v.responses.push(data, data);
        await v.run('refresh()');
        assert.equal(v.run('count'), 34);
        assert.equal(v.run('observed'), 1000);
        assert.equal(v.run('source'), 'Onchain');
    }
    for (const mode of ['stale', 'advancing', 'too many', 'network']) {
        const v = viewer({original: 1});
        const data = snapshot([row(1), row(2)]);
        if (mode === 'stale') v.now(10000);
        v.responses.push(mode === 'network' ? new Error('offline') : data,
            mode === 'advancing' ? snapshot([row(1)], 1101, 11) : data);
        await v.run('refresh()');
        assert.equal(v.run('count'), 34);
    }
});

test('cached reports visibly expire using the viewer clock and a zero API count is valid', async () => {
    const v = viewer();
    v.now(4601);
    v.run('jumble();draw()');
    assert.ok(v.texts.some(t => t[0].startsWith('Onchain stale')));
    v.now(1200);
    const data = snapshot([]);
    v.responses.push(data, data);
    await v.run('refresh()');
    assert.equal(v.run('count'), 0);
    assert.equal(v.images.length, 0);
    assert.equal(v.texts[0][0], '0');
});
