"""Exact Android Java networking code against real HTTP + the real NAS relay.
No phone, Android clipboard, SAF provider, Apple frameworks or live NAS is used.
"""
import base64,hashlib,http.cookiejar,json,os,pathlib,queue,secrets,socket,subprocess,sys,tempfile,threading,time,unicodedata,urllib.request,urllib.error,urllib.parse
root=pathlib.Path(__file__).resolve().parents[2]
jdk=next((root/"jdk").glob("*/Contents/Home"));classes=root/"android/app/build/jvm-tests";classes.mkdir(parents=True,exist_ok=True)
java=jdk/"bin/java";javac=jdk/"bin/javac"
libs=[root/"json-test.jar"]+list((root/"android/app/libs").glob("*.jar"))
cp=os.pathsep.join(str(x) for x in libs)
sources=[root/'android/app/src/main/java/me/ahna'/name for name in ['Protocol.java','Client.java','RelayBridge.java']]+[root/'android/tests/ProtocolFixture.java']
args=['-encoding','UTF-8','--release','11','-cp',cp,'-d',str(classes)]+[str(x) for x in sources]
argfile=classes/'compile.args';argfile.write_text('\n'.join('"'+x.replace('\\','/')+'"' for x in args),encoding='utf-8')
subprocess.run([str(javac),'@'+str(argfile)],check=True)
checks=[];processes=[]
def check(ok,name):
 checks.append(dict(name=name,passed=bool(ok)))
 if not ok:raise AssertionError(name)
def port():
 with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
class Fixture:
 def __init__(self,directory,url=None,key=None):
  args=[str(java),'-cp',str(classes)+os.pathsep+cp,'me.ahna.ProtocolFixture',str(directory)]+([url,key] if url else [])
  self.p=subprocess.Popen(args,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf-8',creationflags=0);processes.append(self.p)
  self.info=json.loads(self.p.stdout.readline());self.base='http://localhost:'+str(self.info['port'])
 def command(self,**values):
  self.p.stdin.write(json.dumps(values)+'\n');self.p.stdin.flush();return json.loads(self.p.stdout.readline())
 def stop(self):
  if self.p.poll() is None:self.p.stdin.write('{"command":"stop"}\n');self.p.stdin.flush();self.p.wait(timeout=10)
def client():return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar(policy=http.cookiejar.DefaultCookiePolicy(secure_protocols=("http","https","wss")))),urllib.request.ProxyHandler({}))
def request(http,url,data=None,headers=None):
 if isinstance(data,dict):data=json.dumps(data).encode();headers={'Content-Type':'application/json',**(headers or {})}
 try:
  with http.open(urllib.request.Request(url,data=data,headers=headers or {}),timeout=30) as r:return r.status,r.read()
 except urllib.error.HTTPError as e:return e.code,e.read()
 except (OSError,__import__('http.client').client.HTTPException):return 0,b''
def pair(fixture,http,base=None):
 status,body=request(http,(base or fixture.base)+'/api/pair',dict(pin=fixture.info['pin'],name='테스트 iPhone',native=True,canReceive=True));check(status==200,'Native pairing succeeds');return json.loads(body)['id']
def upload(base,name):return base+'/api/upload?batch=87dd1c2c-071b-4d1e-9bc3-76c589056bff&path='+urllib.parse.quote(name)
def wait_ready(url,http):
 for _ in range(300):
  status,_=request(http,url)
  if status not in (0,502,503):return
  time.sleep(.1)
 raise AssertionError('relay startup')
