import Foundation
import Photos
import UniformTypeIdentifiers

enum PhotoLibrarySaver {
    static func isMedia(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }
    static func save(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "Ahna.Photos", code: 1, userInfo: [NSLocalizedDescriptionKey: "파일 앱에 저장했습니다. 사진 앱에도 저장하려면 설정에서 아나의 사진 추가 권한을 허용하세요."])
        }
        let video = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: video ? .video : .photo, fileURL: url, options: nil)
        }
    }
}
