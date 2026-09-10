# 물리 모델 · 구현 · 검증 기록

[프로젝트 소개로 돌아가기](../README.md) · [v1.1 새 시나리오 가이드](SCENARIOS.md)

SwiftUI + Metal로 만든 iOS / macOS 은하 충돌 시뮬레이션입니다. 별과 암흑물질 **모든 입자가 중력원**이며, 물질 분포가 바뀔 때마다 중력장을 다시 계산합니다. 외부 패키지 의존성은 없습니다.

## 실행

- Xcode 15 이상, iOS 17 이상 / macOS 14 이상, Metal 지원 기기.
- `GalaxyCollision.xcodeproj` → `GalaxyCollision` scheme → My Mac 또는 iPhone/iPad.
- iOS 실기기에는 Signing & Capabilities에서 본인의 Development Team을 지정합니다.
- 프로젝트 설정은 `project.yml`에 있으며 수정 후 `xcodegen generate`를 실행합니다. 생성된 프로젝트도 포함되어 있어 일반 빌드에는 XcodeGen이 필요하지 않습니다.

## 조작과 입자 수

- 재생 / 일시 정지, 처음부터 다시 시작. macOS 단축키: Space / R.
- 드래그로 회전, 핀치 또는 확대 슬라이더로 확대. 밝기, 위에서 보기, 시점 초기화.
- 조석 꼬리 / 정면 충돌 / 스쳐 지나가기 / **단독 은하 검증**.
- 별 입자 8,192 / 16,384 / 32,768 / 65,536개. 같은 수의 암흑물질 입자가 추가됩니다. 최대 **131,072개 질량 입자**가 서로 영향을 줍니다.
- 기본값: iOS 별 8,192 + 암흑물질 8,192개, macOS 각각 16,384개.
- 입자 하나는 여러 별 또는 암흑물질의 질량을 대표합니다. 표시된 별 수가 실제 개별 항성의 수를 뜻하지는 않습니다. 입자 수를 바꿔도 은하의 총질량은 유지됩니다.
- `암흑물질 분포 보기`는 보이지 않는 질량을 시각화합니다. 꺼도 중력에는 계속 기여합니다. 파랑/주황은 출신 은하를 구분하는 색입니다.
- 고정 시간 간격으로 진행하며 실제 진행 속도는 GPU의 물리 계산 처리량에 따라 달라집니다. SIM TIME으로 계산된 시간을 확인할 수 있습니다. 입자 수나 시나리오 변경 시 재시작합니다. 단독 은하로 바꾸면 시점을 자동으로 확대합니다.
- 좁은 화면에서는 설정 패널이 아래에 표시되며 우측 상단 버튼으로 접을 수 있습니다.

## 물리 모델

**Collisionless, self-gravitating N-body** 모델입니다. 고정된 중심 중력장이나 정해진 합병 경로는 없습니다. 감속 계수를 붙여서 합병시키지도 않습니다. 별과 헤일로의 집단적인 중력 상호작용을 통해 궤도 에너지가 내부 운동과 흩어지는 물질로 전달될 수 있습니다.

기본 원반 은하는 다음 두 성분으로 초기화합니다. 새 시나리오의 다른 질량·구형 모델은 [별도 가이드](SCENARIOS.md)를 참고하세요. 모든 수치는 G = 1인 무차원 단위입니다.

| 성분 | 질량 | 초기 분포와 속도 |
|---|---:|---|
| 별 원반 | 3 | 척도 길이 1의 지수 표면밀도, 반지름 7에서 절단, 수직 sech² 분포(척도 높이 0.2). 원형 운동에 반경·방위·수직 속도 분산을 추가합니다. |
| 암흑물질 | 17 | 척도 길이 3의 Hernquist 밀도에 exp[-(r/18)²]를 곱해 외곽을 완만하게 줄인 구형 헤일로. |

