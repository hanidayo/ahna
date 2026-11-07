package me.ahna;
import java.io.*;
import java.nio.file.*;
import org.json.*;

/** Desktop JVM harness around the exact APK protocol/client/relay sources. */
public class ProtocolFixture {
 public static void main(String[] args)throws Exception {
  System.setOut(new java.io.PrintStream(System.out,true,"UTF-8"));
  File root=new File(args[0]);root.mkdirs();File state=new File(root,"sessions.json");
  Protocol server=new Protocol(new File(root,"cache"),"aabbccddeeff00112233445566778899","테스트 Android",new Protocol.Store(){public String load(){try{return Files.readString(state.toPath());}catch(Exception e){return "[]";}}public void save(String text){try{Files.writeString(state.toPath(),text);}catch(Exception e){throw new RuntimeException(e);}}},new Protocol.Listener(){public void received(File file,String name)throws Exception{Files.copy(file.toPath(),new File(root,name).toPath(),StandardCopyOption.REPLACE_EXISTING);}public void changed(){}});
  server.start(0);RelayBridge bridge=null;
  if(args.length>2)bridge=new RelayBridge(server,args[1],args[2],s->System.err.println(s),true);
  System.out.println(new JSONObject().put("port",server.port()).put("bindAddress",server.loopbackAddress().getHostAddress()).put("pin",server.pin));System.out.flush();
  try(BufferedReader reader=new BufferedReader(new InputStreamReader(System.in,java.nio.charset.StandardCharsets.UTF_8))){String line;while((line=reader.readLine())!=null){try{JSONObject input=new JSONObject(line);String cmd=input.getString("command");JSONObject result=new JSONObject();
   if(cmd.equals("queue"))result.put("id",server.queue(new File(input.getString("file")),input.getString("name"),input.getString("target")));
   else if(cmd.equals("clip"))server.sendClipboard(input.getString("text"),input.getString("target"));
   else if(cmd.equals("clipboard"))result.put("items",server.clipboard());
   else if(cmd.equals("client")){Client c=new Client(new JSONObject().put("address",input.getString("address")));c.pair(input.getString("pin"),"Android JVM client");c.send(new File(input.getString("file")),input.getString("name"));c.sendClipboard("안드로이드 → 다른 기기");result.put("state",c.state);}
   else if(cmd.equals("url")){try{Client.endpoint(input.getString("address"),"/api/state");result.put("allowed",true);}catch(Exception e){result.put("allowed",false);}}
   else if(cmd.equals("revoke"))server.revoke();
   else if(cmd.equals("stop"))break;
   System.out.println(result);System.out.flush();
  }catch(Exception e){System.out.println(new JSONObject().put("error",e.getClass().getSimpleName()));System.out.flush();}}}
  if(bridge!=null)bridge.close();server.close();
 }
}
