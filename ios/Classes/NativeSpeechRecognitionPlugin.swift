import Flutter
import UIKit
import Speech

public class NativeSpeechRecognitionPlugin: NSObject, FlutterPlugin {
  private var resultHandler: ResultStreamHandler!
  private var audioDataHandler: ResultStreamHandler!

//  private let audioEngine = AVAudioEngine()
  private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
  private var speechRecognizer = SFSpeechRecognizer(locale: Locale.current)
  private var recognitionTask: SFSpeechRecognitionTask?
  private var authorized: Bool = false
  private var recognizedText: String = ""
  private var currentLocale: Locale = Locale.current


  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "native_speech_recognition", binaryMessenger: registrar.messenger())

    let resultEventChannel = FlutterEventChannel(name: "native_speech_recognition/result", binaryMessenger: registrar.messenger())
    let audioDataEventChannel = FlutterEventChannel(name: "native_speech_recognition/audioData", binaryMessenger: registrar.messenger())

    let resultHandler = ResultStreamHandler()
    let audioDataHandler = ResultStreamHandler()

    let instance = NativeSpeechRecognitionPlugin()
    instance.audioDataHandler = audioDataHandler
    instance.resultHandler = resultHandler


    registrar.addMethodCallDelegate(instance, channel: channel)
    resultEventChannel.setStreamHandler(resultHandler)
    audioDataEventChannel.setStreamHandler(audioDataHandler)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "start":
        self.getPermissions{
            do {
                guard self.authorized else {
                     result("")
                        return
                     }

                try self.start(flutterResult: result)
            } catch {
                result("")
            }
        }
        break
    case "sendAudioData":
      if let args = call.arguments as? [String: Any],
         let data = args["data"] as? FlutterStandardTypedData,
         let sampleRate = args["sampleRate"] as? Double {
        self.sendAudioData(data: data.data, sampleRate: sampleRate)
        result(nil)
      } else {
        result(FlutterError(code: "INVALID_ARGS", message: "Missing data or sampleRate", details: nil))
      }
    case "stop":
        self.stop()
        break
    case "setLocale":
        if let localeString = call.arguments as? String{
            setLocale(localIdentifier: localeString)
        }
        break
    case "getSupportedLocales":
        result(getSupportedLocales());
    case "getCurrentLocale":
        result(getCurrentLocale());
    default:
      result(FlutterMethodNotImplemented)
    }
  }


    func extractData(from buffer: AVAudioPCMBuffer) -> Data? {
            let bufferList = buffer.audioBufferList
            let audioBuffer = bufferList.pointee.mBuffers

            guard let mData = audioBuffer.mData else {
                print("Audio data is empty")
                return nil
            }

            let length = Int(audioBuffer.mDataByteSize)
            return Data(bytes: mData, count: length)
    }

    public func start(flutterResult: @escaping FlutterResult) throws {
        recognitionTask?.cancel()
        self.recognitionTask = nil

        if speechRecognizer?.locale.identifier != currentLocale.identifier {
            speechRecognizer = SFSpeechRecognizer(locale: currentLocale)
        }

//        let audioSession = AVAudioSession.sharedInstance()
//
//        try audioSession.setCategory(
//                .playAndRecord,
//                mode: .spokenAudio,
//                options: [.allowBluetooth, .duckOthers]
//        )
//
//        try audioSession.setPreferredSampleRate(16000)
//        try audioSession.setPreferredIOBufferDuration(0.016)
//        if audioSession.isInputGainSettable {
//            try audioSession.setInputGain(1.0)
//        }
//        try audioSession.setActive(true)

//        let inputNode = audioEngine.inputNode
//
//        var setting = audioEngine.inputNode.inputFormat(forBus: 0).settings
//        setting[AVLinearPCMBitDepthKey] = 16
//        setting[AVSampleRateKey] = 16000
//        setting[AVLinearPCMIsFloatKey] = 0
//
//        inputNode.removeTap(onBus: 0)
//
//        let recordingFormat = AVAudioFormat.init(settings: setting)

//        inputNode.installTap(onBus: 0, bufferSize: 1600, format: recordingFormat) { (buffer: AVAudioPCMBuffer, when: AVAudioTime) in
//            self.recognitionRequest?.append(buffer)
//
//            let format = buffer.format
//            let pcmData = self.extractData(from: buffer)
//
//            let resultDict: [String: Any] = [
//                "sampleRate": format.sampleRate,
//                "channelCount": format.channelCount,
//                "data": pcmData
//            ]
//
//            self.audioDataHandler.sendResult(resultDict)
//        }
//
//        audioEngine.prepare()
//        try audioEngine.start()

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
            fatalError("Unable to create a SFSpeechAudioBufferRecognitionRequest object")
        }

        recognitionRequest.shouldReportPartialResults = true

        if #available(iOS 13, *) {
            if speechRecognizer?.supportsOnDeviceRecognition ?? false{
                recognitionRequest.requiresOnDeviceRecognition = true
            }
        }

        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { result, error in
            if let result = result {
                let bestTranscription = result.bestTranscription.formattedString
                self.resultHandler.sendResult([
                     "text": bestTranscription,
                     "isFinal": result.isFinal
                ])
            }
            if let error = error as NSError? {
                self.stop()
                // 把 NSError 透传给 Flutter 端, 让上层识别如
                // kLSRErrorDomain code=201 (Siri/Dictation disabled) 等场景
                self.resultHandler.sendResult([
                    "error": [
                        "domain": error.domain,
                        "code": error.code,
                        "message": error.localizedDescription
                    ]
                ])
                flutterResult(nil)
                print(error)
            }
        }
        flutterResult(nil)
    }

    func sendAudioData(data: Data, sampleRate: Double) {
        guard let recognitionRequest = recognitionRequest, !data.isEmpty else { return }

        // 确保数据长度是 Int16 的整数倍
        guard data.count % MemoryLayout<Int16>.size == 0 else {
            print("Invalid data length: not aligned to 16-bit samples")
            return
        }

        let int16Count = data.count / MemoryLayout<Int16>.size

        // 设置音频格式：单声道，16kHz，16位 PCM
        let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )!

        // 创建 PCM Buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(int16Count)) else {
            print("Failed to create AVAudioPCMBuffer")
            return
        }
        buffer.frameLength = UInt32(int16Count)

        // 获取 buffer 的声道数据指针 (UnsafeMutablePointer<Int16>)
        let channelData = buffer.int16ChannelData![0]

        // ✅ 关键修复：使用 withUnsafeBytes 获取 UnsafeRawBufferPointer
        // 然后用 `baseAddress.assumingMemoryBound(to:)` 转为 UnsafePointer<Int16>
        data.withUnsafeBytes { rawBuffer in
            // rawBuffer 是 UnsafeRawBufferPointer
            // 获取起始地址并强转为 UnsafePointer<Int16>
            guard let baseAddress = rawBuffer.baseAddress else { return }
            let int16Src = baseAddress.assumingMemoryBound(to: Int16.self)

            // ✅ 现在类型正确：UnsafePointer<Int16> → 可用于 initialize
            channelData.initialize(from: int16Src, count: int16Count)
        }

        // 推入识别引擎
        recognitionRequest.append(buffer)
    }

    public func stop() {
//        self.audioEngine.stop()
//        self.audioEngine.inputNode.removeTap(onBus: 0)
        self.recognitionRequest = nil
        self.recognitionTask?.cancel()
        self.recognitionTask = nil
    }

    public func getPermissions(callback: @escaping () -> Void){
        SFSpeechRecognizer.requestAuthorization{authStatus in
            OperationQueue.main.addOperation {
               switch authStatus {
                    case .authorized:
                        self.authorized = true
                        callback()
                        break
                    default:
                        break
               }
            }
        }
    }

    public func getSupportedLocales() -> [String: String] {
        var locales = [String: String]()
        let supportedLocales = SFSpeechRecognizer.supportedLocales()
        for locale in supportedLocales {
            let localizedName = locale.localizedString(forLanguageCode: locale.languageCode!)
            locales[locale.identifier] = localizedName
        }
        return locales
    }

    public func setLocale(localIdentifier: String) -> Void {
        currentLocale = Locale(identifier: localIdentifier)
    }

    public func getCurrentLocale() -> [String: String] {
        var locales = [String: String]()
        locales["languageCode"] = currentLocale.languageCode
        locales["identifier"] = currentLocale.identifier
        locales["localizedName"] = currentLocale.localizedString(forLanguageCode: currentLocale.languageCode!)
        return locales
    }


}
