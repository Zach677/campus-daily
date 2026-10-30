# 校日常 — architecture

How the iOS code is organised and why. Endpoint details (params, envelopes, raw shapes) are in
Appendix A; the Android app in `Android/` is a separate Gradle project that only shares the
school-login script and, later, the fixtures.

Ground rules: the BLE frame format and the `wxcode`/MD5 signing are kept byte for byte; any
change to signing, BLE commands or school/U净 response parsing goes in its own commit with its
reason. Money paths stop rather than guess. The repo never contains real names, ids, rooms,
tokens or the hot-water platform `secret`/`sid`.

---

## 1. Module layout

Open `XiaoRiChang.xcworkspace`. It holds `App.xcodeproj` (targets **App** and **Widget**, both
using file-system synchronized folders, so adding a file needs no project edit) and the local
package `Packages/Core`. Build settings live in `Configuration/*.xcconfig`; a per-developer
`Configuration/Developer.xcconfig` (untracked) overrides team and bundle id.

```
App/
  Application/        XiaoRiChangApp (entry, scene), AppEnvironment (builds the services)
  Interface/<Feature>/ Home, CampusCard, Shower, Laundry, Onboarding, Settings, Common
  Services/           Bluetooth (CoreBluetooth ShowerTransport), CampusWebLogin (official-page WKWebView + login script),
                      BackgroundRefresh (BGAppRefreshTask), Alipay, LiveActivities, Intents, Reminders
  Resources/          Assets, Fonts, Info.plist, App.entitlements
Shared/               compiled into App and Widget
  WidgetViews/        widget views (also used by the in-app preview)
  LiveActivityViews/  ActivityAttributes and Live Activity views
  Theme/              formatting and the mascot shape the widget also draws (app colours and fonts
                      are in App/Interface/Common: Theme, NothingTheme)
Widget/               XiaoRiChangWidget, ShowerLiveActivity, LaundryLiveActivity, Info.plist, Widget.entitlements
Packages/Core/        one library product `Core` (swift-tools 6.0, iOS 17 / macOS 14, Swift 6 mode)
  Sources/Core/
    Campus/           CAS/portal/ecykt session, balance and electricity, meter matching, recharge, SchoolVault + store
    Shower/           lxt6 signed client and signing, BLE frame codec, ShowerEngine + reducer, onboarding, platform profile,
                      ShowerVault + store
    Laundry/          U净 client, order/payment rules, LaundryEngine + reducer, LaundryVault + store, 学校洗衣机 switch
    Snapshot/         the home snapshot ("latest data") and reminder lines shared with the widget, and their store
    Networking/       HTTPClient protocol + URLSession implementation, envelopes, redacting logger
    Storage/          generic Keychain and UserDefaults access only: SecureStore, StoreKey, SharedKeychain
                      (access group shared with the widget), PreferenceStorage, StorageError
    Common/           Money, ServiceError, JSONValue, DormAddress, ShowerHandoff (used by Campus and Shower)
  Tests/
    CampusTests/ ShowerTests/ LaundryTests/ SnapshotTests/ NetworkingTests/ StorageTests/ CommonTests/
    Support/          StubServer, FixtureLoader, FakeShowerTransport
    Fixtures/         synthetic/redacted API samples, one folder per service
Scripts/              fetch-alipay-sdk, stage-water-profile, check-widget-signature, package-ipa, privacy-check
                      (run through mise.toml)
```

Dependency direction (no cycles, nothing imports App):

```
App ──→ Shared ──→ Core
Widget ─→ Shared ──→ Core
Core: Campus / Shower / Laundry ──→ Networking, Storage, Common
      Snapshot ──→ Campus (balances, electricity), Storage
```

- Core imports only Foundation, CryptoKit, Security and os: no SwiftUI, UIKit, WidgetKit,
  ActivityKit or CoreBluetooth. Bluetooth is implemented in `App/Services/Bluetooth` behind the
  Core `ShowerTransport` protocol, so tests drive the state machine with a fake transport.
- The three features do not reference each other; shared pieces go in Common. Each feature owns
  its persistence protocol and Keychain store; Storage knows no feature types.
- The widget never touches the shower or laundry state machines; it reads the snapshot only.
- Only Networking creates URL sessions.

Pure / testable vs platform:

| Layer | Contents | Tested how |
|---|---|---|
| Pure (Common, reducers, parsing) | value types, reducers `(State, Event) -> (State, [Effect])`, parsing, money | plain unit tests, no I/O |
| Clients | request builders + response decoders + error mapping; I/O only through `HTTPClient` | fixture replay via `StubServer` |
| Engines (`ShowerEngine`, `LaundryEngine`, `SchoolSession`) | actors that run reducers, persist before each side effect, call clients/transport through protocols | fakes for transport/store/clock + fixtures |
| Platform (App/Widget) | CoreBluetooth, WKWebView, AlipaySDK, ActivityKit, WidgetKit, BGTask, Keychain access-group entitlement | device/simulator only, kept thin |

Rules: clients are `Sendable` structs, engines are actors, time is injected in Core, only
Networking makes sessions.

**Current state of the App layer.** The screen models are `ObservableObject` classes passed down
with `@EnvironmentObject`. `ShowerModel.shared`, `CampusModel.shared` and `Reminders.shared` are
singletons (the Live Activity intent, background refresh and notification delegate reach them
outside the view tree); `LaundryModel` is created by the app scene. The App and Widget targets
build in Swift 5 language mode; Core builds in Swift 6 mode.

**Target design.** The App and Widget targets move to Swift 6. Models become `@Observable`
adapters that observe the engines' `AsyncStream<State>`, created in `AppEnvironment` and passed
through initializers or the environment, with no singletons.

### Networking

- `ephemeral` sessions, no cookies/cache, redirects **not followed** (a 302 is a response, see
  `getPowerUrl`), timeouts 15 s request / 20 s resource, body cap 64 KiB (1 MiB for campus-wide
  `getMeterStatus`). HTTPS only, default TLS, per-client host allow-list (school hosts,
  `isv.lxt6.cn`, `phoenix.ujing.online`).
