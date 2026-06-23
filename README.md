# runcat-gpu — GPU에도 반응하는 "달리는 고양이" 메뉴바

> 상태: **구현 완료 (네이티브 B안).** 2026-06-22 빌드. Apple M5 Pro / macOS 26.5에서 동작 확인.

## 목표
RunCat처럼 메뉴바에서 동물이 달리는데, **CPU·GPU 중 더 바쁜 쪽** 기준으로 속도가 변하는 것.
("뭐든 빡세면 빨리 달리면 좋겠다" — RunCat은 CPU만 봐서 GPU 작업(예: 임베딩) 때 한가해 보임.)

## 빌드 / 실행 (구현됨)
```bash
./make_app.sh          # swift build -c release → BusyCat.app 생성 (애드혹 서명)
open BusyCat.app     # 메뉴바에 고양이 등장 (Dock 아이콘 없음 = LSUIElement)
# 설치: cp -R BusyCat.app /Applications/ 후 한 번 open
# 종료: 메뉴바 고양이 클릭 → Quit BusyCat (⌘Q)
```
- 추가 설치 불필요 — macOS 기본 Swift 툴체인(swiftc/xcodebuild)만 있으면 빌드됨.

## 기능 (RunCat 정식앱 기능 ⊇ + GPU)
메뉴를 열면:
- **실시간 지표:** CPU · **GPU** · 메모리 · 디스크 · 네트워크(↓↑) · 배터리(%, 충전 ⚡)
- **속도 기준 선택:** 가장 바쁜 쪽(CPU·GPU, 기본) / CPU / GPU / 메모리
- **메뉴바에 % 표시** 토글 (선택한 기준값을 고양이 옆에)
- **속도 반전** (바쁠수록 느리게 — RunCat "invert")
- **좌우 반전** (고양이 방향 — RunCat "flip")
- **로그인 시 자동 실행** (`SMAppService`)
- **sleep/wake 처리:** 잠자면 애니메이션 정지, 깨면 재개
- 설정은 `UserDefaults`에 저장(재실행해도 유지).

**속도 공식 = RunCat 그대로:** `interval = 0.2 / clamp(usage/5, 1...20)`.
- **idle 임계값을 따로 안 잡음** — `max(1.0, …)` 바닥이 곧 idle 속도(usage ≤5% → 0.2s/5fps). 100%면 빨라짐(40fps에서 캡).

### RunCat에 있지만 안 넣은 것
- **57종 러너 캐릭터 / 러너 자동교체 / 커스텀 이미지** — 그림 에셋이 없어 고양이 1종만. (원하면 추가 가능.)

## 구현 메모 (코드 위치)
- `Sources/BusyCat/UsageReader.swift` — `SystemSampler`: CPU(HOST_CPU_LOAD_INFO 델타)·GPU(IOKit, `max(Device,Renderer,Tiler)`)·메모리(HOST_VM_INFO64)·디스크(volume capacity)·네트워크(getifaddrs 바이트 델타)·배터리(IOKit.ps).
- `Sources/BusyCat/CatFrames.swift` — **RunCat 고양이 5프레임을 base64 PNG로 내장**(자체 완결, 경로 의존 없음). 원본 아트: `Kyome22/menubar_runcat` (Apache 2.0). 템플릿 이미지라 다크/라이트 자동.
- `Sources/BusyCat/AppDelegate.swift` — NSStatusItem, 1초마다 샘플링 → 속도 갱신(RunCat 공식), 프레임 타이머(.common 모드).
- 디버그: `BusyCat --dump <dir>`(프레임 PNG 덤프), `BusyCat --metrics`(지표 1회 출력).

## 출처 / 라이선스
- 고양이 스프라이트 = **RunCat** 오픈소스(`Kyome22/menubar_runcat`, **Apache License 2.0**). 원문 라이선스: `THIRD_PARTY_LICENSE-RunCat.txt`. `assets/cat0~4.png`가 원본 프레임.
- 속도 매핑 공식도 RunCat 코드(`Menubar RunCat/AppDelegate.swift`의 `updateUsage`)를 그대로 채택.

