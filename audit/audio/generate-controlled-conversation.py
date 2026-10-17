import subprocess,pathlib,wave,json,numpy as np
root=pathlib.Path('/private/tmp/minutes-extended-speech');root.mkdir(exist_ok=True)
lines=[
('Samantha','This is speaker Amber in a synthetic meeting. The observatory team will inspect the telescope on Tuesday. We will check the lens, compare the star charts, and write a short report. This sentence is generated for the recording test.'),
('Daniel','This is speaker Rowan responding in the synthetic meeting. The harbor team will inspect the lighthouse on Friday. We will check the beacon, compare the tide tables, and write a separate report. These are fictional plans for a controlled audio test.')]
parts=[np.zeros(16000*8,dtype='<i2')];turns=[];cursor=8
for n in range(18):
 voice,text=lines[n%2];text += ' This is test turn '+str(n+1)+'.'
 p=root/f'turn-{n:02}.wav'
 subprocess.run(['/usr/bin/say','-v',voice,'-r','160','--data-format=LEI16@16000','-o',str(p),text],check=True)
 with wave.open(str(p),'rb') as w:
  assert w.getnchannels()==1 and w.getframerate()==16000 and w.getsampwidth()==2
  x=np.frombuffer(w.readframes(w.getnframes()),dtype='<i2').copy()
 duration=len(x)/16000;turns.append({'voice':voice,'start':cursor,'end':cursor+duration,'text':text});parts.extend([x,np.zeros(16000*3,dtype='<i2')]);cursor+=duration+3
parts.append(np.zeros(16000*12,dtype='<i2'));audio=np.concatenate(parts)
out=root/'minutes-two-speaker-long.wav'
with wave.open(str(out),'wb') as w:
 w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(audio.tobytes())
manifest={'path':str(out),'duration':len(audio)/16000,'sampleRate':16000,'turns':turns}
(root/'ground-truth.json').write_text(json.dumps(manifest,indent=2))
pathlib.Path('audit-2026-10-14/extended-capture-evidence/generated-ground-truth.json').write_text(json.dumps(manifest,indent=2))
print(json.dumps({'path':str(out),'durationSeconds':manifest['duration'],'turns':len(turns),'voices':[a[0] for a in lines]}))
