# BusyCat 1.1.6 — Final maintenance release / 최종 유지보수 릴리스

This release wraps up active development. No further release or support schedule
is promised; the source remains available for possible future resumption.
There is no 1.2.0 release planned.

## Changes

- Fix stale CPU/GPU averages when sampling resumes and discard graph history and
  in-flight results across sleep/wake boundaries.
- Restore the update menu after language changes during background update checks.
- Wrap long IPv6 addresses; correct signed temperature decoding and bounded
  subprocess output collection.
- Improve metric edge cases, version parsing, selective sampling and installation
  safeguards; include licenses and extend regression coverage.
- Add final DMG/Homebrew checksum validation and clean, tested-commit packaging checks.

## Installation and limitations

Apple Silicon (M1 or newer), macOS 13 or later. Intel Macs are not supported.
**Not notarized and not Developer ID signed.** The app is ad-hoc signed. macOS may
block the first launch. Only if you trust this download, use System Settings →
Privacy & Security → Open Anyway. Do not disable Gatekeeper globally.
Quit the running app, open the DMG and drag BusyCat.app to Applications to replace
the old copy. Updates remain manual; BusyCat only notifies about releases.

Regression tests pass, but long-duration use, real sleep/reboot cycles and full
macOS 13 device validation are not claimed. GPU compute is an estimate and
temperature availability varies by hardware/OS. See [handoff notes](HANDOFF.md).

---

이번 1.1.6으로 적극적인 개발을 종료합니다. 추가 릴리스·지원 일정은 약속하지
않으며, 필요 시 재개할 수 있도록 소스를 남깁니다. 1.2.0 배포 계획은 없습니다.

CPU/GPU 측정 재개·잠자기 전후 그래프, 언어 변경 중 업데이트 메뉴, 긴 IPv6 표시,
온도값 부호와 외부 명령 출력 처리 등을 수정했습니다. 측정·버전 파싱의 예외 처리,
설치 안전장치, 라이선스 포함과 테스트·배포 해시 검사도 보완했습니다.

**Apple Silicon / macOS 13 이상 전용, 미공증·애드혹 서명 배포본입니다.**
다운로드를 신뢰하는 경우에만 시스템 설정 → 개인정보 보호 및 보안 → 그래도 열기를
이용하세요. 시스템 보안 기능 전체를 끄지 마세요.
실행 중인 앱을 종료한 뒤 DMG의 BusyCat.app을 Applications로 드래그해 교체합니다.

장기 사용·실제 잠자기/재부팅·macOS 13 실기기 전체 검증까지 완료했다는 의미는
아닙니다. GPU 연산 부하는 추정치이며 온도 센서는 기종/OS별로 다를 수 있습니다.