try:
 with tempfile.TemporaryDirectory(prefix='Ahna-Android-tests-') as tmp:
  base=pathlib.Path(tmp);host=Fixture(base/'android');a=client();b=client();anonymous=client()
  check(request(anonymous,host.base+'/api/state')[0]==401,'State requires pairing')
  check(request(a,host.base+'/api/pair',dict(pin='000000',name='bad'))[0]==401,'Wrong code rejected')
  aid=pair(host,a);bid=pair(host,b)
  state=json.loads(request(a,host.base+'/api/state?receiving=true')[1]);check(state['platform']=='Android' and not state['owner'],'Android host implements iOS state schema')
  payload=secrets.token_bytes(2*1024*1024+13);sample=base/'sample.bin';sample.write_bytes(payload)
  filename=unicodedata.normalize('NFD','한글 사진 🐱.bin')
  check(request(a,upload(host.base,filename),payload)[0]==200,'iOS-style file upload accepted')
  check((base/'android'/unicodedata.normalize('NFC',filename)).read_bytes()==payload,'Korean NFC file content preserved')
  for name in ['../escape','a//b','a\\..\\b','bad:name','a/../x']:
   check(request(a,upload(host.base,name),b'bad')[0] not in range(200,300),'Unsafe path rejected: '+name)
  check(request(a,host.base+'/api/state',headers={'Origin':'https://untrusted.invalid'})[0]==403,'Cross-origin calls rejected')
  check(request(a,host.base+'/api/state',headers={'Host':'untrusted.invalid'})[0]==400,'DNS rebinding host rejected')
  queued=host.command(command='queue',file=str(sample),name='받을 파일.bin',target=aid)['id']
  check(request(a,host.base+'/api/download/'+queued)[1]==payload,'Host to phone file download preserves SHA-256')
  check(request(b,host.base+'/api/download/'+queued)[0]==404,'Other paired device cannot read file')
  check(request(b,host.base+'/api/received/'+queued,dict(destination='files'))[0]==404,'Other paired device cannot acknowledge file')
  check(request(a,host.base+'/api/received/'+queued,dict(destination='files'))[0]==200,'Phone saved receipt accepted')
  text='한글 🐱\r\n둘째 줄  '
  check(request(a,host.base+'/api/upload?kind=clipboard&batch=87dd1c2c-071b-4d1e-9bc3-76c589056bff',text.encode())[0]==200,'Phone clipboard reaches Android host')
  check(host.command(command='clipboard')['items'][0]['bytes']==len(text.encode()),'Clipboard uses UTF-8 byte length')
  host.command(command='clip',text=text,target=aid)
  clips=json.loads(request(a,host.base+'/api/state')[1])['clipboard'];clipid=clips[0]['id']
  check(request(a,host.base+'/api/download/'+clipid+'?kind=clipboard')[1].decode()==text,'Android clipboard reaches phone')
  check(request(b,host.base+'/api/download/'+clipid+'?kind=clipboard')[0]==404,'Clipboard isolated per paired device')
  check(request(a,host.base+'/api/upload?kind=clipboard&batch=87dd1c2c-071b-4d1e-9bc3-76c589056bff',b'x'*65537)[0] not in range(200,300),'Oversize clipboard rejected')
  for address in ['http://public.invalid','https://user:pass@a.test','https://a.test/path','https://a.test?q=1','https://a.test#fragment']:
   check(not host.command(command='url',address=address)['allowed'],'Client rejects unsafe origin: '+address)
  check(not host.command(command='url',address='http://192.168.1.23:45831')['allowed'],'NAS-only client rejects LAN HTTP')
  # Reuse session cookie against host restart at a new local endpoint.
  host.stop();restarted=Fixture(base/'android');restarted.base='http://localhost:'+str(restarted.info['port'])
  check(request(a,restarted.base+'/api/state?receiving=true')[0]==200,'Saved native session survives Android host restart')
 report=dict(checks=checks,passed=len(checks),actualAndroidDevice=False,actualIOSDevice=False,realNASRelayProcess=False,liveSynologyUsed=False)
 out=root/'verification/android-0.6.0-tests.json';out.write_text(json.dumps(report,ensure_ascii=False,indent=2),encoding='utf-8');print(json.dumps(dict(passed=len(checks),report=str(out)),ensure_ascii=False))
finally:
 for p in processes:
  if p.poll() is None:p.terminate()
 for p in processes:
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:p.kill()

