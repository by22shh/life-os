import AVFoundation
import Combine
import GRDB
import Observation
import PDFKit
import PhotosUI
import Speech
import SwiftUI
import UIKit
import Vision
//
//  Extracted from NutritionDayView.swift as part of the module split.
//
@MainActor
final class NutritionSpeechRecognizer: NSObject, ObservableObject {
    private typealias SpeechAuthorizationCompletion = @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void
    private typealias MicrophonePermissionCompletion = @Sendable (Bool) -> Void

    @Published private(set) var isRecording = false
    @Published private(set) var isProcessing = false
    @Published private(set) var transcription = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var confidence: Double?

     let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale.autoupdatingCurrent)
        ?? SFSpeechRecognizer(locale: Locale(identifier: "en_US"))
     var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
#if DEBUG
    private static let testSpeechAuthorizationRequestOverride = LockedTestOverride<
        @Sendable (@escaping SpeechAuthorizationCompletion) -> Void
    >()
    private static let testAudioApplicationPermissionOverride = LockedTestOverride<
        @Sendable (@escaping MicrophonePermissionCompletion) -> Void
    >()
    private static let testAudioSessionPermissionOverride = LockedTestOverride<
        @Sendable (@escaping MicrophonePermissionCompletion) -> Void
    >()
    private static let testInstallAudioTapOverride = LockedTestOverride<
        @Sendable (NutritionSpeechRecognizer, SFSpeechAudioBufferRecognitionRequest) -> Void
    >()
    private static let testPrepareAudioOverride = LockedTestOverride<
        @Sendable (AVAudioEngine) -> Void
    >()
    private static let testStartAudioOverride = LockedTestOverride<
        @Sendable (AVAudioEngine) throws -> Void
    >()
    private static let testStartRecognitionTaskOverride = LockedTestOverride<
        @Sendable (@escaping @MainActor (String?, Bool, Error?) -> Void) async -> Void
    >()
    private static let testEndAudioOverride = LockedTestOverride<
        @Sendable (SFSpeechAudioBufferRecognitionRequest?) -> Void
    >()
    private static let testFinishAudioPipelineOverride = LockedTestOverride<
        @Sendable (NutritionSpeechRecognizer) -> Void
    >()
    private static let testConfigureSessionCategoryOverride = LockedTestOverride<
        @Sendable () throws -> Void
    >()
    private static let testConfigureSessionActiveOverride = LockedTestOverride<
        @Sendable () throws -> Void
    >()
