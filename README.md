# QualityBadge

Spotify 플레이어 재생바(시간 표시) 가운데에 음질 배지를 표시합니다.

| Spotify 설정 | 배지 |
|---|---|
| 낮음 | 데이터 절약 |
| 보통 | 일반음질 |
| 높음 | 고음질 |
| 매우 높음 | 무손실 |

Vitrine의 로컬 FLAC 재생 중에는 자동으로 "무손실"로 표시됩니다.
Wi‑Fi에서는 Wi‑Fi 음질 설정을, 셀룰러에서는 셀룰러 음질 설정을 따릅니다.

## 빌드 (GitHub Actions)
1. GitHub에서 새 **public** 저장소를 만듭니다.
2. 이 폴더의 `QualityBadge.m`, `README.md`, `.github/workflows/build.yml` 을 그대로(폴더 구조 포함) 업로드합니다.
3. 저장소의 **Actions** 탭 → **Build QualityBadge** → **Run workflow**.
4. 끝나면 실행 결과 화면 맨 아래 **Artifacts**에서 `QualityBadge`를 받아 압축을 풀면 `QualityBadge.dylib`이 나옵니다.

## 설치
Sideloadly 등으로 서명할 때, Vitrine IPA에 `QualityBadge.dylib`을 **추가로 주입(inject)** 해서 설치합니다.
