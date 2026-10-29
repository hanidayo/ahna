using System.Security.Cryptography;
using System.Text.Json;
using Ahna;
using Ahna.Remote;

var output=new SemaphoreSlim(1,1);
async Task Emit(object value){await output.WaitAsync();try{await Console.Out.WriteLineAsync(JsonSerializer.Serialize(value,Util.Json).ReplaceLineEndings(""));await Console.Out.FlushAsync();}finally{output.Release();}}
TransferServer? server=null;
using var stop=new CancellationTokenSource();
Task? monitor=null;
try
{
    var first=await Console.In.ReadLineAsync()??throw new ArgumentException("Missing application configuration");
    var boot=JsonSerializer.Deserialize<Boot>(first,Util.Json)??throw new ArgumentException("Invalid application configuration");
    RemoteKey.Initialize(boot.EncryptionKey);
    if(!Path.IsPathFullyQualified(boot.DataPath)||!Path.IsPathFullyQualified(boot.SavePath))throw new ArgumentException("Absolute application paths required");
    server=new TransferServer(boot.DataPath,boot.Port);
    // One code entry connects both ways: a device pairing with this Mac may hand over its own session.
    // The Swift app stores it as an added device (shared with the share extension).
    server.ReverseReceived=credential=>{_ = Emit(new{type="reverseReceived",address=credential.Address,computerID=credential.ComputerId,token=credential.Token,name=credential.Name});return true;};
    var previous=server.Settings;
    server.SaveSettings(new(){SavePath=boot.SavePath,Notifications=previous.Notifications,RecipientSavedNotifications=previous.RecipientSavedNotifications,RemoteEnabled=previous.RemoteEnabled,RemoteUrl=previous.RemoteUrl,RemoteKeyProtected=previous.RemoteKeyProtected});
    await server.StartAsync(Path.Combine(AppContext.BaseDirectory,"wwwroot"));
    server.Received+=text=>{_ = Emit(new{type="received",message=text});};
    async Task Status()=>await Emit(new{type="status",pin=server.Pin,addresses=server.Addresses,hostName=Environment.MachineName,savePath=server.Settings.SavePath,remoteStatus=server.RemoteStatus,remoteEnabled=server.Settings.RemoteEnabled,remoteUrl=server.Settings.RemoteUrl,joined=!string.IsNullOrEmpty(server.Settings.RemoteKeyProtected),memberToken=MemberToken(),
        history=server.HistorySnapshot(),clipboardSupported=true,devices=server.Nearby().Select(x=>new{id=x.Id,name=x.Name}),
        computerID=server.ComputerId,peers=server.Peers().Select(x=>new{id=x.Id,name=x.Name,computerID=x.ComputerId,online=x.Online}),clipboard=server.ClipboardInbox().Select(x=>new{x.Id,x.Sender,x.Bytes,x.Created})});
    // 공유 메뉴(근처 기기로 보내기)가 쓰도록 연결 토큰을 Swift 앱에 알립니다(이 프로세스와 앱 사이의 파이프로만).
    string? MemberToken(){try{var key=string.IsNullOrEmpty(server.Settings.RemoteKeyProtected)?"":RemoteKey.Unprotect(server.Settings.RemoteKeyProtected);return Brand.IsMemberToken(key)?key:null;}catch{return null;}}
    server.ClipboardReceived+=sender=>{_ = Emit(new{type="clipboardReceived",sender});_ = Status();};
    // 서버 관리자 알림(사용량 한도·메시지·초기화·차단). 초기화·차단이면 연결 정보가 지워져 초대 코드 화면이 나옵니다.
    server.ServerNotice+=(action,text)=>{_ = Emit(new{type="notice",action,text});_ = Status();};
    // 근처 기기 · QR 공유: 1회용 게스트 티켓 상태를 Swift 앱에 알립니다.
    object Snap(TransferServer.GuestTicket t)=>new{token=t.Token,kind=t.Kind,state=t.State,code=t.Code,expires=t.Expires.ToUnixTimeSeconds(),files=t.Files.Select(f=>new{name=f.Name,bytes=f.Bytes}),completed=t.CompletedCount,peer=t.Peer,transferred=t.Transferred,total=t.Total};
    server.GuestChanged+=t=>{_ = Emit(new{type="guest",ticket=Snap(t)});};
    server.GuestRequested=t=>{_ = Emit(new{type="guestRequest",ticket=Snap(t)});};
    await Status();
    monitor=Task.Run(async()=>{try{while(!stop.IsCancellationRequested){await Task.Delay(2000,stop.Token);await Status();}}catch(OperationCanceledException){}},stop.Token);
    string? line;
    while((line=await Console.In.ReadLineAsync()) is not null)
    {
        string? requestID=null;string? commandName=null;
        try
        {
            using var doc=JsonDocument.Parse(line);var command=doc.RootElement;
            requestID=command.TryGetProperty("requestID",out var request)?request.GetString():null;
            commandName=command.GetProperty("command").GetString();
            switch(commandName)
            {
                case "stop":stop.Cancel();return 0;
                case "filesSend":
                    var paths=command.GetProperty("paths").Deserialize<string[]>(Util.Json)??[];
                    if(paths.Length is <1 or >256)throw new ArgumentException("파일은 한 번에 1~256개 선택하세요.");
                    await server.AddPathsAsync(paths,command.GetProperty("target").GetString()??"",snapshot:true);
                    await Emit(new{type="filesPrepared",requestID});await Status();break;
                case "clipboardSend":
                    var text=command.GetProperty("text").GetString()??"";
                    var target=command.GetProperty("target").GetString()??"";
                    var sent=server.SendClipboard(text,target);
                    await Emit(new{type="clipboardSent",requestID,id=sent.Id});await Status();break;
                case "clipboardRead":
                    var id=command.GetProperty("id").GetString()??"";
                    var received=server.FindClipboard(id)??throw new ArgumentException("받은 글자가 만료되었거나 삭제되었습니다.");
                    await Emit(new{type="clipboardText",requestID,id=received.Id,text=received.Text});break;
                case "forgetSessions":
                    foreach(var forget in command.GetProperty("ids").EnumerateArray())server.ForgetSession(forget.GetString()??"");
                    await Emit(new{type="sessionsForgotten",requestID});await Status();break;
                case "reverseOffer":
                    var reverseOffer=server.ReverseOffer();
                    await Emit(new{type="reverseOffer",requestID,offer=reverseOffer is null ? null : new{address=reverseOffer.Address,computerID=reverseOffer.ComputerId,token=reverseOffer.Token,name=reverseOffer.Name}});break;
                case "reverseComplete":
                    var reverseAccepted=command.TryGetProperty("accepted",out var acceptedValue)&&acceptedValue.ValueKind==JsonValueKind.True;
                    var reverseName=command.TryGetProperty("name",out var nameValue)&&nameValue.ValueKind==JsonValueKind.String?nameValue.GetString():null;
                    var reverseIdentity=command.TryGetProperty("computerID",out var identityValue)&&identityValue.ValueKind==JsonValueKind.String?identityValue.GetString():null;
                    server.CompleteReverse(command.GetProperty("token").GetString()??"",reverseAccepted,reverseName,reverseIdentity);
                    await Status();break;
                case "ticketCreate":
                    var ticketKind=command.GetProperty("kind").GetString();
                    var ticketPeer=command.TryGetProperty("peer",out var peerValue)&&peerValue.ValueKind==JsonValueKind.String?peerValue.GetString()??"":"";
                    TransferServer.GuestTicket ticket;
                    if(ticketKind=="send")
                    {
                        var ticketPaths=command.GetProperty("paths").Deserialize<string[]>(Util.Json)??[];
                        var ticketCode=command.TryGetProperty("code",out var codeValue)&&codeValue.ValueKind==JsonValueKind.String?codeValue.GetString():null;
                        ticket=await server.CreateSendTicketAsync(ticketPaths,ticketPeer,ticketCode);
                    }
                    else ticket=server.CreateReceiveTicket(ticketPeer.Length>0?ticketPeer:"QR");
                    await Emit(new{type="ticket",requestID,ticket=Snap(ticket),url=server.GuestUrl(ticket)});break;
                case "ticketCancel":
                    server.CancelTicket(command.GetProperty("token").GetString()??"");break;
                case "ticketAnswer":
                    server.AnswerGuest(command.GetProperty("token").GetString()??"",command.TryGetProperty("accept",out var acceptValue)&&acceptValue.ValueKind==JsonValueKind.True);break;
                case "configure":
                    var settings=command.Deserialize<Configuration>(Util.Json)??throw new ArgumentException("Invalid settings");
                    // 아나: 서버는 고정, 연결 키 칸에는 초대 코드가 옵니다 → 이 Mac 전용 토큰으로 바꿔 저장
                    var input=(settings.RemoteKey??"").Trim();
                    if(Brand.Ahna&&input.Length>0&&!Brand.IsMemberToken(input))input=await server.JoinServer(Brand.Server,input,CancellationToken.None);
                    var key=input.Length==0?server.Settings.RemoteKeyProtected:RemoteKey.Protect(input);
                    server.SaveSettings(new(){SavePath=settings.SavePath,Notifications=true,RecipientSavedNotifications=server.Settings.RecipientSavedNotifications,RemoteEnabled=settings.RemoteEnabled,RemoteUrl=Brand.Ahna?Brand.Server:settings.RemoteUrl.Trim().TrimEnd('/'),RemoteKeyProtected=key});
                    await Emit(new{type="saved"});await Status();break;
                default:throw new ArgumentException("Unknown command");
            }
        }
        catch(Exception error){await Emit(new{type="error",requestID,message=commandName is "reverseOffer" or "reverseComplete"?"기기 연결 정보를 준비하지 못했습니다.":commandName is "clipboardSend" or "clipboardRead" or "filesSend" or "ticketCreate"?(error is ArgumentException?error.Message:"전송 요청을 완료하지 못했습니다. 파일 접근과 연결을 확인하고 다시 시도하세요."):(error is ArgumentException&&commandName=="configure"?error.Message:"옵션을 저장하지 못했습니다. 폴더 접근 권한과 인터넷 연결을 확인하세요.")});}
    }
    return 0;
}
catch(Exception error)
{
    await Emit(new{type="error",message=error is ArgumentException?error.Message:"Mac 수신 서비스를 시작하지 못했습니다. 저장 폴더와 사용 중인 포트를 확인하세요."});
    return 1;
}
finally
{
    stop.Cancel();if(monitor is not null)try{await monitor;}catch(OperationCanceledException){}
    if(server is not null)await server.DisposeAsync();
}
record Boot(string DataPath,string SavePath,string EncryptionKey,int Port=45851);
record Configuration(string SavePath,bool RemoteEnabled,string RemoteUrl,string? RemoteKey);
