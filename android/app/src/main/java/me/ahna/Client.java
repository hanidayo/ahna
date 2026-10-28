package me.ahna;

import org.json.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Explicit per-host credentials; redirects are never followed with a session cookie. */
public final class Client {
    public final JSONObject profile;
    public volatile JSONObject state;
    /** 상대 기기에서 이 연결을 해제함(인증 값이 더 이상 맞지 않음, 401). 다시 연결되면 false. */
    public volatile boolean revoked;
    public static final String REVOKED = "상대 기기에서 연결을 해제했습니다 · 다시 추가하세요";
    public Client(JSONObject profile){this.profile=profile;}
    public static URL endpoint(String address,String path)throws Exception {
        URI base=new URI(address.trim());String host=base.getHost();if(host==null||base.getUserInfo()!=null||base.getQuery()!=null||base.getFragment()!=null||!(base.getPath().isEmpty()||base.getPath().equals("/")))throw new IOException("기기의 주소만 입력하세요.");
        boolean local=host.equals("localhost")||host.endsWith(".local")||host.matches("10\\.(\\d{1,3}\\.){2}\\d{1,3}")||host.matches("192\\.168\\.\\d{1,3}\\.\\d{1,3}")||host.matches("172\\.(1[6-9]|2[0-9]|3[01])\\.\\d{1,3}\\.\\d{1,3}");
        if(!base.getScheme().equals("https"))throw new IOException("외부 연결에는 HTTPS 주소가 필요합니다.");
        URI target=base.resolve(path);if(!Objects.equals(target.getHost(),host)||!Objects.equals(target.getScheme(),base.getScheme())||target.getPort()!=base.getPort())throw new IOException("잘못된 주소입니다.");return target.toURL();
    }
    private HttpURLConnection connection(String path)throws Exception {
        HttpURLConnection c=(HttpURLConnection)endpoint(profile.getString("address"),path).openConnection();c.setInstanceFollowRedirects(false);c.setConnectTimeout(10000);c.setReadTimeout(60000);c.setUseCaches(false);
        if(profile.has("token"))c.setRequestProperty("Cookie","ahna="+profile.getString("token"));if(profile.has("computerID"))c.setRequestProperty("X-Ahna-Computer",profile.getString("computerID"));return c;
    }
    static String escape(String value)throws Exception{return URLEncoder.encode(value,"UTF-8").replace("+","%20");}
    private void check(HttpURLConnection c)throws Exception {int status=c.getResponseCode();if(status==401&&profile.has("token")){revoked=true;throw new IOException(REVOKED);}if(status<200||status>=300)throw new IOException(status==401?"연결 코드로 다시 인증해 주세요.":"요청 실패 ("+status+") · 상대 앱과 연결을 확인하세요.");}
    public JSONObject request(String path,JSONObject json)throws Exception {
        HttpURLConnection c=connection(path);try {if(json!=null){byte[] bytes=json.toString().getBytes(StandardCharsets.UTF_8);c.setRequestMethod("POST");c.setDoOutput(true);c.setFixedLengthStreamingMode(bytes.length);c.setRequestProperty("Content-Type","application/json");try(OutputStream out=c.getOutputStream()){out.write(bytes);}}
            check(c);if(path.equals("/api/pair")){String token=null;for(Map.Entry<String,List<String>> h:c.getHeaderFields().entrySet())if(h.getKey()!=null&&h.getKey().equalsIgnoreCase("Set-Cookie"))for(String value:h.getValue()){java.util.regex.Matcher match=java.util.regex.Pattern.compile("(?:^|,\\s*)ahna=([A-Za-z0-9_-]{32,256})(?:;|,|$)").matcher(value);if(match.find())token=match.group(1);}if(token==null)throw new IOException("잘못된 인증 응답입니다.");profile.put("token",token);String identity=c.getHeaderField("X-Ahna-Computer");if(identity!=null)profile.put("computerID",identity);}
            try(InputStream in=c.getInputStream()){ByteArrayOutputStream b=new ByteArrayOutputStream();byte[] buffer=new byte[8192];int n;while((n=in.read(buffer))>=0){if(b.size()+n>2*1024*1024)throw new IOException("응답이 너무 큽니다.");b.write(buffer,0,n);}return b.size()==0?new JSONObject():new JSONObject(Protocol.strictUTF8(b.toByteArray()));}
        }finally{c.disconnect();}
    }
    public void pair(String pin,String name)throws Exception {pair(pin,name,null);}
    /** own = this device's receiver identity (prefs "identity"); hosts use it to list this device once. Older hosts ignore it. */
    public void pair(String pin,String name,String own)throws Exception {pair(pin,name,own,null);}
    /**
     * reverse = 이 기기 쪽 연결(Protocol.reverseOffer). 함께 보내면 상대 앱이 이 기기를 추가한 기기로 저장합니다.
     * 상대가 저장했다고 답하면 true. 예전 앱은 이 값을 무시하고 false가 됩니다.
     */
    public boolean pair(String pin,String name,String own,JSONObject reverse)throws Exception {JSONObject body=new JSONObject().put("pin",pin.trim()).put("name",name).put("native",true).put("canReceive",true);String mine=Protocol.peerIdentity(own);if(!mine.isEmpty())body.put("computerID",mine);if(reverse!=null)body.put("reverse",reverse);JSONObject paired=request("/api/pair",body);String identity=paired.optString("computerID","");if(identity.matches("[a-fA-F0-9]{32}"))profile.put("computerID",identity);boolean accepted=reverse!=null&&paired.optBoolean("reverse",false);refresh(name,own);return accepted;}
    public void refresh(String name)throws Exception {refresh(name,null);}
    public void refresh(String name,String own)throws Exception {String mine=Protocol.peerIdentity(own);state=request("/api/state?receiving=true&deviceName="+escape(name)+(mine.isEmpty()?"":"&computerID="+mine),null);revoked=false;profile.put("hostName",state.optString("hostName","기기"));}
    public void send(File file,String name)throws Exception {HttpURLConnection c=connection("/api/upload?batch="+UUID.randomUUID()+"&path="+escape(Protocol.safeName(name)));try{if(file.length()>Protocol.MAX)throw new IOException("최대 4 GiB입니다.");c.setRequestMethod("POST");c.setDoOutput(true);c.setFixedLengthStreamingMode(file.length());c.setRequestProperty("Content-Type","application/octet-stream");try(InputStream in=new FileInputStream(file);OutputStream out=c.getOutputStream()){Protocol.copy(in,out,file.length());}check(c);}finally{c.disconnect();}}
    public void sendClipboard(String text)throws Exception {Protocol.validateText(text);byte[] bytes=text.getBytes(StandardCharsets.UTF_8);HttpURLConnection c=connection("/api/upload?batch="+UUID.randomUUID()+"&kind=clipboard");try{c.setRequestMethod("POST");c.setDoOutput(true);c.setFixedLengthStreamingMode(bytes.length);try(OutputStream out=c.getOutputStream()){out.write(bytes);}check(c);}finally{c.disconnect();}}
    public String clipboard(String id)throws Exception {if(!id.matches("[a-fA-F0-9]{32}"))throw new IOException("잘못된 글자 ID입니다.");HttpURLConnection c=connection("/api/download/"+id+"?kind=clipboard");try{check(c);try(InputStream in=c.getInputStream()){ByteArrayOutputStream b=new ByteArrayOutputStream();byte[] buffer=new byte[4096];int n;while((n=in.read(buffer))>=0){if(b.size()+n>65536)throw new IOException("글자가 너무 큽니다.");b.write(buffer,0,n);}String text=Protocol.strictUTF8(b.toByteArray());Protocol.validateText(text);return text;}}finally{c.disconnect();}}
    public void download(JSONObject item,File destination)throws Exception {String id=item.getString("id");long expected=item.getLong("bytes");if(!id.matches("[a-fA-F0-9]{32}")||expected<0||expected>Protocol.MAX)throw new IOException("잘못된 파일 정보입니다.");HttpURLConnection c=connection("/api/download/"+id);try{check(c);if(c.getContentLengthLong()!=expected)throw new IOException("파일 크기가 다릅니다.");try(InputStream in=c.getInputStream();OutputStream out=new FileOutputStream(destination)){Protocol.copy(in,out,expected);if(in.read()!=-1)throw new IOException("파일 크기가 다릅니다.");}}catch(Exception e){destination.delete();throw e;}finally{c.disconnect();}}
    public void receipt(String id)throws Exception {request("/api/received/"+id,new JSONObject().put("destination","files"));}
}
