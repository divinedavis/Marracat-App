import subprocess
segs=[(7.5,9.5,1),(16,18,1),(21,26,2),(30,32,1),(34,37,2),(38.5,40.5,1),(58,64,3),(64,65.5,1),(70,75,2.5),(103,104.5,1),(108,113,2.5),(134,135.5,1),(140,145,2.5),(146,148.5,1)]
f=[];labels=[]
for i,(a,b,s) in enumerate(segs):
    f.append(f"[0:v]trim={a}:{b},setpts=(PTS-STARTPTS)/{s}[v{i}]")
    labels.append(f"[v{i}]")
f.append("".join(labels)+f"concat=n={len(segs)}:v=1:a=0[v]")
print(sum((b-a)/s for a,b,s in segs))
subprocess.run(["ffmpeg","-v","error","-y","-i","cfr.mp4","-f","lavfi","-i","anullsrc=channel_layout=stereo:sample_rate=44100",
 "-filter_complex",";".join(f),"-map","[v]","-map","1:a","-shortest","-c:v","libx264","-profile:v","high","-level","4.0","-pix_fmt","yuv420p","-b:v","10M","-r","30",
 "-c:a","aac","-b:a","256k","-movflags","+faststart","preview.mp4"],check=True)
