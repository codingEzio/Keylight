#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
work=$(mktemp -d "${TMPDIR:-/tmp}/keylight-icon-test.XXXXXX")
cleanup() { status=$?; if [ "$status" -eq 0 ]; then rm -rf "$work"; else printf 'Retained diagnostic fixture: %s\n' "$work" >&2; fi; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
python3 - "$work" <<'PY'
import json, pathlib, plistlib, struct, sys, zlib
root=pathlib.Path(sys.argv[1]); catalog=root/'Fixture.xcassets'; images=catalog/'AppIcon.imageset'; images.mkdir(parents=True)
app=root/'Chroma.app'/'Contents'; (app/'Resources').mkdir(parents=True)
with (app/'Info.plist').open('wb') as f: plistlib.dump({'CFBundleName':'Chroma','CFBundleIdentifier':'test.chroma','CFBundleIconName':'AppIcon'},f)
def chunk(kind,data): return struct.pack('!I',len(data))+kind+data+struct.pack('!I',zlib.crc32(kind+data)&0xffffffff)
def png(path,rgb):
    row=b'\0'+bytes(rgb)*64; data=zlib.compress(row*64)
    path.write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('!IIBBBBB',64,64,8,2,0,0,0))+chunk(b'IDAT',data)+chunk(b'IEND',b''))
png(images/'light.png',(227,55,40)); png(images/'dark.png',(21,182,90))
(catalog/'Contents.json').write_text(json.dumps({'info':{'author':'xcode','version':1}}))
(images/'Contents.json').write_text(json.dumps({'images':[{'filename':'light.png','idiom':'universal','scale':'1x'},{'filename':'dark.png','idiom':'universal','scale':'1x','appearances':[{'appearance':'luminosity','value':'dark'}]}],'info':{'author':'xcode','version':1}}))
PY
xcrun actool --compile "$work/Chroma.app/Contents/Resources" --platform macosx --minimum-deployment-target 26.0 --output-format human-readable-text "$work/Fixture.xcassets" >"$work/actool.log" 2>&1 || { cat "$work/actool.log" >&2; exit 1; }
swiftc -module-cache-path "$work/module-cache" Sources/AppIcons.swift Tests/AssetIconSmoke.swift -o "$work/check"
"$work/check" "$work/Chroma.app"
