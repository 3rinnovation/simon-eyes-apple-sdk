# Simon Eyes Apple SDK (ThreeRSip)

Simon Eyes 감지 코어를 iOS·macOS 앱에서 쓰는 Swift 패키지입니다. 코어는 바이너리 라이브러리(`ThreeRSipHosted.xcframework`)로 들어 있고, 이 저장소의 Swift 파일은 그 위의 API입니다.

- `SipSession`: 세션을 열고, 감지를 설정하고, 입력을 처리합니다.
- `DeviceMotion`: 기기의 가속도계(Core Motion의 `CMMotionManager`)를 읽어 세션에 넘기는 수집기입니다.

판정과 계산은 모두 바이너리 안의 코어가 합니다. Swift 파일은 호출을 잇고 답을 읽는 층입니다.

> **0.1.0은 시험판입니다.** iPad 실기기 확인을 마치기 전까지는 운영에 쓰지 마십시오.

## 요구 사항

- Xcode 16 이상 (Swift 6 tools)
- iOS 15 이상, macOS 12 이상
- iOS 시뮬레이터는 Apple 실리콘 Mac(arm64)에서만 됩니다. Intel Mac의 시뮬레이터용 바이너리는 들어 있지 않습니다.

## 설치

Xcode: **File → Add Package Dependencies…** 에서 아래 주소를 넣고, 제품 `ThreeRSip`을 앱 대상에 더합니다.

```
https://github.com/3rinnovation/simon-eyes-apple-sdk
```

`Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/3rinnovation/simon-eyes-apple-sdk", exact: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "ThreeRSip", package: "simon-eyes-apple-sdk"),
    ]),
]
```

1.0 전에는 판마다 API가 바뀔 수 있으므로 `exact:`로 고정하기를 권합니다.

## 사용 예

세션 인자(JSON)의 형식은 이용 계약과 함께 제공됩니다. 아래 값은 예시입니다.

```swift
import ThreeRSip

final class Listener: DeviceMotionListener {
    func onAnswer(_ answerJson: String) throws {
        print(answerJson)
    }
}

let session = try SipSession.create(sensorGroups: ["device_motion"])
_ = try session.openSession(#"{"sessionId":"s1","subjectRef":"p1"}"#)
_ = try session.setupSensing(setupJson)      // 감지 계획
_ = try session.registerSource(sourceJson)   // "motion" 출처와 그 능력
_ = try session.judge(judgmentJson)          // 지금의 기기 상태

let settings = try DeviceMotion.Settings.builder()
    .windowMs(1_000)            // 창 길이
    .samplingPeriodUs(20_000)   // 50 Hz
    .deliveryMs(5_000)          // 세션에 넘기는 간격
    .options(targetJson)        // 만들 관측, 예: device.posture
    .build()
let motion = try DeviceMotion(
    session: session,
    sourceId: "motion",
    settings: settings,
    listener: Listener()
)
if try motion.start() {
    // 가속도계를 읽는 중입니다. 창이 닫힐 때마다 onAnswer가 불립니다.
}
try motion.stop(flush: true)
try motion.close()
try session.close()
```

가속도계가 없는 기기(Mac, 시뮬레이터)에서는 `start()`가 `false`를 돌려주고 아무것도 읽지 않습니다.

## 알아 둘 것

- 바이너리는 서명되어 있지 않습니다. 앱은 평소처럼 여러분의 인증서로 서명합니다.
- Apple 개인정보 매니페스트(`PrivacyInfo.xcprivacy`)가 들어 있습니다. 바이너리 안의 Rust 표준 라이브러리가 파일 정보를 읽는 함수(`stat` 등)를 쓰므로, 파일 시각 API를 `C617.1`(앱 컨테이너 안 파일의 정보)로 밝힙니다. 추적과 데이터 수집은 없습니다.
- 이 패키지는 `CMMotionManager`로 가속도계만 읽습니다. 다른 센서나 위치는 읽지 않습니다.
- 바이너리는 정적 라이브러리입니다. 앱에 링크되어 함께 들어갑니다.

## 라이선스

[LICENSE](LICENSE)와 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)를 보십시오.

---

## English

Simon Eyes Apple SDK: a Swift package (`ThreeRSip`) over the Simon Eyes sensing core, which ships as a
binary library (`ThreeRSipHosted.xcframework`). `SipSession` runs a session; `DeviceMotion` reads the
device's accelerometer (Core Motion) into it. Every rule runs in the binary core.

- **0.1.0 is a pre-release**: do not use it in production before the device checks are complete.
- Requirements: Xcode 16+, iOS 15+, macOS 12+. The iOS simulator slice is arm64 only (Apple silicon).
- Install: add `https://github.com/3rinnovation/simon-eyes-apple-sdk` with `exact: "0.1.0"` and use the
  product `ThreeRSip`.
- The binary is not signed; your app is signed as usual.
- It ships an Apple privacy manifest (`PrivacyInfo.xcprivacy`): file timestamp APIs used by the Rust
  standard library inside the binary, reason `C617.1`; no tracking, no data collected.
- Licence: see [LICENSE](LICENSE) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
