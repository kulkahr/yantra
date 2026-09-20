# Firefly — Diagrams

All diagrams are Mermaid (render on GitHub/VS Code).

## 1. System context (C4-L1)

```mermaid
graph TB
    subgraph Users[" "]
        U[User]
    end
    subgraph Firefly["Firefly app (iOS / Android)"]
        APP[Firefly UI + ScaleKit]
    end
    SCALE["realme Smart Scale (Lifesense LS213-B)"]
    HK["Apple Health / local CSV export (opt-in)"]

    U -->|step on / tap| SCALE
    U -->|views weight & trends| APP
    SCALE <-->|"BLE GATT A602 (proprietary A6 protocol)"| APP
    APP -->|"explicit user action only"| HK
```

## 2. Component view (C4-L2)

```mermaid
graph TB
    subgraph UI
        VM[ViewModels: Scan, Pair, Measure, History]
        V[SwiftUI / Compose Views]
    end
    subgraph Domain
        BC[BodyComposer]
        UC[UnitConverter]
        PROF[UserProfileStore]
    end
    subgraph ScaleKit["ScaleKit (pure protocol)"]
        SC[ScaleClient facade]
        PAIR[PairStateMachine]
        SES[SessionStateMachine]
        ENC[A6Command encode]
        DEC[A6PacketAssembler + WeightRecordParser]
        FC[FrameCodec XOR/CRC32]
        Q[CommandQueue ack/resend]
    end
    subgraph Port["BleCentralPort (interface)"]
        IOS[CoreBleCentral]
        AND[AndroidBleCentral]
    end
    subgraph Persist
        DB[(Encrypted DB)]
        EXP[Export CSV / HealthKit]
    end

    V --> VM
    VM --> SC
    VM --> PROF
    VM --> BC
    SC --> PAIR
    SC --> SES
    PAIR --> ENC
    SES --> ENC
    ENC --> FC
    DEC --> FC
    ENC --> Q
    Q --> IOS
    Q --> AND
    IOS -->|notifies| DEC
    AND -->|notifies| DEC
    DEC --> SC
    SC --> VM
    VM --> DB
    DB --> EXP
    BC --> VM
```

## 3. Sequence — discovery & binding (SRD-001/002)

```mermaid
sequenceDiagram
    autonumber
    participant U as User
    participant App as Firefly (ScaleKit)
    participant BT as BLE stack
    participant S as Scale

    U->>App: Tap "Add scale"
    App->>BT: scan(service A602)
    S-->>BT: adv: name "realme Smart Scale", svc A602, mfg[12 34 56 78 01 MAC]
    BT-->>App: peripheral + MAC from mfg data
    App->>U: confirm device + user slot
    App->>BT: connect GATT
    App->>S: discover services (A602, 180a)
    App->>S: write CCCD enable notify (A621, A625)
    App->>S: read 180a (model/fw) + A641 (feature)
    App->>S: W A624: 0x0001 register [deviceId = code⊕MAC][state]
    S-->>App: N A621: 0x0002 registerResult(1)
    S-->>App: N A621: 0x0007 authChallenge [verificationCode]
    App-->>S: W A622: ACK ok [00 01 01]
    App->>S: W A624: 0x0008 authResponse ["01"][code][mode=1]["02"]
    U->>App: confirm bind
    App->>S: W A624: 0x0003 bindNotice [slot][confirm=1]
    S-->>App: N A621: 0x0004 bindResult(1)
    App-->>S: W A622: ACK ok
    App->>S: W A624: 0x0005-unbind-n/a → disconnect politely
    App->>U: "Bound ✓" (persist BindRecord)
```

## 4. Sequence — measurement session (SRD-003/004/005)

