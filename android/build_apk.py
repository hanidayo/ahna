"""Build without Gradle downloads. Requires JDK 17+ and official SDK 35/build-tools 35.
Usage: python build_apk.py --jdk PATH --sdk PATH --keystore PATH --alias ahna
AHNA_KEY_PASSWORD supplies the existing signing password; never commit the key.
"""
import argparse, os, pathlib, shutil, subprocess, zipfile
p=argparse.ArgumentParser();p.add_argument('--jdk',required=True);p.add_argument('--sdk',required=True);p.add_argument('--keystore',required=True);p.add_argument('--alias',default='ahna');a=p.parse_args()
root=pathlib.Path(__file__).resolve().parent; build=root/'app/build/manual';build.mkdir(parents=True,exist_ok=True)
jdk=pathlib.Path(a.jdk).resolve();sdk=pathlib.Path(a.sdk).resolve()
suffix='.exe' if os.name=='nt' else '';batch='.bat' if os.name=='nt' else ''
java=jdk/'bin'/('java'+suffix)
android=next(p for p in sdk.rglob('android.jar') if p.parent.name=='android-35')
tools=next((p.parent for p in sdk.rglob('aapt2'+suffix) if p.parent.name=='35.0.0'),None) or next(sdk.rglob('aapt2'+suffix)).parent
env=os.environ.copy();env['JAVA_HOME']=str(jdk);env['PATH']=str(jdk/'bin')+os.pathsep+env.get('PATH','')
def run(args):subprocess.run([os.path.relpath(x) if isinstance(x,pathlib.Path) else str(x) for x in args],check=True,env=env)
run([tools/('aapt2'+suffix),'compile','--dir',root/'app/src/main/res','-o',build/'resources.zip'])
run([tools/('aapt2'+suffix),'link','-o',build/'base.apk','-I',android,'--manifest',root/'app/src/main/AndroidManifest.xml','--min-sdk-version','29','--target-sdk-version','35','--version-code','10001','--version-name','1.0.1','-A',root/'app/src/main/assets',build/'resources.zip'])
classes=build/'classes'
assert classes.resolve().is_relative_to((root/'app/build').resolve())
if classes.exists():shutil.rmtree(classes)
classes.mkdir()
sources=list((root/'app/src/main/java').rglob('*.java'))
# javac argument files avoid the Windows command-line limit and preserve paths with spaces.
def quote(s):return '"'+str(s).replace('\\','/').replace('"','\\"')+'"'
libs=list((root/'app/libs').glob('*.jar'))
args=['-encoding','UTF-8','--release','11','-classpath',os.pathsep.join(str(x) for x in [android]+libs),'-d',str(classes)]+[str(x) for x in sources]
argfile=build/'javac.args';argfile.write_text('\n'.join(quote(x) for x in args),encoding='utf-8')
run([jdk/'bin'/('javac'+suffix),'@'+str(argfile)])
classjar=build/'classes.jar'
with zipfile.ZipFile(classjar,'w') as z:
 for f in classes.rglob('*.class'):z.write(f,f.relative_to(classes).as_posix())
run([java,'-cp',tools/'lib/d8.jar','com.android.tools.r8.D8','--release','--min-api','29','--lib',android,'--output',build,classjar]+libs)
shutil.copy2(build/'base.apk',build/'unsigned.apk')
with zipfile.ZipFile(build/'unsigned.apk','a',zipfile.ZIP_DEFLATED) as z:
 for f in build.glob('classes*.dex'):z.write(f,f.name)
run([tools/('zipalign'+suffix),'-f','4',build/'unsigned.apk',build/'aligned.apk'])
apk=build/'Ahna-1.0.1-Android.apk'
run([java,'-jar',tools/'lib/apksigner.jar','sign','--ks',a.keystore,'--ks-key-alias',a.alias,'--ks-pass','env:AHNA_KEY_PASSWORD','--key-pass','env:AHNA_KEY_PASSWORD','--out',apk,build/'aligned.apk'])
run([java,'-jar',tools/'lib/apksigner.jar','verify','--verbose','--print-certs',apk])
run([tools/('zipalign'+suffix),'-c','4',apk])
print('APK:',apk)
