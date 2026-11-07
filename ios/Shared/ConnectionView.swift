import SwiftUI

struct ConnectionView: View {
    @ObservedObject var client: AhnaClient
    var body: some View {
        Section("연결한 기기") {
            ForEach(client.connections) { connection in
                HStack {
                    Button {
                        client.selectedID = connection.id
                    } label: {
                        HStack {
                            DeviceStatusIcon(systemName: client.selectedID == connection.id ? "checkmark.circle.fill" : "desktopcomputer", isOnline: connection.state != nil)
                            VStack(alignment: .leading) {
                                Text(connection.hostName).font(.headline)
                                Text(connection.status).font(.caption).foregroundStyle(.secondary)
                            }
                            ConnectionStatusBadge(isOnline: connection.state != nil)
                        }
                    }.buttonStyle(.borderless).disabled(client.busy)
                    Spacer()
                    Button("삭제", role: .destructive) { Task { await client.forget(connection) } }
                        .buttonStyle(.borderless).disabled(client.busy)
                }
            }
            if client.connections.isEmpty { Text("아직 추가한 기기가 없습니다.").foregroundStyle(.secondary) }
            Text("여러 기기의 연결을 함께 유지합니다. 꺼진 기기는 켜지고 아나가 실행되면 자동으로 다시 연결됩니다.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section("기기 추가 / 다시 인증") {
            TextField("서버 HTTPS 주소 또는 상대 기기의 로컬 주소", text: $client.address)
                .ahnaURLInput()
                .disabled(client.busy)
            TextField("추가할 기기의 6자리 연결 코드", text: $client.pin).ahnaCodeInput().disabled(client.busy)
            Button("기기 추가") { Task { await client.connect() } }.disabled(client.busy)
            Text(client.status).font(.footnote).foregroundStyle(.secondary)
        }
        Section("이 기기의 이름") {
            TextField("예: 내 아이폰, 거실 아이패드", text: $client.deviceName)
                .ahnaNameInput().disabled(client.busy)
            Button("이름 저장") { Task { await client.saveDeviceName() } }.disabled(client.busy)
            Text(client.deviceNameStatus.isEmpty ? "기기에서 받을 기기를 고를 때 표시되는 이름입니다." : client.deviceNameStatus)
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private extension View {
    @ViewBuilder func ahnaURLInput() -> some View {
        #if os(iOS)
        self.keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
    @ViewBuilder func ahnaCodeInput() -> some View {
        #if os(iOS)
        self.keyboardType(.numberPad)
        #else
        self
        #endif
    }
    @ViewBuilder func ahnaNameInput() -> some View {
        #if os(iOS)
        self.textInputAutocapitalization(.never).autocorrectionDisabled()
        #else
        self
        #endif
    }
}

struct WindowsTargetView: View {
    @ObservedObject var client: AhnaClient
    let send: () -> Void
    var body: some View {
        Section("보낼 기기") {
            ForEach(client.connections) { connection in
                Button {
                    client.selectedID = connection.id
                    send()
                } label: {
                    HStack {
                        DeviceStatusIcon(systemName: "desktopcomputer", isOnline: connection.state != nil).font(.title)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.hostName).font(.headline).foregroundStyle(.primary)
                            ConnectionStatusBadge(isOnline: connection.state != nil, onlineText: "온라인 · 눌러서 보내기", offlineText: "오프라인 · 재연결 대기")
                        }
                        Spacer(); Image(systemName: "paperplane.fill").foregroundStyle(connection.state == nil ? AhnaPalette.offline : AhnaPalette.accent)
                    }.padding(.vertical, 8).ahnaRow(isOnline: connection.state != nil)
                }.disabled(client.busy || connection.state == nil)
            }
            if client.connections.isEmpty { Text("먼저 기기를 추가하세요.").foregroundStyle(.secondary) }
        }
    }
}
