# MyKeyMapping

macOS에서 자주 쓰는 문구를 키 조합으로 입력하고, 설정 창에서 바로 수정하는 앱입니다.

## 다운로드 및 설치

[최신 GitHub Release](https://github.com/choijhyeok/my-key-mapping/releases/latest)에서 **MyKeyMapping.pkg**를 받으세요. macOS 13 이상, Apple Silicon과 Intel Mac을 지원합니다.

1. `.pkg`를 열어 설치한 뒤 **응용 프로그램 → MyKeyMapping**을 실행하세요. `.zip`을 사용하면 압축을 풀고 앱을 응용 프로그램으로 옮기면 됩니다.
2. **설치 및 실행**을 누르세요. 필요한 앱과 로그인 자동 실행을 현재 사용자에게 설정합니다.
3. **입력 권한 설정**을 누르고, 손쉬운 사용에서 Finder에 선택된 **PhraseTyper.app**을 추가해 켜세요.
4. **설치 및 실행**을 다시 눌러 허용된 권한으로 시작하세요.

Apple Developer ID 서명 및 공증이 없는 배포판입니다. macOS가 설치나 실행을 차단하면 시스템 설정 → 개인정보 보호 및 보안에서 해당 앱의 **확인 없이 열기**를 허용하세요. 앱 바이너리가 변경되는 업데이트는 기존 승인 기록을 이 앱에 한해 초기화하므로 입력 권한을 다시 허용해야 합니다.

## 사용법

- **Control + Option + Command + 숫자**: 숫자에 지정된 문구를 입력합니다. 키를 모두 놓은 뒤 입력하며 Enter는 보내지 않습니다.
- **Control + Option + Command 3초 유지**: Fn+1~0의 문구 목록과 편집 창을 엽니다. 다른 키를 함께 누르면 창 열기를 취소합니다.
- 문구를 고치고 **저장**하면 자동 입력 도우미에 반영합니다. **닫기**만 누르면 저장하지 않습니다.
- 메뉴 막대의 **문구 → Fn 문구 보기 및 수정…**에서도 설정 창을 열 수 있습니다.

| 숫자 | 기본 문구 |
| --- | --- |
| 1 | push pr 진행 |
| 2 | 알려줘 |
| 3 | 계속해줘 |
| 4 | 진행해줘 |
| 5 | 확인해줘 |
| 6 | artifact 확인 |
| 7 | 확인해봐 |
| 8 | 반영해줘 |
| 9 | 신규 이슈 발급해줘 |
| 0 | 수정해줘 |

문구는 `~/Library/Application Support/MyKeyMapping/phrases.json`에 저장하며 업데이트 시 유지합니다. 프로그램 시작 때 읽으므로 파일을 직접 수정했다면 MyKeyMapping에서 **설치 및 실행**을 다시 누르세요.

### Vial에서 Fn+숫자 연결

설치 프로그램은 키보드 펌웨어를 자동 변경하지 않습니다. Vial에서 Fn 레이어의 숫자키를 **왼쪽 Control + Option + Command + 해당 숫자**로 지정하면 Fn+숫자를 사용할 수 있습니다. Any Key에 입력할 QMK 키코드는 숫자 1~0 순으로 `0x0D1E`~`0x0D27`입니다. 변경 전에 Vial의 Save로 원본 키맵을 보관하세요.

`Sources/VialSetup.swift`는 KabeDon NocFree 65 유선 모델용 보조 도구입니다. 다른 모델에 사용하지 마세요. Vial을 종료한 뒤 프로젝트 루트에서 `backup` → `plan`을 실행해 계획을 확인하고 `apply`합니다. 전체 키맵을 다시 읽어 지정한 10개 위치만 변경됐는지 확인합니다. 로컬 `backups/`는 Git에 올리지 않습니다.

### 제거 및 키보드 복원

프로젝트에서 만든 NocFree 키맵 백업이 있다면 Vial을 종료하고 `zsh scripts/rollback.sh`를 실행하세요. 이후 바꾼 키를 보존하면서 이 설정이 설치한 키만 원복하고 도우미를 제거합니다.

배포 앱만 제거하려면 다음 명령으로 현재 사용자의 자동 실행을 중단한 뒤 MyKeyMapping.app과 `~/Library/Application Support/MyKeyMapping`의 앱을 지우세요. 문구를 보관하려면 `phrases.json`은 남겨 두세요.

```sh
launchctl bootout gui/$(id -u)/com.jaehyeokchoi.MyKeyMapping.PhraseTyper
launchctl bootout gui/$(id -u)/com.jaehyeokchoi.MyKeyMapping.PhraseSettings
```

`~/Library/LaunchAgents`에서 이 두 이름의 `.plist`를 제거하면 다음 로그인에 시작하지 않습니다. 앱 제거는 키보드 매핑을 바꾸지 않으므로 Vial 키맵은 원래 Save 파일로 복원하세요.

## 개발 및 릴리스

소스 검증과 범용 설치 파일 생성에는 macOS와 Xcode Command Line Tools의 Swift, Python 3가 필요합니다. 배포 앱 실행에는 개발 도구가 필요하지 않습니다.

```sh
python3 scripts/check.py
python3 scripts/package-installer.py
```

`dist/`에 범용 앱, `.pkg`, `.zip`, SHA-256 체크섬을 만듭니다. 빌드 과정은 현재 설치된 앱, 문구 파일, 키보드 설정을 바꾸지 않습니다.

`main`에 push하면 CI가 검증합니다. `v0.1.0` 같은 버전 태그를 push하면 GitHub Actions가 검증·빌드 후 GitHub Release에 파일을 업로드합니다. `VERSION`은 로컬 빌드의 기본 버전이며 태그 빌드는 태그의 버전을 사용합니다.

`analysis/analyze_history.py`는 로컬 Codex 기록에서 짧은 한국어 요청의 표현 빈도를 집계하는 선택적 개발 도구입니다. 원문은 내보내지 않으며 개인 집계 결과와 장치 백업은 공개 저장소 및 배포 파일에서 제외합니다.
