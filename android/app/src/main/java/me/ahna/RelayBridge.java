package me.ahna;

import org.java_websocket.client.WebSocketClient;
import org.java_websocket.handshake.ServerHandshake;
import org.java_websocket.drafts.Draft_6455;
import org.json.*;
import javax.net.ssl.SSLParameters;
import java.io.*;
import java.net.*;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Consumer;

/** Outbound-only NAS bridge. The NAS still applies its existing route allowlist. */
public final class RelayBridge implements Closeable {
    final Protocol host;
    final URI origin;
    final String key;
    final Consumer<String> status;
    final ScheduledExecutorService supervisor=Executors.newSingleThreadScheduledExecutor();
    final ExecutorService jobs=Executors.newFixedThreadPool(4);
    final Set<Channel> active=ConcurrentHashMap.newKeySet();
    volatile Channel control;
    volatile boolean closed;
    /** 서버가 보낸 알림(action: limit·message·rejoin·blocked, text) */
    volatile java.util.function.BiConsumer<String,String> notice;
    public RelayBridge(Protocol host,String address,String key,Consumer<String> status)throws Exception {this(host,address,key,status,false);}
    public static URI validate(String address,String key,boolean test)throws Exception {
        URI uri=new URI(address.trim());if(!(("https".equals(uri.getScheme()))||(test&&"http".equals(uri.getScheme())&&"localhost".equals(uri.getHost())))||uri.getHost()==null||uri.getUserInfo()!=null||uri.getQuery()!=null||uri.getFragment()!=null||!(uri.getPath().isEmpty()||uri.getPath().equals("/"))||!(Brand.isMemberToken(key)||key.matches("[a-fA-F0-9]{64,256}")))throw new IOException("서버 HTTPS 주소와 64자리 이상의 연결 키를 확인하세요.");
        return uri;
    }
    public RelayBridge(Protocol host,String address,String key,Consumer<String> status,boolean test)throws Exception {
        URI uri=validate(address,key,test);
        this.host=host;this.origin=uri;this.key=key;this.status=status;supervisor.execute(this::connect);supervisor.scheduleAtFixedRate(()->{Channel c=control;if(c!=null&&c.isOpen())c.send("{\"type\":\"ping\"}");else if(!closed)connect();},15,15,TimeUnit.SECONDS);
    }
    URI endpoint(String path)throws Exception{return new URI("https".equals(origin.getScheme())?"wss":"ws",null,origin.getHost(),origin.getPort(),path,null,null);}
    void connect(){if(closed)return;try {Channel old=control;if(old!=null){old.close();active.remove(old);}Map<String,String> headers=auth();headers.put("X-Ahna-Computer",host.identity);headers.put("X-Ahna-Features","notice");headers.put("X-Ahna-Platform","Android");try{headers.put("X-Ahna-Name",URLEncoder.encode(host.name==null?"":host.name,"UTF-8").replace("+","%20"));}catch(Exception ignored){}byte[] hash=MessageDigest.getInstance("SHA-256").digest(host.pin.getBytes(StandardCharsets.UTF_8));StringBuilder hex=new StringBuilder();for(byte b:hash)hex.append(String.format(Locale.ROOT,"%02X",b));headers.put("X-Ahna-Pin-Hash",hex.toString());Channel c=new Channel(endpoint("/_bridge/control"),headers);control=c;active.add(c);if(!c.connectBlocking(15,TimeUnit.SECONDS))throw new IOException();c.send("{\"type\":\"ping\"}");status.accept("서버 연결됨 · 원격 전송 가능");jobs.execute(()->{try{while(!closed&&c.isOpen()){JSONObject message=c.controlJSON();if("notice".equals(message.optString("type"))){java.util.function.BiConsumer<String,String> n=notice;if(n!=null)n.accept(message.optString("action"),message.optString("text"));continue;}String id=message.getString("id");if(!id.matches("[a-f0-9]{32}"))throw new IOException();jobs.execute(()->handle(id));}}catch(Exception ignored){}finally{c.close();active.remove(c);if(!closed)status.accept("서버 재연결 대기");}});}catch(Exception e){status.accept("서버 재연결 대기 · 주소·연결 키·인증서를 확인하세요.");}}
    Map<String,String> auth(){Map<String,String> h=new HashMap<>();h.put("Authorization","Bearer "+key);return h;}
    static boolean allowed(String method,String path){String p=path.split("\\?",2)[0];if(path.length()>4096||!path.startsWith("/")||path.startsWith("//")||path.contains("#")||path.contains("\\"))return false;
        // 아나 1.2 게스트 경로 /s/{cid}/{token}[/info|/status|/file/N|/decline|/request|/upload] — server/Common/Wire.cs와 같은 목록
        if(p.startsWith("/s/"))return Protocol.guestAllowed(method,p);
        return method.equals("GET")&&(p.equals("/api/state")||p.matches("/api/download/[a-fA-F0-9]{32}"))||method.equals("POST")&&(Arrays.asList("/api/pair","/api/upload","/api/logout").contains(p)||p.matches("/api/received/[a-fA-F0-9]{32}"));}
    /** 큰 본문(최대 4 GiB)을 받을 수 있는 경로: 기존 /api/upload와 게스트 올리기(/s/…/upload) */
    static boolean largeBody(String path){String p=path.split("\\?",2)[0];if(p.equals("/api/upload"))return true;String[] g=Protocol.guestParts(p);return g!=null&&g[2].equals("upload");}
    void handle(String id){Channel c=null;try{c=new Channel(endpoint("/_bridge/data/"+id),auth());active.add(c);if(!c.connectBlocking(15,TimeUnit.SECONDS))return;JSONObject h=c.json(45);String method=h.getString("Method"),path=h.getString("Path");long length=h.getLong("Length");String cookie=h.optString("Cookie",""),type=h.optString("ContentType","application/octet-stream");
        if(!allowed(method,path)||length<0||length>Protocol.MAX||(!largeBody(path)&&length>16384)||cookie.contains("\r")||cookie.contains("\n")||type.contains("\r")||type.contains("\n")){c.send(new JSONObject().put("Status",400).put("Length",0).toString());c.json(45);return;}
        try(Socket local=new Socket(host.loopbackAddress(),host.port())){local.setSoTimeout(60000);OutputStream out=new BufferedOutputStream(local.getOutputStream());InputStream in=new BufferedInputStream(local.getInputStream());out.write((method+" "+path+" HTTP/1.1\r\nHost: 127.0.0.1:"+host.port()+"\r\nConnection: close\r\nContent-Length: "+length+"\r\nCookie: "+cookie+"\r\nContent-Type: "+type+"\r\n\r\n").getBytes(StandardCharsets.US_ASCII));out.flush();c.send("{\"Status\":100}");long left=length;while(left>0){byte[] bytes=c.binary(60);if(bytes.length==0||bytes.length>left)throw new IOException();out.write(bytes);left-=bytes.length;}out.flush();
            String[] first=Protocol.line(in,8192).split(" ");int code=Integer.parseInt(first[1]);JSONObject headers=new JSONObject();long responseLength=-1;int headerBytes=0;for(;;){String line=Protocol.line(in,8192);headerBytes+=line.length();if(headerBytes>32768)throw new IOException();if(line.isEmpty())break;int p=line.indexOf(':');String k=line.substring(0,p),value=line.substring(p+1).trim();if(k.equalsIgnoreCase("Content-Length"))responseLength=Long.parseLong(value);if(Arrays.asList("content-type","set-cookie","content-disposition","x-ahna-computer","content-security-policy","referrer-policy","cache-control").contains(k.toLowerCase(Locale.ROOT)))headers.put(k,new JSONArray().put(value));}
            if(responseLength<0||responseLength>Protocol.MAX)throw new IOException();c.send(new JSONObject().put("Status",code).put("Length",responseLength).put("Headers",headers).toString());byte[] buffer=new byte[65536];left=responseLength;while(left>0){int n=in.read(buffer,0,(int)Math.min(buffer.length,left));if(n<0)throw new EOFException();while(c.hasBufferedData()){if(!c.isOpen())throw new EOFException();Thread.sleep(5);}c.send(Arrays.copyOf(buffer,n));left-=n;}if(!c.json(60).optBoolean("received"))throw new IOException();
        }
    }catch(Exception ignored){}finally{if(c!=null){c.close();active.remove(c);}}}
    static final class Channel extends WebSocketClient {
        final BlockingQueue<Object> incoming=new ArrayBlockingQueue<>(8);
        Channel(URI uri,Map<String,String> headers){super(uri,new Draft_6455(Collections.emptyList(),65536),headers,15000);setConnectionLostTimeout(40);}
        @Override protected void onSetSSLParameters(SSLParameters params){params.setEndpointIdentificationAlgorithm("HTTPS");}
        public void onOpen(ServerHandshake h){}
        public void onMessage(String value){if(value.length()>32768||!incoming.offer(value))close();}
        public void onMessage(ByteBuffer value){byte[] bytes=new byte[value.remaining()];value.get(bytes);try{if(bytes.length>65536||!incoming.offer(bytes,60,TimeUnit.SECONDS))close();}catch(InterruptedException e){Thread.currentThread().interrupt();close();}}
        public void onClose(int code,String reason,boolean remote){incoming.offer(new IOException("서버 연결 종료"));}
        public void onError(Exception e){incoming.offer(new IOException("서버 연결 오류"));}
        Object next(int seconds)throws Exception{Object value=incoming.poll(seconds,TimeUnit.SECONDS);if(value==null||value instanceof Exception)throw new IOException("서버 응답 대기 시간 초과");return value;}
        // No application request is expected while idle. WebSocket ping/pong and
        // onClose/onError detect a broken transport independently of this queue.
        JSONObject controlJSON()throws Exception {
            while(isOpen()) {
                Object value=incoming.poll(1,TimeUnit.SECONDS);
                if(value==null)continue;
                if(value instanceof Exception)throw (Exception)value;
                if(!(value instanceof String))throw new IOException("Invalid control message");
                return new JSONObject((String)value);
            }
            throw new IOException("서버 연결 종료");
        }
        JSONObject json(int seconds)throws Exception{Object value=next(seconds);if(!(value instanceof String))throw new IOException();return new JSONObject((String)value);}
        byte[] binary(int seconds)throws Exception{Object value=next(seconds);if(!(value instanceof byte[]))throw new IOException();return (byte[])value;}
    }
    @Override public void close(){closed=true;for(Channel c:active)c.close();supervisor.shutdownNow();jobs.shutdownNow();}
}
