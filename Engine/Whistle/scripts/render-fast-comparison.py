"""Render the paired app-session measurements as a self-contained HTML report."""

import argparse
import contextlib
import importlib.util
import io
import json
import sys
from pathlib import Path


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("report", type=Path)
    p.add_argument("output", type=Path)
    a = p.parse_args()
    report = json.loads(a.report.read_text())
    root = Path(__file__).resolve().parents[3]
    spec = importlib.util.spec_from_file_location(
        "scorer", root / "Prototypes/iOS/scripts/score-corpus.py"
    )
    scorer = importlib.util.module_from_spec(spec)
    old = sys.argv
    try:
        sys.argv = ["score-corpus.py"]
        with contextlib.redirect_stdout(io.StringIO()):
            spec.loader.exec_module(scorer)
    finally:
        sys.argv = old
    data = {"summary": report["summary"], "models": report["models"], "rows": []}
    for row in report["rows"]:
        data["rows"].append(
            {
                "name": row["name"],
                "group": row["group"],
                "reference": row["reference"],
                "referenceTokens": scorer.normalize(row["reference"]).split(),
                "words": row["referenceWords"],
                "backends": {
                    k: {
                        "text": v["finalText"],
                        "tokens": v["normalizedHypothesis"].split(),
                        "errors": v["wordEdits"],
                        "wer": v["WER"],
                        "first": v["firstSnapshotSeconds"],
                        "compute": v["speechComputeSeconds"],
                        "audio": v["audioSeconds"],
                        "tail": v["speechReplayWallSeconds"] - v["audioSeconds"],
                        "rss": v["processPeakRSSBytes"] / 2**20,
                        "queue": v["latestSpeechTelemetry"]["peakPendingAudioChunks"]
                        * 0.096,
                    }
                    for k, v in row["backends"].items()
                },
            }
        )
    payload = json.dumps(data, ensure_ascii=False).replace("</", "<\\/")
    html = TEMPLATE.replace("__DATA__", payload)
    a.output.parent.mkdir(parents=True, exist_ok=True)
    a.output.write_text(html)
    print(a.output)