- Logging: `os.Logger` with method, host, path, status, latency, decoded `code` only. Query
  strings, bodies and headers are never logged; a `Redactor` masks token/ticket/sign/sid/custid/
  syscustid keys if a DEBUG body dump is needed.
- Error classification (`ServiceError`, in Core/Common):

```swift
enum ServiceError: Error, Equatable, Sendable {
  case offline                     // URLError.notConnectedToInternet, .dataNotAllowed, .networkConnectionLost before send
  case timedOut                    // URLError.timedOut
  case tls                         // URLError.secureConnection*, server cert errors
  case sessionExpired(Service)     // service says the credential is dead (see per-service table)
  case rejected(Service, code: String, message: String)  // service answered "no", with its own words (≤80 chars)
  case badRequest(Service)         // ecykt HTTP 200 + empty body; lxt6 4002 — our params are wrong/stale
  case malformed(Service, String)  // unparseable / missing fields; String = field path, never values
  case uncertain(Service)          // a state-changing request whose outcome we cannot know
}
enum Service: String, Sendable { case cas, portal, ecykt, lxt6, ujing }
```

`uncertain` is produced by engines, not by Networking: any transport error or malformed reply to a
**state-changing** request (authorize, settle, order create, pay arguments, cancel) is
`uncertain`, never `offline`/`timedOut`, so the UI never offers a blind retry.

---

## 2. Services

### 2.1 School: CAS → portal → ecykt

**Login (interactive, WKWebView).** CAS uses a JS-encrypted password form; we never see or store
the password. The app opens the CAS login for the portal service in a non-persistent
`WKWebsiteDataStore`, the user signs in, then:

1. On the portal origin, read `localStorage.token` → **portal token** (`X-Id-Token` JWT).
2. Natively (Networking): `GET portal …/getMyInfo` → dorm address string (`gydz`);
   `GET portal …/getMyECard` → `pcUrl` containing a fresh one-time CAS ticket.
3. Exchange: `POST ecykt /ykt-mini/verify/csalogintoken/{areacode}` `{ticket}` →
   `{syscustid, isbind, token}` → **ecykt token**. Then `getSysBindCustInfo` → bound card
   (`custid`, display name for the owner check).
4. Fallback while step 3 is not verified on device: let the WebView follow `pcUrl` and read
   `localStorage.elecampus_state` on the ecykt origin (what the current app does).

The ticket is single-use and must never be logged; nor may the CAS redirect URL (its JWT carries
personal claims).

**Client surface (`Core/Campus`):**

```swift
struct PortalClient { // X-Id-Token, X-Device-Info: PC, X-Terminal-Info: PC
  func myInfo(_ t: PortalToken) async throws -> DormAddress          // getMyInfo.gydz
  func eCardTicketURL(_ t: PortalToken) async throws -> URL           // getMyECard.pcUrl
}
struct EcyktClient { // POST JSON, acc_token in header AND body
  func exchange(ticket: String) async throws -> EcyktLogin            // csalogintoken
  func boundCards(_ s: EcyktSession) async throws -> [BoundCard]      // getSysBindCustInfo  (VALIDATES token)
  func freshLogin(_ s: EcyktSession) async throws -> EcyktLogin       // loginBySysId        (VALIDATES token)
  func signData(_ s: EcyktSession, custid: String) async throws -> ShowerHandoff // getSignData (VALIDATES)
  func balance(_ s: EcyktSession, custid: String) async throws -> Money        // scanpay/getUserBalance
  func buildings(_ s: EcyktSession, parent: String?) async throws -> [PowerNode] // electricnew/service getBuildingInfo
  func meters(_ s: EcyktSession, nodeID: String) async throws -> [Meter]         // electricnew/service getMeterStatus
  func rechargeWebSession(_ s: EcyktSession, card: BoundCard) async throws -> RechargeWebSession
}
```

**Session model.**

| Credential | Source | Stored | Lifetime (observed) |
|---|---|---|---|
| portal token | CAS login (WebView) | Keychain `school.portal` (WhenUnlocked) | unknown |
| ecykt token + `syscustid` + `custid` + `areacode` + UA | exchange / elecampus_state | Keychain `school.ecykt` (AfterFirstUnlock, so BG refresh works) | > 64 min incl. 28 min idle; real TTL unknown |
| dorm address, chosen meter id, building path | portal / user choice | Keychain `school.profile` | until changed |

Facts the design relies on (from the read-only captures):

- Only `loginBySysId`, `getSysBindCustInfo` and `getSignData` validate the token. When it is bad
  they return HTTP 200 `{code:-1, msg:"登录状态已过期，请重新登录！"}`.
- **Do not rely on balance/electricity endpoints to detect expiry**; use the liveness check below.
  (Relying on them produced the current "home is fine, recharge says expired" symptom.)
- HTTP 200 with an **empty body** means missing/undecryptable parameters → `badRequest`, never
  `sessionExpired`.
- `syscustid`/`custid` are re-encrypted on every response. Never compare them for identity; keep
  the value from the latest validating response and use it as input next time.
- `loginBySysId` mints a new token per call and does not revoke old ones; it does not check
  `timestamp`. Do not call it on every refresh (token sprawl); only when building a recharge web
  session (and then use the **fresh** token for `logintoken`, not the old one).

**Refresh algorithm (`SchoolSession.refresh()`, foreground and BG task):**

1. `boundCards` (liveness check). `code:-1` → `sessionExpired(.ecykt)`; go to step 4.
2. On success: `balance`, and `meters(nodeID: savedMeterNode)` in parallel. Store snapshot.
3. Done. Card/power failures are recorded per tile; a liveness failure marks **all** school tiles
   with a "重新登录" state even if old values are shown (values keep their `fetchedAt`).
4. Silent re-exchange (only when not running in background): if a portal token exists,
   `eCardTicketURL` → `exchange` → retry step 1 once. Portal `-1001`/`-1` → `sessionExpired(.portal)`
   → UI asks the user to sign in again. No loops, no retries beyond one.