## 왜 RunCat으로는 안 되나 (확정)
- RunCat은 **앱스토어 앱 = 샌드박스**라 GPU·온도 정보 접근이 원천 차단됨. 개발자가 공식 FAQ에서
  "그래서 GPU 기능 넣을 계획 없다"고 명시. (출처: https://kyome.io/runcat/index.html?lang=en)
- 결론: **GPU에 반응시키려면 앱스토어 밖 도구**여야 함.

## 핵심 발견 (검증 완료)
- **GPU 사용률을 sudo 없이 읽을 수 있다** (Apple Silicon, IOKit `IOAccelerator`).
- ⚠️ **지표 선택이 핵심 (한 번 거꾸로 짚었다가 정정함):**
  - `"Device Utilization %"` = **컴퓨트(Metal/MPS) 포함 전체 GPU 점유율.** ML·임베딩이 바로 이걸 올림.
    → **ML 작업엔 이게 맞는 지표.** (README 원래 가정이 옳았음.)
  - `"Renderer Utilization %"` / `"Tiler Utilization %"` = **그래픽(래스터/지오메트리) 파이프라인 전용.**
    순수 컴퓨트(임베딩) 땐 ~0으로 떨어짐 → **이걸 쓰면 정작 원하는 GPU 작업 때 고양이가 한가해 보임** (함정).
  - **교차검증:** 활성 상태 보기에서 임베딩 python = **GPU 93.4%** (GPU 시간 47분/실행 51분 ≈ 지속) ↔
    같은 시각 ioreg `Device`=100, `Renderer`=13. → Device가 활성 상태 보기와 일치.
  - 한때 헷갈린 이유: 임베딩이 51분간 안 멈춰서 "idle 기준"으로 본 순간조차 GPU 90%였음 → Device=100이 "고정"처럼 보였을 뿐.
  ```bash
  # 컴퓨트 부하(임베딩 등)는 Device에서 보임. Renderer/Tiler는 그래픽일 때만.
  ioreg -r -d 1 -w 0 -c IOAccelerator | tr ',' '\n' \
    | grep -oE '"(Device|Renderer|Tiler) Utilization %"=[0-9]*'
  ```
  - 코드: GPU 지표 = **`max(Device%, Renderer%, Tiler%)`** (컴퓨트+그래픽 둘 다 잡게), 없으면 `GPU Activity(%)` fallback. (`UsageReader.swift:deviceUsage`)
  - 남은 검증: **GPU가 진짜 idle일 때 Device%가 내려가는지** 아직 직접 못 봄(임베딩이 계속 돌아서). 임베딩 끝나면 확인할 것.
- CPU 사용률: 맥 커널 API(`host_statistics`, HOST_CPU_LOAD_INFO 틱 델타).
- → 표시 기준 = **max(CPU%, GPU%)** 로 잡으면 "뭐든 바쁘면 빨리".

## RunCat 작동 원리 (참고 — 이걸 본떠 만들면 됨)
- 네이티브 **Swift** 메뉴바 앱. `NSStatusItem`에 고양이 **프레임 그림 여러 장**을 타이머로
  빠르게 갈아끼워 애니메이션(플립북). 타이머 간격 ∝ 1/CPU% (바쁠수록 빨리).
- 개발자가 **축소판을 오픈소스로 공개**: https://github.com/Kyome22/menubar_runcat

## 채택한 길: B. 네이티브 (★추천대로)
- `Kyome22/menubar_runcat`를 **포크하지 않고**, 같은 원리로 처음부터 직접 작성(의존성 0, SwiftPM 실행 타깃).
- CPU/GPU를 직접 읽어 `max(CPU,GPU)`에 프레임 타이머를 연동. **앱스토어 밖 빌드 = 샌드박스 없음 → GPU 읽힘.**
- 고양이는 외부 스프라이트 대신 **코드로 그림**(CatRenderer) → 라이선스/에셋 관리 불필요, 템플릿 이미지라 다크/라이트 자동 대응.
- (A SwiftBar 안은 미채택 — 네이티브가 더 부드럽고 설치도 필요 없어서.)

## 남은 옵션 (원하면)
- **로그인 시 자동 실행:** 시스템 설정 → 일반 → 로그인 항목에 `BusyCat.app` 추가 (또는 `SMAppService`로 메뉴 토글 추가 가능).
- 동물/색/속도 곡선 커스터마이즈, GPU 메모리 표시, 토글(예: CPU만/GPU만) 등.

## 메모
- 이 프로젝트는 stocklab4(퀀트 연구)와 무관한 곁가지. 메인은 stocklab4 임베딩 연구.
- 빌드/실행에 추가 설치 없었음(맥 기본 Swift 툴체인만 사용). SwiftBar/brew 불필요.