별의 반지름은 면적 요소를 포함한 `p(R) ∝ R exp(-R)`로 샘플링합니다. 회전 속도는 원반의 고리 적분과 헤일로 질량 분포에서 구하며, 속도 분산에는 Q≈1.6의 근사 처방과 asymmetric drift 보정을 사용합니다. 실제 이산 입자계에서 모든 반지름의 Q가 정확히 1.6이라는 뜻은 아닙니다.

헤일로 속도는 헤일로 + 구형으로 평균한 원반의 퍼텐셜에서 **Eddington 역산**으로 구한 등방성 분포함수를 샘플링합니다. 밀도/속도 테이블은 CPU에서 한 번 계산하고 GPU에 올립니다. 실제 원반은 납작하므로 전체 모델은 근사 평형이며, 단독 은하 테스트가 필요합니다. 입자 쌍의 위치와 속도를 반전해 초기 질량중심과 총운동량의 표본 잡음을 줄입니다.

기본 충돌은 중심 간 거리 24, 중심 속도 `(±0.67, ∓0.39, 0)`에서 시작하는 결합된 비스듬한 접근입니다. 원반의 기울기는 각각 0.12 / 0.5 라디안입니다. 이 초기 속도는 물질이 있는 실제 확장 은하계의 정확한 포물선 궤도라는 뜻은 아닙니다.

적분은 고정 시간 간격 1/60의 kick–drift–kick leapfrog입니다. 모든 입자 쌍에는 Plummer softening 0.15를 사용합니다. 근접 항성 충돌 자체를 계산하는 모델은 아닙니다.

## GPU 중력 계산

고정 깊이의 공간 격자를 **입자 분포에 맞춘 compact binary radix tree(LBVH)**로 교체했습니다. N개 입자에 잎 N개와 내부 노드 N−1개만 사용합니다. 이전처럼 밀집한 공간 칸 하나에 많은 입자를 넣고 그 칸의 모든 입자 쌍을 직접 계산하지 않습니다.

1. 모든 입자의 실제 위치에서 경계 상자를 GPU로 갱신합니다. 멀리 빠져나간 입자도 포함합니다.
2. 각 입자에 63비트 Morton 위치 키와 고유 ID를 붙이고 GPU bitonic sort로 정렬합니다. 같은 위치의 입자도 ID로 구분합니다.
3. 정렬된 키의 공통 접두사로 모든 내부 노드의 자식과 입자 범위를 병렬로 구성합니다. 입자가 밀집한 곳도 입자 하나당 잎 하나까지 나뉩니다.
4. 접두사 순서로 별도 패스를 실행해 질량·질량중심·질량의 2차 중심 모멘트·실제 경계 상자를 아래에서 위로 합산합니다. 패스 사이의 자원 추적으로 쓰기 완료를 보장하며, GPU 스핀 대기는 사용하지 않습니다.
5. 미리 계산한 다음 노드 인덱스로 스택 없이 순회합니다. 실제 노드 경계 상자의 대각선 길이를 `size`로 삼고, `size / distance < 0.7`인 먼 노드는 질량과 질량 분포의 사중극자(quadrupole) 보정으로 근사합니다. 대상 입자를 포함한 노드는 항상 열고 자기 힘은 제외합니다.
6. 새 분포의 힘을 모두 구한 뒤 다음 반 스텝의 속도를 갱신합니다. 같은 큐에서 순서를 유지하며 힘 계산은 8,192개 대상 입자 단위로 제출합니다.

사중극자 보정은 질량이 각 방향으로 퍼진 정도를 반영해 먼 노드를 덜 세분화하고도 정확도를 유지하도록 합니다. 6개 독립 성분의 2차 중심 모멘트를 합산하며, Plummer softening을 적용한 퍼텐셜의 2차 전개에서 trace 항까지 유지합니다. 잎에서는 기존의 정확한 두 입자 상호작용을 사용합니다.

위치 키는 정렬을 위한 것으로 물리적 위치를 양자화하지 않습니다. 힘에는 원래 부동소수점 위치와 Plummer softening을 사용합니다. 63비트 위치 키는 먼 입자 때문에 경계가 넓어질 때 중심부의 정렬 해상도가 떨어지는 문제도 줄입니다.

