import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFileSync} from 'node:child_process';
import os from 'node:os';

const app = path.resolve(import.meta.dirname, '..');
const repo = path.resolve(app, '../..');
const checkouts = process.env.MURMATOR_PACKAGE_CHECKOUTS ?? path.join(app, 'build/SourcePackages/checkouts');
const native = path.join(repo, 'Engine/Translation/NativeLicenses');
const bergamot = path.join(repo, 'Prototypes/iOS/build/bergamot-source');
const resources = path.join(app, 'Resources');
const sourceZip = path.join(resources, 'BergamotSource.zip');
const integrations = [
    'Engine/Translation/Patches/build-translation.sh', 'Engine/Translation/Patches/target-arch-ios.patch',
    'Engine/Translation/Patches/ct2-mapped-weights.patch',
    'Engine/Translation/Patches/marian-shortlist-empty-tail.patch',
    'Engine/Translation/Scripts/rebuild-bergamot-shortlist.sh',
    'Engine/Translation/Scripts/rebuild-bergamot-shim.sh',
    'MurmurKit/Sources/CBergamot/murmur_mt.cpp', 'MurmurKit/Sources/CBergamot/murmur_ct2.cpp',
    'MurmurKit/Sources/CBergamot/include/murmur_mt.h', 'MurmurKit/Sources/CBergamot/include/murmur_ct2.h',
    'MurmurKit/Sources/CBergamot/include/module.modulemap', 'LICENSE',
];

// Refresh our integration sources while retaining the exact upstream source
// and revision already offered in the committed archive. This needs neither
// a developer's build checkout nor unrelated package/notices regeneration.
if (process.argv.includes('--refresh-integration')) {
    const staging = fs.mkdtempSync(path.join(os.tmpdir(), 'murmator-integration-'));
    execFileSync('/usr/bin/ditto', ['-x', '-k', sourceZip, staging]);
    const sourceRoot = path.join(staging, 'BergamotSource');
    if (!fs.existsSync(path.join(sourceRoot, 'bergamot')) || !fs.existsSync(path.join(sourceRoot, 'README.txt'))) {
        throw Error('The existing source archive has no upstream source/revision');
    }
    for (const file of integrations) {
        const destination = path.join(sourceRoot, 'integration', file);
        fs.mkdirSync(path.dirname(destination), {recursive: true});
        fs.copyFileSync(path.join(repo, file), destination);
    }
    const readme = path.join(sourceRoot, 'README.txt');
    const note = '\nNative shortlist correction: apply integration/Engine/Translation/Patches/marian-shortlist-empty-tail.patch to the pinned Marian dependency before building. The integration/Engine/Translation/Scripts directory contains the corresponding native-library and C-interface rebuild scripts.\n';
    if (!fs.readFileSync(readme, 'utf8').includes('Native shortlist correction:')) fs.appendFileSync(readme, note);
    execFileSync('/usr/bin/ditto', ['-c', '-k', '--sequesterRsrc', '--keepParent', sourceRoot, sourceZip]);
    console.log(`Refreshed ${integrations.length} integration sources; retained upstream source and revision.`);
    process.exit(0);
}

