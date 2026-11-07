using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.IO.Pipes;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Reflection;
using System.Reflection.PortableExecutable;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace Ahna;

internal static class SelfTest
{
	public static async Task<int> RunAsync(string? reportPath)
	{
		List<object> checks = new List<object>();
		string root = Path.Combine(Path.GetTempPath(), "Ahna-test-" + Guid.NewGuid().ToString("N"));
		Directory.CreateDirectory(root);
		Dictionary<HttpClient, CookieContainer> cookies = new Dictionary<HttpClient, CookieContainer>();
		bool success = false;
		string failure = null;
		try
		{
			Check(OutboundDevices.Endpoint("https://ahna.example", "/api/state").Scheme == "https", "Direct device client accepts 서버 HTTPS origin");
			string[] array = new string[6] { "http://192.168.0.20:45851", "http://public.example", "https://user:password@ahna.example", "https://ahna.example/path", "https://ahna.example?query=1", "https://ahna.example#fragment" };
			foreach (string text in array)
			{
				bool ok = false;
				try
				{
					OutboundDevices.Endpoint(text, "/api/state");
				}
				catch (ArgumentException)
				{
					ok = true;
				}
				Check(ok, "Direct device client rejects unsafe origin: " + text);
			}
			bool[] array2 = new bool[2] { false, true };
			for (int j = 0; j < array2.Length; j++)
			{
				bool enabled = array2[j];
				Preferences preferences = JsonSerializer.Deserialize<Preferences>("{\"notifications\":" + (enabled ? "true" : "false") + "}", Util.Json);
				Check(preferences.Notifications == enabled && preferences.RecipientSavedNotifications == enabled, "Legacy notification choice preserved: " + enabled);
				bool[] array3 = new bool[2] { false, true };
				foreach (bool savedEnabled in array3)
				{
					Preferences settings = new Preferences
					{
						SavePath = Path.Combine(root, "notification-received"),
						Notifications = enabled,
						RecipientSavedNotifications = savedEnabled
					};
					await using (TransferServer transferServer = new TransferServer(Path.Combine(root, "notification-data"), FreePort()))
					{
						transferServer.SaveSettings(settings);
					}
					await using TransferServer transferServer2 = new TransferServer(Path.Combine(root, "notification-data"), FreePort());
					Check(transferServer2.Settings.Notifications == enabled && transferServer2.Settings.RecipientSavedNotifications == savedEnabled, $"Independent notification switches survive restart: transfer={enabled}, saved={savedEnabled}");
				}
			}
			Check(Program.NormalizeActivationArgs(Array.Empty<string>(), notification: true, alreadyRunning: false).SequenceEqual(new ReadOnlySpan<string>(new string[1] { "--notification" })), "Notification activation routes only to received folder");
			Check(Program.NormalizeActivationArgs(Array.Empty<string>(), notification: false, alreadyRunning: true).SequenceEqual(new ReadOnlySpan<string>(new string[1] { "--background" })), "Shell reactivation of running tray app does not open web UI");
			Check(Program.NormalizeActivationArgs(new string[1] { "--open" }, notification: false, alreadyRunning: true).SequenceEqual(new ReadOnlySpan<string>(new string[1] { "--open" })), "Explicit open still opens 아나 UI");
			Check(Program.NormalizeActivationArgs(new string[2] { "--send", "sample.txt" }, notification: false, alreadyRunning: true).SequenceEqual(new ReadOnlySpan<string>(new string[2] { "--send", "sample.txt" })), "File-send reactivation preserves arguments");
			await using TransferServer server = new TransferServer(Path.Combine(root, "data"), FreePort());
			server.SaveSettings(new Preferences
			{
				SavePath = Path.Combine(root, "received")
			});
			await server.StartAsync(Path.Combine(AppContext.BaseDirectory, "wwwroot"));
			using HttpClient anonymous = Client(server.LocalUrl);
			using HttpClient owner = Client(server.LocalUrl);
			using HttpClient phone = Client(server.LocalUrl);
			using HttpClient other = Client(server.LocalUrl);
			Check((await anonymous.GetAsync("api/state")).StatusCode == HttpStatusCode.Unauthorized, "Unauthenticated state denied");
			Check((await anonymous.GetStringAsync("/")).Contains("아나"), "Web UI served");
			string text2 = (await anonymous.GetAsync("app.js")).Content.Headers.ContentType?.MediaType;
			bool ok2 = ((text2 == "text/javascript" || text2 == "application/javascript") ? true : false);
			Check(ok2, "Browser script served");
			HttpRequestMessage httpRequestMessage = new HttpRequestMessage(HttpMethod.Post, "api/owner");
			httpRequestMessage.Headers.Add("X-Ahna-Owner", server.OwnerSecret);
			httpRequestMessage.Content = JsonContent.Create(new { });
			Check((await owner.SendAsync(httpRequestMessage)).IsSuccessStatusCode, "Local owner authentication");
			Check((await State(owner)).GetProperty("owner").GetBoolean(), "Owner session established");
			Check((await phone.PostAsJsonAsync("api/pair", new
			{
				pin = "000000",
				name = "bad"
			})).StatusCode == HttpStatusCode.Unauthorized, "Incorrect PIN denied");
			Check((await phone.PostAsJsonAsync("api/pair", new
			{
				pin = server.Pin,
				name = "Test iPhone"
			})).IsSuccessStatusCode, "Phone pairing");
			Check((await other.PostAsJsonAsync("api/pair", new
			{
				pin = server.Pin,
				name = "Test Mac"
			})).IsSuccessStatusCode, "Second device pairing");
			JsonElement jsonElement = await State(phone);
			string phoneId = jsonElement.GetProperty("id").GetString();
			Check(jsonElement.GetProperty("pin").ValueKind == JsonValueKind.Null && jsonElement.GetProperty("urls").GetArrayLength() == 0, "Device cannot see owner PIN or URLs");
			Check((await State(owner)).GetProperty("devices").GetArrayLength() == 2, "Connected devices discovered");
			Check((await phone.PostAsJsonAsync("api/admin/settings", new { })).StatusCode == HttpStatusCode.Unauthorized, "Device cannot use owner settings");
			Check((await phone.GetAsync("api/admin/options")).StatusCode == HttpStatusCode.Unauthorized, "Device cannot read owner options");
			Check((await phone.PostAsJsonAsync("api/admin/options", new { savePath = Path.Combine(root, "evil") })).StatusCode == HttpStatusCode.Unauthorized, "Device cannot change owner options");
			Check((await phone.PostAsJsonAsync("api/admin/pick-folder", new { })).StatusCode == HttpStatusCode.Unauthorized && (await phone.PostAsJsonAsync("api/admin/open-folder", new { })).StatusCode == HttpStatusCode.Unauthorized, "Device cannot open owner folder picker or receive folder");
			Check((await phone.PostAsJsonAsync("api/admin/update-check", new { })).StatusCode == HttpStatusCode.Unauthorized && (await phone.PostAsJsonAsync("api/admin/update-install", new { })).StatusCode == HttpStatusCode.Unauthorized, "Device cannot run owner update actions");
			JsonElement ownerOptions = await owner.GetFromJsonAsync<JsonElement>("api/admin/options");
			Check(ownerOptions.GetProperty("savePath").GetString() == server.Settings.SavePath && !ownerOptions.GetProperty("remoteKeySaved").GetBoolean() && !ownerOptions.GetProperty("integrationsAvailable").GetBoolean(), "Owner reads options without exposing the 서버 key");
			Check((await State(owner)).GetProperty("version").GetString() == Ahna.Update.UpdateService.CurrentText && (await anonymous.GetFromJsonAsync<JsonElement>("api/version")).GetProperty("version").GetString() == Ahna.Update.UpdateService.CurrentText, "Running app version reported to the web UI");
			HttpResponseMessage optionsSave = await owner.PostAsJsonAsync("api/admin/options", new
			{
				savePath = server.Settings.SavePath,
				notifications = true,
				recipientSavedNotifications = false,
				remoteUrl = "",
				nasKey = ""
			});
			Check(optionsSave.IsSuccessStatusCode && server.Settings.Notifications && !server.Settings.RecipientSavedNotifications, "Owner saves options from the web panel");
			Check((await owner.PostAsJsonAsync("api/admin/options", new { savePath = server.Settings.SavePath, notifications = true, recipientSavedNotifications = true })).IsSuccessStatusCode && server.Settings.RecipientSavedNotifications, "Owner restores options from the web panel");
			Check((await owner.PostAsJsonAsync("api/admin/options", new { savePath = "relative-folder", notifications = true, recipientSavedNotifications = true })).StatusCode == HttpStatusCode.BadRequest, "Web options reject a relative receive folder");
			using (OutboundDevices outboundDevices = new OutboundDevices(server, Path.Combine(root, "outbound")))
			{
				server.ExternalDevices = outboundDevices;
				Check((await phone.GetAsync("api/admin/devices")).StatusCode == HttpStatusCode.Unauthorized && (await phone.PostAsJsonAsync("api/admin/devices/pair", new { address = "https://ahna.example", pin = "123456" })).StatusCode == HttpStatusCode.Unauthorized, "Device cannot list or add owner's outbound devices");
				Check((await phone.PostAsJsonAsync("api/admin/devices/out-x/send-text", new { text = "x" })).StatusCode == HttpStatusCode.Unauthorized && (await phone.PostAsJsonAsync("api/admin/devices/out-x/send-files", new { })).StatusCode == HttpStatusCode.Unauthorized && (await phone.PostAsJsonAsync("api/admin/devices/out-x/remove", new { })).StatusCode == HttpStatusCode.Unauthorized, "Device cannot use owner's outbound send or remove");
				JsonElement outboundList = await owner.GetFromJsonAsync<JsonElement>("api/admin/devices");
				Check(outboundList.GetProperty("devices").GetArrayLength() == 0 && (await State(owner)).GetProperty("outbound").GetProperty("devices").GetArrayLength() == 0, "Owner sees outbound device list in state");
				Check((await owner.PostAsJsonAsync("api/admin/devices/pair", new { address = "https://ahna.example", pin = "12ab" })).StatusCode == HttpStatusCode.BadRequest && (await owner.PostAsJsonAsync("api/admin/devices/pair", new { address = "http://ahna.example", pin = "123456" })).StatusCode == HttpStatusCode.BadRequest, "Outbound pairing validates code and HTTPS address");
				Check((await owner.PostAsJsonAsync("api/admin/devices/out-missing/send-text", new { text = "hello" })).StatusCode == HttpStatusCode.BadRequest, "Outbound text to an unknown device is rejected");
				server.ExternalDevices = null;
			}
			Check((await State(phone)).GetProperty("outbound").ValueKind == JsonValueKind.Null, "Devices do not see owner's outbound list");
			string clipboardText = "  아나 clip test · 한글 e\u0301 \ud83d\udc31\r\n둘째 줄\n<script>alert('text')</script>  ";
			string clipboardPath = "api/upload?kind=clipboard&batch=" + Guid.NewGuid();
			int clipboardEvents = 0;
			string clipboardSender = null;
			server.ClipboardReceived += (string sender) =>
			{
				Interlocked.Increment(ref clipboardEvents);
				clipboardSender = sender;
			};
			Check((await anonymous.PostAsync(clipboardPath, new StringContent(clipboardText))).StatusCode == HttpStatusCode.Unauthorized, "Unpaired clipboard upload denied");
			HttpResponseMessage clipboardUpload = await phone.PostAsync(clipboardPath, new StringContent(clipboardText, Encoding.UTF8, "text/plain"));
			string text3 = (await clipboardUpload.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetString();
			Check(clipboardUpload.IsSuccessStatusCode && clipboardEvents == 1 && clipboardSender == "Test iPhone", "Phone clipboard reaches Windows with sender-only notification");
			Check(server.ClipboardInbox().Single().Text == clipboardText && !Directory.EnumerateFiles(server.Settings.SavePath).Any(), "Clipboard preserves Unicode and whitespace without creating a received file");
			string incomingClipboardPath = "api/download/" + text3 + "?kind=clipboard";
			Check(await owner.GetStringAsync(incomingClipboardPath) == clipboardText, "Windows owner reads received clipboard text");
			ok2 = (await phone.GetAsync(incomingClipboardPath)).StatusCode == HttpStatusCode.NotFound;
			if (ok2)
			{
				ok2 = (await other.GetAsync(incomingClipboardPath)).StatusCode == HttpStatusCode.NotFound;
			}
			Check(ok2, "Devices cannot read the Windows clipboard inbox");
			Check((await phone.PostAsJsonAsync("api/admin/clipboard", new
			{
				target = phoneId,
				text = clipboardText
			})).StatusCode == HttpStatusCode.Unauthorized, "Device cannot send as Windows owner");
			HttpResponseMessage clipboardOutbound = await owner.PostAsJsonAsync("api/admin/clipboard", new
			{
				target = phoneId,
				text = clipboardText
			});
			string outgoingClipboardId = (await clipboardOutbound.Content.ReadFromJsonAsync<JsonElement>()).GetProperty("id").GetString();
			JsonElement property = (await State(phone)).GetProperty("clipboard");
			int ok3;
			if (clipboardOutbound.IsSuccessStatusCode)
			{
				JsonElement value = property.EnumerateArray().Single().GetProperty("id");
				if (value.GetString() == outgoingClipboardId)
				{
					ok3 = ((!property[0].TryGetProperty("text", out value)) ? 1 : 0);
					goto IL_18d8;
				}
			}
			ok3 = 0;
			goto IL_18d8;
			IL_18d8:
			Check((byte)ok3 != 0, "Windows clipboard is advertised only as metadata to its selected device");
			ok2 = (await State(other)).GetProperty("clipboard").GetArrayLength() == 0;
			if (ok2)
			{
				ok2 = (await State(owner)).GetProperty("clipboard").GetArrayLength() == 1;
			}
			Check(ok2, "Clipboard inboxes isolated between devices and owner");
			using (HttpResponseMessage clipboardDownload = await phone.GetAsync("api/download/" + outgoingClipboardId + "?kind=clipboard"))
			{
				ok2 = clipboardDownload.Content.Headers.ContentType?.MediaType == "text/plain";
				if (ok2)
				{
					ok2 = await clipboardDownload.Content.ReadAsStringAsync() == clipboardText;
				}
				Check(ok2, "Phone receives exact UTF-8 clipboard as plain text");
			}
			ok2 = (await other.GetAsync("api/download/" + outgoingClipboardId + "?kind=clipboard")).StatusCode == HttpStatusCode.NotFound;
			if (ok2)
			{
				ok2 = (await phone.GetAsync("api/download/" + outgoingClipboardId)).StatusCode == HttpStatusCode.NotFound;
			}
			Check(ok2, "Clipboard download requires recipient authorization and explicit text mode");
			Check((await phone.PostAsync(clipboardPath, new ByteArrayContent(Array.Empty<byte>()))).StatusCode == HttpStatusCode.BadRequest, "Empty clipboard text rejected");
			Check((await phone.PostAsync(clipboardPath, new ByteArrayContent(new byte[2] { 195, 40 }))).StatusCode == HttpStatusCode.BadRequest, "Malformed UTF-8 clipboard rejected");
			Check((await phone.PostAsync(clipboardPath, new ByteArrayContent(new byte[3] { 65, 0, 66 }))).StatusCode == HttpStatusCode.BadRequest, "NUL clipboard text rejected");
			Check((await phone.PostAsync(clipboardPath, new ByteArrayContent(new byte[65537]))).StatusCode == HttpStatusCode.RequestEntityTooLarge, "Oversized clipboard upload bounded");
			Check((await owner.PostAsJsonAsync("api/admin/clipboard", new
			{
				target = phoneId,
				text = new string('한', 22000)
			})).StatusCode == HttpStatusCode.BadRequest, "Clipboard limit counts UTF-8 bytes, not characters");
			Check((await owner.PostAsJsonAsync("api/admin/clipboard", new
			{
				target = "missing",
				text = "test"
			})).StatusCode == HttpStatusCode.BadRequest, "Clipboard send requires a connected receiving device");
			for (int num = 0; num < 22; num++)
			{
				server.SendClipboard("bounded clip " + num, phoneId);
			}
			ok2 = (await State(phone)).GetProperty("clipboard").GetArrayLength() == 20;
			if (ok2)
			{
				ok2 = (await phone.GetAsync("api/download/" + outgoingClipboardId + "?kind=clipboard")).StatusCode == HttpStatusCode.NotFound;
			}
			Check(ok2, "Clipboard retains at most 20 messages per recipient and evicts old content");
			Check(!File.ReadAllText(Path.Combine(root, "data", "history.json")).Contains("아나 clip test"), "Clipboard body is excluded from persistent transfer history");
			HttpRequestMessage httpRequestMessage2 = new HttpRequestMessage(HttpMethod.Post, "api/upload?path=bad.txt&batch=" + Guid.NewGuid());
			httpRequestMessage2.Headers.Add("Origin", "https://evil.example");
			httpRequestMessage2.Content = new ByteArrayContent(new byte[1] { 1 });
			Check((await phone.SendAsync(httpRequestMessage2)).StatusCode == HttpStatusCode.Forbidden, "Cross-origin mutation rejected");
			HttpRequestMessage httpRequestMessage3 = new HttpRequestMessage(HttpMethod.Get, "api/state");
			httpRequestMessage3.Headers.Host = "evil.example";
			Check((await phone.SendAsync(httpRequestMessage3)).StatusCode == HttpStatusCode.BadRequest, "DNS rebinding hostname rejected");
			byte[] payload = RandomNumberGenerator.GetBytes(2097169);
			Guid batch = Guid.NewGuid();
			string uploadUrl = "api/upload?path=" + Uri.EscapeDataString("사진 폴더/hello 한글.bin") + "&batch=" + batch;
			Check((await phone.PostAsync(uploadUrl, new ByteArrayContent(payload))).IsSuccessStatusCode, "Binary folder upload");
			string uploaded = Directory.GetFiles(server.Settings.SavePath, "*.bin", SearchOption.AllDirectories).Single();
			Check(SHA256.HashData(File.ReadAllBytes(uploaded)).SequenceEqual(SHA256.HashData(payload)), "Upload SHA256 and Korean nested path preserved");
			Check((await phone.PostAsync(uploadUrl, new ByteArrayContent(new byte[1] { 9 }))).IsSuccessStatusCode, "Duplicate filename upload accepted");
			Check(Directory.GetFiles(server.Settings.SavePath, "*.bin", SearchOption.AllDirectories).Length == 2 && File.ReadAllBytes(uploaded).Length == payload.Length, "Duplicate filename does not overwrite");
			Check((await phone.PostAsync("api/upload?path=empty.txt&batch=" + batch, new ByteArrayContent(Array.Empty<byte>()))).IsSuccessStatusCode, "Zero-byte file upload");
			Check(File.Exists(Path.Combine(server.Settings.SavePath, "empty.txt")), "Ordinary file saved directly in 아나 folder");
			Check(File.Exists(Path.Combine(server.Settings.SavePath, "사진 폴더", "hello 한글.bin")), "Explicit folder upload preserves only original folder hierarchy");
			Check((await phone.PostAsync("api/upload?path=flat.txt&batch=" + Guid.NewGuid(), new ByteArrayContent(new byte[1] { 1 }))).IsSuccessStatusCode, "Flat upload from a fresh batch");
			Check((await phone.PostAsync("api/upload?path=flat.txt&batch=" + Guid.NewGuid(), new ByteArrayContent(new byte[1] { 2 }))).IsSuccessStatusCode, "Same filename in another batch accepted");
			Check((await other.PostAsync("api/upload?path=flat.txt&batch=" + Guid.NewGuid(), new ByteArrayContent(new byte[1] { 3 }))).IsSuccessStatusCode, "Same filename from another device accepted");
			Check(File.ReadAllBytes(Path.Combine(server.Settings.SavePath, "flat.txt")).SequenceEqual(new byte[1] { 1 }) && File.ReadAllBytes(Path.Combine(server.Settings.SavePath, "flat (1).txt")).SequenceEqual(new byte[1] { 2 }) && File.ReadAllBytes(Path.Combine(server.Settings.SavePath, "flat (2).txt")).SequenceEqual(new byte[1] { 3 }), "Root filename collisions preserve every file across batches and devices");
			Check(Directory.GetDirectories(server.Settings.SavePath).Select(Path.GetFileName).SequenceEqual(new string[1] { "사진 폴더" }), "No timestamp or random per-transfer receive folders created");
			string koreanName = "스크린샷, 2026-10-17 오후 4.12.38.png";
			string decomposedName = koreanName.Normalize(NormalizationForm.FormD);
			string requestUri = "api/upload?path=" + Uri.EscapeDataString(decomposedName) + "&batch=" + Guid.NewGuid();
			using (HttpResponseMessage clipboardDownload = await phone.PostAsync(requestUri, new ByteArrayContent(new byte[2] { 11, 12 })))
			{
				JsonElement jsonElement2 = await clipboardDownload.Content.ReadFromJsonAsync<JsonElement>();
				Check(clipboardDownload.IsSuccessStatusCode && jsonElement2.GetProperty("name").GetString() == koreanName && File.ReadAllBytes(Path.Combine(server.Settings.SavePath, koreanName)).SequenceEqual(new byte[2] { 11, 12 }) && !File.Exists(Path.Combine(server.Settings.SavePath, decomposedName)), "Decomposed iPhone Hangul is saved and returned as composed Korean");
			}
			Check((await phone.PostAsync("api/upload?path=" + Uri.EscapeDataString(koreanName) + "&batch=" + Guid.NewGuid(), new ByteArrayContent(new byte[1] { 13 }))).IsSuccessStatusCode && File.ReadAllBytes(Path.Combine(server.Settings.SavePath, Path.GetFileNameWithoutExtension(koreanName) + " (1).png")).SequenceEqual("\r"u8) && File.ReadAllBytes(Path.Combine(server.Settings.SavePath, koreanName)).SequenceEqual(new byte[2] { 11, 12 }), "Composed and decomposed names share collision handling without overwriting");
			string text4 = "한글 폴더/여행 사진 café \ud83d\udc31.txt";
			Check((await phone.PostAsync("api/upload?path=" + Uri.EscapeDataString(text4.Normalize(NormalizationForm.FormD)) + "&batch=" + Guid.NewGuid(), new ByteArrayContent(new byte[1] { 14 }))).IsSuccessStatusCode && File.ReadAllBytes(Path.Combine(server.Settings.SavePath, "한글 폴더", "여행 사진 café \ud83d\udc31.txt")).SequenceEqual(new byte[1] { 14 }), "Nested decomposed folder and filename compose while preserving spaces, accents and emoji");
			string originalSavePath = server.Settings.SavePath;
			server.SaveSettings(new Preferences
			{
				SavePath = Path.Combine(root, "changed-receive-folder") + Path.DirectorySeparatorChar
			});
			Check((await phone.PostAsync("api/upload?path=moved.txt&batch=" + batch, new ByteArrayContent(new byte[1] { 4 }))).IsSuccessStatusCode && File.Exists(Path.Combine(server.Settings.SavePath, "moved.txt")), "Changed receive folder used immediately even for an existing batch and trailing separator");
			server.SaveSettings(new Preferences
			{
				SavePath = originalSavePath
			});
			bool flag = false;
			try
			{
				server.SaveSettings(new Preferences
				{
					SavePath = "relative-receive-folder"
				});
			}
			catch (ArgumentException)
			{
				flag = true;
			}
			Check(flag && server.Settings.SavePath == originalSavePath, "Relative receive folder is rejected without changing the configured folder");
			string text5 = Path.Combine(root, "not-a-folder.txt");
			File.WriteAllText(text5, "keep");
			bool flag2 = false;
			try
			{
				server.SaveSettings(new Preferences
				{
					SavePath = text5
				});
			}
			catch (IOException)
			{
				flag2 = true;
			}
			Check(flag2 && File.ReadAllText(text5) == "keep" && server.Settings.SavePath == originalSavePath, "Selecting a file as the receive folder preserves the file and previous setting");
			using (TcpClient interrupted = new TcpClient())
			{
				await interrupted.ConnectAsync(IPAddress.Loopback, server.Port);
				string s = $"POST /api/upload?path=interrupted.bin&batch={batch} HTTP/1.1\r\nHost: 127.0.0.1:{server.Port}\r\nCookie: {cookies[phone].GetCookieHeader(phone.BaseAddress)}\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\nabc";
				NetworkStream interruptedStream = interrupted.GetStream();
				await interruptedStream.WriteAsync(Encoding.ASCII.GetBytes(s));
				interrupted.Client.Shutdown(SocketShutdown.Send);
				using StreamReader reader = new StreamReader(interruptedStream);
				await reader.ReadToEndAsync().WaitAsync(TimeSpan.FromSeconds(5L));
			}
			Check(!Directory.GetFiles(server.Settings.SavePath, "interrupted.bin", SearchOption.AllDirectories).Any(), "Interrupted upload never committed");
			int k;
			for (k = 0; k < 60; k++)
			{
				if (!Directory.GetFiles(server.Settings.SavePath, "*.part", SearchOption.AllDirectories).Any())
				{
					break;
				}
				await Task.Delay(50);
			}
			Check(!Directory.GetFiles(server.Settings.SavePath, "*.part", SearchOption.AllDirectories).Any(), "Interrupted upload temporary file removed");
			Check((await phone.PostAsync("api/upload?path=after-interruption.txt&batch=" + batch, new ByteArrayContent(new byte[1] { 7 }))).IsSuccessStatusCode, "Upload slot released after interrupted request");
			string[] array4 = new string[8] { "../escape.txt", "C:\\escape.txt", "folder/../../escape.txt", "CON.txt", "dir/file:stream", "bad. ", "/root.txt", "dir//x" };
			foreach (string name in array4)
			{
				Check((await phone.PostAsync("api/upload?path=" + Uri.EscapeDataString(name) + "&batch=" + batch, new ByteArrayContent(new byte[1] { 1 }))).StatusCode == HttpStatusCode.BadRequest, "Reject unsafe path: " + name);
			}
			using (TcpClient interrupted = new TcpClient())
			{
				await interrupted.ConnectAsync(IPAddress.Loopback, server.Port);
				string s2 = $"POST /api/upload?path=huge.bin&batch={batch} HTTP/1.1\r\nHost: 127.0.0.1:{server.Port}\r\nCookie: {cookies[phone].GetCookieHeader(phone.BaseAddress)}\r\nContent-Length: {4294967297L}\r\nConnection: close\r\n\r\n";
				await interrupted.GetStream().WriteAsync(Encoding.ASCII.GetBytes(s2));
				using StreamReader reader = new StreamReader(interrupted.GetStream());
				Check((await reader.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(5L)))?.Contains("413") ?? false, "Over 4 GiB request rejected before reading");
			}
			string source = Path.Combine(root, "outgoing 한글.bin");
			File.WriteAllBytes(source, payload);
			int preparedNotices = 0;
			int deliveredNotices = 0;
			int savedNotices = 0;
			server.SendPrepared += (string _) =>
			{
				Interlocked.Increment(ref preparedNotices);
			};
			server.Delivered += (string _) =>
			{
				Interlocked.Increment(ref deliveredNotices);
			};
			server.ClientSaved += (string _) =>
			{
				Interlocked.Increment(ref savedNotices);
			};
			await server.AddPathsAsync(new _003C_003Ez__ReadOnlySingleElementList<string>(source), phoneId);
			Check(preparedNotices == 1, "Send preparation notification emitted");
			JsonElement property2 = (await State(phone)).GetProperty("items");
			Check(property2.GetArrayLength() == 1, "Selected file queued for phone");
			string itemId = property2[0].GetProperty("id").GetString();
			Check((await other.GetAsync("api/download/" + itemId)).StatusCode == HttpStatusCode.NotFound, "Other device cannot download target's file");
			Check((await anonymous.GetAsync("api/download/" + itemId)).StatusCode == HttpStatusCode.Unauthorized, "Anonymous download rejected");
			using (HttpResponseMessage clipboardDownload = await phone.GetAsync("api/download/" + itemId))
			{
				ok2 = clipboardDownload.IsSuccessStatusCode;
				if (ok2)
				{
					ok2 = SHA256.HashData(await clipboardDownload.Content.ReadAsByteArrayAsync()).SequenceEqual(SHA256.HashData(payload));
				}
				Check(ok2, "Download SHA256 matches source");
				Check(clipboardDownload.Content.Headers.ContentDisposition?.DispositionType == "attachment", "Download attachment header");
			}
			k = 0;
			while (Volatile.Read(in deliveredNotices) == 0 && k < 100)
			{
				await Task.Delay(10);
				k++;
			}
			Check(deliveredNotices == 1, "Completed HTTP transfer notification emitted");
			Check((await anonymous.PostAsJsonAsync("api/received/" + itemId, new
			{
				destination = "files"
			})).StatusCode == HttpStatusCode.Unauthorized, "Anonymous save receipt rejected");
			Check((await other.PostAsJsonAsync("api/received/" + itemId, new
			{
				destination = "files"
			})).StatusCode == HttpStatusCode.NotFound, "Other device cannot confirm recipient storage");
			Check((await phone.PostAsJsonAsync("api/received/" + itemId, new
			{
				destination = "invalid"
			})).StatusCode == HttpStatusCode.BadRequest, "Unknown receipt destination rejected");
			Check((await phone.PostAsJsonAsync("api/received/" + itemId, new
			{
				destination = "files"
			})).IsSuccessStatusCode && savedNotices == 1, "Native local file receipt emits saved notification");
			Check((await phone.PostAsJsonAsync("api/received/" + itemId, new
			{
				destination = "files"
			})).IsSuccessStatusCode && savedNotices == 1, "Repeated receipt does not duplicate notifications");
			Check((await phone.PostAsJsonAsync("api/received/" + itemId, new
			{
				destination = "photos"
			})).IsSuccessStatusCode && savedNotices == 2, "Photos receipt upgrades completion status");
			Check((await phone.PostAsJsonAsync("api/received/" + itemId, new
			{
				destination = "files"
			})).IsSuccessStatusCode && savedNotices == 2, "Late file receipt cannot downgrade Photos completion");
			await phone.GetByteArrayAsync("api/download/" + itemId);
			Check(deliveredNotices == 1, "Repeat download does not duplicate delivery notification");
			string folder = Path.Combine(root, "sample-folder");
			Directory.CreateDirectory(Path.Combine(folder, "하위"));
			File.WriteAllText(Path.Combine(folder, "하위", "메모.txt"), "아나 폴더 전송");
			Directory.CreateDirectory(Path.Combine(folder, "empty"));
			await server.AddPathsAsync(new _003C_003Ez__ReadOnlySingleElementList<string>(folder), phoneId);
			using (ZipArchive zipArchive = new ZipArchive(new MemoryStream(await phone.GetByteArrayAsync("api/download/" + (await State(phone)).GetProperty("items").EnumerateArray().First((JsonElement x) => x.GetProperty("name").GetString().EndsWith(".zip"))
				.GetProperty("id")
				.GetString()))))
			{
				using StreamReader streamReader = new StreamReader(zipArchive.Entries.Single((ZipArchiveEntry e) => e.FullName.EndsWith("메모.txt")).Open());
				Check(streamReader.ReadToEnd() == "아나 폴더 전송", "Folder ZIP preserves nested Unicode file contents");
				Check(zipArchive.Entries.Any((ZipArchiveEntry e) => e.FullName.Replace('\\', '/').EndsWith("empty/")), "Folder ZIP preserves empty directory");
			}
			Check((await State(other)).GetProperty("items").GetArrayLength() == 0, "Inbox isolated per device");
			Check((await State(owner)).GetProperty("history").GetArrayLength() >= 5, "Upload and download history recorded");
			Check((await State(other)).GetProperty("history").EnumerateArray().All((JsonElement h) => h.GetProperty("device").GetString() == "Test Mac"), "History isolated per device");
			Check(File.Exists(Path.Combine(root, "data", "settings.json")) && File.Exists(Path.Combine(root, "data", "history.json")), "Settings and history persisted");
			Check(!Directory.GetFiles(server.Settings.SavePath, "*.part", SearchOption.AllDirectories).Any(), "No partial upload files after successful requests");
			_ = server.Pin;
			Check((await owner.PostAsJsonAsync("api/admin/revoke", new { })).IsSuccessStatusCode, "Owner can revoke devices");
			Check(server.ClipboardInbox().Length == 0, "Revoking devices clears received clipboard content");
			Check((await phone.GetAsync("api/state")).StatusCode == HttpStatusCode.Unauthorized, "Revoked session loses access");
			Check((await State(owner)).GetProperty("devices").GetArrayLength() == 0, "Revoked devices removed from discovery");
			using HttpClient namedPhone = Client(server.LocalUrl);
			using HttpClient namedPad = Client(server.LocalUrl);
			ok2 = (await namedPhone.PostAsJsonAsync("api/pair", new
			{
				pin = server.Pin,
				name = "나의 iPhone · 앱",
				native = true
			})).IsSuccessStatusCode;
			if (ok2)
			{
				ok2 = (await namedPad.PostAsJsonAsync("api/pair", new
				{
					pin = server.Pin,
					name = "나의 iPhone · 앱",
					native = true
				})).IsSuccessStatusCode;
			}
			Check(ok2, "Two native devices can start with the same legacy name");
			string namedPhoneId = (await State(namedPhone)).GetProperty("id").GetString();
			string namedPadId = (await State(namedPad)).GetProperty("id").GetString();
			JsonElement namedPhoneState = await namedPhone.GetFromJsonAsync<JsonElement>("api/state?deviceName=" + Uri.EscapeDataString("내 아이폰"));
			JsonElement jsonElement3 = await namedPad.GetFromJsonAsync<JsonElement>("api/state?deviceName=" + Uri.EscapeDataString("거실 아이패드"));
			Check(namedPhoneState.GetProperty("id").GetString() == namedPhoneId && jsonElement3.GetProperty("id").GetString() == namedPadId && namedPhoneState.GetProperty("name").GetString() == "내 아이폰" && jsonElement3.GetProperty("name").GetString() == "거실 아이패드", "Native devices change their own names without replacing pairing or identity");
			JsonElement[] source2 = (await State(owner)).GetProperty("devices").EnumerateArray().ToArray();
			Check(source2.Any((JsonElement d) => d.GetProperty("id").GetString() == namedPhoneId && d.GetProperty("name").GetString() == "내 아이폰") && source2.Any((JsonElement d) => d.GetProperty("id").GetString() == namedPadId && d.GetProperty("name").GetString() == "거실 아이패드"), "Windows recipient list distinguishes custom iPhone and iPad names");
			ok2 = (await anonymous.GetAsync("api/state?deviceName=intruder")).StatusCode == HttpStatusCode.Unauthorized;
			if (ok2)
			{
				ok2 = (await owner.GetAsync("api/state?deviceName=intruder")).StatusCode == HttpStatusCode.BadRequest;
			}
			Check(ok2, "Anonymous and owner sessions cannot change native device names");
			ok2 = (await namedPhone.GetAsync("api/state?deviceName=")).StatusCode == HttpStatusCode.BadRequest;
			if (ok2)
			{
				ok2 = (await namedPhone.GetAsync("api/state?deviceName=" + new string('a', 41))).StatusCode == HttpStatusCode.BadRequest;
			}
			bool flag3 = ok2;
			if (flag3)
			{
				flag3 = (await namedPhone.GetAsync("api/state?deviceName=bad%0Aname")).StatusCode == HttpStatusCode.BadRequest;
			}
			bool flag4 = flag3;
			if (flag4)
			{
				flag4 = (await namedPhone.GetAsync("api/state?deviceName=a&deviceName=b")).StatusCode == HttpStatusCode.BadRequest;
			}
			bool flag5 = flag4;
			if (flag5)
			{
				flag5 = (await State(namedPhone)).GetProperty("name").GetString() == "내 아이폰";
			}
			Check(flag5, "Invalid names are rejected without replacing the saved valid name");
			((ConcurrentDictionary<string, Device>)typeof(TransferServer).GetField("sessions", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(server)).Values.Single((Device d) => d.Id == namedPhoneId).LastReceiverSeen = DateTimeOffset.UtcNow.AddMinutes(-1.0);
			Check((await namedPhone.GetFromJsonAsync<JsonElement>("api/state?receiving=false")).GetProperty("id").GetString() == namedPhoneId && !server.Nearby().Any(((string Id, string Name) d) => d.Id == namedPhoneId), "Shared-token extension heartbeat does not advertise a closed containing app as a receiver");
			Check((await namedPhone.GetFromJsonAsync<JsonElement>("api/state?receiving=true")).GetProperty("id").GetString() == namedPhoneId && server.Nearby().Count(((string Id, string Name) d) => d.Id == namedPhoneId) == 1, "Containing app resumes receiving with the same shared identity and no duplicate pairing");
			Check((await namedPhone.GetAsync("api/state?receiving=invalid")).StatusCode == HttpStatusCode.BadRequest, "Invalid receiver heartbeat rejected");
			using HttpClient rate = Client(server.LocalUrl);
			HttpStatusCode httpStatusCode = (HttpStatusCode)0;
			for (k = 0; k < 12; k++)
			{
				httpStatusCode = (await rate.PostAsJsonAsync("api/pair", new
				{
					pin = "000000",
					name = "bad"
				})).StatusCode;
			}
			Check(httpStatusCode == HttpStatusCode.TooManyRequests, "PIN brute-force rate limiting");
			await server.DisposeAsync();
			await using TransferServer restarted = new TransferServer(Path.Combine(root, "data"), FreePort());
			await restarted.StartAsync(Path.Combine(AppContext.BaseDirectory, "wwwroot"));
			Check(restarted.Settings.SavePath == server.Settings.SavePath, "Save path survives restart");
			using HttpClient restartOwner = Client(restarted.LocalUrl);
			HttpRequestMessage httpRequestMessage4 = new HttpRequestMessage(HttpMethod.Post, "api/owner");
			httpRequestMessage4.Headers.Add("X-Ahna-Owner", restarted.OwnerSecret);
			httpRequestMessage4.Content = JsonContent.Create(new { });
			await restartOwner.SendAsync(httpRequestMessage4);
			JsonElement jsonElement4 = await State(restartOwner);
			Check(jsonElement4.GetProperty("history").GetArrayLength() >= 5, "History survives restart");
			Check(jsonElement4.GetProperty("items").GetArrayLength() == 0, "Outgoing shares cleared on restart");
			Check(jsonElement4.GetProperty("clipboard").GetArrayLength() == 0, "Clipboard content is not restored from disk after restart");
			Check(restarted.Nearby().Length == 0, "Restored native credentials alone do not advertise an open receiving app");
			using HttpClient restoredNamedPhone = Client(restarted.LocalUrl);
			using HttpClient restoredNamedPad = Client(restarted.LocalUrl);
			cookies[restoredNamedPhone].Add(new Uri(restarted.LocalUrl), new Cookie("ahna", cookies[namedPhone].GetCookies(new Uri(server.LocalUrl))["ahna"].Value, "/"));
			cookies[restoredNamedPad].Add(new Uri(restarted.LocalUrl), new Cookie("ahna", cookies[namedPad].GetCookies(new Uri(server.LocalUrl))["ahna"].Value, "/"));
			JsonElement restoredPhone = await State(restoredNamedPhone);
			JsonElement jsonElement5 = await State(restoredNamedPad);
			Check(restoredPhone.GetProperty("name").GetString() == "내 아이폰" && jsonElement5.GetProperty("name").GetString() == "거실 아이패드" && restarted.Nearby().Any(((string Id, string Name) d) => d.Id == namedPhoneId) && restarted.Nearby().Any(((string Id, string Name) d) => d.Id == namedPadId), "Custom device names and identities survive Windows restart and return on app heartbeat");
			Check(Program.AppIcon.Width == 32 && Program.AppIcon.Height == 32, "Branded icon embedded and decoded for native tray/windows");
			using (Stream input = typeof(Program).Assembly.GetManifestResourceStream("Ahna.AppIcon"))
			{
				using BinaryReader binaryReader = new BinaryReader(input);
				Check(binaryReader.ReadUInt16() == 0 && binaryReader.ReadUInt16() == 1 && binaryReader.ReadUInt16() == 7, "Windows ICO contains seven resolution frames");
			}
			if (string.Equals(Path.GetFileNameWithoutExtension(Environment.ProcessPath), "아나", StringComparison.OrdinalIgnoreCase))
			{
				Check(ExecutableIconMatches(Environment.ProcessPath), "Published Windows EXE icon resources match all seven branded ICO frames");
			}
			StorageFile storageFile = await StorageFile.GetFileFromPathAsync(source);
			StorageFolder storageFolder = await StorageFolder.GetFolderFromPathAsync(folder);
			string namedManifest = Path.Combine(root, "request.json");
			File.WriteAllText(namedManifest, "actual shared user file");
			StorageFile storageFile2 = await StorageFile.GetFileFromPathAsync(namedManifest);
			Check(ExplorerSelectionRoundTrip(new string[2] { source, namedManifest }).SequenceEqual(new string[2] { source, namedManifest }), "Explorer command delivers both selected files in one invocation");
			Check(ExplorerSelectionRoundTrip(new string[3] { source, folder, namedManifest }).SequenceEqual(new string[3] { source, folder, namedManifest }), "Explorer command preserves mixed file and folder selection with Unicode paths");
			Check(ExplorerSelectionRoundTrip(new string[2] { source, source }).SequenceEqual(new string[1] { source }), "Explorer command removes duplicate paths without losing unique items");
			DataPackage dataPackage = new DataPackage();
			dataPackage.SetStorageItems(new IStorageItem[3] { storageFile, storageFolder, storageFile2 });
			DataPackageView view = dataPackage.GetView();
			Check(view.Contains(StandardDataFormats.StorageItems), "Windows DataPackage exposes StorageItems share format");
			string cache = Path.Combine(root, "share-cache");
			string stagedManifest = await ShareStaging.StageAsync(await view.GetStorageItemsAsync(), cache);
			SharedFiles sharedFiles = ShareStaging.Load(stagedManifest, cache);
			Check(sharedFiles.Paths.Length == 3, "Windows share stages multiple storage items and accepts its request manifest");
			Check(SHA256.HashData(File.ReadAllBytes(sharedFiles.Paths[0])).SequenceEqual(SHA256.HashData(payload)), "Windows shared file copied with SHA256 integrity before source completion");
			Check(File.ReadAllText(sharedFiles.Paths[2]) == "actual shared user file", "Shared file named request.json cannot be overwritten by staging metadata");
			Check(File.ReadAllText(Path.Combine(sharedFiles.Paths[1], "하위", "메모.txt")) == "아나 폴더 전송" && Directory.Exists(Path.Combine(sharedFiles.Paths[1], "empty")), "Windows shared folder preserves Unicode hierarchy and empty directories");
			Check(sharedFiles.Bytes == payload.Length + new FileInfo(namedManifest).Length + new FileInfo(Path.Combine(folder, "하위", "메모.txt")).Length, "Windows share staged byte count matches copied files");
			string duplicateManifest = await ShareStaging.StageAsync(new IStorageItem[2] { storageFile, storageFile }, cache);
			SharedFiles sharedFiles2 = ShareStaging.Load(duplicateManifest, cache);
			Check(sharedFiles2.Paths.Distinct(StringComparer.OrdinalIgnoreCase).Count() == 2 && sharedFiles2.Paths.All(File.Exists), "Duplicate filenames in Windows share preserve both items");
			string contents = File.ReadAllText(stagedManifest);
			Util.SaveJson(stagedManifest, new SharedFiles(new string[1] { source }, 0L));
			bool ok4 = false;
			try
			{
				ShareStaging.Load(stagedManifest, cache);
			}
			catch (ArgumentException)
			{
				ok4 = true;
			}
			Check(ok4, "Windows share request cannot point outside its own staging directory");
			File.WriteAllText(stagedManifest, contents);
			int beforeCancel = Directory.GetDirectories(cache).Length;
			using (CancellationTokenSource cancelled = new CancellationTokenSource())
			{
				cancelled.Cancel();
				bool enabled = false;
				try
				{
					await ShareStaging.StageAsync(new IStorageItem[1] { storageFile }, cache, null, cancelled.Token);
				}
				catch (OperationCanceledException)
				{
					enabled = true;
				}
				Check(enabled && Directory.GetDirectories(cache).Length == beforeCancel, "Cancelled Windows share cleans incomplete staging directory");
			}
			bool emptyShare = false;
			try
			{
				await ShareStaging.StageAsync(Array.Empty<IStorageItem>(), cache);
			}
			catch (ArgumentException)
			{
				emptyShare = true;
			}
			Check(emptyShare, "Empty Windows share rejected");
			bool largeShare = false;
			try
			{
				await ShareStaging.StageAsync(Enumerable.Repeat((IStorageItem)storageFile, 257).ToArray(), cache);
			}
			catch (ArgumentException)
			{
				largeShare = true;
			}
			Check(largeShare, "Oversized Windows share item list rejected");
			string text6 = "Ahna-test-" + Guid.NewGuid().ToString("N");
			await using (NamedPipeServerStream listener = new NamedPipeServerStream(text6, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly))
			{
				string[] args = new string[2] { "--shared-manifest", stagedManifest };
				text2 = text6;
				Task forwarded = WindowsShare.ForwardAsync(args, default, text2);
				await listener.WaitForConnectionAsync().WaitAsync(TimeSpan.FromSeconds(5L));
				using StreamReader reader = new StreamReader(listener, null, detectEncodingFromByteOrderMarks: true, -1, leaveOpen: true);
				using StreamWriter writer = new StreamWriter(listener, null, -1, leaveOpen: true)
				{
					AutoFlush = true
				};
				array4 = JsonSerializer.Deserialize<string[]>(await reader.ReadLineAsync());
				await writer.WriteLineAsync("{\"accepted\":true}");
				await forwarded;
				Check(array4.SequenceEqual(new string[2] { "--shared-manifest", stagedManifest }), "Windows share single-instance delivery waits for acknowledgement and preserves request path");
			}
			string? directoryName = Path.GetDirectoryName(duplicateManifest);
			ShareStaging.RemoveStage(directoryName, cache);
			Check(!Directory.Exists(directoryName) && File.Exists(source), "Staging cleanup does not delete original shared source files");
			// 1.2 게스트 링크 (근처 기기 · QR): 서버 중계 경로 /s/{컴퓨터}/{토큰} 으로 주고받는 1회용 티켓
			{
				await using TransferServer guestHost = new TransferServer(Path.Combine(root, "guest-data"), FreePort());
				guestHost.SaveSettings(new Preferences
				{
					SavePath = Path.Combine(root, "guest-received"),
					RemoteUrl = "https://ahna.example",
					RemoteKeyProtected = RemoteKey.Protect(new string('a', 64))
				});
				await guestHost.StartAsync(Path.Combine(AppContext.BaseDirectory, "wwwroot"));
				using HttpClient guestClient = Client(guestHost.LocalUrl);
				string guestSource = Path.Combine(root, "guest-send.txt");
				File.WriteAllText(guestSource, "아나 게스트 보내기");
				TransferServer.GuestTicket guestSend = await guestHost.CreateSendTicketAsync(new string[1] { guestSource }, "Test iPhone", "47");
				string guestSendUrl = guestHost.GuestUrl(guestSend);
				string guestSendPath = new Uri(guestSendUrl).AbsolutePath;
				Check(guestSendUrl.StartsWith("https://ahna.example/s/" + guestHost.ComputerId + "/", StringComparison.Ordinal) && guestSend.Token.Length == 43
					&& Ahna.Remote.Wire.Allowed("GET", guestSendPath) && Ahna.Remote.Wire.Allowed("GET", guestSendPath + "/info") && Ahna.Remote.Wire.Allowed("GET", guestSendPath + "/file/0") && Ahna.Remote.Wire.Allowed("POST", guestSendPath + "/upload?i=0&name=a")
					&& Ahna.Remote.Wire.LargeBody(guestSendPath + "/upload?i=0") && !Ahna.Remote.Wire.LargeBody(guestSendPath + "/request") && Ahna.Remote.Wire.GuestComputer(guestSendPath) == guestHost.ComputerId
					&& !Ahna.Remote.Wire.Allowed("GET", guestSendPath + "/file/01") && !Ahna.Remote.Wire.Allowed("POST", guestSendPath + "/file/0") && !Ahna.Remote.Wire.Allowed("GET", "/s/" + guestHost.ComputerId + "/short"), "Guest link format and relay allow-list");
				HttpResponseMessage guestPage = await guestClient.GetAsync(guestSendPath);
				string guestHtml = await guestPage.Content.ReadAsStringAsync();
				Check(guestPage.IsSuccessStatusCode && guestHtml.Contains("<script nonce=", StringComparison.Ordinal) && guestPage.Headers.TryGetValues("Content-Security-Policy", out var guestCsp) && guestCsp.Single().Contains("'nonce-", StringComparison.Ordinal), "Guest page served self-contained with a nonce CSP");
				JsonElement guestInfo = await guestClient.GetFromJsonAsync<JsonElement>(guestSendPath + "/info");
				Check(guestInfo.GetProperty("kind").GetString() == "send" && guestInfo.GetProperty("code").GetString() == "47" && guestInfo.GetProperty("files").GetArrayLength() == 1 && guestInfo.GetProperty("state").GetString() == "ready" && guestInfo.GetProperty("expiresIn").GetInt32() > 500, "Guest send info");
				Check((await guestClient.GetAsync("/s/" + guestHost.ComputerId + "/" + new string('x', 43) + "/info")).StatusCode == HttpStatusCode.NotFound && (await guestClient.GetAsync("/s/" + new string('0', 32) + "/" + guestSend.Token + "/info")).StatusCode == HttpStatusCode.NotFound, "Unknown guest token or computer returns 404");
				HttpResponseMessage guestDownload = await guestClient.GetAsync(guestSendPath + "/file/0");
				Check(guestDownload.IsSuccessStatusCode && await guestDownload.Content.ReadAsStringAsync() == "아나 게스트 보내기" && guestDownload.Content.Headers.ContentDisposition?.FileNameStar == "guest-send.txt", "Guest downloads the offered file");
				for (int wait = 0; wait < 50 && guestSend.State != "done"; wait++)
				{
					await Task.Delay(100);
				}
				Check(guestSend.State == "done" && (await guestClient.GetAsync(guestSendPath + "/file/0")).StatusCode == HttpStatusCode.NotFound && File.Exists(guestSource), "Send ticket ends after every file was delivered once");
				TransferServer.GuestTicket? guestAsked = null;
				guestHost.GuestRequested = (TransferServer.GuestTicket asked) =>
				{
					guestAsked = asked;
				};
				TransferServer.GuestTicket guestReceive = guestHost.CreateReceiveTicket();
				string guestReceivePath = new Uri(guestHost.GuestUrl(guestReceive)).AbsolutePath;
				HttpResponseMessage guestRequest = await guestClient.PostAsJsonAsync(guestReceivePath + "/request", new
				{
					name = "민수",
					files = new[] { new { name = "사진.jpg", bytes = 5 } }
				});
				JsonElement guestRequested = await guestRequest.Content.ReadFromJsonAsync<JsonElement>();
				Check(guestRequest.IsSuccessStatusCode && guestRequested.GetProperty("state").GetString() == "waiting" && guestAsked == guestReceive && guestReceive.Peer == "민수" && guestReceive.Code?.Length == 2, "Guest upload request waits for the owner");
				string guestUploadPath = guestReceivePath + "/upload?i=0&name=" + Uri.EscapeDataString("사진.jpg");
				Check((await guestClient.PostAsync(guestUploadPath, new ByteArrayContent(new byte[5]))).StatusCode == HttpStatusCode.Conflict, "Guest cannot upload before the owner accepts");
				Check(guestHost.AnswerGuest(guestReceive.Token, accept: true) && (await guestClient.GetFromJsonAsync<JsonElement>(guestReceivePath + "/status")).GetProperty("state").GetString() == "accepted", "Owner accepts the guest request");
				HttpResponseMessage guestUploaded = await guestClient.PostAsync(guestUploadPath, new ByteArrayContent(new byte[5] { 1, 2, 3, 4, 5 }));
				Check(guestUploaded.IsSuccessStatusCode && File.ReadAllBytes(Path.Combine(root, "guest-received", "사진.jpg")).SequenceEqual(new byte[5] { 1, 2, 3, 4, 5 }) && guestReceive.State == "done" && guestHost.HistorySnapshot().Any((HistoryItem item) => item.Direction == "receive" && item.Device == "민수" && item.Status == "저장 완료"), "Accepted guest upload is saved like a normal receive");
				TransferServer.GuestTicket guestDeclined = guestHost.CreateReceiveTicket();
				string guestDeclinedPath = new Uri(guestHost.GuestUrl(guestDeclined)).AbsolutePath;
				await guestClient.PostAsJsonAsync(guestDeclinedPath + "/request", new
				{
					name = "x",
					files = new[] { new { name = "a.txt", bytes = 1 } }
				});
				guestHost.AnswerGuest(guestDeclined.Token, accept: false);
				Check(guestDeclined.State == "declined" && (await guestClient.PostAsync(guestDeclinedPath + "/upload?i=0&name=a.txt", new ByteArrayContent(new byte[1]))).StatusCode == HttpStatusCode.NotFound && (await guestClient.GetFromJsonAsync<JsonElement>(guestDeclinedPath + "/status")).GetProperty("state").GetString() == "declined", "Declined guest request cannot upload and reports declined");
				byte[] guestOffer = NearbyService.OfferBytes("사무실 PC", "47", 2, 5347123L, "사진 2장", guestSendUrl);
				NearbyOffer? guestParsed = NearbyService.ParseOffer(guestOffer, null);
				Check(guestOffer.Length <= NearbyService.MaxOfferBytes && guestParsed != null && guestParsed.Code == "47" && guestParsed.Url == guestSendUrl && guestParsed.Count == 2 && guestParsed.Name == "사무실 PC"
					&& NearbyService.ParseOffer(JsonSerializer.SerializeToUtf8Bytes(new { v = 1, t = "offer", code = "47", count = 1, bytes = 1, url = "http://ahna.example/s/" + guestHost.ComputerId + "/" + guestSend.Token }), null) == null, "Nearby offer fits 512 bytes and only accepts HTTPS guest links");
			}
			success = true;
		}
		catch (Exception ex8)
		{
			failure = ex8.ToString();
		}
		finally
		{
			try
			{
				Directory.Delete(root, recursive: true);
			}
			catch
			{
			}
		}
		string text7 = JsonSerializer.Serialize(new
		{
			success = success,
			at = DateTimeOffset.UtcNow,
			checks = checks,
			failure = failure
		}, Util.Json);
		if (reportPath != null)
		{
			Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(reportPath)));
			File.WriteAllText(reportPath, text7);
		}
		Console.WriteLine(text7);
		return (!success) ? 1 : 0;
		void Check(bool flag6, string text8)
		{
			checks.Add(new
			{
				name = text8,
				passed = flag6
			});
			if (!flag6)
			{
				throw new Exception(text8);
			}
		}
		HttpClient Client(string url)
		{
			CookieContainer cookieContainer = new CookieContainer();
			HttpClient httpClient = new HttpClient(new HttpClientHandler
			{
				CookieContainer = cookieContainer
			})
			{
				BaseAddress = new Uri(url),
				Timeout = TimeSpan.FromSeconds(40L)
			};
			cookies[httpClient] = cookieContainer;
			return httpClient;
		}
		static int FreePort()
		{
			using TcpListener tcpListener = new TcpListener(IPAddress.Loopback, 0);
			tcpListener.Start();
			return ((IPEndPoint)tcpListener.LocalEndpoint).Port;
		}
		static async Task<JsonElement> State(HttpClient client)
		{
			return await client.GetFromJsonAsync<JsonElement>("api/state");
		}
	}

	private static string[] ExplorerSelectionRoundTrip(string[] paths)
	{
		string[] result = null;
		Exception failure = null;
		Thread thread = new Thread(() =>
		{
			nint[] array = paths.Select(ILCreateFromPath).ToArray();
			IShellItemArray items = null;
			try
			{
				if (array.Any((nint x) => x == IntPtr.Zero))
				{
					throw new Exception("Shell item creation failed");
				}
				Marshal.ThrowExceptionForHR(SHCreateShellItemArrayFromIDLists((uint)array.Length, array, out items));
				int calls = 0;
				ExplorerCommand explorerCommand = new ExplorerCommand((string[] array4) =>
				{
					calls++;
					result = array4;
				});
				nint iUnknownForObject = Marshal.GetIUnknownForObject(explorerCommand);
				try
				{
					Guid[] array2 = new Guid[2]
					{
						typeof(IExplorerExecuteCommand).GUID,
						typeof(IExplorerObjectWithSelection).GUID
					};
					for (int num = 0; num < array2.Length; num++)
					{
						Guid iid = array2[num];
						Marshal.ThrowExceptionForHR(Marshal.QueryInterface(iUnknownForObject, in iid, out var ppv));
						Marshal.Release(ppv);
					}
				}
				finally
				{
					Marshal.Release(iUnknownForObject);
				}
				Marshal.ThrowExceptionForHR(explorerCommand.SetSelection(items));
				Marshal.ThrowExceptionForHR(explorerCommand.Execute());
				if (calls != 1)
				{
					throw new Exception("Explorer selection was not delivered exactly once");
				}
			}
			catch (Exception ex)
			{
				failure = ex;
			}
			finally
			{
				if (items != null)
				{
					Marshal.ReleaseComObject(items);
				}
				nint[] array3 = array;
				foreach (nint num2 in array3)
				{
					if (num2 != IntPtr.Zero)
					{
						Marshal.FreeCoTaskMem(num2);
					}
				}
			}
		});
		thread.SetApartmentState(ApartmentState.STA);
		thread.Start();
		thread.Join();
		if (failure != null)
		{
			throw failure;
		}
		return result;
	}

	[DllImport("shell32.dll", CharSet = CharSet.Unicode, EntryPoint = "ILCreateFromPathW")]
	private static extern nint ILCreateFromPath(string path);

	[DllImport("shell32.dll")]
	private static extern int SHCreateShellItemArrayFromIDLists(uint count, [MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 0)] nint[] pidls, out IShellItemArray items);

	private static bool ExecutableIconMatches(string path)
	{
		PEReader pe;
		byte[] resources;
		using (FileStream peStream = File.OpenRead(path))
		{
			pe = new PEReader(peStream);
			try
			{
				resources = pe.GetSectionData(pe.PEHeaders.PEHeader.ResourceTableDirectory.RelativeVirtualAddress).GetContent().ToArray();
				Dictionary<int, byte[]> dictionary = Type(14);
				Dictionary<int, byte[]> dictionary2 = Type(3);
				byte[] value = dictionary.Values.Single();
				using Stream stream = typeof(Program).Assembly.GetManifestResourceStream("Ahna.AppIcon");
				using MemoryStream memoryStream = new MemoryStream();
				stream.CopyTo(memoryStream);
				byte[] array = memoryStream.ToArray();
				ushort num = BitConverter.ToUInt16(array, 4);
				if (BitConverter.ToUInt16(value, 4) != num)
				{
					return false;
				}
				for (int i = 0; i < num; i++)
				{
					int num2 = 6 + i * 16;
					int num3 = 6 + i * 14;
					int length = BitConverter.ToInt32(array, num2 + 8);
					int start = BitConverter.ToInt32(array, num2 + 12);
					ushort key = BitConverter.ToUInt16(value, num3 + 12);
					if (!dictionary2.TryGetValue(key, out var value2) || !value2.SequenceEqual(array.AsSpan(start, length).ToArray()))
					{
						return false;
					}
				}
				return true;
			}
			finally
			{
				if (pe != null)
				{
					((IDisposable)pe).Dispose();
				}
			}
		}
		(int Id, int Offset)[] Entries(int directory)
		{
			int count = BitConverter.ToUInt16(resources, directory + 12) + BitConverter.ToUInt16(resources, directory + 14);
			return Enumerable.Range(0, count).Select((int num5) =>
			{
				int num4 = directory + 16 + num5 * 8;
				return ((int)(BitConverter.ToUInt32(resources, num4) & 0x7FFFFFFF), (int)(BitConverter.ToUInt32(resources, num4 + 4) & 0x7FFFFFFF));
			}).ToArray();
		}
		Dictionary<int, byte[]> Type(int type)
		{
			int item = Entries(0).Single(((int Id, int Offset) e) => e.Id == type).Offset;
			return Entries(item).ToDictionary(((int Id, int Offset) e) => e.Id, ((int Id, int Offset) e) =>
			{
				int item2 = Entries(e.Offset)[0].Offset;
				int relativeVirtualAddress = BitConverter.ToInt32(resources, item2);
				int length2 = BitConverter.ToInt32(resources, item2 + 4);
				return pe.GetSectionData(relativeVirtualAddress).GetContent(0, length2).ToArray();
			});
		}
	}
}
