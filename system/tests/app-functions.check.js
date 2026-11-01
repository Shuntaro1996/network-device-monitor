// ==============================================================================
// app-functions.check.js - app.js の関数を画面なしで確かめるテスト (AppJs.Tests.ps1 から実行する)
// ==============================================================================
// 【初心者向けの簡単な解説】
// app.js はブラウザの画面がないと動きません。そこで、画面に触らない関数だけを文字として取り出し、
// Node.js の中で動かして結果を確かめます。npm のパッケージは使いません。
//
// 【使い方】
//   node app-functions.check.js <public フォルダ> <結果を書き出すファイル>
// 結果は [{ name: テスト名, ok: 合否, message: 失敗の理由 }] の JSON です。
// 結果をファイルに書くのは、Windows PowerShell 5.1 が画面出力の日本語を文字化けさせるためです。
//
// 【変更するときの注意】
// - 取り出す関数が別の関数を呼ぶときは、TARGET_FUNCTIONS に呼ばれる側も入れてください。
// - 取り出し方は「{ と } の対応」を数えるだけです。文字列の中に対応しない { や } がある関数には使えません。
// - document を使う関数のために、最小限の偽物を用意しています (fakeTheme を変えるとテーマを切り替えられます)。
// ==============================================================================
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert');
const childProcess = require('child_process');

const publicDir = process.argv[2];
const resultFile = process.argv[3];
const appPath = path.join(publicDir, 'app.js');
const appSource = fs.readFileSync(appPath, 'utf8');
const indexHtml = fs.readFileSync(path.join(publicDir, 'index.html'), 'utf8');
const styleCss = fs.readFileSync(path.join(publicDir, 'style.css'), 'utf8');

const TARGET_FUNCTIONS = ['escapeHTML', 'safeLinkUrl', 'getChartThemeColors', 'parseObrTime', 'formatObrDuration', 'describeObrEvent'];

// 「function 名前(」から、対応する } までを取り出す
function extractFunction(name) {
    const start = appSource.indexOf(`function ${name}(`);
    assert(start >= 0, `function ${name} was not found in app.js`);
    let index = appSource.indexOf('{', appSource.indexOf(')', start));
    let depth = 0;
    for (; index < appSource.length; index++) {
        if (appSource[index] === '{') depth++;
        if (appSource[index] === '}' && --depth === 0) return appSource.slice(start, index + 1);
    }
    throw new Error(`function ${name} is not closed`);
}

let fakeTheme = 'night';
const context = {
    document: { documentElement: { getAttribute: () => fakeTheme } }
};
const results = [];
function check(name, body) {
    try {
        body();
        results.push({ name, ok: true, message: '' });
    } catch (err) {
        results.push({ name, ok: false, message: String(err.message) });
    }
}

check('app.js に構文エラーがないこと', () => {
    childProcess.execFileSync(process.execPath, ['--check', appPath], { stdio: 'pipe' });
});

vm.createContext(context);
vm.runInContext(TARGET_FUNCTIONS.map(extractFunction).join('\n'), context);

check('escapeHTML が HTML の特殊文字をすべて置き換えること', () => {
    assert.strictEqual(context.escapeHTML(`<a href="x" y='z'>&`), '&lt;a href=&quot;x&quot; y=&#039;z&#039;&gt;&amp;');
});

check('escapeHTML が null と空文字を空文字にすること', () => {
    assert.strictEqual(context.escapeHTML(null), '');
    assert.strictEqual(context.escapeHTML(''), '');
});

check('safeLinkUrl がスクリプトを動かす URL を無効にすること', () => {
    for (const url of ['javascript:alert(1)', ' JAVASCRIPT:alert(1)', 'data:text/html,x', 'vbscript:x']) {
        assert.strictEqual(context.safeLinkUrl(url), '', url);
    }
});

check('safeLinkUrl がパスや機器名を開ける URL に直すこと', () => {
    assert.strictEqual(context.safeLinkUrl('https://a.example/'), 'https://a.example/');
    assert.strictEqual(context.safeLinkUrl('\\\\srv\\share'), 'file://srv/share');
    assert.strictEqual(context.safeLinkUrl('C:\\docs\\a'), 'file:///C:/docs/a');
    assert.strictEqual(context.safeLinkUrl('printer.local:8080'), 'http://printer.local:8080');
    assert.strictEqual(context.safeLinkUrl('example.test'), 'http://example.test');
    assert.strictEqual(context.safeLinkUrl(''), '');
});

check('getChartThemeColors がテーマに合った色を返すこと', () => {
    fakeTheme = 'day';
    assert.strictEqual(context.getChartThemeColors().textColor, '#0f172a');
    fakeTheme = 'night';
    assert.strictEqual(context.getChartThemeColors().textColor, '#f8fafc');
});

check('parseObrTime がパソコンの時刻として読むこと', () => {
    assert.strictEqual(context.parseObrTime('2026-10-30 10:00:05'), new Date(2026, 9, 30, 10, 0, 5).getTime());
});

check('formatObrDuration が時間・分・秒で表すこと', () => {
    assert.strictEqual(context.formatObrDuration(0), '0秒');
    assert.strictEqual(context.formatObrDuration(5), '5秒');
    assert.strictEqual(context.formatObrDuration(65), '1分5秒');
    assert.strictEqual(context.formatObrDuration(3725), '1時間2分5秒');
});

check('describeObrEvent が切断の長さと継続中を表すこと', () => {
    const ended = context.describeObrEvent({ type: 'disconnected', durationSec: 20 });
    assert(ended.label.includes('切断'));
    assert.strictEqual(ended.detail, '20秒');
    assert.strictEqual(context.describeObrEvent({ type: 'disconnected', durationSec: 20, ongoing: true }).detail, '継続中 20秒');
});

check('describeObrEvent が復旧の接続先を表すこと', () => {
    const event = context.describeObrEvent({ type: 'recovered', ssid: 'A', bssid: 'B', signalDbm: -50, txBitrate: '72 Mbit/s' });
    assert(event.label.includes('復旧'));
    assert.strictEqual(event.detail, 'A / B / -50 dBm / 72 Mbit/s');
});

check('describeObrEvent が AP の切り替えを表し、電波の 0 dBm も隠さないこと', () => {
    const event = context.describeObrEvent({ type: 'roamed', fromBssid: 'A', toBssid: 'B', signalDbm: 0 });
    assert(event.label.includes('AP'));
    assert.strictEqual(event.detail, 'A → B / 0 dBm');
});

check('describeObrEvent がログイン失敗と確認できない状態を表すこと', () => {
    assert(context.describeObrEvent({ type: 'loginFailed', durationSec: 10 }).label.includes('ログイン失敗'));
    const unreachable = context.describeObrEvent({ type: 'unreachable', durationSec: 10 });
    assert(unreachable.detail.includes('接続できません'));
    assert(unreachable.detail.includes('10秒'));
});

check('無線履歴の画面で使う部品が index.html と style.css にあること', () => {
    const ids = ['obr-history-modal', 'obr-history-title', 'obr-history-summary', 'obr-history-message', 'obr-history-content',
        'obr-history-events', 'obr-history-refresh-btn', 'close-obr-history-btn', 'close-obr-history-footer-btn', 'obr-signal-chart', 'obr-rate-chart'];
    for (const id of ids) assert(indexHtml.includes(`id="${id}"`), id);
    assert(styleCss.includes('.obr-history-btn'));
    assert(styleCss.includes('.obr-history-chart'));
});

fs.writeFileSync(resultFile, JSON.stringify(results), 'utf8');