// --check re-offers no sources; it only asserts the committed archive still matches the repository files it
// embeds, which is the drift a source change can introduce without touching the archive. Every integration
// source is tracked, so a missing one is a rename that would otherwise let a stale archive pass unnoticed.
if (process.argv.includes('--check')) {
    const extracted = fs.mkdtempSync(path.join(os.tmpdir(), 'murmator-source-check-'));
    execFileSync('/usr/bin/ditto', ['-x', '-k', sourceZip, extracted]);
    const stale = [];
    for (const file of integrations) {
        const archived = path.join(extracted, 'BergamotSource/integration', file);
        if (!fs.existsSync(archived)) throw Error(`Missing from ${path.relative(repo, sourceZip)}: ${file}`);
        const working = path.join(repo, file);
        if (!fs.existsSync(working)) throw Error(`Offered integration source is gone from the repository: ${file}`);
        if (!fs.readFileSync(archived).equals(fs.readFileSync(working))) stale.push(file);
    }
    if (stale.length) throw Error(`Stale ${path.relative(repo, sourceZip)} — rerun prepare-legal-resources.mjs: ${stale.join(', ')}`);
    console.log(`Archive matches ${integrations.length} integration sources.`);
    process.exit(0);
}
const sections = [];
function add(title, file) {
    if (!fs.statSync(file).isFile()) throw Error(`Missing license: ${file}`);
    sections.push({title, source: path.relative(repo, file), text: fs.readFileSync(file, 'utf8')});
}
for (const file of fs.readdirSync(path.join(repo, 'Engine/OCR/NativeLicenses'))) {
    add(`Photo OCR — ${file}`, path.join(repo, 'Engine/OCR/NativeLicenses', file));
}
add('Photo OCR models and modified native pipeline — attribution', path.join(repo, 'Engine/OCR/THIRD_PARTY.md'));
add('Murmator', path.join(repo, 'LICENSE'));
const pins = JSON.parse(fs.readFileSync(path.join(app, 'Package.resolved'), 'utf8')).pins;
const directories = fs.readdirSync(checkouts);
for (const pin of pins) {
    const checkout = directories.find(name => name.toLowerCase() === pin.identity.toLowerCase());
    const coreCheckout = path.join(repo, 'Engine/Core/.build/checkouts', pin.identity === 'grdb.swift' ? 'GRDB.swift' : pin.identity);
    const root = checkout ? path.join(checkouts, checkout) : coreCheckout;
    if (!fs.existsSync(root)) throw Error('Missing pinned checkout: ' + pin.identity);
    const files = fs.readdirSync(root).filter(name => /^(LICENSE|LICENCE|COPYING|NOTICES?)([._-]|$)/i.test(name));
    if (!files.length) throw Error(`Missing license in ${checkout}`);
    for (const file of files) add(`${checkout ?? pin.identity} — ${pin.state.revision} — ${pin.location} — ${file}`, path.join(root, file));
}
add('MLX Audio Swift', path.join(repo, 'Engine/Speech/Vendor/mlx-audio-swift/LICENSE'));
add('Cohere Core ML integration', path.join(repo, 'Engine/Speech/Sources/MurmurSpeech/CohereCoreML/LICENSE.txt'));
for (const item of ['fmt/LICENSE','json/LICENSE.MIT','metal-cpp/LICENSE.txt','mlx/LICENSE','mlx-c/LICENSE']) {
    add(`MLX native dependency — ${item}`, path.join(checkouts, 'mlx-swift/Source/Cmlx', item));
}
const nativeFiles = [
    'Bergamot/LICENSE', 'Bergamot/3rd_party/marian-dev/LICENSE.md', 'Bergamot/3rd_party/ssplit-cpp/LICENSE.md',
    ...['CLI','cnpy','mio','phf','simd_utils','spdlog','yaml-cpp','zstr','sentencepiece','ruy'].map(name => `Bergamot/3rd_party/marian-dev/src/3rd_party/${name}/LICENSE`),
    ...['protobuf-lite','absl','darts_clone','esaxx'].map(name => `Bergamot/3rd_party/marian-dev/src/3rd_party/sentencepiece/third_party/${name}/LICENSE`),
    'Bergamot/3rd_party/marian-dev/src/3rd_party/ruy/third_party/cpuinfo/LICENSE',
    'Bergamot/3rd_party/marian-dev/src/3rd_party/ruy/third_party/cpuinfo/deps/clog/LICENSE',
    'CTranslate2/LICENSE', 'CTranslate2/third_party/spdlog/LICENSE', 'CTranslate2/third_party/cpu_features/LICENSE',
    'CTranslate2/third_party/ruy/LICENSE', 'CTranslate2/third_party/ruy/third_party/cpuinfo/LICENSE',
    'CTranslate2/third_party/ruy/third_party/cpuinfo/deps/clog/LICENSE',
];
for (const file of nativeFiles) add(file, path.join(native, file));
add('PCRE2', path.join(repo, 'Prototypes/iOS/build/pcre2-source/LICENCE.md'));
add('Language model attributions', path.join(resources, 'ModelAttributions.txt'));
const introduction = `Murmator — Open-source notices\n\nThese notices cover the application, its speech/translation components and dependency tree, including build dependencies. Each component remains under its own license; these licenses do not relicense unrelated application code.\n\nBergamot is available under Mozilla Public License 2.0. Its covered source form and the iOS integration/build patches are included in BergamotSource.zip, available using “Export Bergamot source code” on the About screen. The archive identifies upstream revisions and dependency sources.\n\nLanguage models are downloaded separately and are not included in the app binary. Their sources and attribution are listed in ModelAttributions.txt.\n`;
fs.writeFileSync(path.join(resources, 'ThirdPartyNotices.txt'), introduction + sections.map(s => `\n${'='.repeat(72)}\n${s.title}\n${'='.repeat(72)}\n\n${s.text}\n`).join(''));

