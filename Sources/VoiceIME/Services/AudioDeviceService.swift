import Foundation
import CoreAudio
import AVFoundation

/// オーディオ入力デバイス情報
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String              // デバイスUID (永続化識別子)
    public let deviceID: AudioDeviceID // CoreAudio デバイスID
    public let name: String            // 表示名 (例: 外付けUSBマイク, Bluetoothヘッドセット)
    public let isSystemDefault: Bool   // 現在 macOS のシステムデフォルト入力デバイスかどうか

    public init(id: String, deviceID: AudioDeviceID, name: String, isSystemDefault: Bool) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.isSystemDefault = isSystemDefault
    }
}

/// 入力マイク（オーディオ入力デバイス）の管理、自動検出、フォールバック制御サービス
@MainActor
public final class AudioDeviceService: ObservableObject {
    public static let shared = AudioDeviceService()

    /// 現在接続・検出されている利用可能な全入力デバイス
    @Published public private(set) var availableDevices: [AudioInputDevice] = []

    /// macOS システムのデフォルト入力デバイス
    @Published public private(set) var systemDefaultDevice: AudioInputDevice? = nil

    /// 現在実際に使用される入力デバイスの表示名
    @Published public private(set) var effectiveDeviceName: String = "システムデフォルト"

    /// ユーザーが選択したデバイスが未接続・利用不能で、システムデフォルトにフォールバック中かどうか
    @Published public private(set) var isFallbackActive: Bool = false

    /// フォールバック理由の説明メッセージ
    @Published public private(set) var fallbackReason: String? = nil

    private var devicesPropertyListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultPropertyListenerBlock: AudioObjectPropertyListenerBlock?

    private init() {
        refreshDevices()
        startHardwareMonitoring()
    }
    // 本クラスは shared シングルトンとしてアプリ常駐するため deinit は呼ばれません。
    // 手動停止が必要な場合は stopHardwareMonitoring() を MainActor から明示的に呼び出します。