TEMPLATE = r"""<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Whistle vs текущий Fast</title>
<style>
:root{color-scheme:light;--ink:#192830;--muted:#596873;--line:#dbe3e7;--n:#365cdf;--w:#08765d;--bg:#f4f7f8}*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--ink);font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}main{max-width:1140px;margin:auto;padding:28px 22px 36px}h1{font-size:clamp(25px,4vw,40px);line-height:1.13;letter-spacing:-.03em;margin:7px 0 12px}h2{font-size:20px;line-height:1.3;margin:0 0 10px}.eyebrow{font-weight:650;font-size:12px;letter-spacing:.09em;text-transform:uppercase;color:var(--muted)}p{margin:0 0 14px}.muted{color:var(--muted)}.legend{display:flex;gap:18px;flex-wrap:wrap;margin:16px 0}.dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:6px}.n .dot,.bar.n{background:var(--n)}.w .dot,.bar.w{background:var(--w)}.card{background:white;border:1px solid var(--line);border-radius:14px;padding:19px}.graphs{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:12px;margin:18px 0}.metric{font-size:13px;font-weight:650}.hint{font-size:12px;color:var(--muted);margin:2px 0 14px}.barlabel{display:flex;justify-content:space-between;gap:10px;font-size:12px;margin-top:10px}.track{height:9px;background:#edf1f3;border-radius:5px;overflow:hidden;margin-top:4px}.bar{height:100%;border-radius:5px}.verdict{background:#e8f2ee;border-left:4px solid var(--w);padding:14px 17px;border-radius:7px;margin:16px 0}.facts{width:100%;border-collapse:collapse;margin:12px 0 4px;font-size:14px}.facts th,.facts td{padding:10px 12px;border-bottom:1px solid var(--line);text-align:left}.facts th{font-size:12px;color:var(--muted);font-weight:650}.facts th:last-child{color:var(--w)}.facts th:nth-child(2){color:var(--n)}.section{margin-top:27px}.controls{display:flex;align-items:center;gap:12px;flex-wrap:wrap;margin:14px 0}select{font:inherit;color:var(--ink);background:white;border:1px solid #a5b2bb;border-radius:8px;padding:10px 12px;max-width:100%}label{font-size:13px;font-weight:650}.reference{font-size:14px;background:#ebf0f3;border-radius:10px;padding:15px;margin:12px 0}.reference strong{display:block;color:var(--muted);font-size:11px;text-transform:uppercase;letter-spacing:.08em;margin-bottom:6px}.outputs{display:grid;grid-template-columns:1fr 1fr;gap:12px}.pill{display:inline-block;border-radius:5px;background:#f0f3f5;padding:3px 7px;margin:0 4px 7px 0;font-size:11px}.transcript{font-size:15px;line-height:1.65}.aligned{font-size:13px;line-height:1.95;margin-top:10px}.aligned span{margin-right:4px}.sub,.ins{background:#fde8e5;border-radius:3px;padding:1px 3px;color:#8e2d25}.del{background:#f2e7e6;border-radius:3px;padding:1px 3px;color:#8e2d25;text-decoration:line-through}details{margin-top:14px}summary{font-size:12px;cursor:pointer;color:var(--muted)}.foot{font-size:12px;color:var(--muted);margin-top:20px}.sample{font-size:12px;color:var(--muted)}button{font:inherit;color:var(--ink);border:1px solid #a5b2bb;background:white;border-radius:7px;padding:8px 12px;cursor:pointer}button:focus-visible,select:focus-visible,summary:focus-visible{outline:3px solid #6e8eff;outline-offset:3px}@media(max-width:740px){.graphs{grid-template-columns:1fr}.outputs{grid-template-columns:1fr}main{padding:20px 15px}.facts td,.facts th{padding:10px 7px;font-size:12px}}@media print{body{background:white}main{padding:0}.controls{display:none}.card{break-inside:avoid}details{display:none}}
</style></head><body><main>
<div class="eyebrow">Mac M1 Max · English Fast · 11 октября 2026</div>
<h1>Whistle CPU vs Nemotron GPU</h1>
<p class="muted">Два реальных пути диктовки в приложении. Те же 4 записи: 56,02 секунды аудио, 108 слов. Перевод и корректор выключены.</p>
<div class="legend"><span class="n"><i class="dot"></i>Nemotron 3.5 0.6B · текущий Fast</span><span class="w"><i class="dot"></i>Whistle · экспериментальный CPU</span></div>
<div class="verdict" id="verdict"></div>
<div class="graphs" id="graphs"></div>
<div class="card"><table class="facts"><thead><tr><th>Короткий пилот</th><th>Nemotron GPU</th><th>Whistle CPU</th></tr></thead><tbody id="facts"></tbody></table>
<p class="sample">Вычисления — сумма времени внутри вызовов ASR/VAD, включая ожидание GPU и завершение фраз. Паузы между поступлениями аудио исключены. Это разные полные пути приложения, а не изолированные математические графы.</p></div>
<section class="section"><h2>Посмотреть, где ошибаются</h2><p class="muted">Выберите запись. Ниже — исходная фраза и точные результаты обоих движков.</p>
<div class="controls"><label for="clip">Запись</label><select id="clip"></select><button id="toggle">Раскрыть сравнение слов</button></div>
<div class="reference"><strong>Эталон</strong><span id="reference" lang="en"></span></div>
<div class="outputs" id="outputs"></div></section>
<p class="foot">Один последовательный парный прогон на каждой записи; порядок чередовался. WER — замены, пропуски и добавления слов / число слов эталона; регистр и пунктуация нормализованы одинаково. Корпус маленький и уже использовался при разработке Whistle: общий рейтинг качества из него не следует. Длинный тест — 4 полных повтора первого WAV с паузами (86,64 с), а не новая независимая речь.</p>
<p class="foot">Память — пик RSS всего процесса, включая загрузку моделей; это учёт macOS, а не отдельное измерение памяти GPU. Потребление энергии и реальный микрофон не измерялись. Whistle сейчас доступен только в English Fast. Текущий Fast и настройки приложения не переключались.</p>
</main><script>
const D=__DATA__;
const labels={nemotron:'Nemotron GPU',whistle:'Whistle CPU'};
const f=(x,d=2)=>Number(x).toLocaleString('ru-RU',{minimumFractionDigits:d,maximumFractionDigits:d});
const n=D.summary.nemotron,w=D.summary.whistle;
const text=(el,t)=>{el.textContent=t;return el};
const el=(tag,cls)=>{const a=document.createElement(tag);if(cls)a.className=cls;return a};
text(document.getElementById('verdict'),`На этом пилоте Whistle: ${w.errors} ошибок вместо ${n.errors}, в ${f(n.peakRSSBytes/w.peakRSSBytes,1)} раза меньше пик памяти. Nemotron: первый текст на ${f(w.firstTextMedian-n.firstTextMedian,2)} с раньше и в ${f(w.computeSeconds/n.computeSeconds,1)} раза меньше времени на обработку.`);
for(const [title,hint,key,scale,unit] of [
 ['Ошибки слов · WER','Меньше — лучше. Только этот пилот.','WER',100,'%'],
 ['Первый текст','Медиана от начала подачи аудио.','firstTextMedian',1,'с'],
 ['Память процесса','Максимальный пик RSS четырёх прогонов.','peakRSSBytes',1/2**20,'MiB']]){
 const card=el('div','card');card.append(text(el('div','metric'),title),text(el('div','hint'),hint));
 const hi=Math.max(n[key],w[key]);
 for(const k of ['nemotron','whistle']){const v=D.summary[k][key];const row=el('div','barlabel');row.append(text(el('span'),labels[k]),text(el('strong'),f(v*scale,key==='peakRSSBytes'?0:2)+' '+unit));const track=el('div','track'),bar=el('div','bar '+(k==='nemotron'?'n':'w'));bar.style.width=(100*v/hi)+'%';track.append(bar);card.append(row,track)}
 document.getElementById('graphs').append(card);
}
for(const [name,fn] of [
 ['Ошибки / слова',s=>`${s.errors} / ${s.words}`],
 ['Первый текст: диапазон',s=>`${f(s.firstTextRange[0])}–${f(s.firstTextRange[1])} с`],
 ['Время обработки 56,02 с аудио',s=>`${f(s.computeSeconds)} с · ${f(s.computePerAudio)}× длительности`],
 ['CPU-время процесса',s=>`${f(s.CPUSeconds)} с (GPU-время сюда не входит)`],
 ['После конца аудио: медиана / максимум',s=>`${f(s.tailMedian)} / ${f(s.tailMax)} с`],
 ['Пик очереди аудио',s=>`${f(s.peakPendingChunks*0.096)} с`]]){
 const row=el('tr');row.append(text(el('td'),name),text(el('td'),fn(n)),text(el('td'),fn(w)));document.getElementById('facts').append(row);
}
const row=el('tr');row.append(text(el('td'),'Файлы ASR-модели'),text(el('td'),f(D.models.nemotron.bytes/1e6,1)+' MB'),text(el('td'),f(D.models.whistle.bytes/1e6,1)+' MB'));document.getElementById('facts').append(row);
function align(ref,hyp){const dp=Array.from({length:ref.length+1},()=>Array(hyp.length+1).fill(0));for(let i=0;i<=ref.length;i++)dp[i][0]=i;for(let j=0;j<=hyp.length;j++)dp[0][j]=j;for(let i=1;i<=ref.length;i++)for(let j=1;j<=hyp.length;j++)dp[i][j]=Math.min(dp[i-1][j]+1,dp[i][j-1]+1,dp[i-1][j-1]+(ref[i-1]!==hyp[j-1]));let i=ref.length,j=hyp.length,out=[];while(i||j){if(i&&j&&dp[i][j]===dp[i-1][j-1]+(ref[i-1]!==hyp[j-1])){out.push({type:ref[i-1]===hyp[j-1]?'same':'sub',word:hyp[j-1],original:ref[i-1]});i--;j--}else if(j&&dp[i][j]===dp[i][j-1]+1){out.push({type:'ins',word:hyp[--j]})}else{out.push({type:'del',word:ref[--i]})}}return out.reverse()}
const titles=['Организация и спорт','Pa amb oli: ужин','Вакцина и Ebola','Транспорт в Goma','Длинный тест: 4 повтора'];
D.rows.forEach((r,i)=>{const option=el('option');option.value=i;text(option,`${titles[i]} · ${r.words} слов`);document.getElementById('clip').append(option)});
function show(){const r=D.rows[Number(document.getElementById('clip').value)];text(document.getElementById('reference'),r.reference);const host=document.getElementById('outputs');host.replaceChildren();for(const k of ['nemotron','whistle']){const v=r.backends[k],card=el('div','card');card.append(text(el('h2'),labels[k]));const pills=el('div');for(const value of [`${v.errors}/${r.words} ошибок · ${f(v.wer*100,1)}% WER`,`первый текст ${f(v.first)} с`,`обработка ${f(v.compute)} с`,`RSS ${f(v.rss,0)} MiB`,`конец +${f(v.tail)} с`])pills.append(text(el('span','pill'),value));card.append(pills,text(el('p','transcript'),v.text));const detail=el('details');detail.append(text(el('summary'),'Слова после нормализации · ошибки выделены, пропуски зачёркнуты'));const words=el('div','aligned');words.lang='en';const ops=align(r.referenceTokens,v.tokens);if(ops.filter(o=>o.type!=='same').length!==v.errors)throw Error('Word alignment disagrees with scorer');for(const o of ops){const span=text(el('span',o.type),o.word);if(o.type==='sub')span.title='В эталоне: '+o.original;if(o.type==='del')span.title='Пропущено';if(o.type==='ins')span.title='Добавлено';words.append(span)}detail.append(words);card.append(detail);host.append(card)}}
document.getElementById('clip').addEventListener('change',show);document.getElementById('toggle').addEventListener('click',()=>{const details=[...document.querySelectorAll('#outputs details')],open=details.some(d=>!d.open);details.forEach(d=>d.open=open)});show();
</script></body></html>"""


if __name__ == "__main__":
    main()