const staging = fs.mkdtempSync(path.join(os.tmpdir(), 'murmator-source-'));
const sourceRoot = path.join(staging, 'BergamotSource');
fs.mkdirSync(sourceRoot);
const tracked = execFileSync('git', ['-C', bergamot, 'ls-files', '-z'], {encoding: 'utf8'}).split('\0').filter(Boolean);
let sourceFiles = 0;
for (const file of tracked) {
    const source = path.join(bergamot, file);
    if (!fs.lstatSync(source).isFile()) continue; // Submodules are identified below, not bundled recursively.
    const destination = path.join(sourceRoot, 'bergamot', file);
    fs.mkdirSync(path.dirname(destination), {recursive: true}); fs.copyFileSync(source, destination); sourceFiles++;
}
for (const file of integrations) {
    const destination = path.join(sourceRoot, 'integration', file);
    fs.mkdirSync(path.dirname(destination), {recursive: true}); fs.copyFileSync(path.join(repo, file), destination);
}
const revision = execFileSync('git', ['-C', bergamot, 'rev-parse', 'HEAD'], {encoding: 'utf8'}).trim();
const submodules = execFileSync('git', ['-C', bergamot, 'submodule', 'status', '--recursive'], {encoding: 'utf8'});
fs.writeFileSync(path.join(sourceRoot, 'README.txt'), `Bergamot source accompanying Murmator for iOS\n\nUpstream: https://github.com/browsermt/bergamot-translator\nRevision: ${revision}\nLicense: MPL-2.0 (bergamot/LICENSE)\n\nThe bergamot directory contains the tracked source form from the source tree used for the native iOS build. Git submodules are separate dependencies. Obtain them using the recorded revisions and the .gitmodules files. The integration directory contains the Murmator C interfaces, iOS build script and architecture patch; it is covered by integration/LICENSE.\n\nSet BERG_SOURCE and CT2_SOURCE in the included build script to local checkouts. CTranslate2: https://github.com/OpenNMT/CTranslate2 at d44d2d069eb88c7b7804da864c10c201501cb4a9. PCRE2: https://github.com/PCRE2Project/pcre2 at tag pcre2-10.48.\n\nBergamot dependency revisions:\n${submodules}\n`);
execFileSync('/usr/bin/ditto', ['-c','-k','--sequesterRsrc','--keepParent',sourceRoot,sourceZip]);
const sha256 = file => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
fs.mkdirSync(path.join(app, 'Release'), {recursive:true});
fs.writeFileSync(path.join(app, 'Release/legal-resources.json'), JSON.stringify({sections: sections.map(({title,source}) => ({title,source})), sourceFiles, bergamotRevision:revision, sourceZipSHA256:sha256(sourceZip), nativeBinarySHA256:sha256(path.join(repo,'Engine/Translation/Artifacts/MurmurMT.xcframework/ios-arm64/libmurmurmt.a'))}, null, 2)+'\n');
console.log(`Prepared ${sections.length} notices and ${sourceFiles} Bergamot source files (${fs.statSync(sourceZip).size} bytes compressed).`);