**Electricity resolution.** The power tree contains apartment levels that the dorm address lacks,
so do not walk it level by level. Onboarding: call `meters(nodeID: <campus node>)` once (≈2.3k
rows, needs the 1 MiB cap), match `piplineName == "<building>栋<room>"` from the parsed dorm
address; exactly one match → save `comAddress` + the room-level node id; zero or many → manual
picker over `buildings(parent:)`. Daily refresh queries the room-level node only (1 row).
`data` is a JSON **string**; all numeric fields are strings → parse with `Decimal` in POSIX locale.

**Error mapping (school):**

| Observed | Maps to |
|---|---|
| ecykt `{code:-1}` from a validating endpoint | `sessionExpired(.ecykt)` |
| ecykt `{code:-1}` from a non-validating endpoint | `rejected(.ecykt, "-1", msg)` (not seen; don't infer expiry) |
| ecykt HTTP 200 + empty body | `badRequest(.ecykt)` |
| ecykt `{code:500, msg:"缺少参数"}` | `badRequest(.ecykt)` |
| ecykt other non-zero `code` | `rejected(.ecykt, code, msg)` |
| ecykt `data:"[]"` for meters | `.success([])` → "没找到电表" in UI, not an error |
| portal `{code:-1001,"无效 token"}`, `{code:-1,"没有访问权限"}` | `sessionExpired(.portal)` |
| HTTP 401/403 from any school host | `sessionExpired(service)` |
| missing `data`/fields, wrong JSON types | `malformed(service, path)` |

### 2.2 Hot water: isv.lxt6.cn + BLE controller

**Platform profile.** `secret`, `sid`, `bleName`, `typeId`, `version` are shared platform
parameters staged into the app bundle at build time from a git-ignored file (`Scripts/stage-water-profile.py stage`, run by the
App build phase). They are never in the repo, logs or fixtures.

**Identity hand-off.** `EcyktClient.signData` → `appdata` (`vsuppid, appid, userId, deptId,
username, phone, sign, nonce, timestamp`) → `getUserMsg` (signed, `requestType=1`) → water
`studentid` + `schoolid`. Room/device: `getAreaInfoForApplests` (campus → building → floor),
`getAreaForRoomApplests` (rooms), `getMachineMacAddress` (`machineId`, `Mac`, `machineName`).
Match names against the parsed dorm address (floors use Chinese numerals: `一楼`…).

**Client surface (`Core/Shower`):**

```swift
struct LxtClient {  // signed: wxcode=k=v*_k=v…, sign=md5(secret + formEncode(wxcode)), sid
  func userInfo(_ h: ShowerHandoff) async throws -> ShowerUser             // AECC …/getUserMsg
  func areas(parent: String) async throws -> [AreaNode]                   // getAreaInfoForApplests
  func rooms(floor: String) async throws -> [AreaNode]                    // getAreaForRoomApplests
  func machines(room: String) async throws -> [ShowerMachine]             // getMachineMacAddress
  func authorize(_ c: ShowerBinding, frame: Data) async throws -> ShowerAuthorization // POST, STATE + MONEY
  func settle(_ c: ShowerBinding, frame: Data) async throws -> ShowerReceipt         // POST, MONEY
}
```

Read calls are GET with the signed query; authorize/settle are POST form bodies with the same
three fields. Envelope casing differs by backend: `Code/Data/Message` (AECC) vs
`code/data/message|msg` (zk_*); the decoder accepts both, and accepts a body that is a JSON
**string** containing JSON (seen on `getUserMsg` errors).

**Auth/session.** No user token; requests carry the platform signature, identity is the
`studentid` from the school hand-off. Keychain `water.binding`: `studentId`, `schoolId`,
`machineId`, `roomId`, room label, last peripheral UUID. `getSignData` `-1` → school re-login
(onboarding/rebinding only, not per shower).

**Error mapping (lxt6):**

| Observed | Maps to |
|---|---|
| `code:4002 "参数不匹配"` (bad sign or missing id) | `badRequest(.lxt6)`; if it persists with a known-good request → profile outdated, show "热水配置需要更新" |
| `Code:-301 "…sign 不合法"` | `badRequest(.lxt6)` (same handling as 4002) |
| `code:4034 "查无此信息…"` | `rejected(.lxt6, "4034", msg)` → onboarding shows "学校没有登记这个地址" |
| `code:5000 "当前房间未绑定设备"` | `rejected(.lxt6, "5000", msg)` → "这个房间没有水控" |
| authorize/settle: explicit non-zero code | `rejected` (definite refusal, nothing charged for authorize) |
| authorize/settle: transport error, non-200, unreadable body | `uncertain(.lxt6)` |

Authorize/settle reply shapes and their refusal codes are **not captured**; the
decoders are written from the existing iOS and Android code (`machineid`, `studentId`,
`systemData` hex; settle `pay` in fen) and are verified on device.

### 2.3 Laundry: U净 (phoenix.ujing.online)

**Client surface (`Core/Laundry`):**

```swift
struct UjingClient { // Authorization: Bearer, x-app-code, x-app-version, x-mobile-id, x-mobile-brand, UA
  func requestSMS(mobile: String) async throws                                   // GET /api/v1/captcha  (sends SMS)
  func login(mobile: String, code: String) async throws -> UjingAccount          // POST /api/v1/login
  func scan(qr: String) async throws -> WasherScan                               // POST devices/scanWasherCode
  func programs(deviceID: String) async throws -> WasherInfo                    // GET app/washer/devices/program/info
  func washer(qr: String) async throws -> WasherSnapshot                         // scan + programs
  func createOrder(_ r: OrderRequest) async throws -> String                     // POST orders/create   STATE
  func order(_ id: String) async throws -> LaundryOrder                          // GET orders/{id}/detail?additional=price
  func paymentMethods(_ id: String) async throws -> [PayChannel]                // GET payment/methods
  func paymentArguments(_ id: String, channel: PayChannel) async throws -> PaymentArguments // GET payment/arguments  MONEY
  func cancel(_ id: String) async throws                                         // POST orders/{id}/cancel STATE
}
```

`paymentArguments` returns the raw reply (redacted in descriptions, never stored or logged);
`PaymentLaunchPolicy` turns it into a `PayLaunch` (§3.2). Only the machine-label QR
`https://q.ujing.com.cn/ucqrc/index.html?cd=<18 digits>` is accepted; ids that go into paths
are `[A-Za-z0-9]{1,80}`. Only module type 7 is ordered from the app.

**Auth/session.** SMS login → `{token, id, userId, isTempToken}`; `isTempToken` or a challenge →
`rejected(.ujing, "verification", …)` ("先在 U净 App 里验证一下"). Keychain `laundry.account` plus a
per-install `x-mobile-id` UUID. Expiry: **HTTP 401** `{code:401, message:"Token is invalid" |
"JWT token is missing"}` → `sessionExpired(.ujing)`; no silent refresh, user repeats SMS login
(60 s UI cooldown, never auto-requested). `x-app-code`: `ZI` on captcha/login, `BI` on every
authenticated call (what the existing iOS and Android clients send; to be confirmed on device). `x-mobile-id`
is created once per install and kept in `laundry.account` across logouts. Signed-in calls without
a token fail locally with `sessionExpired` (nothing sent).

**Error mapping (U净):** HTTP 401/403 or envelope `code` 401/403 → `sessionExpired`; envelope
`code != 0` → `rejected(code, message)`; a login challenge message (滑块/风控…) → `verification`.
SMS request, create, payment arguments and cancel are state-changing: transport failure, non-2xx,
unreadable reply or a success without the expected id → `uncertain`. Reads: non-2xx →
`rejected("HTTP n")`, unreadable → `malformed(path)`.

---

## 3. State machines

All engines persist the new state **before** performing the side effect it guards, and treat any
unknown outcome as "may have happened". Reducers live in Core next to their engine and are exhaustively unit-tested.

### 3.1 Hot-water session (`ShowerEngine`)

```
idle ──start──► authorizing ──auth ok──► writePending ──ack 0xAA (9B)──► running
  ▲                │  │                       │                          │
  │      refused   │  │ uncertain             │ user taps 结束            │ user taps 结束
  │◄───────────────┘  ▼                       ▼                          ▼
  │            failed(needsReview)      closing ◄──────────────────────  closing
  │                                         │ state probe 0xA5 → send close cmd
  │                                         ▼
  │                                     settling ──receipt──► done ──► idle
  │                                         │ uncertain/refused
  └──── resolveManually (after user checks official record) ◄── failed(needsReview)
```

| State | Persisted fields | UI | Allowed actions |
|---|---|---|---|
| `idle` | last receipt | 开水 | start |
| `authorizing` | machineId, peripheral, startedAt | 正在开水… | none (await) |
| `writePending` | + authorizationId | **洗澡中**, hint 「水控没回应，有热水就照常洗」 | finish, review |
| `running` | same | 洗澡中 + timer; Live Activity | finish, review |
| `closing` | + close requested | 正在结束… | none |
| `settling` | + consumption frame | 正在结算… | none; on relaunch: show "结算待核对" |
| `done` | receipt (fen, duration) | 本次 ¥x.xx | dismiss → idle |
| `failed(reason, needsReview)` | everything above | reason + 「去看热水记录」 | resolveManually (if needsReview), dismiss (if not) |

Rules:

- Any state but `idle`/`done` blocks `start`. Authorize: explicit refusal → `failed(needsReview:
  false)` (nothing issued); anything else → `failed(needsReview: true)`; never re-authorize.
- `writePending` shows as running on purpose (the controller may have accepted without acking).
  `finish` from it: probe shows the device idle with our identity → `idle`, no charge; else close.
- Close is sent only after the probe returns `0xA5`; otherwise keep the session, flag review.
- `settling` is never auto-retried; repeat-settle idempotency is unknown, so a manual retry
  needs a second confirmation and is recorded in diagnostics.
- Unsettled reminder after the configured minutes in `writePending/running`. The Live Activity
  mirrors `{phase, startedAt, writeUnconfirmed, amountYuan?}`; its "结束并结算" intent calls
  `ShowerEngine.finish()` in the app process.

### 3.2 Laundry order (`LaundryEngine`)

Local checkout record (one at a time) + server status:

```
none ─confirm─► creating ─id─► created ─付款─► paying ─app returns─► verifying ─paid─► active
                   │uncertain     │  ▲ refused / launch refused │  uncertain ──────►│        │ 40 → Live Activity
                   ▼              │  └───── not paid after polling ◄──────────────┘        ▼ 50/51/53 → none
              reconcile ─adopt─►  │ cancel (unpaid read → one POST → reads)            52 → attention
                   │ none found   ▼                                                        │ acknowledge
                   └─resolveManually─► none   cancelling ─53─► none                        ▼ none
```

Persisted phases: `none, creating, reconcile, created, paying, verifying, active, cancelling,
attention` (Keychain `laundry.checkout`). Relaunch (`LaundryReducer.restore`) never sends
anything: `creating` → `reconcile`, `paying` → `verifying`, `cancelling` before the POST →
`created`; the rest stay.

Server status codes (from current code, to be confirmed on device): `10` reserved/unpaid, `17` unpaid,
`20` paid/waiting start, `21` starting, `40` washing, `50` done, `51` payment timed out,
`52` machine didn't start (check charge in U净), `53` cancelled.

Rules:

- Create only after an explicit confirmation sheet showing machine, program and price, from a
  snapshot (scan + programs) under 60 s old that is still orderable at that price. Payment is
  offered only when `order(id).price` is known and not above the confirmed price (else
  "价格变了，刷新一下").
- `creating` uncertain (or a success without a usable id) → `reconcile`: `scanWasherCode` of the
  same QR gives the account's unfinished `orderId`; adopt it only if `order(id)` matches machine +
  program, was created within 2 min of the local confirmation and is not above the confirmed
  price. Never create a second one; if nothing matches the user checks the U净 app and clears.
- Payment: `payment/methods`, prefer `alipay`, then `alipayF2F` (`alipayF2FNoAds=true`); no
  WeChat and no automatic-debit channel. `paying` (with `paymentRequestedAt`) is persisted before
  `payment/arguments` is sent. The reply is launched only if `PaymentLaunchPolicy` accepts it:
  `https://qr.alipay.com/<code>`; the U净 F2F link `alipays://platformapi/startApp?appId=20000042
  &actionType=WebView&followType=PUBLIC&url=https://openauth.alipay.com/oauth2/publicAppAuthorize.htm?…
  redirect_uri=https://wx.zhinengxiyifang.cn/static/commonWasher/index.html…` (no user/port/
  fragment, no duplicate parameters); or a signed `alipay.trade.app.pay` string for AlipaySDK whose
  `biz_content.total_amount` **equals** the order amount. Any amount parameter in a link (also
  nested) must equal it too. Anything else (other hosts/schemes, `weixin://`, unknown amount)
  is refused and nothing opens. `skipPay`/`jumpToQuery` → poll directly.
- On return (or after 10 s foreground) poll `order(id)` after 2, 4, 8, 15, 15, 15 s (≈ 1 min);
  still unpaid → back to `created` with "付款未确认". Paid = `payFlag 1` or any non-10/17 status.
- Re-pay only while unpaid (10/17) at the confirmed price, ≥ 2 min after the last payment
  request, with an order read taken after that window and under 5 min old, **and** a second
  confirmation. Never auto-relaunch payment; an uncertain arguments request goes to polling.
- Cancel only from an unpaid `10/17`: fresh read first, then at most one POST (persisted
  `cancelSent` first), then the same polling until `53` or another terminal status. Paid in
  between → no POST.
- `40` → Live Activity (machine, program, endsAt) + laundry-done notification at `endsAt`;
  `50`/`53`/`51`/`52` end the activity and clear the record (`52` keeps a warning card until
  acknowledged).

### 3.3 Recharge (card and electricity)

Payment stays inside the school's own web pages (WKWebView); the app does not call the recharge
submit APIs itself (not captured).

```
idle ─tap 充值─► checkingSession ─ok─► webSession ─page loaded─► inPage ─back / app foreground─► confirming ─► idle
                      │expired                                      │ alipays:// | weixin:// link
                      ▼                                             ▼ open external app
                  needsLogin (re-login, then retry once)        inPage (still)
```

- `checkingSession`: `boundCards` (liveness) then `freshLogin` → build `elecampus_state`
  `{logintoken: <fresh token>, loginInfo, schoolid, custInfo, custid}` and inject it as a
  document-start user script, ecykt origin only. Card: `/ykt-view/recharge?isbind=1`.
  Electricity: `getPowerUrl?custid&syscustid` (302 → `/ykt-view/powersel?...`; let the WebView
  follow it).
- Navigation allow-list: https on `ecykt.`, `portal.`, `cas.` school hosts; `alipays`/`alipay`/
  `weixin` schemes only from a user link tap on the ecykt origin → `UIApplication.open`.
- `confirming`: on return, refresh balance (card) or the room meter (electricity) up to 3 times
  over 30 s and show the delta; no claim of success without a changed value
  ("充值结果以学校记录为准").

---

## 4. Persistence, sharing, identifiers

### 4.1 Stores

| Data | Store | Accessibility | Shared with widget |
|---|---|---|---|
| school credentials (`school.portal`, `school.ecykt`) | Keychain | portal: WhenUnlockedThisDeviceOnly; ecykt: AfterFirstUnlockThisDeviceOnly | no |
| school profile (dorm, meter) | Keychain `school.profile` | AfterFirstUnlockThisDeviceOnly | no |
| water binding, shower session | Keychain `water.binding`, `water.session` | AfterFirstUnlockThisDeviceOnly | no |
| U净 account, checkout record | Keychain `laundry.account`, `laundry.checkout` | AfterFirstUnlockThisDeviceOnly | no |
| home snapshot (balances, meter, room label, per-tile error, fetchedAt, needsLogin) | Keychain `shared.snapshot` (≤64 KiB JSON) | AfterFirstUnlockThisDeviceOnly | **yes** |
| reminder thresholds mirrored for widget | Keychain `shared.reminderLines` | same | **yes** |
| UI prefs, reminder toggles, de-dupe state | UserDefaults (standard), keys prefixed `xrc.` | – | no |

All Keychain items use service `com.beamjason.xiaorichang.<name>.v1`, account `default`.
Session stores (water/laundry) write synchronously and fail closed: a failed write blocks the
next side effect (`storage` error), same as today.

Widget sharing: the widget reads only `shared.snapshot` and `shared.reminderLines`, never
credentials, via the **keychain access group** (works with any signing team incl. free Personal
Teams, no portal registration). No App Group is introduced: the current build has none and
re-signers of the public IPA may not get one. Live Activities get data via ActivityKit content
state. Each snapshot write calls `WidgetCenter.reloadTimelines(ofKind:)`; tiles carry their own
`fetchedAt`, and `needsLogin` shows a "需重新登录" badge instead of silently stale numbers.

UserDefaults keys: old `reminder.*`, `laundryAckFailedOrder`, `water.needsResidenceReview`
become `xrc.reminder.*`, `xrc.laundry.ackFailedOrder`, `xrc.water.needsResidenceReview`.

### 4.2 Identifiers

| Item | Value |
|---|---|
| App bundle id | `com.beamjason.xiaorichang` (matches Android `applicationId`) |
| Widget extension | `com.beamjason.xiaorichang.balances` |
| Keychain access group | `$(AppIdentifierPrefix)com.beamjason.xiaorichang.shared` |
| Keychain services | `com.beamjason.xiaorichang.<name>.v1` |
| BG task id | `com.beamjason.xiaorichang.refresh` |
| Widget kind | `XiaoRiChangBalances` |
| Alipay return scheme | `com.beamjason.xiaorichang.alipay` (derived, see below) |
| Navigation scheme | `campusdaily://home`, `campusdaily://demo/<state>` |
| Xcode workspace / project / targets | `XiaoRiChang.xcworkspace` / `App.xcodeproj` / `App` (product `XiaoRiChang.app`), `Widget` (product `XiaoRiChangWidget.appex`) |
| Swift package / product | `Packages/Core` / `Core` |
| Display names | 校日常 / widget gallery title 校园双余额 |

Distribution is an unsigned IPA the user re-signs (`Scripts/package-ipa.py`); there is no App
Store/TestFlight record. Paid-team signers register `com.beamjason.xiaorichang` and
`.balances`; free Personal Teams count them toward the 10 App IDs / 7 days limit.
`Scripts/check-widget-signature.py` checks a signed build before installing.

**Alipay scheme notes.** (1) AlipaySDK `payOrder(_:fromScheme:)` (laundry signed order) returns
to `<scheme>://safepay…`; Info.plist declares `$(PRODUCT_BUNDLE_IDENTIFIER).alipay`, so it
follows the rename. Keep the runtime lookup of the declared scheme ending in `.alipay` (re-signing
tools may change the bundle id after build) and forward only `<scheme>://safepay` URLs to the SDK.
(2) Checkout URLs (`alipays://`, `qr.alipay.com`) and the school page's `alipays`/`weixin` links
open the external app with no return URL, hence the polling/confirming states. Keep
`LSApplicationQueriesSchemes` = `alipay, alipays, alipayqr`. Nothing ties payment to an
Alipay-registered bundle id (the SDK only needs the return scheme); verify on device with one real
laundry payment.

---

## 5. Testing strategy

**Harness** (`Tests/Support`): `FixtureLoader` reads `Packages/Core/Tests/Fixtures/<service>/<name>.json`
(`{request, response:{status, headers, body}, _fixture}`; `body` is an object, a string, or `""`).
`StubServer` (a `URLProtocol`) matches method + host + path (+ body keys like `server`, `buildingID`), replays
status/headers/body, records requests for assertions (`acc_token` in header and body, `wxcode`
field order, no `timestamp`), fails on unmatched requests, and can inject `URLError`s (offline,
timeout, TLS). Plus `FakeBLETransport` (scripted frames, delays, drops), `FakeClock`, in-memory
stores with injectable write failures.

Every endpoint gets at least: success, expired/unauthorized, refused with message, malformed
(derived in-test from a good fixture by deleting a key or changing a type).

**Fixture coverage:**

| Path | Fixtures |
|---|---|
| ecykt liveness ok / expired | `getSysBindCustInfo-ok`, `-badToken`, `-*Token-t1`, `-*-afterMint10`, `expiry-*` |
| fresh login (recharge) ok / expired / bad params | `loginBySysId-mintSeries*`, `-noTimestamp`, `-timestamp*`, `-badToken`, `-missingSyscustid`, `-wrongSyscustid` (empty body), `-rotatedSyscustidInput`, `-mintedTokenAsInput` |
| balance (incl. "no expiry signal here") | `getUserBalance-ok`, `-missingCustid` (empty body → badRequest), `-tokenHeaderOnly`, `-tokenBodyOnly`, `-rotatedSyscustid`, `-afterLoginBySysId`, `-mintedToken*` |
| electricity tree / meters | `electric-getBuildingInfo-root`, `-level1..4`, `-leafEmpty`; `electric-getMeterStatus-ok` (campus), `-leaf`, `-room`, `-unknownBuilding` (`[]`); `electric-service-missingServer` (500) |
| electricity web entry | `getPowerUrl-ok` (302 not followed) |
| water hand-off | `getSignData-ok`, `-badToken` |
| recharge web session state | `localStorage-elecampus_state-csaLogin` |
| card records (not used yet) | `card-getRecordList-ok` |
| portal | `getMyInfo-ok`, `-badtoken` (-1001), `-notoken` (-1), `getMyECard-ok`, `me-user-ok` |
| lxt6 reads | `getUserMsg-ok`, `-badSign` (-301, JSON-in-string); `areaInfo-level0..3`, `-badSign`/`-missingId` (4002), `-unknownParent` (4034); `getMachineMacAddress-ok`, `-unknownRoom` (5000) |
| U净 auth errors | `ujing/programInfo-noAuth`, `orderDetail-badAuth` (401 shapes, captured); `scanWasherCode-badAuth`, `orderCreate-badAuth` |
| U净 (synthetic, shapes from the existing app) | `captcha-ok`/`-refused`; `login-ok`/`-tempToken`/`-challenge`/`-refused`; `scanWasherCode-ok`/`-activeOrder`/`-refused`; `programInfo-ok`/`-refused`; `orderCreate-ok`/`-refused`; `orderDetail-unpaid`/`-paid`/`-washing`/`-done`/`-failedStart`/`-cancelled`/`-refused`; `paymentMethods-ok`/`-refused`; `paymentArguments-f2f`/`-sdk`/`-skipPay`/`-refused`; `orderCancel-ok`/`-refused` |

Fixture consistency: `portal/getMyInfo-ok`, `lxt6/areaInfo-level3` and
`lxt6/getMachineMacAddress-ok` share one faked dorm, so dorm → room → machine matching runs end to
end; the `piplineName` match test appends one synthetic meter row in-test.

State machines (ShowerEngine, LaundryEngine, recharge) are tested with scripted fakes for every
transition in §3, including: crash/relaunch in each persisted state, store write failure,
cancellation between persist and side effect, refusal vs uncertain on authorize/settle/create/
pay/cancel.

**Open gaps.** There is no live capture session. Money and state-changing paths are written
from the existing iOS implementation and the Android code as reference, then verified on the
maintainer's device:

| Gap | Closed by |
|---|---|
| hot water `bathingConsumptionAuthorization` success + refusal shapes | decoder from the existing iOS/Android code; on device |
| hot water `analysisOfBathingConsumptionData` success (+ whether a repeat is idempotent) | decoder from existing code; on device; settle is never auto-retried until then |
| U净 SMS captcha + login (incl. `isTempToken`/challenge), scan, program info, order detail, payment methods, create → pay → status 20/40/50, cancel from 10/17 | client from existing code; on device |
| card recharge submit | not needed: recharge stays in the school's web page |
| electricity recharge order | not needed: recharge stays in the school's web page |
| `csalogintoken` ticket exchange | shape taken from the official page's JS (synthetic test fixture); `adoptWebState` fallback; on device |
| token lifetime: ecykt at +2/+6/+24 h idle; portal token lifetime | scheduled read-only probes (`getSysBindCustInfo`); no user session needed beyond one sign-in |

Decoder tests for the hot-water authorize/settle and U净 paths use synthetic replies shaped like the existing code expects and are
marked as such; no release ships a money path whose device check is still open. `swift test`
touches no network, Bluetooth or host Keychain.

---

## Appendix A. API notes

Recorded with read-only requests only. Redacted fixtures live in
`Packages/Core/Tests/Fixtures/<service>/<endpoint>-<case>.json`, each
`{request:{method,url,headers,body}, response:{status,headers,body}, _fixture:{…}}`.

**Redaction rules.** Tokens, signatures, nonces, CAS tickets, `pcUrl`/`appUrl`, ticket-bearing
`Location` values and the hot-water `sid` are `REDACTED_TOKEN_n` (same value → same number
across fixtures). Personal identifiers (`syscustid`, `custid`, `custunionid`, name, `idno`,
phone, `studentid`, `userId`, `deptId`, `vsuppid`, appid, `headurl`, `voucherno`, meter
`comAddress`, water `machineId`/`Mac`/`machineName`, portal `gydz`/`szbj`, and in `me/user`
`username`/`userUid`, `organizationId`, `accountId`, `userId`, `imageUrl`,
`organizationName`/`organizationCode`, `identityTypeId`, `userName`) are fake values. Numeric
ids and ciphertexts use shapes no real value has, so `Scripts/privacy-check.sh` can allow them by whole value: zero-padded
counters (`TESTid` + 26 digits, meter `000000000199`), numeric ids starting with `99` (dorm
building ids `991001…`, hot-water area ids `997…`, room `991000000000000002`), or a few fixed
placeholders listed in the script. Dorm data is synthetic: the faked user room is
`星湖校区9栋9号1层199房` (meter `9栋199`, water room `199`), and the room/building lists around
it are synthetic, as are all meter readings and balances (the campus-wide meter list
`electric-getMeterStatus-ok` is 12 invented rows). Lists longer than 12 entries are cut to 12
(`_fixture.truncatedLists` keeps the original length). A `_fixture.synthetic` note in a fixture
names the parts that were replaced with invented data. Captures of a bad token still returning data are not kept in the repo.

Legend: **RO** read-only, **ST** changes server state, **$$** spends money.

### A.1 Login chain

1. CAS (`cas.gdbtu.edu.cn/cas/login?service=<portal>`) is a username/password form; the
   password is encrypted by the CAS page's JS. It redirects to the portal with a `ticket`
   (a JWT whose claims identify the student: never log that URL).
2. The portal SPA turns the ticket into `localStorage.token`. Portal calls send it as
   `X-Id-Token`, plus `X-Device-Info: PC` and `X-Terminal-Info: PC`.
3. `GET /portal-api/v2/personalData/getMyECard` returns `data.pcUrl`/`appUrl`:
   `https://ecykt.gdbtu.edu.cn/ykt-view/authcsatoken?areacode=450010&redirect=…&ticket=…`, with a
   fresh one-time CAS ticket on every call.
4. The ecykt page calls `POST /ykt-mini/verify/csalogintoken/{areacode} {ticket}` (no
   `acc_token`) → `data = {syscustid, isbind, status, token}`, then writes
   `localStorage.elecampus_state = {logintoken: token, loginInfo: {...data, csa:1}, schoolid, custInfo, custid:null, …}`
   (`custInfo` from `getSysBindCustInfo`; see `ecykt/localStorage-elecampus_state-csaLogin`).
   The CSA `loginInfo` has no `timestamp`, so no `timestamp` is sent anywhere.
5. Every ecykt call: `POST` JSON to `https://ecykt.gdbtu.edu.cn/ykt-mini`, `acc_token` in the
   header **and** the body (either alone is accepted).

**Token behaviour.**
- `loginBySysId` ignores `timestamp`, mints a new token on every call, accepts minted tokens
  as input, and does not revoke older tokens (original, first and last minted tokens all still
  validated after 10 mints). It also returns a re-encrypted `syscustid` each time;
  `getSysBindCustInfo` re-encrypts `custid` each time. All variants are accepted as input:
  never compare these ciphertexts, keep the latest.
- Only `loginBySysId`, `getSysBindCustInfo` and `getSignData` validate the token
  (`code:-1, msg:"登录状态已过期，请重新登录！"`, HTTP 200). Balance and electricity endpoints
  don't signal expiry; use `getSysBindCustInfo` as the liveness check.
- Lifetime: tokens were still valid after > 1 h including 28 min idle; the real TTL is measured
  by scheduled probes.

### A.2 ecykt.gdbtu.edu.cn (`/ykt-mini`)

Envelope `{code:int, msg, data}`, HTTP 200, `code 0` = OK. The electricity service returns
`data` as a JSON **string**. A missing or undecryptable required parameter gives **HTTP 200
with an empty body**: treat it as a bad request, never as expiry.

| Endpoint | Validates token | Body (besides `syscustid`, `acc_token`) | `data` | Kind |
|---|---|---|---|---|
| `POST /api/customer/loginBySysId` | yes | `areacode, version("v1.1.55"), appid("wx7077a0b57d156efe"), redirect` | `{syscustid, isbind:1, token}` | RO (mints a token) |
| `POST /api/customer/getSysBindCustInfo` | yes | `areacode, version, appid` | `[{custid, custunionid, custname, idno(masked), areaname, headurl, …}]` | RO |
| `POST /scanpay/getUserBalance` | no | `custid` | yuan number | RO |
| `POST /api/electricnew/service` `server=/api/getBuildingInfo` | no | `areacode, [buildingID]` | JSON string `[{buildingName, buildingID}]`; `[]` at a room | RO |
| `POST /api/electricnew/service` `server=/api/getMeterStatus` | no | `areacode, buildingID` | JSON string `[{comAddress, piplineName("9栋199"), type, meterData, leftMoney, preUseDay, meterStatus, updateDateTime, onlineStatus("在线"/"离线"), price, remaining}]` (all strings) | RO |
| `POST /api/electricnew/service` without `server` | – | – | `code:500, msg:"缺少参数"` | – |
| `POST /api/customer/getSignData` | yes | `custid, timestamp:""` | `{userLoginData, appdata:{vsuppid, phone, appid, sign, deptId, userId, nonce, username, timestamp}}` | RO (hot-water hand-off) |
| `POST /card/getRecordList` | – | `begin, end (yyyyMMdd), custid, datetype:1, pageNum, pageSize, dcflag:"", address:""` | `{total, rows:[{transdate, transtime, transname, amount, balance, dcflag, …}]}` | RO |
| `GET /api/electricnew/getPowerUrl?custid&syscustid` | – | – | **302** to `/ykt-view/powersel?interfaceName=powernew_450010&isbind=1` | RO |
| `POST /verify/csalogintoken/{areacode}` | ticket | `{ticket}` | `{syscustid, isbind, status, token}` | login |

Electricity tree (`areacode 450010`): campuses → apartments (`xx公寓`) → buildings (`N栋`) →
floors (`N楼`) → rooms (`NNN`) → `[]`. `getMeterStatus` works at any level (a campus returns
every meter, ≈2.3k rows; a room returns 1). Matching `piplineName == "<栋>栋<room>"` on one
campus-wide read finds the room meter.

Money/state endpoints in the official JS (never called by the app; recharge stays in the
school's web page): `/api/business/balRechargeApply`, `/api/business/balRechargeOrder`,
`/api/business/getOrderSupportPayType`, `/api/pay/wxJsPay`, `/api/electricnew/applyorderid`,
`/api/electricnew/CreateOrder`, card loss/password/bind endpoints, `/api/water/*`.

### A.3 portal.gdbtu.edu.cn

Headers as in A.1. Envelope `{code, message, data}`, HTTP 200.

| Endpoint | `data` | Errors | Kind |
|---|---|---|---|
| `GET /portalData/v2/personalData/getMyInfo` | `{gydz:"示例校区9栋9号1层199房", szbj}` (`gydz` = registered dorm address) | bad token `code:-1001 "无效 token"`; no token `code:-1 "没有访问权限"` | RO |
| `GET /portal-api/v2/personalData/getMyECard` | `{balance, monthBalance, cardStatus, lastExpenditure[], lastIncome[], appUrl, pcUrl, …}` | same | RO (new CAS ticket in `pcUrl` each call) |
| `GET https://authx-service.gdbtu.edu.cn/personal/api/v1/personal/me/user` | `{username, roles, attributes}` | same | RO |

### A.4 Hot water: isv.lxt6.cn

Signed GET: `?wxcode=<k=v*_k=v…>&sign=md5(secret + formEncode(wxcode))&sid=<sid>[&requestType=1]`.
`secret`/`sid` come from the private water profile (never in the repo). Envelope casing differs
per backend: `Code/Data/Message` (AECC) vs `code/data/message|msg` (zk_*); some error bodies are
a JSON string containing JSON.

| Endpoint | wxcode fields | Response | Errors | Kind |
|---|---|---|---|---|
| `AECC/GDBusinessSchool/getUserMsg` (+`requestType=1`) | `schoolid=20021, vsuppid, appid, userId, deptId, username, phone` (from `getSignData.appdata`), `random` | `{Code:0, Data:{studentid, studentid_hex, studentname, mobile, schoolid, joinuserid, …}}` | bad sign: JSON-string `{"Code":-301,…"sign 不合法！"}` | RO |
| `zk_areainfo_api/areaInfo/getAreaInfoForApplests` | `id=<parent>` | `{code:0, data:[{id, name}]}` | `4002 "参数不匹配"` (bad sign / missing id); `4034 "查无此信息…"` (unknown id) | RO |
| `zk_areainfo_api/areaInfo/getAreaForRoomApplests` | `id=<floor>` | rooms `[{id, name}]` | – | RO |
| `ZK_BSRS/bathe/getMachineMacAddress` | `typeId, schoolId, roomId` | `{code:0, data:{objList:[{machineId, ID, Mac, machineName}]}}` | `5000 "当前房间未绑定设备"` | RO |
| `ZK_BSRS/GDBusinessSchool/bathingConsumptionAuthorization` | – | not captured | – | **$$** |
| `ZK_BSRS/GDBusinessSchool/analysisOfBathingConsumptionData` | – | not captured | – | **$$** |

Area names: campuses (`星湖校区`, …), buildings `N栋`, floors `一楼…七楼`, rooms `NNN`.

### A.5 Laundry: U净 phoenix.ujing.online

Headers: `Authorization: Bearer <token>`, `x-app-code` (`ZI` captcha/login, `BI` otherwise),
`x-app-version` (`2.4.18`), `x-mobile-id` (per-install UUID), `x-mobile-brand`, UA. Envelope
`{code, message, data}`. Missing token → HTTP 401 "JWT token is missing"; bad token → HTTP 401
"Token is invalid". Only the 401 replies are captured; every other `ujing/` fixture is synthetic
(shapes from the existing app) until they are checked on device.

| Endpoint | Kind |
|---|---|
| `GET /api/v1/captcha?mobile&type=1` | sends an SMS |
| `POST /api/v1/login {mobile, captcha}` → `{token, id, userId, isTempToken}` | login |
| `POST /api/v1/devices/scanWasherCode {qrCode}` | RO |
| `GET /api/v1/app/washer/devices/program/info?deviceId` | RO |
| `GET /api/v1/orders/{id}/detail?additional=price` | RO |
| `GET /api/v1/payment/methods?orderId&include=alipay` | RO |
| `POST /api/v1/orders/create` | **ST** |
| `GET /api/v1/payment/arguments?channel&orderId&payVersion=1[&branchType][&alipayF2FNoAds=true]` | **$$** (Alipay link / signed order / `skipPay`) |
| `POST /api/v1/orders/{id}/cancel` | **ST** |