앱의 위치·속도·중력·트리 버퍼는 GPU private storage에 머뭅니다. 매 프레임 CPU로 위치를 읽지 않습니다. 트리 관련 버퍼는 기본 32,768개 질량 입자에서 약 **6.6 MiB**, 최대 131,072개에서 약 **26.5 MiB**입니다. 이전 구조의 고정 약 70 MiB보다 작으며, 입자와 렌더/녹화 버퍼는 별도입니다.

정렬은 O(N log²N) bitonic sort입니다. 트리 순회 비용은 분포와 opening criterion에 따라 달라지며 모든 분포에서 O(N log N)을 보장하지는 않습니다. 입자를 반사·주기적으로 되돌리거나 제거하지 않습니다.

최대 3프레임을 제출합니다. GPU 완료 시간을 바탕으로 긴 물리 계산은 한 프레임에 1회씩, 충분히 빠른 경우에는 최대 2회까지 처리합니다. 과부하일 때는 시뮬레이션이 벽시계보다 느려집니다. SIM TIME이 실제 계산된 시간이며, FPS는 제출된 화면 프레임 빈도입니다. 높은 입자 설정에서는 여전히 속도가 느려질 수 있습니다.

별빛은 RGBA16Float 타깃에 누적한 후 Reinhard tone mapping으로 화면과 녹화 영상에 출력합니다. 과도한 밝기가 바로 잘리는 현상을 줄이기 위한 시각화이며, 관측 장비의 광도나 스펙트럼을 재현하지는 않습니다.

## 녹화

- 하단 **녹화**(원형 아이콘) → **녹화 종료**(사각형 아이콘) → 미리보기 → **파일로 저장** 또는 **공유**.
- 재생 화면 아이콘으로 최근 녹화를 다시 엽니다.
- 은하 화면만 무음 H.264 MP4로 녹화합니다. 조작 패널·텍스트는 포함하지 않습니다. 화면 캡처/마이크 권한은 필요하지 않습니다.
- 최대 30 fps, 긴 변 최대 1,920px이며 시작 시점의 영상 해상도를 유지합니다. 회전·확대·시나리오 전환과 암흑물질 표시가 반영됩니다.
- 시뮬레이션 일시 정지 중에도 녹화는 계속됩니다. 앱이 비활성화되거나 창이 닫히면 녹화를 종료합니다. 강제 종료하면 진행 중인 녹화가 복구되지 않을 수 있습니다.
- 완성된 녹화는 앱의 Application Support `GalaxyLab/Recordings`에 보관합니다. 최근 녹화는 앱 재실행 후에도 열 수 있습니다.
- 인코더가 밀리면 프레임을 생략하고 실제 시간 간격을 유지합니다. 녹화는 추가 GPU 작업과 메모리를 사용합니다.

## 검증

```sh
swift test
xcodebuild -project GalaxyCollision.xcodeproj -scheme GalaxyCollision -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project GalaxyCollision.xcodeproj -scheme GalaxyCollision -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
swiftc -O GalaxyCollision/Physics/Encounter.swift GalaxyCollision/Physics/M51Model.swift GalaxyCollision/Physics/EquilibriumTables.swift GalaxyCollision/Rendering/GalaxyDynamics.swift Scripts/MetalSmoke.swift -o /tmp/galaxy-live-smoke
/tmp/galaxy-live-smoke
GALAXY_TEST_COLLISION=1 GALAXY_TEST_STEPS=6000 /tmp/galaxy-live-smoke
swiftc -O GalaxyCollision/Physics/Encounter.swift GalaxyCollision/Physics/M51Model.swift GalaxyCollision/Physics/EquilibriumTables.swift GalaxyCollision/Rendering/GalaxyDynamics.swift Scripts/GravityBenchmark.swift -o /tmp/galaxy-gravity-benchmark
/tmp/galaxy-gravity-benchmark
swiftc -O GalaxyCollision/Physics/Encounter.swift GalaxyCollision/Physics/M51Model.swift GalaxyCollision/Physics/EquilibriumTables.swift GalaxyCollision/Rendering/GalaxyDynamics.swift Scripts/GravityAccuracy.swift -o /tmp/galaxy-gravity-accuracy
/tmp/galaxy-gravity-accuracy
swiftc -parse-as-library GalaxyCollision/Recording/GalaxyRecorder.swift Scripts/RecordingSmoke.swift -o /tmp/galaxy-recording-smoke
/tmp/galaxy-recording-smoke
```

