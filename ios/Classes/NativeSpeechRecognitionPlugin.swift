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
  // 识别任务自动重启计数(见 handleRecognitionError), 每次 start()/stop() 复位
  private var restartCount = 0
  private let maxRestartCount = 3


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
        self.getPermissions{ granted in
            // 未授权也必须回 result: 否则 Dart 端 await start() 永久挂起,
            // 调用方(录音页)的启动防抖标记卡死, 页面内无法再触发录音
            guard granted else {
                result(FlutterError(code: "PERMISSION_DENIED",
                                    message: "Speech recognition authorization denied or restricted",
                                    details: nil))
                return
            }
            do {
                try self.start(flutterResult: result)
            } catch {
                result(FlutterError(code: "START_FAILED", message: "\(error)", details: nil))
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
        restartCount = 0

        if speechRecognizer?.locale.identifier != currentLocale.identifier {
            speechRecognizer = SFSpeechRecognizer(locale: currentLocale)
        }

        startRecognitionTask()
        flutterResult(nil)
    }

    /// 创建识别请求并启动识别任务; [sendAudioData] 始终写入当前 recognitionRequest,
    /// 重建后自动衔接, 无需 Flutter 端感知
    private func startRecognitionTask() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        if #available(iOS 13, *) {
            if speechRecognizer?.supportsOnDeviceRecognition ?? false{
                request.requiresOnDeviceRecognition = true
            }
        }

        recognitionRequest = request
        recognitionTask = speechRecognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let bestTranscription = result.bestTranscription.formattedString
                self.resultHandler.sendResult([
                     "text": bestTranscription,
                     "isFinal": result.isFinal
                ])
            }
            if let error = error as NSError? {
                self.handleRecognitionError(error)
            }
        }
    }

    /// 识别出错处理: 授权刚授予瞬间 SFSpeech 服务未就绪、网络抖动等会立刻报错,
    /// 若直接销毁请求, 后续音频全部被丢弃且无任何提示(首装第一次进录音页
    /// "无转写"的根因)。可重试错误自动重建识别任务续传, 超限才终止并透传。
    private func handleRecognitionError(_ error: NSError) {
        if isRetryable(error) && restartCount < maxRestartCount {
            restartCount += 1
            print("SpeechRecognition error \(error.domain)/\(error.code), restart \(restartCount)/\(maxRestartCount)")
            recognitionTask?.cancel()
            recognitionTask = nil
            startRecognitionTask()
            return
        }
        stop()
        // 把 NSError 透传给 Flutter 端, 让上层识别如
        // kLSRErrorDomain code=201 (Siri/Dictation disabled) 等场景
        self.resultHandler.sendResult([
            "error": [
                "domain": error.domain,
                "code": error.code,
                "message": error.localizedDescription
            ]
        ])
        print(error)
    }

    /// 可自动重试的错误: kAFAssistantErrorDomain
    /// 1101(网络错误) / 203(静音段 skipped) / 209(连接中断)
    private func isRetryable(_ error: NSError) -> Bool {
        if error.domain == "kAFAssistantErrorDomain" {
            return [1101, 203, 209].contains(error.code)
        }
        return false
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
        restartCount = 0
    }

    public func getPermissions(callback: @escaping (Bool) -> Void){
        SFSpeechRecognizer.requestAuthorization{authStatus in
            OperationQueue.main.addOperation {
                // 所有授权状态都必须回调: 旧实现非 authorized 时 callback 不调用,
                // method channel 的 result 悬空, Dart 端 await start() 永久挂起
                let granted = (authStatus == .authorized)
                self.authorized = granted
                callback(granted)
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