```mermaid
sequenceDiagram
    autonumber
    participant App as Firefly
    participant S as Scale

    Note over App,S: auto-connect on app open (or near-scale trigger)
    App->>S: connect + enable notifies
    S-->>App: 0x0009 initRequest (capabilities)
    App->>S: 0x000A initResponse (mtu=20, UTC, tz, timestamp)
    App->>S: 0x1002 pushTime(utc, tz, datetime)
    App->>S: 0x1001 pushUserInfo(slot, sex, age, height, athlete)
    App->>S: 0x1004 pushUnit(kg)
    App->>S: 0x4801 measureSetting(slot, on)
    U->>S: steps on scale
    S-->>App: live weight frames (0x00E9 stream / real-time path)
    App-->>App: render live weight
    S-->>App: 0x4802 final record (weight, utc, impedance?, remainCount)
    App-->>S: ACK ok
    App-->>App: BodyComposer (BMI, fat%...) → store locally
    Note over App,S: history drain if remainCount > 0
    loop until remainCount == 0
        S-->>App: 0x4802 stored record
        App-->>S: ACK ok
    end
    opt user chose "clear scale memory"
        App->>S: 0x1005 clearData(slot, timestamp)
    end
    App->>S: disconnect
```

## 5. State machine — connection lifecycle

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Scanning : user add / auto-reconnect timer
    Scanning --> Idle : timeout 30s / not found
    Scanning --> Connecting : peripheral found (svc A602)
    Connecting --> Connected : services discovered
    Connecting --> Scanning : connect fail (retry ≤2)
    Connected --> Pairing : no BindRecord (new device)
    Connected --> SessionStart : BindRecord exists
    Pairing --> Bound : bindResult = 1
    Pairing --> PairFailed : timeout 180s / result 2
    PairFailed --> Idle
    Bound --> SessionStart
    SessionStart --> Measuring : 0x4801 on / weight frames
    Measuring --> Draining : final record, remainCount > 0
    Measuring --> Idle : final record, remainCount == 0
    Draining --> Idle : remainCount == 0
    Idle --> Disconnecting : app close / policy
    Disconnecting --> [*]
    Connected --> Scanning : link lost (reconnect ≤2)
```

## 6. State machine — A6 frame reassembly

```mermaid
stateDiagram-v2
    [*] --> AwaitHeader
    AwaitHeader --> Collecting : frame serial 0 (header, count>0)
    AwaitHeader --> AckDispatch : frame count==0 (ACK)
    Collecting --> Collecting : serial 1..n-1
    Collecting --> VerifyCRC : last frame received
    VerifyCRC --> Dispatch : CRC ok
    VerifyCRC --> AckFail : CRC bad → ACK 02, device resends
    AckDispatch --> [*]
    Dispatch --> [*]
```

## 7. Entity-relationship (local store)

```mermaid
erDiagram
    USER_PROFILE ||--o{ MEASUREMENT : owns
    BIND_RECORD ||--o{ MEASUREMENT : "produced by"
    BIND_RECORD }o--|| USER_PROFILE : "bound to slot"

    USER_PROFILE {
        uuid id PK
        string name
        int sex "0 male 1 female"
        int age
        float heightCm
        bool athlete
        int activityLevel
        int unit "0 kg 1 lb 2 st 3 jin"
        float targetKg "nullable"
        int scaleSlot "0..4"
    }
    BIND_RECORD {
        string deviceKey PK "MAC from advertisement"
        string macString
        string peripheralId "iOS CBIdentifier"
        string deviceId "12 hex = code XOR mac"
        int slot
        string fwVersion
        bytes featureBitmap
        datetime boundAt
    }
    MEASUREMENT {
        uuid id PK
        uuid profileId FK "nullable (guest)"
        string deviceId
        int utcEpoch
        float weightKg
        float impedanceOhm "nullable"
        int unitRaw
        int rawFlags
        string source "live | history"
        datetime createdAt
    }
```

## 8. Privacy data-flow (what leaves the phone: nothing)

```mermaid
graph LR
    SCALE[Scale] -->|BLE| SK[ScaleKit]
    SK --> DB[(Encrypted local DB)]
    DB --> UI[Firefly UI]
    DB -.->|opt-in export only| HK[Apple Health / CSV]
    SK -.-> X1["❌ no cloud"]
    SK -.-> X2["❌ no analytics"]
    SK -.-> X3["❌ no network permission"]
```

## 9. Android bridge (fallback path, Path C)

```mermaid
graph LR
    SCALE[Scale] -->|A6/BLE| AND[Android phone: realme Link or Firefly-Android]
    AND -->|LAN WebSocket / HTTP push| IOS[iPhone: Firefly ingest]
    IOS --> HK[Apple Health]
```