`GALAXY_TEST_STARS` / `GALAXY_TEST_STEPS`로 GPU 검증의 입자 수와 진행 길이를 조절할 수 있습니다. 기본값은 별 8,192 + 헤일로 8,192개, 1,800스텝입니다. 이 검증은 렌더링 FPS 벤치마크가 아닙니다.

### 측정 결과 — Apple M2 Pro, 2026-09-09–10

- Swift 테스트 15개(M51 단위·궤도·팽대부와 쿼터니언 트랙볼 검증 포함): 초기 조건 테이블의 유한성/단조성, 데이터 레이아웃, 단독 은하/충돌 초기 조건.
- GPU 힘 검증: 1,024개 입자에서 직접 합산 대비 상대 RMS 오차 약 **0.34%**. 별도 CPU 두 입자 해석해, 자기 힘 제외, 트리의 총질량, 실제 질량 입자 이동에 대한 중력 반응도 확인. 동일 위치, 밀집 입자 + 먼 입자, 2의 거듭제곱이 아닌 개수도 검사하며 직접 합산 대비 RMS 오차는 모두 1% 미만입니다.
- 단독 은하: 1,800스텝(30 시간 단위) 후 원반 반질량 반지름 **+3.1%**, 수직 RMS 두께 **+17.7%**, 헤일로 반질량 반지름 **−0.34%**, 총에너지 변화 **0.00083%**. 두께 변화는 0이 아니며 근사 초기 조건/이산 입자 효과의 한계입니다.
- 기본 충돌: 6,000스텝(약 100 시간 단위)을 GPU 오류 없이 통과. 처음 중심부에 있던 별들의 두 질량중심 간 거리가 **24 → 약 0.077**, 전체 에너지 변화 약 **0.0046%**. 이 중심 추적 지표 하나만으로 모든 물질이 합쳐졌다고 판정하지는 않습니다.
- 녹화 검증: 실제 GPU 픽셀을 H.264로 인코딩하고 디코딩해 색상·길이·해상도를 확인했습니다. 새 렌더링을 사용한 macOS 앱에서도 MP4 저장과 미리보기 재생을 확인했습니다. 즉시 종료, 미완료 GPU 프레임, 크기 변경, GPU 오류와 최근 영상 재로드도 검사합니다.

안정성/충돌 수치는 별 8,192 + 헤일로 8,192개에서 측정했습니다. 총에너지는 같은 softened tree 퍼텐셜을 사용해 평가합니다. 최대 131,072개 질량 입자는 초기 분포와 밀집 + 먼 입자 분포에서 512개 대상의 직접 합산 비교와 60스텝 적분을 확인했으며, 최대 설정의 장시간 수렴 검증까지 수행한 것은 아닙니다.

이 수치는 정해진 초기 조건과 입자 수의 수치 검증입니다. 관측 은하에 대한 적합도 검증이나 광범위한 해상도 수렴 연구를 수행한 것은 아닙니다. macOS, iOS Simulator, iOS 기기용 빌드가 통과했고 iOS Simulator에서 실행 화면을 확인했습니다. iPhone/iPad 실기기의 성능·발열·녹화는 별도 확인이 필요합니다.

## 성능 비교 — Apple M2 Pro

