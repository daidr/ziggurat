#!/bin/sh
# Encodes the clips the system media engines play, with ffmpeg: H.264
# without B-frames, so that no edit list shifts their pictures' times, and
# AAC sound.
#
#   src/video/testdata/rgb.mp4   1.2 s at 10 fps, 64×48: 0.4 s red, green, blue; silent
#   examples/assets/trailer.mp4  6 s at 30 fps, 480×270: drifting colors and a tone
set -eu
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null 2>&1 || { echo "make-video-clips: ffmpeg with libx264 and the lavfi sources is required" >&2; exit 1; }
exact="-map_metadata -1 -fflags +bitexact -flags:v +bitexact -flags:a +bitexact"
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "color=c=red:s=64x48:r=10:d=0.4" -f lavfi -i "color=c=lime:s=64x48:r=10:d=0.4" -f lavfi -i "color=c=blue:s=64x48:r=10:d=0.4" \
  -f lavfi -i "anullsrc=r=44100:cl=mono" \
  -filter_complex "[0:v][1:v][2:v]concat=n=3:v=1:a=0,format=yuv420p[v]" -map "[v]" -map 3:a -t 1.2 \
  -c:v libx264 -profile:v baseline -bf 0 -g 10 -crf 18 -colorspace bt470bg -color_primaries bt470bg -color_trc smpte170m -color_range tv \
  -c:a aac -b:a 16k -shortest -movflags +faststart $exact \
  src/video/testdata/rgb.mp4
ffmpeg -hide_banner -loglevel error -y \
  -f lavfi -i "gradients=s=480x270:c0=0x0b1d3a:c1=0x3a7bd5:c2=0x00d2ff:c3=0x7b2ff7:nb_colors=4:speed=0.04:r=30:d=6,drawbox=x='210+150*sin(t*1.3)':y='105+70*cos(t*1.7)':w=60:h=60:color=white@0.6:t=fill" \
  -f lavfi -i "aevalsrc='0.15*sin(2*PI*(220+40*sin(t))*t)+0.08*sin(2*PI*330*t)*(0.5+0.5*sin(2*PI*t/3))':s=44100:d=6" \
  -c:v libx264 -profile:v main -bf 0 -pix_fmt yuv420p -crf 30 -g 30 -colorspace bt470bg -color_primaries bt470bg -color_trc smpte170m -color_range tv \
  -c:a aac -b:a 48k -ac 1 -shortest -movflags +faststart $exact \
  examples/assets/trailer.mp4
