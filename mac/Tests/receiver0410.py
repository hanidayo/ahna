"""Protocol integration checks for the Mac receiver service; portable .NET host.
This does not execute macOS SwiftUI, Finder extensions or sandbox entitlements.
"""
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import queue
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

root=Path(__file__).resolve().parents[2]
checks=[]
def check(value,name):
    checks.append(dict(name=name,passed=bool(value)))
    if not value: raise AssertionError(name)
def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); return sock.getsockname()[1]
class Receiver:
    def __init__(self,directory,folder,key):
        self.port=port(); self.base=f'http://127.0.0.1:{self.port}'
        self.process=subprocess.Popen([sys.argv[1]],stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,text=True,encoding='utf-8',creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        self.events=queue.Queue()
        def read():
            for line in self.process.stdout:
                try: self.events.put(json.loads(line))
                except json.JSONDecodeError: pass
        threading.Thread(target=read,daemon=True).start()
        self.send(dict(dataPath=str(directory),savePath=str(folder),encryptionKey=key,port=self.port))
        self.status=self.event('status')
    def send(self,value):
        self.process.stdin.write(json.dumps(value)+'\n');self.process.stdin.flush()
    def event(self,kind):
        for _ in range(20):
            item=self.events.get(timeout=15)
            if item['type']==kind:return item
            if item['type']=='error':raise RuntimeError(item.get('message'))
        raise TimeoutError(kind)
    def close(self):
        if self.process.poll() is None:
            self.send(dict(command='stop'));self.process.stdin.close();self.process.wait(timeout=15)
        self.process.stdout.close()
def client(jar=None):return urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar if jar is not None else http.cookiejar.CookieJar()),urllib.request.ProxyHandler({}))
def request(http,url,data=None,json_body=False):
    if json_body:data=json.dumps(data).encode()
    req=urllib.request.Request(url,data=data,headers={'Content-Type':'application/json' if json_body else 'application/octet-stream'})
    try:
        with http.open(req,timeout=10) as response:return response.status,response.read()
    except urllib.error.HTTPError as error:return error.code,error.read()

