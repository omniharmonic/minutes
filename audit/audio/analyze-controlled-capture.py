import sqlite3,pathlib,json,subprocess,re,itertools,argparse
import numpy as np
from scipy.signal import correlate
from scipy.optimize import linear_sum_assignment
parser=argparse.ArgumentParser(description='Analyze only the explicitly selected synthetic capture; never enroll voices or export transcripts.')
parser.add_argument('--meeting-id',required=True)
parser.add_argument('--output-dir',required=True)
args=parser.parse_args()
out=pathlib.Path(args.output_dir);out.mkdir(parents=True,exist_ok=True)
gt=json.loads(pathlib.Path('/private/tmp/minutes-extended-speech/ground-truth.json').read_text())
c=sqlite3.connect('file:'+str(pathlib.Path.home()/'Library/Application Support/Minutes/minutes.db')+'?mode=ro',uri=True)
mid,audio,status=c.execute('select id,audio_path,status from meeting where id=?',(args.meeting_id,)).fetchone()
if not audio: raise SystemExit('recording has not finalized')
d=pathlib.Path(audio).parent;m=json.loads((d/'capture.json').read_text())
def pcm(p):
 raw=subprocess.run(['/Users/benjaminlife/.local/bin/ffmpeg','-v','error','-i',str(p),'-ar','4000','-ac','1','-f','f32le','pipe:1'],capture_output=True,check=True).stdout
 return np.frombuffer(raw,dtype='<f4').astype(np.float64)
def match(x,r):
 r=r-r.mean();v=correlate(x,r,mode='valid',method='fft');en=np.r_[0,np.cumsum(x.astype(float)**2)];den=np.sqrt(np.maximum(en[len(r):]-en[:-len(r)],1e-20)*np.sum(r*r));scores=np.divide(v,den,out=np.zeros_like(v),where=den>1e-6);k=int(np.argmax(scores));return k/4000,float(np.clip(scores[k],-1,1))
first=pcm('/private/tmp/minutes-extended-speech/turn-00.wav');last=pcm('/private/tmp/minutes-extended-speech/turn-17.wav');trackstats=[]
for t in m['tracks']:
 x=pcm(d/t['file']);a,score=match(x[:4000*55],first);base=max(0,len(x)-4000*90);b,endscore=match(x[base:],last) if len(x)/4000 > gt['turns'][-1]['end'] else (None,None)
 trackstats.append({'source':t['source'],'sampleRate':t['sampleRate'],'channels':t['channels'],'frames':t['frameCount'],'segments':len(t['segments']),'rms':float(np.sqrt(np.mean(x*x))),'firstTurnCorrelation':score,'lastTurnCorrelation':endscore,'stimulusOffsetSeconds':a-gt['turns'][0]['start'],'startToEndOffsetDriftSeconds':None if b is None else base/4000+b-gt['turns'][-1]['start']-(a-gt['turns'][0]['start'])})
mixed=pcm(audio);start,score=match(mixed[:4000*55],first);offset=start-gt['turns'][0]['start']
rows=c.execute('select start,end,text,cluster_id from utterance where meeting_id=? order by start',(mid,)).fetchall()
clusters=c.execute('select id,label,speech_seconds,assignment,person_id from speaker_cluster where meeting_id=?',(mid,)).fetchall()
voices=sorted(set(t['voice'] for t in gt['turns']));labels=sorted(set(r[3] for r in rows));weights=np.zeros((len(voices),len(labels)));turns=[]
for t in gt['turns']:
 a=t['start']+offset;b=t['end']+offset;hits=[]
 for s,e,text,label in rows:
  overlap=max(0,min(b,e)-max(a,s))
  if overlap:
   weights[voices.index(t['voice']),labels.index(label)]+=overlap;hits.append((overlap,label))
 turns.append({'voice':t['voice'],'start':a,'end':b,'covered':bool(hits),'dominantCluster':max(hits)[1] if hits else None})
if weights.size:
 ii,jj=linear_sum_assignment(-weights);mapping={labels[j]:voices[i] for i,j in zip(ii,jj)};correct=sum(weights[i,j] for i,j in zip(ii,jj));total=float(weights.sum())
else:mapping={};correct=0;total=0
norm=lambda s:re.findall(r"[a-z0-9]+",s.lower())
ref=norm(' '.join(t['text'] for t in gt['turns']));hyp=norm(' '.join(r[2] for r in rows));prev=list(range(len(hyp)+1))
for i,a in enumerate(ref,1):
 cur=[i]
 for j,b in enumerate(hyp,1):cur.append(min(cur[-1]+1,prev[j]+1,prev[j-1]+(a!=b)))
 prev=cur
report={'meetingId':mid,'status':status,'completed':m['completed'],'issues':m['issues'],'durationSeconds':m['duration'],'sourceDurationSeconds':gt['duration'],'tracks':trackstats,'utterances':len(rows),'clusterCount':len(clusters),'identifiedPeople':sum(r[4] is not None for r in clusters),'turnsCovered':sum(t['covered'] for t in turns),'turnsExpected':len(turns),'matchedSpeakerTimeAccuracy':correct/total if total else None,'turnDominantSpeakerMatches':sum(mapping.get(t['dominantCluster'])==t['voice'] for t in turns),'referenceWordCount':len(ref),'recognizedWordCount':len(hyp),'normalizedWordErrorRate':prev[-1]/len(ref),'firstUtteranceStart':rows[0][0] if rows else None,'lastUtteranceEnd':rows[-1][1] if rows else None,'limits':'Controlled generated voices, no overlap. Speaker-time accuracy is measured on recognized utterance overlap, not benchmark DER or known-person identification.'}
(out/'long-capture-analysis.json').write_text(json.dumps(report,indent=2));print(json.dumps(report,indent=2))
