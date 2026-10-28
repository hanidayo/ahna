package me.ahna;

import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.*;
import java.nio.file.*;
import java.security.SecureRandom;
import java.text.Normalizer;
import java.time.Instant;
import java.util.*;
import java.util.concurrent.*;

/** The same length-delimited, cookie-authenticated protocol as the desktop host. */
public final class Protocol implements Closeable {
    public static final long MAX = 4L * 1024 * 1024 * 1024;
    public interface Store { String load(); void save(String value); }
    public interface Listener { void received(File file, String name) throws Exception; void changed(); }
    /** 한 번의 코드 입력으로 양쪽 연결: 이 기기와 연결한 기기가 넘겨준 그 기기 쪽 연결을 저장하면 true. */
    public interface ReverseListener { boolean accept(JSONObject credential) throws Exception; }
    /** 없으면 예전처럼 한쪽만 연결합니다(상대 기기는 응답의 reverse=false로 알고 자기 쪽 연결을 지웁니다). */
    public volatile ReverseListener reverseListener;
    public final String identity;
    public volatile String name;
    public volatile String pin = String.valueOf(100000 + new SecureRandom().nextInt(900000));
    private final File root;
    private final Store store;
    private final Listener listener;
    private final Map<String, Peer> peers = new ConcurrentHashMap<>();
    private final Map<String, Item> items = new ConcurrentHashMap<>();
    private final Map<String, JSONObject> clips = new ConcurrentHashMap<>();
    private final Map<String, String> clipText = new ConcurrentHashMap<>();
    private final ThreadPoolExecutor workers = new ThreadPoolExecutor(0, 8, 30, TimeUnit.SECONDS, new SynchronousQueue<>());
    private final Set<Socket> sockets = ConcurrentHashMap.newKeySet();
    private final Semaphore uploads = new Semaphore(2);
    private ServerSocket server;
    /** 이 기기가 상대를 추가하는 동안 미리 만들어 둔 상대용 연결: 유효하지만 목록·저장에는 아직 넣지 않습니다. */
    private final Set<String> reserved = ConcurrentHashMap.newKeySet();
    private long attemptWindow;
    private int attempts;
    static final class Peer {
        String id, name; long seen, receiver;
        /** The paired device's own receiver identity when its app reports it ("" for 1.0.x apps). */
        String computerID = "";
        Peer(String id, String name, long seen) { this.id=id; this.name=name; this.seen=seen; }
    }
    static final class Item {
        String id, name, target; File file; long created=System.currentTimeMillis();
        Item(String id,String name,String target,File file) {this.id=id;this.name=name;this.target=target;this.file=file;}
    }
    public Protocol(File root, String identity, String name, Store store, Listener listener) throws Exception {
        this.root=root;this.identity=identity;this.name=name;this.store=store;this.listener=listener;
        if(!root.isDirectory()&&!root.mkdirs())throw new IOException("저장 공간을 준비하지 못했습니다.");
        for(File f:Objects.requireNonNull(root.listFiles())) if(f.getName().startsWith("part-")||f.getName().startsWith("queue-"))f.delete();
        try { JSONArray saved=new JSONArray(store.load()); for(int i=0;i<saved.length();i++) {JSONObject p=saved.getJSONObject(i); if(System.currentTimeMillis()-p.getLong("seen")<30L*86400000){Peer peer=new Peer(p.getString("id"),p.getString("name"),p.getLong("seen"));peer.computerID=peerIdentity(p.optString("peerComputerID",""));peers.put(p.getString("token"),peer);}} } catch(Exception ignored) {}
    }
    public synchronized void start(int port) throws IOException {
        if(server!=null)return;
        server=new ServerSocket(); server.setReuseAddress(true);server.bind(new InetSocketAddress(java.net.InetAddress.getByAddress(new byte[]{127,0,0,1}),port),8);
        ServerSocket active=server;
        Thread thread=new Thread(()->{while(!active.isClosed())try { Socket s=active.accept();s.setSoTimeout(60000);sockets.add(s);try{workers.execute(()->handle(s));}catch(RejectedExecutionException e){sockets.remove(s);s.close();}}catch(IOException ignored){}},"아나 receiver");
        thread.setDaemon(true);thread.start();
    }
    public java.net.InetAddress loopbackAddress(){return server.getInetAddress();}
    public int port(){return server==null?0:server.getLocalPort();}
    private synchronized void persist() throws Exception {
        JSONArray a=new JSONArray();for(Map.Entry<String,Peer> e:peers.entrySet()){if(reserved.contains(e.getKey()))continue;Peer p=e.getValue();a.put(new JSONObject().put("token",e.getKey()).put("id",p.id).put("name",p.name).put("computerID",identity).put("peerComputerID",p.computerID).put("seen",p.seen));}store.save(a.toString());
    }
    /** Every paired device (not only the ones receiving now), so the app can merge and delete them. */
    public synchronized JSONArray peers() throws Exception {
        JSONArray a=new JSONArray();long now=System.currentTimeMillis();for(Map.Entry<String,Peer> e:peers.entrySet()){if(reserved.contains(e.getKey()))continue;Peer p=e.getValue();a.put(new JSONObject().put("id",p.id).put("name",p.name).put("computerID",p.computerID).put("online",now-p.receiver<40000));}return a;
    }
    /** Drops these paired devices (and any other pairing of the same device identity) on this side. */
    public synchronized void forget(Collection<String> ids) throws Exception {
        Set<String> identities=new HashSet<>();for(Peer p:peers.values())if(ids.contains(p.id)&&!p.computerID.isEmpty())identities.add(p.computerID);
        peers.values().removeIf(p->ids.contains(p.id)||identities.contains(p.computerID));persist();listener.changed();
    }
    /**
     * 상대 기기를 추가할 때 함께 보낼 상대용 연결을 만듭니다(/api/pair와 같은 토큰 형식·만료·저장).
     * address = 이 기기가 연결된 NAS HTTPS 주소. 주소가 올바르지 않거나 연결이 너무 많으면 null. 끝나면 completeReverse.
     */
    public synchronized JSONObject reverseOffer(String address) throws Exception {
        String origin=nasOrigin(address);if(origin==null||peers.size()>=100)return null;
        String token=uuid()+uuid();Peer p=new Peer(uuid(),"기기",System.currentTimeMillis());
        reserved.add(token);peers.put(token,p);
        return new JSONObject().put("address",origin).put("computerID",identity).put("token",token).put("name",cleanName(name,"Android"));
    }
    /** 상대가 받아 저장했으면 유지하고(이름·ID 반영, 같은 기기의 예전 연결은 교체), 아니면 지웁니다. */
    public synchronized void completeReverse(String token,boolean accepted,String peerName,String peerComputerID) throws Exception {
        if(token==null||!reserved.remove(token))return;
        Peer p=peers.get(token);if(!accepted||p==null){peers.remove(token);return;}
        p.name=cleanName(peerName,p.name);
        String reported=peerIdentity(peerComputerID);
        if(!reported.isEmpty()){p.computerID=reported;peers.entrySet().removeIf(e->!e.getKey().equals(token)&&e.getValue().computerID.equals(reported));}
        persist();listener.changed();
    }
    /** 받은 상대 기기 쪽 연결 검사. 형식이 하나라도 맞지 않으면 null(예전처럼 한쪽만 연결). */
    static JSONObject reverseCredential(JSONObject input) throws Exception {
        if(input==null)return null;
        String address=nasOrigin(input.optString("address",""));String id=input.optString("computerID","").trim();String token=input.optString("token","").trim();
        if(address==null||!id.matches("[0-9a-fA-F]{32}")||!token.matches("[A-Za-z0-9_-]{32,256}"))return null;
        return new JSONObject().put("address",address).put("computerID",id.toLowerCase(Locale.ROOT)).put("token",token).put("name",cleanName(input.optString("name",""),"기기"));
    }
    /** NAS HTTPS 주소(경로·질의·계정 정보 없음)를 끝의 / 없이 돌려줍니다. */
    static String nasOrigin(String value){
        try{URI u=new URI(value==null?"":value.trim());if(!"https".equalsIgnoreCase(u.getScheme())||u.getHost()==null||u.getHost().isEmpty()||u.getRawUserInfo()!=null||u.getRawQuery()!=null||u.getRawFragment()!=null)return null;
            String path=u.getRawPath();if(path!=null&&!path.isEmpty()&&!path.equals("/"))return null;return "https://"+u.getRawAuthority();}catch(Exception e){return null;}
    }
    static String cleanName(String value,String fallback){String v=(value==null?"":value).replaceAll("\\p{Cntrl}","").trim();if(v.length()>40)v=v.substring(0,40).trim();return v.isEmpty()?fallback:v;}
    static String peerIdentity(String value){String v=value==null?"":value.trim();return v.matches("[0-9a-fA-F]{32}")?v.toLowerCase(Locale.ROOT):"";}
    public synchronized JSONArray nearby() throws Exception {
        JSONArray a=new JSONArray();long now=System.currentTimeMillis();for(Peer p:peers.values())if(now-p.receiver<40000)a.put(new JSONObject().put("id",p.id).put("name",p.name).put("computerID",identity));return a;
    }
    public String queue(File source,String displayName,String target) throws Exception {
        if(peers.values().stream().noneMatch(p->p.id.equals(target)&&System.currentTimeMillis()-p.receiver<40000))throw new IOException("받을 기기에서 아나를 열어 주세요.");
        if(source.length()>MAX)throw new IOException("파일 한 개는 최대 4 GiB입니다.");
        prune();if(items.size()>=100)throw new IOException("전송 대기 파일이 많습니다. 연결을 초기화하거나 잠시 후 보내세요.");
        String id=uuid();File file=new File(root,"queue-"+id);try { Files.copy(source.toPath(),file.toPath());items.put(id,new Item(id,safeName(displayName),target,file)); }catch(Exception e){file.delete();throw e;}listener.changed();return id;
    }
    public void sendClipboard(String text,String target) throws Exception { validateText(text);if(peers.values().stream().noneMatch(p->p.id.equals(target)&&System.currentTimeMillis()-p.receiver<40000))throw new IOException("받을 기기가 오프라인입니다.");storeClip(text,name,target); }
    private synchronized void storeClip(String text,String sender,String target) throws Exception {
        prune();String id=uuid();clipText.put(id,text);clips.put(id,new JSONObject().put("id",id).put("sender",sender).put("bytes",text.getBytes(StandardCharsets.UTF_8).length).put("created",Instant.now().toString()).put("target",target));
        List<String> same=new ArrayList<>();for(Map.Entry<String,JSONObject> e:clips.entrySet())if(e.getValue().optString("target").equals(target))same.add(e.getKey());same.sort(Comparator.comparing(i->clips.get(i).optString("created")));while(same.size()>20){String oldest=same.remove(0);clips.remove(oldest);clipText.remove(oldest);}
        if(clips.size()>100){String oldest=clips.entrySet().stream().min(Comparator.comparing(e->e.getValue().optString("created"))).get().getKey();clips.remove(oldest);clipText.remove(oldest);}listener.changed();
    }
    public JSONArray clipboard() throws Exception {return clipboard("host");}
    private JSONArray clipboard(String target) throws Exception {JSONArray a=new JSONArray();for(JSONObject c:clips.values())if(c.getString("target").equals(target))a.put(new JSONObject().put("id",c.getString("id")).put("sender",c.getString("sender")).put("bytes",c.getInt("bytes")).put("created",c.getString("created")));return a;}
    public String clipboardText(String id){JSONObject c=clips.get(id);return c!=null&&c.optString("target").equals("host")?clipText.get(id):null;}
    public synchronized void revoke() throws Exception {synchronized(tickets){for(String t:new ArrayList<>(tickets.keySet()))closeTicket(t,"expired");}publishTickets();peers.clear();clips.clear();clipText.clear();for(Item i:items.values())i.file.delete();items.clear();pin=String.valueOf(100000+new SecureRandom().nextInt(900000));persist();listener.changed();}
    private synchronized void prune() {long cutoff=System.currentTimeMillis()-86400000;for(Item i:items.values())if(i.created<cutoff&&items.remove(i.id,i))i.file.delete();for(String id:new ArrayList<>(clips.keySet()))try{if(Instant.parse(clips.get(id).getString("created")).toEpochMilli()<cutoff){clips.remove(id);clipText.remove(id);}}catch(Exception ignored){} }
    static String uuid(){return UUID.randomUUID().toString().replace("-","");}
    public static String safeName(String raw) throws IOException {
        String name=Normalizer.normalize(raw,Normalizer.Form.NFC);
        if(name.isEmpty()||name.length()>240||name.equals(".")||name.equals("..")||name.matches(".*[\\\\/:*?\"<>|\\p{Cntrl}].*")||name.endsWith(".")||name.endsWith(" "))throw new IOException("올바르지 않은 파일 이름입니다.");return name;
    }
    static void validateText(String text)throws IOException {if(text.isEmpty()||text.indexOf(0)>=0||text.getBytes(StandardCharsets.UTF_8).length>65536)throw new IOException("글자는 1~64 KB까지 보낼 수 있습니다.");}
    static String strictUTF8(byte[] data)throws Exception {return StandardCharsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).decode(java.nio.ByteBuffer.wrap(data)).toString();}
    static String line(InputStream in,int max)throws IOException {ByteArrayOutputStream b=new ByteArrayOutputStream();int previous=-1;while(b.size()<max){int c=in.read();if(c<0)throw new EOFException();if(c==10&&previous==13){byte[] a=b.toByteArray();return new String(a,0,a.length-1,StandardCharsets.US_ASCII);}b.write(c);previous=c;}throw new IOException("header too long");}
    static byte[] body(InputStream in,long size,int max)throws IOException {if(size<0||size>max)throw new IOException("body too large");ByteArrayOutputStream b=new ByteArrayOutputStream();copy(in,b,size);return b.toByteArray();}
    static void copy(InputStream in,OutputStream out,long length)throws IOException {byte[] buffer=new byte[65536];while(length>0){int n=in.read(buffer,0,(int)Math.min(buffer.length,length));if(n<0)throw new EOFException();out.write(buffer,0,n);length-=n;}}
    private void reply(OutputStream out,int status,byte[] content,String extra)throws IOException {reply(out,status,content,"application/json; charset=utf-8",extra);}
    private void reply(OutputStream out,int status,byte[] content,String type,String extra)throws IOException {String h="HTTP/1.1 "+status+" 아나\r\nContent-Length: "+content.length+"\r\nContent-Type: "+type+"\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Ahna-Computer: "+identity+"\r\n"+extra+"\r\n";out.write(h.getBytes(StandardCharsets.US_ASCII));out.write(content);out.flush();}
    private void json(OutputStream out,int status,JSONObject value,String extra)throws IOException {reply(out,status,value.toString().getBytes(StandardCharsets.UTF_8),extra);}
    private void handle(Socket socket) {
        try(Socket s=socket;InputStream in=new BufferedInputStream(s.getInputStream());OutputStream out=new BufferedOutputStream(s.getOutputStream())) {
            String[] first=line(in,8192).split(" ");if(first.length!=3)return;
            String method=first[0];URI uri=new URI(first[1]);if(uri.isAbsolute()||uri.getRawPath()==null)return;
            Map<String,String> headers=new HashMap<>();int total=0;for(;;){String l=line(in,8192);total+=l.length();if(total>32768)return;if(l.isEmpty())break;int p=l.indexOf(':');if(p<1)return;String key=l.substring(0,p).toLowerCase(Locale.ROOT);if(headers.put(key,l.substring(p+1).trim())!=null)return;}
            if(headers.containsKey("origin")||headers.containsKey("transfer-encoding")||"cross-site".equals(headers.get("sec-fetch-site"))){reply(out,403,new byte[0],"");return;}
            String host=headers.getOrDefault("host","").replaceFirst(":\\d+$","");if(!(host.equals("localhost")||host.matches("\\d{1,3}(\\.\\d{1,3}){3}"))){reply(out,400,new byte[0],"");return;}
            long length=Long.parseLong(headers.getOrDefault("content-length","0"));if(length<0||length>MAX){reply(out,413,new byte[0],"");return;}
            Map<String,String> query=new HashMap<>();if(uri.getRawQuery()!=null)for(String part:uri.getRawQuery().split("&")){String[] kv=part.split("=",2);String key=URLDecoder.decode(kv[0],"UTF-8");if(query.put(key,kv.length<2?"":URLDecoder.decode(kv[1],"UTF-8"))!=null){reply(out,400,new byte[0],"");return;}}
            String path=uri.getPath();
            // 게스트 경로(/s/…): 인증 쿠키 없이 1회용 토큰이 권한입니다(근처 기기 · QR).
            if(path.startsWith("/s/")){guest(method,path,query,headers,length,in,out);return;}
            if(path.equals("/api/pair")&&method.equals("POST")) {
                synchronized(this){long now=System.currentTimeMillis();if(now-attemptWindow>60000){attemptWindow=now;attempts=0;}if(++attempts>60||peers.size()>=100){reply(out,429,new byte[0],"");return;}}
                JSONObject input=new JSONObject(strictUTF8(body(in,length,16384)));if(!pin.equals(input.optString("pin"))){reply(out,401,new byte[0],"");return;}
                String label=input.optString("name","기기").trim();if(label.isEmpty()||label.length()>40||label.matches(".*[\\p{Cntrl}].*")){reply(out,400,new byte[0],"");return;}
                String token=uuid()+uuid();Peer p=new Peer(uuid(),label,System.currentTimeMillis());if(input.optBoolean("canReceive",true))p.receiver=p.seen;p.computerID=peerIdentity(input.optString("computerID",""));
                // Pairing again from the same device replaces its earlier pairing, so it is listed once.
                if(!p.computerID.isEmpty())peers.values().removeIf(old->old.computerID.equals(p.computerID));peers.put(token,p);persist();
                // 상대가 자기 쪽 연결도 넘겨줬으면 이 기기에서도 그 기기를 추가한 것으로 저장합니다(예전 앱은 보내지 않음).
                boolean reverse=false;ReverseListener accept=reverseListener;
                if(accept!=null&&input.optBoolean("native",false)){JSONObject credential=reverseCredential(input.optJSONObject("reverse"));if(credential!=null&&!credential.getString("computerID").equals(identity))try{reverse=accept.accept(credential);}catch(Exception ignored){reverse=false;}}
                json(out,200,new JSONObject().put("id",p.id).put("name",p.name).put("computerID",identity).put("reverse",reverse),"Set-Cookie: ahna="+token+"; Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000\r\n");listener.changed();return;
            }
            String token="";for(String cookie:headers.getOrDefault("cookie","").split(";"))if(cookie.trim().startsWith("ahna="))token=cookie.trim().substring(5);
            Peer peer=peers.get(token);if(peer==null||System.currentTimeMillis()-peer.seen>30L*86400000){reply(out,401,new byte[0],"");return;}peer.seen=System.currentTimeMillis();
            if(path.equals("/api/state")&&method.equals("GET")) {
                if(query.containsKey("deviceName")){String label=query.get("deviceName").trim();if(label.isEmpty()||label.length()>40||label.matches(".*[\\p{Cntrl}].*")){reply(out,400,new byte[0],"");return;}if(!label.equals(peer.name)){peer.name=label;persist();}}
                String reported=peerIdentity(query.get("computerID"));if(!reported.isEmpty()&&!reported.equals(peer.computerID)){peer.computerID=reported;persist();}
                if(!query.containsKey("receiving")||query.get("receiving").equals("true"))peer.receiver=peer.seen;
                prune();JSONArray files=new JSONArray();for(Item item:items.values())if(item.target.equals(peer.id))files.put(new JSONObject().put("id",item.id).put("name",item.name).put("bytes",item.file.length()).put("target",item.target));
                json(out,200,new JSONObject().put("id",peer.id).put("name",peer.name).put("hostName",name).put("platform","Android").put("computerID",identity).put("owner",false).put("items",files).put("devices",new JSONArray()).put("history",new JSONArray()).put("clipboard",clipboard(peer.id)).put("maxFile",MAX).put("maxClipboardBytes",65536),"");listener.changed();return;
            }
            if(path.equals("/api/logout")&&method.equals("POST")){peers.remove(token);persist();reply(out,200,new byte[0],"");return;}
            if(path.equals("/api/upload")&&method.equals("POST")) {
                if(!headers.containsKey("content-length")){reply(out,411,new byte[0],"");return;}
                try{UUID.fromString(query.getOrDefault("batch",""));}catch(Exception e){reply(out,400,new byte[0],"");return;}
                if(query.getOrDefault("kind","").equals("clipboard")){String text=strictUTF8(body(in,length,65536));validateText(text);storeClip(text,peer.name,"host");json(out,200,new JSONObject().put("id",uuid()),"");return;}
                String raw=query.getOrDefault("path","");String[] components=raw.replace('\\','/').split("/",-1);for(String c:components)safeName(c);String display=safeName(components[components.length-1]);
                if(!uploads.tryAcquire()){reply(out,429,new byte[0],"");return;}
                File part=new File(root,"part-"+uuid());try {if(length>root.getUsableSpace()-8*1024*1024)throw new IOException("저장 공간이 부족합니다.");try(OutputStream f=new FileOutputStream(part)){copy(in,f,length);}listener.received(part,display);json(out,200,new JSONObject().put("name",display).put("bytes",length),"");}finally{part.delete();uploads.release();}return;
            }
            if(path.startsWith("/api/download/")&&method.equals("GET")) {
                String id=path.substring(14);if(query.getOrDefault("kind","").equals("clipboard")){JSONObject c=clips.get(id);if(c==null||!c.optString("target").equals(peer.id)){reply(out,404,new byte[0],"");return;}reply(out,200,clipText.get(id).getBytes(StandardCharsets.UTF_8),"");return;}
                prune();Item item=items.get(id);if(item==null||!item.target.equals(peer.id)){reply(out,404,new byte[0],"");return;}
                out.write(("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: "+item.file.length()+"\r\nConnection: close\r\nCache-Control: no-store\r\nX-Ahna-Computer: "+identity+"\r\n\r\n").getBytes(StandardCharsets.US_ASCII));try(InputStream f=new FileInputStream(item.file)){copy(f,out,item.file.length());}out.flush();return;
            }
            if(path.startsWith("/api/received/")&&method.equals("POST")){Item item=items.get(path.substring(14));if(item==null||!item.target.equals(peer.id)){reply(out,404,new byte[0],"");return;}JSONObject receipt=new JSONObject(strictUTF8(body(in,length,4096)));if(!Arrays.asList("files","photos").contains(receipt.optString("destination"))){reply(out,400,new byte[0],"");return;}reply(out,200,new byte[0],"");listener.changed();return;}
            reply(out,404,new byte[0],"");
        }catch(Exception ignored){}finally{sockets.remove(socket);}
    }
    // =====================================================================================
    // 아나 1.2 게스트 티켓 (근처 기기 · QR) — ios/Ahna/MobileHost.swift와 같은 규약
    // 경로 /s/{이 기기 ID}/{1회용 토큰}[/info|/status|/file/N|/decline|/request|/upload]
    // 티켓은 메모리에만 있고 10분 뒤 사라집니다. 상태: ready · waiting · accepted · transferring · done · declined · expired
    // =====================================================================================

    public static final long TICKET_LIFETIME = 600_000L;
    /** 웹 페이지(assets/guest.html)와 끝난 링크 페이지. 앱이 시작할 때 넣어 줍니다. */
    public volatile String guestHtml = "", guestGoneHtml = "";
    static final String GUEST_POLICY = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; img-src 'self' blob: data:; media-src blob:; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";
    public interface GuestListener {
        /** 티켓 상태가 바뀜(아무 스레드) */
        void ticketsChanged();
        /** QR로 받기: 웹 페이지에서 [보내기]를 누름. 주인이 answerGuest로 답합니다. */
        void guestRequested(Ticket ticket);
        /** 게스트가 올린 파일 한 개(임시 파일, 돌아오면 지워짐). */
        void guestReceived(File file, String name, String sender) throws Exception;
    }
    public volatile GuestListener guestListener;
    public static final class GuestFile {
        public final String name; public final long bytes; final File file;
        GuestFile(String name, long bytes, File file) { this.name = name; this.bytes = bytes; this.file = file; }
    }
    /** 티켓. 밖에서는 snapshot()으로 받은 복사본만 읽습니다. */
    public static final class Ticket {
        public final String token, kind; public String state, code, sender = "";
        public final long created, expires; public List<GuestFile> files;
        final Set<Integer> done = new HashSet<>(); long requested, activity, closed;
        Ticket(String token, String kind, String code, List<GuestFile> files) {
            this.token = token; this.kind = kind; this.code = code; this.files = files; this.state = "ready";
            created = System.currentTimeMillis(); expires = created + TICKET_LIFETIME; activity = created;
        }
        public int completed() { return done.size(); }
        public long total() { long t = 0; for (GuestFile f : files) t += f.bytes; return t; }
        public boolean finished() { return state.equals("done") || state.equals("declined") || state.equals("expired"); }
        Ticket copy() { return new Ticket(this); }
        private Ticket(Ticket o) {
            token = o.token; kind = o.kind; code = o.code; files = new ArrayList<>(o.files); state = o.state; sender = o.sender;
            created = o.created; expires = o.expires; done.addAll(o.done); requested = o.requested; activity = o.activity; closed = o.closed;
        }
    }
    private final Map<String, Ticket> tickets = new HashMap<>();
    private ScheduledExecutorService ticker;

    /** 32바이트 난수 base64url(43자) */
    static String ticketToken() {
        byte[] b = new byte[32]; new SecureRandom().nextBytes(b);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(b);
    }
    static boolean validTicketToken(String v) { return v != null && v.length() >= 22 && v.length() <= 64 && v.matches("[A-Za-z0-9_-]+"); }
    /** "/s/{cid}/{token}[/나머지]" → {cid, token, 나머지}. 형식이 다르면 null. 질의 없이 경로만 넘기세요. */
    static String[] guestParts(String path) {
        if (path == null) return null;
        String[] pieces = path.split("/", -1);
        if (pieces.length < 4 || !pieces[0].isEmpty() || !pieces[1].equals("s") || !pieces[2].matches("[0-9a-f]{32}") || !validTicketToken(pieces[3])) return null;
        StringBuilder rest = new StringBuilder();
        for (int i = 4; i < pieces.length; i++) { if (i > 4) rest.append('/'); rest.append(pieces[i]); }
        return new String[]{pieces[2], pieces[3], rest.toString()};
    }
    /** 서버 중계가 넘겨도 되는 게스트 요청인지(server/Common/Wire.cs GuestAllowed와 같은 목록) */
    static boolean guestAllowed(String method, String path) {
        String[] p = guestParts(path);
        if (p == null) return false;
        String rest = p[2];
        if (method.equals("GET")) {
            if (rest.isEmpty() || rest.equals("info") || rest.equals("status")) return true;
            if (rest.startsWith("file/")) { String n = rest.substring(5); return n.matches("[0-9]{1,3}") && (n.length() == 1 || n.charAt(0) != '0'); }
            return false;
        }
        return method.equals("POST") && (rest.equals("decline") || rest.equals("request") || rest.equals("upload"));
    }
    /** 게스트 링크에서 보낼 파일을 둘 자리(시작할 때 지워지는 queue- 이름). */
    public File guestStaging() { return new File(root, "queue-guest-" + uuid()); }
    public List<Ticket> tickets() { synchronized (tickets) { List<Ticket> a = new ArrayList<>(); for (Ticket t : tickets.values()) a.add(t.copy()); a.sort(Comparator.comparingLong(t -> t.created)); return a; } }
    public Ticket ticket(String token) { synchronized (tickets) { Ticket t = token == null ? null : tickets.get(token); return t == null ? null : t.copy(); } }
    private void publishTickets() { GuestListener l = guestListener; if (l != null) try { l.ticketsChanged(); } catch (Exception ignored) {} }
    /** 티켓을 끝냅니다: 파일·권한은 바로 지우고, 상태만 2분 동안 남겨 상대 페이지와 이 기기 화면이 결과를 볼 수 있게 합니다. (tickets 잠금 안에서) */
    private void closeTicket(String token, String state) {
        Ticket t = tickets.get(token);
        if (t == null || t.closed != 0) return;
        List<GuestFile> kept = new ArrayList<>();
        for (GuestFile f : t.files) { if (f.file != null) f.file.delete(); kept.add(new GuestFile(f.name, f.bytes, null)); }
        t.files = kept; t.state = state; t.closed = System.currentTimeMillis();
    }
    /** (tickets 잠금 안에서) 바뀐 것이 있으면 true */
    private boolean pruneTickets() {
        long now = System.currentTimeMillis(); boolean changed = false;
        for (Ticket t : new ArrayList<>(tickets.values())) {
            if (t.closed != 0) { if (now - t.closed > 120_000) { tickets.remove(t.token); changed = true; } continue; }
            // 주인이 30초 안에 답하지 않은 받기 요청은 거절(앱 화면도 30초에 자동 거절합니다)
            if (t.state.equals("waiting") && t.requested != 0 && now - t.requested > 40_000) { closeTicket(t.token, "declined"); changed = true; continue; }
            // 만료: 전송 중이면 마지막 활동 뒤 2분까지 기다립니다.
            if (now >= t.expires && !(t.state.equals("transferring") && now - t.activity < 120_000)) { closeTicket(t.token, "expired"); changed = true; }
        }
        return changed;
    }
    private synchronized void startTicker() {
        if (ticker != null) return;
        ticker = Executors.newSingleThreadScheduledExecutor(r -> { Thread t = new Thread(r, "아나 티켓"); t.setDaemon(true); return t; });
        ticker.scheduleAtFixedRate(() -> { boolean changed; synchronized (tickets) { changed = pruneTickets(); } if (changed) publishTickets(); }, 1, 1, TimeUnit.SECONDS);
    }
    /**
     * 티켓을 만듭니다. kind = "send"(staged 파일을 보냄, 이름과 짝) 또는 "receive"(파일 없음). code는 2자리 숫자 또는 null.
     * staged 파일은 guestStaging()으로 만든 이 앱 안의 복사본이어야 하고, 티켓이 끝나면 지워집니다.
     */
    public Ticket createTicket(String kind, List<File> staged, List<String> names, String code) throws Exception {
        List<GuestFile> files = new ArrayList<>();
        Ticket copy;
        try {
            if (kind.equals("send")) {
                if (staged.isEmpty() || staged.size() > 200 || staged.size() != names.size()) throw new IOException("한 번에 200개까지 보낼 수 있습니다.");
                for (int i = 0; i < staged.size(); i++) {
                    File f = staged.get(i);
                    if (f.length() > MAX) throw new IOException("파일 한 개는 최대 4 GiB입니다.");
                    files.add(new GuestFile(safeName(names.get(i)), f.length(), f));
                }
            } else if (!kind.equals("receive")) throw new IOException("올바르지 않은 공유입니다.");
            synchronized (tickets) {
                pruneTickets();
                int open = 0; for (Ticket t : tickets.values()) if (t.closed == 0) open++;
                if (open >= 8) throw new IOException("진행 중인 공유가 너무 많습니다. 잠시 뒤 다시 시도하세요.");
                Ticket t = new Ticket(ticketToken(), kind, code, files);
                tickets.put(t.token, t);
                copy = t.copy();
            }
            startTicker();
            publishTickets();
            return copy;
        } catch (Exception e) {
            if (staged != null) for (File f : staged) f.delete();
            throw e;
        }
    }
    /** 이 기기에서 공유를 취소합니다(QR 창 닫기 · 보내기 취소 · 30초 무응답). */
    public void cancelTicket(String token, String state) {
        synchronized (tickets) { Ticket t = tickets.get(token); if (t == null || t.closed != 0) return; closeTicket(token, state); }
        publishTickets();
    }
    /** QR로 받기 요청에 대한 주인의 답 */
    public void answerGuest(String token, boolean accept) {
        synchronized (tickets) {
            Ticket t = tickets.get(token);
            if (t == null || t.closed != 0 || !t.kind.equals("receive") || !t.state.equals("waiting")) return;
            if (accept) { t.state = "accepted"; t.activity = System.currentTimeMillis(); } else closeTicket(token, "declined");
        }
        publishTickets();
    }
    private static String percent(String name) {
        StringBuilder b = new StringBuilder();
        for (byte x : name.getBytes(StandardCharsets.UTF_8)) {
            int c = x & 0xFF;
            if (c < 128 && (Character.isLetterOrDigit(c) || "!#$&+-.^_`|~".indexOf(c) >= 0)) b.append((char) c);
            else b.append('%').append(String.format(Locale.ROOT, "%02X", c));
        }
        return b.toString();
    }
    private void guestJson(OutputStream out, int status, JSONObject value) throws IOException { json(out, status, value, ""); }
    private void guest(String method, String path, Map<String, String> query, Map<String, String> headers, long length, InputStream in, OutputStream out) throws Exception {
        String[] parts = guestParts(path);
        Ticket ticket;
        synchronized (tickets) { if (pruneTickets()) publishTickets(); ticket = parts == null || !parts[0].equals(identity) ? null : tickets.get(parts[1]); }
        // 맞지 않는 토큰은 늘 404
        if (!guestAllowed(method, path) || ticket == null) { reply(out, 404, new byte[0], ""); return; }
        String rest = parts[2], token = ticket.token;
        if (method.equals("GET") && length != 0) { reply(out, 400, new byte[0], ""); return; }
        if (method.equals("GET") && rest.isEmpty()) {
            boolean closed; synchronized (tickets) { closed = ticket.closed != 0; }
            String page = closed ? guestGoneHtml : guestHtml;
            reply(out, closed ? 404 : 200, page.getBytes(StandardCharsets.UTF_8), "text/html; charset=utf-8", "Content-Security-Policy: " + GUEST_POLICY + "\r\n" + (closed ? "" : "Referrer-Policy: no-referrer\r\n"));
            return;
        }
        if (method.equals("GET") && (rest.equals("info") || rest.equals("status"))) {
            JSONObject r = new JSONObject();
            synchronized (tickets) {
                long remaining = Math.max(0, (ticket.expires - System.currentTimeMillis()) / 1000);
                if (rest.equals("info")) {
                    JSONArray files = new JSONArray();
                    for (int i = 0; i < ticket.files.size(); i++) files.put(new JSONObject().put("i", i).put("name", ticket.files.get(i).name).put("bytes", ticket.files.get(i).bytes));
                    r.put("v", 1).put("kind", ticket.kind).put("owner", name).put("state", ticket.state).put("expiresIn", ticket.closed == 0 ? remaining : 0)
                            .put("code", ticket.code == null ? JSONObject.NULL : ticket.code).put("files", files).put("completed", ticket.done.size());
                } else {
                    r.put("state", ticket.state).put("code", ticket.code == null ? JSONObject.NULL : ticket.code).put("expiresIn", ticket.closed == 0 ? remaining : 0).put("completed", ticket.done.size());
                }
            }
            guestJson(out, 200, r);
            return;
        }
        if (method.equals("GET") && rest.startsWith("file/")) {
            int index = Integer.parseInt(rest.substring(5));
            GuestFile file;
            synchronized (tickets) {
                if (ticket.closed != 0 || !ticket.kind.equals("send") || index < 0 || index >= ticket.files.size() || ticket.files.get(index).file == null) file = null;
                else {
                    file = ticket.files.get(index);
                    if (ticket.state.equals("ready")) ticket.state = "transferring";
                    ticket.activity = System.currentTimeMillis();
                }
            }
            if (file == null) { reply(out, 404, new byte[0], ""); return; }
            publishTickets();
            long size = file.file.length();
            try (InputStream f = new FileInputStream(file.file)) {
                out.write(("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: " + size + "\r\nContent-Disposition: attachment; filename*=UTF-8''" + percent(file.name) + "\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Ahna-Computer: " + identity + "\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
                byte[] buffer = new byte[65536]; long left = size;
                while (left > 0) {
                    int n = f.read(buffer, 0, (int) Math.min(buffer.length, left));
                    if (n < 0) throw new EOFException();
                    out.write(buffer, 0, n); left -= n;
                    synchronized (tickets) { ticket.activity = System.currentTimeMillis(); }
                }
                out.flush();
            }
            // 끝까지 보냈을 때만 셉니다. 모든 파일을 한 번 이상 보내면 완료.
            synchronized (tickets) {
                if (ticket.closed == 0) {
                    ticket.done.add(index); ticket.activity = System.currentTimeMillis();
                    if (ticket.done.size() >= ticket.files.size()) closeTicket(token, "done");
                }
            }
            publishTickets();
            return;
        }
        if (method.equals("POST") && rest.equals("upload")) {
            if (!headers.containsKey("content-length")) { reply(out, 411, new byte[0], ""); return; }
            int index; String display;
            try { index = Integer.parseInt(query.getOrDefault("i", "")); display = safeName(query.getOrDefault("name", "")); }
            catch (Exception e) { reply(out, 400, new byte[0], ""); return; }
            synchronized (tickets) {
                if (ticket.closed != 0 || !ticket.kind.equals("receive") || !(ticket.state.equals("accepted") || ticket.state.equals("transferring"))) { reply(out, 409, new byte[0], ""); return; }
                if (index < 0 || index >= ticket.files.size() || ticket.done.contains(index) || !display.equals(ticket.files.get(index).name) || length != ticket.files.get(index).bytes) { reply(out, 400, new byte[0], ""); return; }
                ticket.state = "transferring"; ticket.activity = System.currentTimeMillis();
            }
            if (!uploads.tryAcquire()) { reply(out, 429, new byte[0], ""); return; }
            File part = new File(root, "part-" + uuid());
            try {
                if (length > root.getUsableSpace() - 8 * 1024 * 1024) throw new IOException("저장 공간이 부족합니다.");
                try (OutputStream f = new FileOutputStream(part)) {
                    byte[] buffer = new byte[65536]; long left = length;
                    while (left > 0) {
                        int n = in.read(buffer, 0, (int) Math.min(buffer.length, left));
                        if (n < 0) throw new EOFException();
                        f.write(buffer, 0, n); left -= n;
                        synchronized (tickets) { ticket.activity = System.currentTimeMillis(); }
                    }
                }
                String sender;
                synchronized (tickets) {
                    if (ticket.closed != 0 || ticket.done.contains(index)) { reply(out, 409, new byte[0], ""); return; }
                    sender = ticket.sender;
                }
                GuestListener l = guestListener;
                if (l != null) l.guestReceived(part, display, sender); else listener.received(part, display);
                String state;
                synchronized (tickets) {
                    ticket.done.add(index); ticket.activity = System.currentTimeMillis();
                    if (ticket.done.size() >= ticket.files.size()) closeTicket(token, "done");
                    state = ticket.state;
                }
                publishTickets();
                guestJson(out, 200, new JSONObject().put("name", display).put("bytes", length).put("state", state));
            } finally { part.delete(); uploads.release(); }
            return;
        }
        // 나머지 POST(decline · request)는 작은 JSON 본문
        if (length > 16384) { reply(out, 413, new byte[0], ""); return; }
        byte[] body = body(in, length, 16384);
        if (rest.equals("decline")) {
            synchronized (tickets) {
                if (ticket.closed != 0 || !ticket.kind.equals("send")) { reply(out, 409, new byte[0], ""); return; }
                closeTicket(token, "declined");
            }
            publishTickets();
            guestJson(out, 200, new JSONObject().put("state", "declined"));
            return;
        }
        if (rest.equals("request")) {
            JSONObject input;
            try { input = new JSONObject(strictUTF8(body)); } catch (Exception e) { reply(out, 400, new byte[0], ""); return; }
            String sender = cleanName(input.optString("name", ""), "웹 브라우저");
            JSONArray list = input.optJSONArray("files");
            if (list == null || list.length() < 1 || list.length() > 200) { reply(out, 400, new byte[0], ""); return; }
            List<GuestFile> files = new ArrayList<>();
            for (int i = 0; i < list.length(); i++) {
                JSONObject item = list.optJSONObject(i);
                long bytes = item == null ? -1 : item.optLong("bytes", -1);
                if (item == null || bytes < 0 || bytes > MAX) { reply(out, 400, new byte[0], ""); return; }
                try { files.add(new GuestFile(safeName(item.optString("name", "")), bytes, null)); } catch (IOException e) { reply(out, 400, new byte[0], ""); return; }
            }
            String code = String.valueOf(10 + new SecureRandom().nextInt(90));
            Ticket copy;
            synchronized (tickets) {
                if (ticket.closed != 0 || !ticket.kind.equals("receive") || !ticket.state.equals("ready")) { reply(out, 409, new byte[0], ""); return; }
                ticket.files = files; ticket.sender = sender; ticket.code = code; ticket.state = "waiting";
                ticket.requested = System.currentTimeMillis(); ticket.activity = ticket.requested;
                copy = ticket.copy();
            }
            publishTickets();
            GuestListener l = guestListener;
            if (l != null) try { l.guestRequested(copy); } catch (Exception ignored) {}
            guestJson(out, 200, new JSONObject().put("state", "waiting").put("code", code));
            return;
        }
        reply(out, 404, new byte[0], "");
    }
    @Override public synchronized void close() throws IOException {if(ticker!=null)ticker.shutdownNow();if(server!=null){server.close();server=null;}for(Socket socket:sockets)try{socket.close();}catch(IOException ignored){}workers.shutdownNow();try{persist();}catch(Exception ignored){}}
}