    /// CoreAudio デバイス変更（接続/切断・デフォルト変更）の監視を開始
    public func startHardwareMonitoring() {
        // 重複登録を防止するため、既存リスナーがあれば一旦解除
        stopHardwareMonitoring()

        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let devicesBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }
        self.devicesPropertyListenerBlock = devicesBlock

        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            DispatchQueue.main,
            devicesBlock
        )

        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let defaultBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.refreshDevices()
            }
        }
        self.defaultPropertyListenerBlock = defaultBlock

        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            DispatchQueue.main,
            defaultBlock
        )
    }

    /// CoreAudio 監視の停止
    public func stopHardwareMonitoring() {
        if let devicesBlock = devicesPropertyListenerBlock {
            var devicesAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                DispatchQueue.main,
                devicesBlock
            )
            devicesPropertyListenerBlock = nil
        }

        if let defaultBlock = defaultPropertyListenerBlock {
            var defaultAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddress,
                DispatchQueue.main,
                defaultBlock
            )
            defaultPropertyListenerBlock = nil
        }
    }

    /// 接続中の入力デバイス一覧を再取得し、現在の実効デバイス状態を更新
    public func refreshDevices() {
        let (defaultDevice, devices) = Self.fetchHardwareInputDevices()
        self.availableDevices = devices
        self.systemDefaultDevice = defaultDevice

        updateEffectiveState()
    }

    /// ユーザーによるマイクデバイスの選択
    public func selectDevice(uid: String, name: String) {
        AppSettings.shared.selectedAudioDeviceUID = uid
        AppSettings.shared.selectedAudioDeviceName = name
        updateEffectiveState()
    }

    /// 現在の実効デバイス（実際に使われるデバイス）およびフォールバック状態を判定
    private func updateEffectiveState() {
        let selectedUID = AppSettings.shared.selectedAudioDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedName = AppSettings.shared.selectedAudioDeviceName

        let defaultName = systemDefaultDevice?.name ?? "システムデフォルト"

        // 「システムデフォルト」選択の場合 (空文字または "default")
        if selectedUID.isEmpty || selectedUID == "default" {
            self.isFallbackActive = false
            self.fallbackReason = nil
            self.effectiveDeviceName = "システムデフォルト (\(defaultName))"
            return
        }

        // 特定のデバイスが選択されている場合、現在利用可能かチェック
        if let matched = availableDevices.first(where: { $0.id == selectedUID }) {
            self.isFallbackActive = false
            self.fallbackReason = nil
            self.effectiveDeviceName = matched.name
        } else {
            // 選択したマイクが見つからない（イヤホンの電源OFF・未接続など）➔ デフォルトへフォールバック
            self.isFallbackActive = true
            let reason = "選択中のマイク「\(selectedName)」が未接続のため、システムデフォルト（\(defaultName)）で待機中"
            self.fallbackReason = reason
            self.effectiveDeviceName = "\(defaultName) (自動代替)"
            NSLog("[VoiceIME] ⚠️ マイク未検出によるフォールバック: %@", reason)
        }
    }

    /// AVAudioEngine の inputNode に対して、選択されたマイク（またはフォールバック）を安全に設定する
    /// - Returns: 設定に成功した (deviceID, deviceName, isFallback)
    @discardableResult
    public func setupInputDevice(for engine: AVAudioEngine) throws -> (deviceID: AudioDeviceID, name: String, isFallback: Bool) {
        // 最新のハードウェア状態を反映
        refreshDevices()

        let selectedUID = AppSettings.shared.selectedAudioDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedName = AppSettings.shared.selectedAudioDeviceName
        let isDefaultExplicit = selectedUID.isEmpty || selectedUID == "default"

        guard let defaultDev = systemDefaultDevice ?? availableDevices.first(where: { $0.isSystemDefault }) ?? availableDevices.first else {
            throw NSError(
                domain: "AudioDeviceService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "利用可能なオーディオ入力マイクが見つかりません。"]
            )
        }

        // 1. システムデフォルトが明示的に選択されている場合
        if isDefaultExplicit {
            do {
                try engine.inputNode.auAudioUnit.setDeviceID(defaultDev.deviceID)
                self.isFallbackActive = false
                self.fallbackReason = nil
                self.effectiveDeviceName = "システムデフォルト (\(defaultDev.name))"
                return (defaultDev.deviceID, defaultDev.name, false)
            } catch {
                NSLog("[VoiceIME] ⚠️ デフォルトマイク設定エラー (ID: %d): %@", defaultDev.deviceID, error.localizedDescription)
                throw error
            }
        }

        // 2. 特定のマイクが指定されている場合
        if let targetDevice = availableDevices.first(where: { $0.id == selectedUID }) {
            do {
                try engine.inputNode.auAudioUnit.setDeviceID(targetDevice.deviceID)
                self.isFallbackActive = false
                self.fallbackReason = nil
                self.effectiveDeviceName = targetDevice.name
                NSLog("[VoiceIME] 🎙️ 選択マイクを設定: %@ (ID: %d)", targetDevice.name, targetDevice.deviceID)
                return (targetDevice.deviceID, targetDevice.name, false)
            } catch {
                NSLog("[VoiceIME] ⚠️ 選択マイク「%@」の設定失敗。システムデフォルト「%@」にフォールバックします: %@", targetDevice.name, defaultDev.name, error.localizedDescription)
                // 選択したマイクのオープン・設定に失敗したため、システムデフォルトで再試行
                do {
                    try engine.inputNode.auAudioUnit.setDeviceID(defaultDev.deviceID)
                    let reason = "「\(targetDevice.name)」の初期化に失敗したため、システムデフォルト（\(defaultDev.name)）を使用しています"
                    self.isFallbackActive = true
                    self.fallbackReason = reason
                    self.effectiveDeviceName = "\(defaultDev.name) (自動代替)"
                    return (defaultDev.deviceID, defaultDev.name, true)
                } catch {
                    throw error
                }
            }
        } else {
            // 選択したマイクが見つからない（未接続等）➔ システムデフォルトにフォールバック
            NSLog("[VoiceIME] ⚠️ 選択マイク「%@」が未接続です。システムデフォルト「%@」に自動フォールバックします。", selectedName, defaultDev.name)
            do {
                try engine.inputNode.auAudioUnit.setDeviceID(defaultDev.deviceID)
                let reason = "「\(selectedName)」が未接続のため、システムデフォルト（\(defaultDev.name)）を使用しています"
                self.isFallbackActive = true
                self.fallbackReason = reason
                self.effectiveDeviceName = "\(defaultDev.name) (自動代替)"
                return (defaultDev.deviceID, defaultDev.name, true)
            } catch {
                throw error
            }
        }
    }

    // MARK: - CoreAudio ハードウェア列挙ヘルパー

    private static func fetchHardwareInputDevices() -> (defaultDevice: AudioInputDevice?, devices: [AudioInputDevice]) {
        // 1. デフォルト入力デバイスID取得
        var defaultID: AudioDeviceID = 0
        var defaultAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultAddress,
            0,
            nil,
            &defaultSize,
            &defaultID
        )

        // 2. 全デバイスID取得
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize
        )
        guard status == noErr else { return (nil, []) }

        let count = Int(propertySize / UInt32(MemoryLayout<AudioDeviceID>.size))
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &propertySize,
            &deviceIDs
        )

        var devices: [AudioInputDevice] = []
        var defaultDevice: AudioInputDevice? = nil

        for id in deviceIDs {
            // 入力ストリームがあるか
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            let streamStatus = AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize)
            guard streamStatus == noErr, streamSize > 0 else { continue }

            // 名前
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfName: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let nameStatus = AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &cfName)
            let name: String
            if nameStatus == noErr, let string = cfName?.takeRetainedValue() as String? {
                name = string
            } else {
                name = "Unknown Device"
            }

            // UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var cfUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let uidStatus = AudioObjectGetPropertyData(id, &uidAddress, 0, nil, &uidSize, &cfUID)
            let uid: String
            if uidStatus == noErr, let string = cfUID?.takeRetainedValue() as String? {
                uid = string
            } else {
                uid = "\(id)"
            }

            // macOS内部の自動生成アグリゲートデバイス（例: CADefaultDeviceAggregate...）など、
            // ユーザー向け設定画面に表示されない内部仮想デバイスを除外
            if uid.contains("CADefaultDeviceAggregate") || name.contains("CADefaultDeviceAggregate") {
                continue
            }

            let isDef = (id == defaultID)
            let dev = AudioInputDevice(id: uid, deviceID: id, name: name, isSystemDefault: isDef)
            devices.append(dev)
            if isDef {
                defaultDevice = dev
            }
        }

        return (defaultDevice, devices)
    }
}