receivers=[]
try:
    with tempfile.TemporaryDirectory(prefix='Ahna-MacReceiver-test-') as tmp:
        base=Path(tmp).resolve(); folder=base/'받은 파일'; data=base/'config'
        key=__import__('base64').b64encode(secrets.token_bytes(32)).decode()
        receiver=Receiver(data,folder,key);receivers.append(receiver)
        check(len(receiver.status['pin'])==6,'Mac receiver publishes a six-digit pairing code')
        check(receiver.status.get('clipboardSupported') is True,'Receiver advertises clipboard capability to native Mac UI')
        phone=client(); anonymous=client()
        check(request(anonymous,receiver.base+'/api/state')[0]==401,'Unpaired clients cannot inspect state')
        check(request(phone,receiver.base+'/api/pair',dict(pin='000000',name='Test iPhone',native=True),True)[0]==401,'Wrong pairing code is rejected')
        check(request(phone,receiver.base+'/api/pair',dict(pin=receiver.status['pin'],name='내 아이폰',native=True),True)[0]==200,'Existing iPhone native pairing protocol works with Mac receiver')
        before=json.loads(request(phone,receiver.base+'/api/state?receiving=false')[1])
        clipboard_text='Mac clipboard test · 한글 e\u0301 🐱\r\n 둘째 줄  '
        clipboard_url=receiver.base+'/api/upload?kind=clipboard&batch=1291586f-a2ac-4bc9-9158-aa3924ef51da'
        clip_code,clip_body=request(phone,clipboard_url,clipboard_text.encode('utf-8'))
        incoming_id=json.loads(clip_body)['id']
        check(clip_code==200 and not list(folder.iterdir()),'iPhone clipboard arrives without writing a received file')
        incoming_event=receiver.event('clipboardReceived')
        check(incoming_event['sender']=='내 아이폰' and 'text' not in incoming_event,'Native arrival event identifies sender without exposing text preview')
        for _ in range(10):
            snapshot=receiver.event('status')
            if any(item['id']==incoming_id for item in snapshot.get('clipboard',[])):break
        else:raise AssertionError('Clipboard metadata did not reach native host')
        check(snapshot['clipboard'][0]['id']==incoming_id and 'text' not in snapshot['clipboard'][0],'Native status exposes clipboard metadata without repeatedly streaming the body')
        check(any(item['id']==before['id'] for item in snapshot['devices']),'Native Mac host discovers the paired iPhone as a clipboard recipient')
        receiver.send(dict(command='clipboardRead',requestID='read-first',id=incoming_id))
        read=receiver.event('clipboardText')
        check(read['requestID']=='read-first' and read['text']==clipboard_text,'Native Mac copy request reads exact Unicode and line endings through IPC')
        receiver.send(dict(command='clipboardSend',requestID='send-first',target=before['id'],text=clipboard_text))
        sent=receiver.event('clipboardSent');outgoing_id=sent['id']
        phone_state=json.loads(request(phone,receiver.base+'/api/state')[1])
        check(sent['requestID']=='send-first' and phone_state['clipboard'][0]['id']==outgoing_id,'Native Mac paste-and-send command advertises text only to the selected iPhone')
        check(request(phone,receiver.base+'/api/download/'+outgoing_id+'?kind=clipboard')[1].decode('utf-8')==clipboard_text,'iPhone downloads Mac clipboard text with intact Unicode and whitespace')
        other=client();request(other,receiver.base+'/api/pair',dict(pin=receiver.status['pin'],name='Other iPad',native=True),True)
        check(request(other,receiver.base+'/api/download/'+outgoing_id+'?kind=clipboard')[0]==404,'Another paired device cannot read a clipboard addressed to the iPhone')
        check(request(phone,receiver.base+'/api/download/'+incoming_id+'?kind=clipboard')[0]==404,'Remote clients cannot read the Mac host clipboard inbox')
        receiver.send(dict(command='clipboardRead',requestID='wrong-inbox',id=outgoing_id))
        check(receiver.event('error')['requestID']=='wrong-inbox','Native read refuses a message from a different recipient inbox')
        receiver.send(dict(command='clipboardSend',requestID='too-big',target=before['id'],text='한'*22000))
        check(receiver.event('error')['requestID']=='too-big','IPC clipboard size is bounded by UTF-8 bytes')
        receiver.send(dict(command='clipboardSend',requestID='missing-device',target='missing',text='text'))
        check(receiver.event('error')['requestID']=='missing-device','IPC clipboard send errors preserve request correlation')
        receiver.send(dict(command='clipboardRead',requestID='read-after-error',id=incoming_id))
        check(receiver.event('clipboardText')['text']==clipboard_text,'Receiver continues serving clipboard requests after rejected input')
        check('Mac clipboard test' not in (data/'history.json').read_text(encoding='utf-8'),'Clipboard body is not persisted in transfer history')
        payload=b'Ahna Mac receiver\x00\xff'+secrets.token_bytes(65537)
        name='스크린샷 사진.png'; query=urllib.parse.urlencode(dict(batch='1291586f-a2ac-4bc9-9158-aa3924ef51da',path=unicodedata.normalize('NFD',name)))
        check(request(phone,receiver.base+'/api/upload?'+query,payload)[0]==200,'iPhone upload endpoint saves a file on the Mac receiver')
        check(hashlib.sha256((folder/name).read_bytes()).digest()==hashlib.sha256(payload).digest(),'Received content and composed Korean filename are intact')
        check(request(phone,receiver.base+'/api/upload?'+query,b'next')[0]==200 and (folder/'스크린샷 사진 (1).png').read_bytes()==b'next','Duplicate Korean names keep both files')
        attack=urllib.parse.urlencode(dict(batch='1291586f-a2ac-4bc9-9158-aa3924ef51da',path='../escape.txt'))
        check(request(phone,receiver.base+'/api/upload?'+attack,b'bad')[0]==400 and not (base/'escape.txt').exists(),'Unsafe paths cannot escape the receive folder')
        custom=base/'내가 고른 폴더';synthetic_secret='synthetic-nas-key-'+secrets.token_hex(8)
        receiver.send(dict(command='configure',savePath=str(custom),remoteEnabled=False,remoteUrl='',remoteKey=synthetic_secret))
        receiver.event('saved')
        check(request(phone,receiver.base+'/api/upload?'+urllib.parse.urlencode(dict(batch='1291586f-a2ac-4bc9-9158-aa3924ef51da',path='moved.txt')),b'moved')[0]==200 and (custom/'moved.txt').read_bytes()==b'moved','Folder selection redirects the next upload immediately')
        settings=(data/'settings.json').read_text(encoding='utf-8')
        check(synthetic_secret not in settings and 'mac1:' in settings,'NAS key is stored encrypted with the application-provided key')
        receiver.close()
        restored=Receiver(data,custom,key);receivers.append(restored)
        after=json.loads(request(phone,restored.base+'/api/state?receiving=false')[1])
        check(after['id']==before['id'] and after['name']==before['name'],'Restart preserves the iPhone identity without entering a new PIN')
        check(restored.status['savePath']==str(custom),'Selected folder is retained after restart')
        check(restored.status['clipboard']==[] and after['clipboard']==[],'Restart clears clipboard bodies while preserving the existing pairing')
        result=dict(success=True,checks=checks,portableProtocolExecuted=True,macOSExecutionTested=False,finderExtensionTested=False)
except Exception as error:
    result=dict(success=False,checks=checks,error=str(error),macOSExecutionTested=False)
finally:
    for receiver in receivers:
        try:receiver.close()
        except Exception:receiver.process.kill()
    report=Path(sys.argv[2]) if len(sys.argv)>2 else root/'verification/mac-receiver-0.4.10-tests.json'
    report.parent.mkdir(parents=True,exist_ok=True)
    report.write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print(json.dumps(dict(success=result['success'],checks=len(checks),error=result.get('error')),ensure_ascii=True))
raise SystemExit(0 if result['success'] else 1)