#endif

    func startRecording(
        permissionAction: (() async throws -> Void)? = nil,
        configureSessionAction: (() throws -> Void)? = nil,
        installAudioTapAction: ((SFSpeechAudioBufferRecognitionRequest) -> Void)? = nil,
        prepareAudioAction: (() -> Void)? = nil,
        startAudioAction: (() throws -> Void)? = nil,
        startRecognitionTaskAction: ((@escaping @MainActor (String?, Bool, Error?) -> Void) async -> Void)? = nil
    ) async {
        errorMessage = nil

        do {
            if let permissionAction {
                try await permissionAction()
            } else {
                try await requestPermissions()
            }

            if let configureSessionAction {
                try configureSessionAction()
            } else {
                try configureSession()
            }

            transcription = ""
            confidence = nil
            isProcessing = false

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request

            installAudioTap(request, explicitAction: installAudioTapAction)
            prepareAudio(explicitAction: prepareAudioAction)
            try startAudio(explicitAction: startAudioAction)
            isRecording = true

            recognitionTask?.cancel()
            let handleRecognitionUpdate = recognitionUpdateHandler()
            await startRecognitionTask(
                with: request,
                explicitAction: startRecognitionTaskAction,
                handleRecognitionUpdate: handleRecognitionUpdate
            )
        } catch {
            errorMessage = error.localizedDescription
            finishRecording()
        }
    }

    func stopRecording(
        endAudioAction: (() -> Void)? = nil,
        finishAudioPipelineAction: (() -> Void)? = nil
    ) async {
        guard isRecording else { return }
        isProcessing = true
        endAudio(explicitAction: endAudioAction)
        completeAudioPipeline(explicitAction: finishAudioPipelineAction)

        if transcription.isEmpty {
            isProcessing = false
        }
    }

    private func recognitionUpdateHandler() -> @MainActor (String?, Bool, Error?) -> Void {
        { [weak self] transcript, isFinal, error in
            guard let self else { return }

            if let transcript {
                self.transcription = transcript
                self.confidence = isFinal ? 0.9 : 0.75
                self.isProcessing = false
            }

            if let error {
                self.errorMessage = error.localizedDescription
                self.finishRecording()
                return
            }

            if isFinal {
                self.finishRecording()
            }
        }
    }

     func installAudioTap(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        explicitAction: ((SFSpeechAudioBufferRecognitionRequest) -> Void)? = nil,
        defaultAction: ((SFSpeechAudioBufferRecognitionRequest) -> Void)? = nil
    ) {
        if let explicitAction {
            explicitAction(request)
            return
        }
#if DEBUG
        if let override = Self.testInstallAudioTapOverride.value {
            override(self, request)
            return
        }
#endif
        let resolvedDefaultAction = defaultAction ?? { request in
            self.installDefaultAudioTap(request)
        }
        resolvedDefaultAction(request)
    }

     func prepareAudio(explicitAction: (() -> Void)? = nil) {
        if let explicitAction {
            explicitAction()
            return
        }
#if DEBUG
        if let override = Self.testPrepareAudioOverride.value {
            override(audioEngine)
            return
        }
#endif
        audioEngine.prepare()
    }

     func startAudio(
        explicitAction: (() throws -> Void)? = nil,
        defaultAction: (() throws -> Void)? = nil
    ) throws {
        if let explicitAction {
            try explicitAction()
            return
        }
#if DEBUG
        if let override = Self.testStartAudioOverride.value {
            try override(audioEngine)
            return
        }
#endif
        let resolvedDefaultAction = defaultAction ?? {
            try self.audioEngine.start()
        }
        try resolvedDefaultAction()
    }

     func startRecognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        explicitAction: ((@escaping @MainActor (String?, Bool, Error?) -> Void) async -> Void)? = nil,
        defaultAction: ((@escaping @MainActor (String?, Bool, Error?) -> Void) async -> Void)? = nil,
        fallbackAction: ((@escaping @MainActor (String?, Bool, Error?) -> Void) async -> Void)? = nil,
        handleRecognitionUpdate: @escaping @MainActor (String?, Bool, Error?) -> Void
    ) async {
        if let explicitAction {
            await explicitAction(handleRecognitionUpdate)
            return
        }
#if DEBUG
        if let override = Self.testStartRecognitionTaskOverride.value {
            await override(handleRecognitionUpdate)
            return
        }
#endif
        if let defaultAction {
            await defaultAction(handleRecognitionUpdate)
        } else {
            let resolvedFallbackAction = fallbackAction ?? { handleRecognitionUpdate in
                self.startDefaultRecognitionTask(
                    with: request,
                    handleRecognitionUpdate: handleRecognitionUpdate
                )
            }
            await resolvedFallbackAction(handleRecognitionUpdate)
        }
    }

     func endAudio(explicitAction: (() -> Void)? = nil) {
        if let explicitAction {
            explicitAction()
            return
        }
#if DEBUG
        if let override = Self.testEndAudioOverride.value {
            override(recognitionRequest)
            return
        }
#endif
        recognitionRequest?.endAudio()
    }

     func completeAudioPipeline(explicitAction: (() -> Void)? = nil) {
        if let explicitAction {
            explicitAction()
            return
        }
#if DEBUG
        if let override = Self.testFinishAudioPipelineOverride.value {
            override(self)
            return
        }
#endif
        finishAudioPipeline()
    }

     func installDefaultAudioTap(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        removeTapAction: ((AVAudioInputNode) -> Void)? = nil,
        outputFormatAction: ((AVAudioInputNode) -> AVAudioFormat)? = nil,
        installTapAction: ((AVAudioInputNode, AVAudioFormat, @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) -> Void)? = nil,
        defaultRemoveTapAction: ((AVAudioInputNode) -> Void)? = nil,
        defaultOutputFormatAction: ((AVAudioInputNode) -> AVAudioFormat)? = nil,
        defaultInstallTapAction: ((AVAudioInputNode, AVAudioFormat, @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) -> Void)? = nil
    ) {
        let inputNode = audioEngine.inputNode
        let resolvedRemoveTapAction =
            removeTapAction ?? defaultRemoveTapAction ?? { $0.removeTap(onBus: 0) }
        let resolvedOutputFormatAction =
            outputFormatAction ?? defaultOutputFormatAction ?? { $0.outputFormat(forBus: 0) }
        let resolvedInstallTapAction =
            installTapAction ?? defaultInstallTapAction ?? { inputNode, recordingFormat, appendBuffer in
                self.defaultInstallTap(
                    inputNode,
                    recordingFormat,
                    appendBuffer,
                    installTapAction: nil
                )
            }

        resolvedRemoveTapAction(inputNode)
        let recordingFormat = resolvedOutputFormatAction(inputNode)

        func appendBuffer(_ buffer: AVAudioPCMBuffer, _: AVAudioTime) {
            recognitionRequest?.append(buffer)
        }

        resolvedInstallTapAction(inputNode, recordingFormat, appendBuffer)
    }

     func defaultInstallTap(
        _ inputNode: AVAudioInputNode,
        _ recordingFormat: AVAudioFormat,
        _ appendBuffer: @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void,
        installTapAction: ((AVAudioInputNode, AVAudioFormat, @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void) -> Void)? = nil,
        systemInstallTapAction: ((
            AVAudioInputNode,
            AVAudioFormat,
            @escaping (AVAudioPCMBuffer, AVAudioTime) -> Void
        ) -> Void)? = nil
    ) {
        let resolvedInstallTapAction = installTapAction ?? systemInstallTapAction ?? {
            inputNode,
            recordingFormat,
            appendBuffer in
            inputNode.installTap(
                onBus: 0,
                bufferSize: 1024,
                format: recordingFormat,
                block: appendBuffer
            )
        }
        resolvedInstallTapAction(inputNode, recordingFormat, appendBuffer)
    }

     func startDefaultRecognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        handleRecognitionUpdate: @escaping @MainActor (String?, Bool, Error?) -> Void,
        recognitionTaskAction: ((SFSpeechAudioBufferRecognitionRequest, @escaping (String?, Bool, Error?) -> Void) -> SFSpeechRecognitionTask?)? = nil
    ) {
        let taskAction = recognitionTaskAction ?? { request, update in
            self.defaultRecognitionTaskAction(
                request,
                update,
                recognitionTaskAction: nil
            )
        }

        recognitionTask = taskAction(request) { transcript, isFinal, error in
            Task { @MainActor in
                handleRecognitionUpdate(transcript, isFinal, error)
            }
        }
    }

     func defaultRecognitionTaskAction(
        _ request: SFSpeechAudioBufferRecognitionRequest,
        _ update: @escaping (String?, Bool, Error?) -> Void,
        recognitionTaskAction: ((SFSpeechAudioBufferRecognitionRequest, @escaping (SFSpeechRecognitionResult?, Error?) -> Void) -> SFSpeechRecognitionTask?)?
    ) -> SFSpeechRecognitionTask? {
        let resolvedRecognitionTaskAction =
            recognitionTaskAction ?? { request, handler in
                self.speechRecognizer?.recognitionTask(with: request, resultHandler: handler)
            }
        return resolvedRecognitionTaskAction(
            request,
            defaultRecognitionResultHandler(update)
        )
    }

    private func defaultRecognitionResultHandler(
        _ update: @escaping (String?, Bool, Error?) -> Void
    ) -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            let transcript = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal == true
            update(transcript, isFinal, error)
        }
    }

     func requestPermissions(
        speechAuthorizationRequest: ((@escaping SpeechAuthorizationCompletion) -> Void)? = nil,
        microphonePermissionRequest: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil,
        defaultSpeechAuthorizationRequest: ((@escaping SpeechAuthorizationCompletion) -> Void)? = nil,
        defaultMicrophonePermissionRequest: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil
    ) async throws {
        let speechAuthorized = await requestSpeechAuthorization(
            requestAction: speechAuthorizationRequest,
            defaultRequestAction: defaultSpeechAuthorizationRequest
        )
        guard speechAuthorized else {
            throw SpeechRecognitionError.speechPermissionDenied
        }

        let micAuthorized = await requestMicrophonePermission(
            requestAction: microphonePermissionRequest,
            defaultRequestAction: defaultMicrophonePermissionRequest
        )
        guard micAuthorized else {
            throw SpeechRecognitionError.microphonePermissionDenied
        }
    }

    private func requestSpeechAuthorization(
        requestAction: ((@escaping SpeechAuthorizationCompletion) -> Void)? = nil,
        defaultRequestAction: ((@escaping SpeechAuthorizationCompletion) -> Void)? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let authorizationAction = requestAction ?? defaultRequestAction ?? { completion in
                self.defaultSpeechAuthorizationRequest(completion: completion)
            }
            authorizationAction { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    private func requestMicrophonePermission(
        requestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil,
        defaultRequestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let permissionAction = requestAction ?? defaultRequestAction ?? { completion in
                self.defaultMicrophonePermissionRequest(completion: completion)
            }
            permissionAction { allowed in
                continuation.resume(returning: allowed)
            }
        }
    }

     func defaultSpeechAuthorizationRequest(
        completion: @escaping SpeechAuthorizationCompletion,
        requestAction: ((@escaping SpeechAuthorizationCompletion) -> Void)? = nil
    ) {
        let authorize: (@escaping SpeechAuthorizationCompletion) -> Void
#if DEBUG
        authorize = requestAction ?? Self.testSpeechAuthorizationRequestOverride.value ?? { completion in
            SFSpeechRecognizer.requestAuthorization { status in
                completion(status)
            }
        }
#else
        authorize = requestAction ?? { completion in
            SFSpeechRecognizer.requestAuthorization { status in
                completion(status)
            }
        }
#endif
        authorize { status in
            completion(status)
        }
    }

     func defaultMicrophonePermissionRequest(
        completion: @escaping MicrophonePermissionCompletion,
        useAudioApplicationRequest: Bool? = nil,
        audioApplicationRequest: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil,
        audioSessionRequest: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil
    ) {
        let shouldUseAudioApplicationRequest: Bool
        if let useAudioApplicationRequest {
            shouldUseAudioApplicationRequest = useAudioApplicationRequest
        } else if #available(iOS 17, *) {
            shouldUseAudioApplicationRequest = true
        } else {
            shouldUseAudioApplicationRequest = false
        }

        if shouldUseAudioApplicationRequest {
            requestAudioApplicationPermission(
                completion: completion,
                requestAction: audioApplicationRequest
            )
        } else {
            requestAudioSessionPermission(
                completion: completion,
                requestAction: audioSessionRequest
            )
        }
    }

     func requestAudioApplicationPermission(
        completion: @escaping MicrophonePermissionCompletion,
        requestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil,
        systemRequestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil
    ) {
        let resolvedRequestAction: (@escaping MicrophonePermissionCompletion) -> Void
#if DEBUG
        resolvedRequestAction = requestAction
            ?? Self.testAudioApplicationPermissionOverride.value
            ?? systemRequestAction
            ?? { completion in
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            }
#else
        resolvedRequestAction = requestAction
            ?? systemRequestAction
            ?? { completion in
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            }
#endif

        resolvedRequestAction(completion)
    }

     func requestAudioSessionPermission(
        completion: @escaping MicrophonePermissionCompletion,
        requestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil,
        systemRequestAction: ((@escaping MicrophonePermissionCompletion) -> Void)? = nil
    ) {
        let resolvedRequestAction: (@escaping MicrophonePermissionCompletion) -> Void
#if DEBUG
        resolvedRequestAction = requestAction
            ?? Self.testAudioSessionPermissionOverride.value
            ?? systemRequestAction
            ?? { completion in
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            }
#else
        resolvedRequestAction = requestAction
            ?? systemRequestAction
            ?? { completion in
                AVAudioApplication.requestRecordPermission(completionHandler: completion)
            }
#endif

        resolvedRequestAction(completion)
    }

     func configureSession(
        setCategoryAction: (() throws -> Void)? = nil,
        setActiveAction: (() throws -> Void)? = nil
    ) throws {
        let resolvedSetCategoryAction: (() throws -> Void)?
        let resolvedSetActiveAction: (() throws -> Void)?
#if DEBUG
        resolvedSetCategoryAction = setCategoryAction ?? Self.testConfigureSessionCategoryOverride.value
        resolvedSetActiveAction = setActiveAction ?? Self.testConfigureSessionActiveOverride.value
#else
        resolvedSetCategoryAction = setCategoryAction
        resolvedSetActiveAction = setActiveAction
#endif

        if let resolvedSetCategoryAction {
            try resolvedSetCategoryAction()
        } else {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        }

        if let resolvedSetActiveAction {
            try resolvedSetActiveAction()
        } else {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
        }
    }

     func finishRecording(
        finishAudioPipelineAction: (() -> Void)? = nil
    ) {
        if let finishAudioPipelineAction {
            finishAudioPipelineAction()
        } else {
            finishAudioPipeline()
        }
        isProcessing = false
        isRecording = false
    }

     func finishAudioPipeline(
        stopAudioAction: (() -> Void)? = nil,
        removeTapAction: (() -> Void)? = nil,
        cancelRecognitionTaskAction: (() -> Void)? = nil,
        deactivateSessionAction: (() -> Void)? = nil
    ) {
        if let stopAudioAction {
            stopAudioAction()
        } else if audioEngine.isRunning {
            audioEngine.stop()
        }

        if let removeTapAction {
            removeTapAction()
        } else {
            audioEngine.inputNode.removeTap(onBus: 0)
        }

        recognitionRequest = nil

        if let cancelRecognitionTaskAction {
            cancelRecognitionTaskAction()
        } else {
            recognitionTask?.cancel()
        }
        recognitionTask = nil

        if let deactivateSessionAction {
            deactivateSessionAction()
        } else {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    enum SpeechRecognitionError: LocalizedError {
        case speechPermissionDenied
        case microphonePermissionDenied

        var errorDescription: String? {
            switch self {
            case .speechPermissionDenied:
                return String(localized: "error.speech.recognition_permission")
            case .microphonePermissionDenied:
                return String(localized: "error.speech.microphone_permission")
            }
        }
    }
}