별 65,536 + 암흑물질 65,536개에서 단극자 LBVH(θ=0.38)의 중력 재계산은 약 **250ms**, 사중극자 보정을 추가한 LBVH(θ=0.7)는 약 **75ms**였습니다. 같은 초기 조건에서 약 **3.3배** 개선이며 입자 수와 적분 시간 간격은 유지했습니다. 1,024개 입자의 직접 합산 대비 힘 RMS 오차는 기존 약 0.42%, 새 방식 약 0.34%입니다. 최대 설정에서도 512개 대상 입자에 대해 나머지 모든 입자의 힘을 직접 합산해 비교했으며, 초기 충돌 분포 RMS 오차 약 **0.055%**, 밀집 + 먼 입자 분포 약 **0.048%**였습니다. 이는 표본 검사이며 모든 입자의 개별 오차 상한을 뜻하지 않습니다. CPU Double 합산으로 트리의 2차 중심 모멘트도 검증했습니다. macOS 앱의 별 65,536개 정면 충돌 초기 구간에서 약 **14 FPS**를 관찰했습니다(이전 약 4 FPS). 장면과 GPU 부하에 따라 달라집니다.

`GravityBenchmark.swift`는 2회 준비 실행 후 7회 중앙값을 출력합니다. GPU 시간과 CPU 인코딩·대기를 포함한 전체 벽시계 시간을 구분합니다. `GALAXY_BENCH_STARS=16384`처럼 입자 수를 제한할 수 있습니다. GPU 클럭과 다른 작업의 부하에 따라 값은 달라지며 아래 수치는 앱의 렌더링 FPS를 뜻하지 않습니다.

| 별 + 암흑물질 합계 | 초기 충돌 분포의 중력 계산 | 밀집 + 먼 입자 분포의 중력 계산 |
|---:|---:|---:|
| 16,384 | 약 11ms | 약 8ms |
| 32,768 | 약 15ms | 약 16ms |
| 65,536 | 약 33ms | 약 33ms |
| 131,072 | 약 75ms | 약 70ms |

밀집 검사는 초기 위치를 0.05배로 압축하고 두 암흑물질 입자를 x=±500에 둔 계산 스트레스 검사입니다. 물리적 평형 은하를 의미하지 않습니다.

## 남아 있는 물리적 한계

가스 유체역학, 냉각, 별 생성, 피드백, 블랙홀은 없습니다. 구형 평균 퍼텐셜에 기반한 헤일로와 원반 속도 처방은 완전한 축대칭 평형 해가 아닙니다. 중력은 사중극자 보정을 포함한 트리 근사이고 softening보다 작은 구조를 해석할 수 없습니다. 따라서 집단 중력과 합병 과정을 관찰하는 교육용 모델이며 실제 특정 은하의 미래를 정밀 예측하는 연구용 모델은 아닙니다.

참고: [Barnes & Hut 계열 트리 코드](https://home.ifa.hawaii.edu/users/barnes/pub.html), [galpy의 Eddington 역산 설명](https://docs.galpy.org/en/latest/reference/dfeddington.html), [평형 은하 초기 조건의 중요성](https://arxiv.org/abs/1402.1623), [NASA/ESA의 은하 충돌 시각화](https://esahubble.org/videos/gal_coll_dome_3800/).

트리 구현 참고: [Karras, HPG 2012 — Parallel construction of binary radix trees](https://research.nvidia.com/publication/2012-06_maximizing-parallelism-construction-bvhs-octrees-and-k-d-trees).

### M51 확장 (v1.2)

별 입자 예산 안에 팽대부를 추가했습니다. 팽대부와 헤일로는 각각의 밀도에 대해 원반+팽대부+헤일로의 총 구형화 퍼텐셜에서 속도 분포를 구합니다. GPU 초기화는 두 성분의 별도 반지름·속도 표를 사용합니다. Swift/Metal 공통 DynamicsUniforms는 208바이트이며 기존 필드 오프셋은 유지합니다. 상세 물리 수치와 검증은 [M51.md](M51.md)에 있습니다.
