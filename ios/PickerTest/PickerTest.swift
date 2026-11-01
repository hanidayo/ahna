// 파일 앱 고르기 시험용 아주 작은 앱 (아나와 무관한 별도 앱). 설치 환경 문제인지 아나 문제인지 가르는 용도.
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@main struct PickerTestApp: App { var body: some Scene { WindowGroup { ContentView() } } }

struct ContentView: View {
    @State private var importing = false
    @State private var log: [String] = []
    var body: some View {
        VStack(spacing: 16) {
            Text("파일 고르기 시험").font(.title2.bold())
            Button("1. SwiftUI fileImporter") { importing = true }.buttonStyle(.borderedProminent)
            Button("2. UIKit 선택 창 (복사)") { Picker.shared.present(asCopy: true) { add($0) } }.buttonStyle(.borderedProminent)
            Button("3. UIKit 선택 창 (그 자리)") { Picker.shared.present(asCopy: false) { add($0) } }.buttonStyle(.borderedProminent)
            List(log, id: \.self) { Text($0).font(.footnote) }
        }
        .padding(.top, 40)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): add("fileImporter: \(urls.count)개 · " + urls.map(\.lastPathComponent).joined(separator: ", "))
            case .failure(let error): add("fileImporter 오류: \(error.localizedDescription)")
            }
        }
    }
    func add(_ line: String) { log.insert(line, at: 0) }
}

@MainActor final class Picker: NSObject, UIDocumentPickerDelegate {
    static let shared = Picker()
    var done: ((String) -> Void)?
    func present(asCopy: Bool, _ done: @escaping (String) -> Void) {
        self.done = done
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: asCopy)
        picker.allowsMultipleSelection = true; picker.delegate = self
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { done("창을 찾지 못함"); return }
        while let next = top.presentedViewController { top = next }
        top.present(picker, animated: true)
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        done?("UIKit: \(urls.count)개 · " + urls.map(\.lastPathComponent).joined(separator: ", "))
    }
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { done?("UIKit: 취소") }
}
